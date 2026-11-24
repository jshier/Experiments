internal import Bytes

/// The container a DEFLATE (RFC 1951) stream comes in.
public enum DeflateFormat: Hashable, Sendable {
    /// Bare DEFLATE, as in zip entries and PNG's chunks after their own framing.
    case raw
    /// zlib (RFC 1950): a 2-byte header, DEFLATE, then the Adler-32 of the data. HTTP's
    /// `Content-Encoding: deflate`.
    case zlib
    /// gzip (RFC 1952): a 10-byte or longer header, DEFLATE, then the CRC-32 and length of the data. HTTP's
    /// `Content-Encoding: gzip`.
    case gzip
}

// The containers' checksums, headers, and trailers, for every DEFLATE encoder and decoder here (sequential and
// parallel). Reading a gzip header's optional fields stays in `InflateStream`, which reads them as they arrive.
extension DeflateFormat {
    /// The checksum of no data: Adler-32's 1 for zlib, 0 otherwise.
    var initialChecksum: UInt32 { self == .zlib ? 1 : 0 }

    /// The container's checksum of `bytes`, continuing `value`: Adler-32 for zlib, CRC-32 for gzip, `value`
    /// unchanged for raw DEFLATE.
    @inline(__always)
    func checksum(_ bytes: RawSpan, continuing value: UInt32) -> UInt32 {
        switch self {
        case .raw: value
        case .zlib: Adler32.checksum(bytes, continuing: value)
        case .gzip: CRC32.checksum(bytes, continuing: value)
        }
    }

    /// The container's checksum of `bytes` alone.
    func checksum(_ bytes: RawSpan) -> UInt32 {
        checksum(bytes, continuing: initialChecksum)
    }

    /// The checksum of two pieces end to end, from each piece's and the second's length.
    func combine(_ first: UInt32, _ second: UInt32, secondLength: Int) -> UInt32 {
        switch self {
        case .raw: 0
        case .zlib: Adler32.combine(first, second, secondLength: secondLength)
        case .gzip: CRC32.combine(first, second, secondLength: secondLength)
        }
    }

    /// The header an encoder writes: nothing for raw DEFLATE; zlib's 2 bytes (DEFLATE, a 32 KB window, `level`'s
    /// class); gzip's 10 (no flags, no time, the extra flags for the slowest and fastest levels, unknown OS).
    ///
    /// - Parameter level: The compression level, 0 through 12.
    /// - Returns: The bytes, and how many there are.
    func header(level: Int) -> (bytes: InlineArray<16, UInt8>, count: Int) {
        var bytes = InlineArray<16, UInt8>(repeating: 0)
        switch self {
        case .raw:
            return (bytes, 0)
        case .zlib:
            let header = ZlibHeader.header(level: level)
            bytes[0] = UInt8(header >> 8)
            bytes[1] = UInt8(header & 0xFF)
            return (bytes, 2)
        case .gzip:
            // Magic, DEFLATE, no flags, no time, extra flags (2 slowest, 4 fastest), unknown OS.
            let header: InlineArray<10, UInt8> = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, level >= 8 ? 2 : level <= 1 ? 4 : 0, 255]
            for index in 0..<10 {
                bytes[index] = header[index]
            }
            return (bytes, 10)
        }
    }

    /// The trailer's size: 0, 4 (zlib's Adler-32), or 8 (gzip's CRC-32 and length).
    var trailerSize: Int {
        switch self {
        case .raw: 0
        case .zlib: 4
        case .gzip: 8
        }
    }

    /// The trailer: the checksum (big-endian for zlib), and for gzip the length modulo 2^32 (both little-endian).
    ///
    /// - Returns: The bytes, and how many there are (``trailerSize``).
    func trailer(checksum: UInt32, length: UInt32) -> (bytes: InlineArray<16, UInt8>, count: Int) {
        var bytes = InlineArray<16, UInt8>(repeating: 0)
        switch self {
        case .raw:
            break
        case .zlib:
            for index in 0..<4 {
                bytes[index] = UInt8(truncatingIfNeeded: checksum &>> (24 &- 8 &* index))
            }
        case .gzip:
            for index in 0..<4 {
                bytes[index] = UInt8(truncatingIfNeeded: checksum &>> (8 &* index))
                bytes[4 &+ index] = UInt8(truncatingIfNeeded: length &>> (8 &* index))
            }
        }
        return (bytes, trailerSize)
    }

    /// Whether `bytes`, ``trailerSize`` of them, are the trailer of output with `checksum` and `length`.
    func trailerMatches(_ bytes: RawSpan, checksum: UInt32, length: UInt32) -> Bool {
        guard bytes.byteCount == trailerSize else { return false }
        switch self {
        case .raw:
            return true
        case .zlib:
            return UInt32(bigEndian: bytes.load(fromByteOffset: 0, as: UInt32.self)) == checksum
        case .gzip:
            return UInt32(littleEndian: bytes.load(fromByteOffset: 0, as: UInt32.self)) == checksum
                && UInt32(littleEndian: bytes.load(fromByteOffset: 4, as: UInt32.self)) == length
        }
    }
}

/// Which code a raw stream uses: DEFLATE (RFC 1951), or PKWARE's Deflate64.
///
/// Deflate64 ("enhanced deflate", zip method 9) is DEFLATE with three changes: a 64 KB window; length symbol 285
/// followed by 16 extra bits, for matches of 3 to 65,538 bytes (DEFLATE's 285 is exactly 258); and distance symbols
/// 30 and 31, with 14 extra bits each, reaching 32,769 to 65,536 bytes back. Block structure and headers are
/// DEFLATE's. It only comes raw, in zip entries: ``DeflateDecoder/init(variant:)`` decodes it.
public enum DeflateVariant: Hashable, Sendable {
    /// DEFLATE: a 32 KB window, matches of 3 to 258 bytes.
    case deflate
    /// Deflate64: a 64 KB window, matches of 3 to 65,538 bytes.
    case deflate64

    /// How far back a match can reach, in bytes: the history a decoder keeps (32 KB or 64 KB).
    public var windowSize: Int {
        switch self {
        case .deflate: 32 << 10
        case .deflate64: 64 << 10
        }
    }

    /// The longest match, in bytes: 258 or 65,538.
    public var maximumMatchLength: Int {
        switch self {
        case .deflate: 258
        case .deflate64: 65538
        }
    }
}

/// The zlib header's fields (RFC 1950, 2.2), as one big-endian `UInt16`: CMF (window size, method), then FLG
/// (level, preset dictionary, check bits).
enum ZlibHeader {
    static var windowBits: BitField<Int> { BitField(bits: 12...15) }
    static var method: BitField<Int> { BitField(bits: 8...11) }
    static var level: BitField<Int> { BitField(bits: 6...7) }
    static var presetDictionary: BitFlag { BitFlag(bit: 5) }

    /// DEFLATE with a 32 KB window, `level`'s class, and the check bits that make the header a multiple of 31.
    ///
    /// - Parameter level: The compression level, 0 through 9.
    /// - Returns: The header, big-endian when written.
    static func header(level: Int) -> UInt16 {
        var header: UInt16 = 0
        header[method] = 8
        header[windowBits] = 7
        header[Self.level] = level <= 1 ? 0 : level <= 5 ? 1 : level == 6 ? 2 : 3
        return header | (31 &- header % 31)
    }
}

/// The gzip header's flags byte (RFC 1952, 2.3.1).
enum GzipFlags {
    static var reserved: BitField<Int> { BitField(bits: 5...7) }
    static var comment: BitFlag { BitFlag(bit: 4) }
    static var name: BitFlag { BitFlag(bit: 3) }
    static var extra: BitFlag { BitFlag(bit: 2) }
    static var headerCRC: BitFlag { BitFlag(bit: 1) }
    static var text: BitFlag { BitFlag(bit: 0) }
}

/// A gzip member's header fields (RFC 1952, 2.3.1), as ``DeflateDecoder/gzipHeader`` reports them: the fixed ones,
/// and which optional fields the member has.
///
/// The optional fields' contents (the file name, comment, and extra subfields) are checked by the header CRC when
/// there is one, then skipped: keeping them would need storage of no fixed size, made while streaming.
public struct GzipHeader: Hashable, Sendable {
    /// FTEXT: the encoder thought the data was text.
    public var isText: Bool
    /// FHCRC: the header ends with the low 16 bits of its CRC-32 (verified).
    public var hasHeaderCRC: Bool
    /// FEXTRA: extra subfields follow the fixed fields.
    public var hasExtraField: Bool
    /// FNAME: the original file's name follows, zero-terminated.
    public var hasName: Bool
    /// FCOMMENT: a comment follows, zero-terminated.
    public var hasComment: Bool
    /// MTIME: the original file's modification time in seconds since 1970 (UTC), or 0 for none.
    public var modificationTime: UInt32
    /// XFL: the encoder's extra flags (2 slowest, 4 fastest for DEFLATE).
    public var extraFlags: UInt8
    /// OS: the file system the member was made on (3 Unix, 255 unknown, …).
    public var operatingSystem: UInt8

    /// The fields of a header whose flags byte is `flags`.
    init(flags: Byte, modificationTime: UInt32, extraFlags: UInt8, operatingSystem: UInt8) {
        isText = flags[GzipFlags.text]
        hasHeaderCRC = flags[GzipFlags.headerCRC]
        hasExtraField = flags[GzipFlags.extra]
        hasName = flags[GzipFlags.name]
        hasComment = flags[GzipFlags.comment]
        self.modificationTime = modificationTime
        self.extraFlags = extraFlags
        self.operatingSystem = operatingSystem
    }
}

/// DEFLATE's fixed tables (RFC 1951, 3.2.5 and 3.2.7).
enum Deflate {
    /// The longest match.
    static var maximumMatch: Int { 258 }
    /// The shortest match.
    static var minimumMatch: Int { 3 }
    /// How far back a match can reach.
    static var windowSize: Int { 32768 }

    static var lengthBases: InlineArray<29, UInt16> {
        [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    }

    static var lengthExtraBits: InlineArray<29, UInt8> {
        [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    }

    static var distanceBases: InlineArray<30, UInt16> {
        [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
         4097, 6145, 8193, 12289, 16385, 24577]
    }

    static var distanceExtraBits: InlineArray<30, UInt8> {
        [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    }

    /// The code-length code's symbols, in the order a dynamic block header lists their lengths.
    static var codeLengthOrder: InlineArray<19, UInt8> {
        [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    }

    /// The fixed literal/length code's lengths (RFC 1951, 3.2.6): 8, 9, 7, and 8 bits.
    static var fixedLiteralLengths: InlineArray<288, UInt8> {
        var lengths = InlineArray<288, UInt8>(repeating: 8)
        for symbol in 144..<256 {
            lengths[symbol] = 9
        }
        for symbol in 256..<280 {
            lengths[symbol] = 7
        }
        return lengths
    }
}

/// The three block types; 3 is reserved, so reading it throws.
enum DeflateBlockType: UInt8 {
    case stored, fixedHuffman, dynamicHuffman
}

/// A Huffman decoding table entry, packed into 32 bits, in the style of libdeflate's: everything the
/// decode loop needs comes from one load.
///
/// - bits 0–7: the bits a match of this code consumes, code plus extra bits (the code alone otherwise; 0 for a
///   subtable link, which the fast loop "consumes" before it knows what it is);
/// - bits 8–11: the code's length, where its extra bits start (a subtable's index width, for links);
/// - bits 12–15: flags, libdeflate's: literal (15); exceptional (14), with subtable link (13) or end of block
///   (12), or neither for an invalid code (or with bit 7, Deflate64's length symbol 285: see
///   ``longLength(codeLength:)``); none for a length or distance. So the fast loop tests one bit per
///   decision, and a length's or distance's bits 8–13 are just its code length: `extra(saved:)` shifts by
///   `raw >> 8` with no mask (a variable shift uses 6 bits);
/// - bits 16–31: the value: a literal, a length or distance base, or a subtable's offset.
struct HuffmanEntry {
    var raw: UInt32

    enum Kind: UInt32 {
        /// A literal byte.
        case literal
        /// A match length or distance: `value` plus the extra bits.
        case lengthOrDistance
        case endOfBlock
        /// Codes longer than the root continue in a subtable at `value`, indexed by `codeLength` more bits.
        case subtable
        /// No code maps here, or the symbol is reserved.
        case invalid
    }

    static var literalFlag: UInt32 { 0x8000 }
    static var exceptionalFlag: UInt32 { 0x4000 }
    static var subtableFlag: UInt32 { 0x2000 }
    static var endOfBlockFlag: UInt32 { 0x1000 }
    /// Deflate64's length symbol 285 (with ``exceptionalFlag``): in bit 7, which consuming ignores (the shift uses
    /// bits 0–5, and the bit count only its low 6 bits).
    static var longLengthFlag: UInt32 { 0x80 }

    /// The entry for Deflate64's length symbol 285: base 3 and 16 extra bits (31 bits at most, within
    /// `totalBits`' 6), marked exceptional and long, so the fast loop checks the room for it alone.
    static func longLength(codeLength: Int) -> Self {
        var entry = Self(codeLength: codeLength, kind: .lengthOrDistance, value: 3, extraBits: 16)
        entry.raw |= exceptionalFlag | longLengthFlag
        return entry
    }

    @inline(__always)
    init(codeLength: Int, kind: Kind, value: Int, extraBits: Int = 0) {
        let flags: UInt32 = switch kind {
        case .literal: Self.literalFlag
        case .lengthOrDistance: 0
        case .endOfBlock: Self.exceptionalFlag | Self.endOfBlockFlag
        case .subtable: Self.exceptionalFlag | Self.subtableFlag
        case .invalid: Self.exceptionalFlag
        }
        let consumed = kind == .subtable ? 0 : codeLength &+ extraBits
        raw = UInt32(consumed) | UInt32(codeLength) << 8 | flags | UInt32(value) << 16
    }

    @inline(__always) init(raw: UInt32) { self.raw = raw }

    // The fields are read as named `BitField`s, as NativeZip's decoder read them. Read with the range
    // subscripts instead, the decode loop ran 3–5% more instructions (2026-11-22). The fast loop reads the
    // flags directly.

    /// Bits to consume: the code, plus a length's or distance's extra bits; 0 for a subtable link.
    @inline(__always) var totalBits: Int { raw[Self.totalBitsField] }
    @inline(__always) var codeLength: Int { raw[Self.codeLengthField] }
    @inline(__always) var kind: Kind {
        if raw & Self.literalFlag != 0 { return .literal }
        if raw & (Self.exceptionalFlag | Self.longLengthFlag) != Self.exceptionalFlag { return .lengthOrDistance }
        if raw & Self.subtableFlag != 0 { return .subtable }
        return raw & Self.endOfBlockFlag != 0 ? .endOfBlock : .invalid
    }
    @inline(__always) var value: Int { raw[Self.valueField] }

    @inline(__always) var isLiteral: Bool { raw & Self.literalFlag != 0 }
    /// A subtable link, the end of the block, an invalid code, or Deflate64's length symbol 285.
    @inline(__always) var isExceptional: Bool { raw & Self.exceptionalFlag != 0 }
    @inline(__always) var isSubtable: Bool { raw & Self.subtableFlag != 0 }
    @inline(__always) var isEndOfBlock: Bool { raw & Self.endOfBlockFlag != 0 }
    @inline(__always) var isLongLength: Bool { raw & Self.longLengthFlag != 0 }

    static var totalBitsField: BitField<Int> { BitField(bits: 0...5) }
    static var codeLengthField: BitField<Int> { BitField(bits: 8...11) }
    static var valueField: BitField<Int> { BitField(bits: 16...31) }

    /// A length's or distance's extra bits, from the bits buffered before the entry was consumed, as
    /// libdeflate's `EXTRACT_VARBITS8(saved, entry) >> (u8)(entry >> 8)`: the low `totalBits` bits, shifted
    /// right by the code length. Both shifts take the raw entry (a variable shift uses its low 6 bits).
    ///
    /// - Parameter saved: The buffered bits, starting with this entry's code.
    /// - Returns: The extra bits as an integer.
    @inline(__always)
    func extra(saved: UInt64) -> Int {
        let mask = ~(UInt64.max &<< UInt64(raw))
        return Int(truncatingIfNeeded: (saved & mask) &>> UInt64(raw &>> 8))
    }

    /// The extra bits' value, from bits whose first is this entry's code's first.
    ///
    /// The unchecked `bits(from:upTo:)` rather than `bits[bits: codeLength..<totalBits]`: with a range not
    /// known to be valid, the subscript's checks stay in the decode loop (measured in NativeZip: 31 more
    /// instructions, two traps). `totalBits` is at most 31 here, as the unchecked form requires.
    ///
    /// - Parameter bits: The buffered bits, starting with this entry's code.
    /// - Returns: The extra bits as an integer.
    @inline(__always)
    func extra(_ bits: UInt64) -> Int {
        Int(truncatingIfNeeded: bits.bits(from: codeLength, upTo: totalBits))
    }

    static var invalid: Self { Self(codeLength: 0, kind: .invalid, value: 0) }
}

/// What a code's symbol decodes to, for each alphabet.
enum DeflateAlphabet {
    case literalLength, distance

    /// The entry for `symbol` with a code of `codeLength` bits.
    ///
    /// - Parameters:
    ///   - symbol: The symbol the code stands for.
    ///   - codeLength: The code's length in bits.
    ///   - deflate64: Whether the stream is Deflate64, where length symbol 285 takes 16 extra bits (lengths 3 to
    ///     65,538) and distance symbols 30 and 31 are valid (14 extra bits each, up to 65,536 back).
    /// - Returns: A literal, end-of-block, or length or distance entry; `invalid` for reserved symbols
    ///   (literal/length 286 and 287, and in DEFLATE distance 30 and 31).
    @inline(__always)
    func entry(_ symbol: Int, codeLength: Int, deflate64: Bool) -> HuffmanEntry {
        switch self {
        case .literalLength:
            switch symbol {
            case 285 where deflate64:
                return HuffmanEntry.longLength(codeLength: codeLength)
            case 0..<256: return HuffmanEntry(codeLength: codeLength, kind: .literal, value: symbol)
            case 256: return HuffmanEntry(codeLength: codeLength, kind: .endOfBlock, value: 0)
            case 257..<286:
                let index = symbol &- 257
                return HuffmanEntry(
                    codeLength: codeLength, kind: .lengthOrDistance,
                    value: Int(Deflate.lengthBases[index]), extraBits: Int(Deflate.lengthExtraBits[index])
                )
            default: return HuffmanEntry(codeLength: codeLength, kind: .invalid, value: 0) // 286, 287
            }
        case .distance:
            if deflate64, symbol == 30 || symbol == 31 { // Bases 32,769 and 49,153 fit the entry's 16-bit value.
                return HuffmanEntry(
                    codeLength: codeLength, kind: .lengthOrDistance, value: symbol == 30 ? 32769 : 49153, extraBits: 14
                )
            }
            guard symbol < 30 else { return HuffmanEntry(codeLength: codeLength, kind: .invalid, value: 0) }
            return HuffmanEntry(
                codeLength: codeLength, kind: .lengthOrDistance,
                value: Int(Deflate.distanceBases[symbol]), extraBits: Int(Deflate.distanceExtraBits[symbol])
            )
        }
    }
}
