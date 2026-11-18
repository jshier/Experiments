public import Bytes

/// Zstandard (RFC 8878) constants and the format's fixed tables.
enum Zstd {
    /// A frame's magic number, little-endian at its start.
    static var magic: UInt32 { 0xFD2F_B528 }
    /// Skippable frames' magic numbers: this value with any low nibble.
    static var skippableMagic: UInt32 { 0x184D_2A50 }
    /// The largest block, in either direction; also bounds a block's literals.
    static var blockSizeMaximum: Int { 128 << 10 }
    /// The largest window this decoder accepts at all (as libzstd on 64-bit systems): window logs up to 31.
    static var windowLogMaximum: Int { 31 }

    /// Bytes a wild copy may write past the end of what it copies, and read past the end of literals: two
    /// 16-byte moves.
    static var wildCopyOverrun: Int { 32 }

    // MARK: Sequence codes

    static var maximumLiteralLengthCode: Int { 35 }
    static var maximumMatchLengthCode: Int { 52 }
    static var maximumOffsetCode: Int { 31 }
    static var literalLengthTableLogMaximum: Int { 9 }
    static var matchLengthTableLogMaximum: Int { 9 }
    static var offsetTableLogMaximum: Int { 8 }

    /// Literal length codes' baselines and extra bits (RFC 8878, 3.1.1.3.2.1.1).
    static let literalLengthBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000,
        0x2000, 0x4000, 0x8000, 0x10000,
    ]
    static let literalLengthBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    /// Match length codes' baselines and extra bits.
    static let matchLengthBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 0x83, 0x103, 0x203, 0x403, 0x803,
        0x1003, 0x2003, 0x4003, 0x8003, 0x10003,
    ]
    static let matchLengthBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    /// An offset code's baseline: `(1 << code) - 3`, so that adding the extra bits gives the offset itself for
    /// codes 2 and up. Codes 0 and 1 (baselines 0 and 1, 0 and 1 extra bits) select repeat offsets.
    static func offsetBase(_ code: Int) -> UInt32 {
        code < 2 ? UInt32(code) : (UInt32(1) << UInt32(code)) &- 3
    }

    // MARK: Predefined distributions (RFC 8878, 3.1.1.3.2.2)

    static let literalLengthDefaultNorm: [Int16] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    static var literalLengthDefaultLog: Int { 6 }
    static let matchLengthDefaultNorm: [Int16] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    static var matchLengthDefaultLog: Int { 6 }
    static let offsetDefaultNorm: [Int16] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]
    static var offsetDefaultLog: Int { 5 }
}

/// A Zstandard frame's header (RFC 8878, 3.1.1.1): what a decoder needs to know before the first block.
///
/// ```swift
/// if let header = try ZstdFrameHeader(parsing: compressed.span.bytes) {
///     print(header.contentSize ?? "unknown size", header.windowSize)
/// }
/// ```
///
/// Useful before decoding: to size an output buffer from ``contentSize``, to check ``windowSize`` against a
/// memory budget, or to see why ``ZstdDecoder`` rejected a frame (``dictionaryID`` not 0).
public struct ZstdFrameHeader: Hashable, Sendable {
    /// Whether this is a skippable frame (user data, which decoders skip); its ``contentSize`` is the number of
    /// bytes to skip after the 8-byte header.
    public var isSkippable: Bool
    /// The header's size in bytes, magic number included.
    public var headerSize: Int
    /// The decompressed size, if the frame states it (and for skippable frames, the skipped data's size).
    public var contentSize: UInt64?
    /// How far back matches may reach: the history a streaming decoder must keep. For single-segment frames,
    /// the content size.
    public var windowSize: UInt64
    /// The dictionary the frame was compressed with; 0 for none. ``ZstdDecoder`` decodes only frames without one.
    public var dictionaryID: UInt32
    /// Whether the frame ends with a checksum of its content (the low 32 bits of its ``XXHash64``).
    public var hasChecksum: Bool
    /// Whether the frame is one segment: the window is the whole content.
    public var isSingleSegment: Bool

    /// The largest block in the frame: the window size, at most 128 KB.
    public var blockSizeMaximum: Int { Int(min(windowSize, UInt64(Zstd.blockSizeMaximum))) }

    /// Parses the header of the frame at the start of `bytes`.
    ///
    /// - Parameter bytes: The frame, or at least its header (up to 18 bytes).
    /// - Returns: The header, or `nil` if `bytes` is too short to hold all of it.
    /// - Throws: ``BytesError/invalidValue`` if the bytes don't start a Zstandard or skippable frame, or the
    ///   header sets its reserved bit or a window log above 31.
    public init?(parsing bytes: RawSpan) throws(BytesError) {
        guard let header = try Self.parse(bytes) else { return nil }
        self = header
    }

    init(
        isSkippable: Bool, headerSize: Int, contentSize: UInt64?, windowSize: UInt64, dictionaryID: UInt32,
        hasChecksum: Bool, isSingleSegment: Bool
    ) {
        self.isSkippable = isSkippable
        self.headerSize = headerSize
        self.contentSize = contentSize
        self.windowSize = windowSize
        self.dictionaryID = dictionaryID
        self.hasChecksum = hasChecksum
        self.isSingleSegment = isSingleSegment
    }

    /// The header's size from its first five bytes (magic number and descriptor), or `nil` if fewer are there.
    static func size(_ bytes: RawSpan) throws(BytesError) -> Int? {
        guard bytes.byteCount >= 4 else {
            // Reject a wrong magic number as early as its first bytes show it.
            for index in 0..<bytes.byteCount {
                let byte = bytes.load(fromByteOffset: index, as: UInt8.self)
                let frame = UInt8(truncatingIfNeeded: Zstd.magic &>> UInt32(8 &* index))
                let skippable = UInt8(truncatingIfNeeded: Zstd.skippableMagic &>> UInt32(8 &* index))
                let isSkippable = index == 0 ? byte & 0xF0 == skippable : byte == skippable
                if byte != frame && !isSkippable { throw .invalidValue }
            }
            return nil
        }
        let magic = UInt32(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromByteOffset: 0, as: UInt32.self))
        if magic & 0xFFFF_FFF0 == Zstd.skippableMagic { return 8 }
        guard magic == Zstd.magic else { throw .invalidValue }
        guard bytes.byteCount >= 5 else { return nil }
        let descriptor = bytes.load(fromByteOffset: 4, as: UInt8.self)
        let singleSegment = descriptor & 0x20 != 0
        let dictionaryIDSize = dictionaryIDFieldSize(descriptor)
        let contentSizeCode = Int(descriptor &>> 6)
        let contentSizeSize = contentSizeCode == 0 ? (singleSegment ? 1 : 0) : 1 &<< contentSizeCode
        return 5 &+ (singleSegment ? 0 : 1) &+ dictionaryIDSize &+ contentSizeSize
    }

    /// Parses a header, or returns `nil` if `bytes` doesn't hold all of it.
    static func parse(_ bytes: RawSpan) throws(BytesError) -> ZstdFrameHeader? {
        guard let size = try size(bytes), bytes.byteCount >= size else { return nil }
        let magic = UInt32(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromByteOffset: 0, as: UInt32.self))
        if magic != Zstd.magic {
            let length = UInt32(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromByteOffset: 4, as: UInt32.self))
            return ZstdFrameHeader(
                isSkippable: true, headerSize: 8, contentSize: UInt64(length), windowSize: 0,
                dictionaryID: magic & 0xF, hasChecksum: false, isSingleSegment: false
            )
        }
        let descriptor = bytes.load(fromByteOffset: 4, as: UInt8.self)
        guard descriptor & 0x08 == 0 else { throw .invalidValue } // The reserved bit.
        let singleSegment = descriptor & 0x20 != 0
        var position = 5
        var windowSize: UInt64 = 0
        if !singleSegment {
            let window = bytes.load(fromByteOffset: position, as: UInt8.self)
            position &+= 1
            let windowLog = 10 &+ Int(window &>> 3)
            guard windowLog <= Zstd.windowLogMaximum else { throw .invalidValue }
            let base = UInt64(1) &<< UInt64(windowLog)
            windowSize = base &+ (base &>> 3) &* UInt64(window & 7)
        }
        let dictionaryIDSize = dictionaryIDFieldSize(descriptor)
        let dictionaryID = UInt32(truncatingIfNeeded: field(bytes, at: position, count: dictionaryIDSize))
        position &+= dictionaryIDSize
        var contentSize: UInt64?
        switch descriptor &>> 6 {
        case 0: contentSize = singleSegment ? field(bytes, at: position, count: 1) : nil
        case 1: contentSize = field(bytes, at: position, count: 2) &+ 256
        case 2: contentSize = field(bytes, at: position, count: 4)
        default: contentSize = field(bytes, at: position, count: 8)
        }
        if singleSegment { windowSize = contentSize ?? 0 }
        return ZstdFrameHeader(
            isSkippable: false, headerSize: size, contentSize: contentSize, windowSize: windowSize,
            dictionaryID: dictionaryID, hasChecksum: descriptor & 0x04 != 0, isSingleSegment: singleSegment
        )
    }

    /// The size of the dictionary ID field a frame header descriptor selects.
    private static func dictionaryIDFieldSize(_ descriptor: UInt8) -> Int {
        let code = Int(descriptor & 3)
        return code == 3 ? 4 : code
    }

    /// `count` bytes at `position` in `bytes`, little-endian.
    private static func field(_ bytes: RawSpan, at position: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(bytes.load(fromByteOffset: position &+ index, as: UInt8.self)) &<< UInt64(8 &* index)
        }
        return value
    }
}
