/// Apple's `pbz` block framing: Apple Archive streams compressed by `aa archive -a ALGORITHM` (`.aar`, and `pbz`
/// streams inside AEA segments), and a `.xip`'s pbzx content.
///
///     "pbz" | algorithm (u8) | block size (u64, big-endian)
///     per block: raw size (u64 BE) | stored size (u64 BE) | stored bytes
///
/// The algorithm is an ``AppleArchiveCompression`` letter (`pbzx`: LZMA, each block an `.xz` stream). A block whose
/// sizes are equal is stored as is. Blocks are independent: BytesCompressionAsync's `ParallelBlockDecoder` decodes them
/// in parallel.
public enum PBZ {
    /// The stream header's size: 12 bytes.
    public static var headerSize: Int { 12 }
    /// A block header's size: 16 bytes. (`package`: read by BytesCompressionAsync's inlinable block producers.)
    @usableFromInline package static var blockHeaderSize: Int { 16 }
    /// The largest block size accepted (every buffer is sized from it, so a hostile header can't ask for more).
    static var maximumBlockSize: Int { 256 << 20 }

    /// The stream's compression and block size, if `bytes` start a `pbz` stream: its 12-byte header read and checked.
    ///
    /// ```swift
    /// let head = try file.read(at: 0, count: min(size, PBZ.headerSize))
    /// if let (compression, blockSize) = try PBZ.header(head.span.bytes) { … }   // else a plain stream
    /// ```
    ///
    /// - Parameter bytes: The stream's first bytes: ``headerSize`` of them, or all there are if fewer.
    /// - Returns: `nil` if `bytes` don't start a `pbz` stream: no `pbz` magic, fewer than 4 bytes, or a letter
    ///   ``AppleArchiveCompression`` doesn't know.
    /// - Throws: ``PBZError/headerCutShort`` if they start one (the magic and a known letter) but end before its 12
    ///   bytes; ``PBZError/header`` for a block size of 0 or above 256 MiB.
    public static func header(_ bytes: RawSpan) throws(PBZError) -> (compression: AppleArchiveCompression, blockSize: Int)? {
        guard let compression = compression(bytes) else { return nil }
        guard bytes.byteCount >= headerSize else { throw .headerCutShort }
        let size = UInt64(bigEndian: bytes.load(fromByteOffset: 4, as: UInt64.self))
        guard size > 0, size <= UInt64(maximumBlockSize) else { throw .header }
        return (compression, Int(size))
    }

    /// The algorithm, if `bytes` start a `pbz` stream with a letter ``AppleArchiveCompression`` knows; `nil` otherwise
    /// (no magic, fewer than 4 bytes, or another letter).
    package static func compression(_ bytes: RawSpan) -> AppleArchiveCompression? {
        guard bytes.byteCount >= 4 else { return nil }
        let magic = UInt32(bigEndian: bytes.load(fromByteOffset: 0, as: UInt32.self))
        guard magic >> 8 == 0x70_627A else { return nil } // "pbz"
        return AppleArchiveCompression(rawValue: UInt8(truncatingIfNeeded: magic))
    }

    /// Block `index`'s raw and stored sizes, from its 16-byte header, checked: a raw size from 1 to `blockSize`, a
    /// stored size from 1 to the raw size (and to `available`, the bytes left after the header, when known).
    ///
    /// - Throws: ``PBZError/blockHeaderCutShort`` for fewer than 16 bytes; ``PBZError/blockSizes(block:raw:stored:)``.
    @usableFromInline package static func blockSizes(_ bytes: RawSpan, index: Int, blockSize: Int, available: Int? = nil) throws(PBZError) -> (raw: Int, stored: Int) {
        guard bytes.byteCount >= blockHeaderSize else { throw .blockHeaderCutShort }
        // Sizes past `Int.max` read as negative, and fail the checks below.
        let raw = Int(truncatingIfNeeded: UInt64(bigEndian: bytes.load(fromByteOffset: 0, as: UInt64.self)))
        let stored = Int(truncatingIfNeeded: UInt64(bigEndian: bytes.load(fromByteOffset: 8, as: UInt64.self)))
        guard raw > 0, raw <= blockSize, stored > 0, stored <= raw, stored <= available ?? stored else {
            throw .blockSizes(block: index, raw: raw, stored: stored)
        }
        return (raw, stored)
    }
}

/// Why a `pbz` stream's framing can't be read.
public enum PBZError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The 12-byte header is invalid: a block size of 0 or over 256 MiB.
    case header
    /// The stream ends inside its 12-byte header.
    case headerCutShort
    /// The stream ends inside a block's 16-byte header.
    case blockHeaderCutShort
    /// A block's sizes are invalid: a raw size of 0 or over the block size, a stored size of 0, over the raw size, or
    /// past the stream's end.
    case blockSizes(block: Int, raw: Int, stored: Int)
    /// The stream ends inside a block's stored bytes.
    case blockCutShort(block: Int)

    public var description: String {
        switch self {
        case .header: "a pbz header"
        case .headerCutShort: "a pbz header is cut short"
        case .blockHeaderCutShort: "a pbz block header is cut short"
        case let .blockSizes(block, raw, stored): "pbz block \(block) sizes \(raw)/\(stored)"
        case let .blockCutShort(block): "pbz block \(block) is cut short"
        }
    }
}
