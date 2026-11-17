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
/// - bits 0–7: the bits a match of this code consumes, code plus extra bits (the code alone otherwise);
/// - bits 8–11: the code's length, where its extra bits start (a subtable's index width, for links);
/// - bits 12–14: the kind;
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

    @inline(__always)
    init(codeLength: Int, kind: Kind, value: Int, extraBits: Int = 0) {
        raw = UInt32(codeLength &+ extraBits) | UInt32(codeLength) << 8 | kind.rawValue << 12 | UInt32(value) << 16
    }

    @inline(__always) init(raw: UInt32) { self.raw = raw }

    /// Bits to consume: the code, plus a length's or distance's extra bits.
    /// Masked to 6 bits, the width a variable shift uses: so `BitBuffer.consume` can shift by the raw entry
    /// (ARM's `lsr` ignores the rest), keeping the mask off the decode loop's critical path.
    @inline(__always) var totalBits: Int { Int(raw[bits: 0..<6]) }
    @inline(__always) var codeLength: Int { Int(raw[Nibble.self, at: 8]) }
    /// Compiles to the same code as comparing the raw field: the optimizer folds the conversion away.
    @inline(__always) var kind: Kind { Kind(rawBits: raw[Bits<3>.self, at: 12]) ?? .invalid }
    @inline(__always) var value: Int { Int(raw[bits: 16..<32]) }

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
    /// - Returns: A literal, end-of-block, or length or distance entry; `invalid` for reserved symbols
    ///   (literal/length 286 and 287, distance 30 and 31).
    @inline(__always)
    func entry(_ symbol: Int, codeLength: Int) -> HuffmanEntry {
        switch self {
        case .literalLength:
            switch symbol {
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
            guard symbol < 30 else { return HuffmanEntry(codeLength: codeLength, kind: .invalid, value: 0) }
            return HuffmanEntry(
                codeLength: codeLength, kind: .lengthOrDistance,
                value: Int(Deflate.distanceBases[symbol]), extraBits: Int(Deflate.distanceExtraBits[symbol])
            )
        }
    }
}
