public import Bytes

// Each container's name for a compression, mapped to the one run-time identity, `DecompressionFormat` (decoding) or
// `CompressionFormat` (encoding). The containers keep their own identifiers (ZIP's method numbers, an Apple Encrypted
// Archive's compression letter, a `decmpfs` type); what each means to a codec is decided here, once. ARCHITECTURE.md
// §1 has the table.

/// The compression an Apple Archive's `pbz` stream or an Apple Encrypted Archive's segments use: one ASCII letter
/// (the `pbz` header's fourth byte, AEA's root header's compression byte), the same letters in both.
///
/// ```swift
/// let compression = AppleArchiveCompression(rawValue: header.compression)   // "e": LZFSE
/// let format = compression.flatMap(DecompressionFormat.init(aeaSegment:))
/// ```
public enum AppleArchiveCompression: UInt8, Sendable {
    /// `-`: stored; every block is its raw bytes.
    case none = 0x2D
    /// `4`: LZ4 (raw blocks in AEA segments, Compression's `bv41` frames in `pbz4` blocks).
    case lz4 = 0x34
    /// `b`: Apple's LZBITMAP.
    case lzbitmap = 0x62
    /// `e`: Apple's LZFSE (`aa archive`'s default).
    case lzfse = 0x65
    /// `f`: Apple's LZVN.
    case lzvn = 0x66
    /// `m`: Apple's LZRAVEN (macOS 27's `aea encrypt -a lzraven`).
    case lzraven = 0x6D
    /// `x`: LZMA, as an `.xz` stream per block (a `.xip`'s pbzx).
    case lzma = 0x78
    /// `z`: zlib (RFC 1950).
    case zlib = 0x7A
}

public extension DecompressionFormat {
    /// The format of an Apple Encrypted Archive's segments compressed with `compression`: LZ4 as raw blocks, LZMA as an
    /// `.xz` stream, zlib with its wrapper; `nil` for ``AppleArchiveCompression/none`` (segments are stored).
    init?(aeaSegment compression: AppleArchiveCompression) {
        self.init(compression, framedLZ4: false)
    }

    /// The format of a `pbz` stream's blocks compressed with `compression`: as AEA segments, but LZ4 as Compression's
    /// `bv41` frames; `nil` for ``AppleArchiveCompression/none``.
    init?(pbzBlock compression: AppleArchiveCompression) {
        self.init(compression, framedLZ4: true)
    }

    private init?(_ compression: AppleArchiveCompression, framedLZ4: Bool) {
        switch compression {
        case .none: return nil
        case .zlib: self = .deflate(.zlib)
        case .lzma: self = .xz()
        case .lzfse: self = .lzfse
        case .lzvn: self = .lzvn
        case .lz4: self = .lz4(framed: framedLZ4)
        case .lzbitmap: self = .lzbitmap
        case .lzraven: self = .lzraven
        }
    }

    /// The format of a ZIP entry's payload compressed with `method` (APPNOTE 4.4.5): 8 DEFLATE, 9 Deflate64, 12 bzip2,
    /// 93 Zstandard, 95 xz. `nil` for any other: stored (0), methods without a decoder here, and LZMA (14), whose
    /// properties are in the payload's first bytes (``LZMAProperties/init(zipHeader:)``, then
    /// ``zipLZMA(_:uncompressedSize:hasEndMarker:)``).
    ///
    /// - Parameter uncompressedSize: The entry's recorded size, if it fits an `Int`: an xz entry's window is no larger.
    init?(zipMethod method: UInt16, uncompressedSize: Int?) {
        switch method {
        case 8: self = .deflate(.raw)
        case 9: self = .deflate64
        case 12: self = .bzip2
        case 93: self = .zstd(sizeHint: uncompressedSize)
        case 95: self = .xz(sizeHint: uncompressedSize)
        default: return nil
        }
    }

    /// The raw LZMA stream after a ZIP method-14 entry's header (``LZMAProperties/init(zipHeader:)``).
    ///
    /// - Parameters:
    ///   - properties: The header's properties.
    ///   - uncompressedSize: The entry's recorded size.
    ///   - hasEndMarker: General-purpose flag bit 1: the stream ends with an end marker. The size is then its maximum
    ///     (the marker is required, and a stream decoding past the size throws ``BytesError/limitExceeded``);
    ///     without it, the stream ends at `uncompressedSize`, with a marker or without one.
    static func zipLZMA(_ properties: LZMAProperties, uncompressedSize: Int, hasEndMarker: Bool) -> DecompressionFormat {
        .lzma(properties, uncompressedSize: hasEndMarker ? nil : uncompressedSize, maximumSize: hasEndMarker ? uncompressedSize : nil)
    }
}

public extension DeflateFormat {
    /// The container of a stream that comes as zlib or as raw DEFLATE, decided by its first two bytes: HTTP's `deflate`
    /// content coding is zlib (RFC 9110 §8.4.1.2), but some servers send raw DEFLATE under the name, and browsers accept
    /// both. ``zlib`` when the bytes are a zlib header for DEFLATE (RFC 1950 §2.2: method 8, a window of at most 32 KiB,
    /// and the check bits making them a multiple of 31), ``raw`` otherwise. (A raw stream's first byte has method 8's
    /// bits only for a first block that's stored, not final, with a padding bit set: encoders write zeros there.)
    ///
    /// ```swift
    /// guard let container = DeflateFormat(zlibOrRaw: body) else { return }   // one byte so far: wait for more
    /// try decompressor.reset(for: .deflate(container))
    /// ```
    ///
    /// - Parameter firstBytes: The stream's first bytes, two or more.
    /// - Returns: `nil` for fewer than two bytes: decide when more arrive.
    init?(zlibOrRaw firstBytes: RawSpan) {
        guard firstBytes.byteCount >= 2 else { return nil }
        let cmf = UInt16(firstBytes.load(fromByteOffset: 0, as: UInt8.self)), flg = UInt16(firstBytes.load(fromByteOffset: 1, as: UInt8.self))
        self = ZlibHeader.isDeflate(cmf &<< 8 | flg) ? .zlib : .raw
    }
}

public extension LZMAProperties {
    /// The size of a ZIP method-14 entry's header, before the raw LZMA stream: 9 bytes.
    static var zipHeaderSize: Int { 9 }

    /// Reads a ZIP method-14 entry's header (APPNOTE 5.8.8): a 2-byte LZMA SDK version, the properties' size (5) as 2
    /// bytes, then the properties: the lc/lp/pb byte and the dictionary size (4 bytes, little-endian).
    ///
    /// - Parameter header: At least ``zipHeaderSize`` bytes: the payload's first.
    /// - Throws: ``BytesError/insufficientData`` for fewer bytes; ``BytesError/invalidValue`` for a properties size
    ///   other than 5 or an invalid properties byte.
    init(zipHeader header: RawSpan) throws(BytesError) {
        guard header.byteCount >= Self.zipHeaderSize else { throw .insufficientData }
        let propertiesSize = UInt16(littleEndian: header.load(fromByteOffset: 2, as: UInt16.self))
        let dictionarySize = UInt32(littleEndian: header.load(fromByteOffset: 5, as: UInt32.self))
        guard propertiesSize == 5 else { throw .invalidValue }
        try self.init(byte: header.load(fromByteOffset: 4, as: UInt8.self), dictionarySize: Int(dictionarySize))
    }
}
