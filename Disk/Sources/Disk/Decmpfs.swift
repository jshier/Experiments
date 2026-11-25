import Bytes
import BytesCompression
import Darwin

// APFS transparent compression (`decmpfs`), as `ditto --hfsCompression`, `aa extract`, and `xip --expand` write it. A
// compressed file has an empty data fork, the `UF_COMPRESSED` flag, and a `com.apple.decmpfs` attribute:
//
//     "fpmc" (the magic 'cmpf', little-endian) | type u32 | uncompressed size u64 | [inline data]
//
// Types come in pairs: the data inline in the attribute (odd), or in the resource fork (even). The fork starts with a
// table of `chunks + 1` 32-bit offsets (from the fork's start), then the chunks, each 64 KiB of the file compressed
// on its own. A chunk (or inline data) that doesn't compress is stored as a marker byte and the raw bytes.
//
//     3 zlib (inline)    7, 8 LZVN    11, 12 LZFSE    13, 14 LZBITMAP
//
// zlib's fork form (type 4) is the old Resource Manager layout; a probe of it didn't open (`EINVAL`), so zlib is
// written inline only (files whose attribute doesn't fit stay plain).

/// The codecs APFS compression uses.
public enum DiskCodec: Sendable, Hashable, CaseIterable {
    /// Types 7 and 8: what `xip --expand` writes (always the fork, 8).
    case lzvn
    /// Types 11 and 12.
    case lzfse
    /// Types 13 and 14: what `aa extract` writes for Xcode's archives (`AFT` 14).
    case lzbitmap
    /// Type 3, inline only.
    case zlib

    /// The byte before a chunk stored raw: `0x06` for LZVN (its end-of-stream opcode, which no compressed chunk starts
    /// with), `0xFF` for the others (zlib: a low nibble of 0xF, which no zlib header has).
    var rawMarker: UInt8 { self == .lzvn ? 0x06 : 0xFF }

    /// The inline and resource-fork types (0 where there's none).
    var types: (inline: UInt32, fork: UInt32) {
        switch self {
        case .lzvn: (7, 8)
        case .lzfse: (11, 12)
        case .lzbitmap: (13, 14)
        case .zlib: (3, 0)
        }
    }

    /// The codec of a `decmpfs` type (an archive's `AFT` field), or `nil`.
    public init?(decmpfsType type: UInt32) {
        switch type {
        case 3: self = .zlib
        case 7, 8: self = .lzvn
        case 11, 12: self = .lzfse
        case 13, 14: self = .lzbitmap
        default: return nil
        }
    }

    /// BytesCompression's encoding of a chunk: Compression's bytes for the Apple codecs, zlib at level 6.
    var compressionFormat: CompressionFormat {
        switch self {
        case .lzvn: .lzvn
        case .lzfse: .lzfse
        case .lzbitmap: .lzbitmap
        case .zlib: .deflate(.zlib, level: 6)
        }
    }

    /// BytesCompression's decoding of a chunk.
    var decompressionFormat: DecompressionFormat {
        switch self {
        case .lzvn: .lzvn
        case .lzfse: .lzfse
        case .lzbitmap: .lzbitmap
        case .zlib: .deflate(.zlib)
        }
    }
}

/// How a file is stored when it's to be APFS-compressed: the codec and an extractor's rules for when compressing pays.
///
/// The presets match Apple's tools file for file and byte for byte (measured on Xcode: Disk/RESULTS.md,
/// NativeAEA/RESULTS.md): ``appleArchive`` is `aa extract`'s, ``xipExpand`` is `xip --expand`'s.
public struct StoragePolicy: Sendable, Hashable {
    /// When a compressed file is worth its fork.
    package enum Rule: Sendable, Hashable {
        /// The fork under `percent` of the file's bytes (`aa extract`: 93).
        case bytes(percent: Int)
        /// The fork's 4 KiB blocks at most `numerator / denominator` of the file's (`xip --expand`: 4/5).
        case blocks(numerator: Int, denominator: Int)
    }

    /// How much output room each chunk's encoder gets: the encoders' output depends on it.
    public enum Room: Sendable, Hashable {
        /// A whole chunk (64 KiB) whatever the chunk's size: `aa extract`.
        case wholeChunk
        /// The chunk's own size: `xip --expand` (LZVN needs 1–10 bytes beyond its stream, so a short last chunk that
        /// saves less is stored raw).
        case chunkSize
    }

    public var codec: DiskCodec
    /// Whether a one-chunk file may go inline, in the attribute (at most 3,584 bytes with its header).
    var allowsInline: Bool
    /// Files smaller than this stay plain.
    var minimumSize: Int
    /// PNG files stay plain, however well they compress (`xip --expand`).
    var skipsPNG: Bool
    package var rule: Rule
    public var room: Room

    init(codec: DiskCodec, allowsInline: Bool, minimumSize: Int = 0, skipsPNG: Bool = false, rule: Rule, room: Room) {
        self.codec = codec
        self.allowsInline = allowsInline && codec != .lzvn
        self.minimumSize = minimumSize
        self.skipsPNG = skipsPNG
        self.rule = rule
        self.room = room
    }

    /// `aa extract`: LZBITMAP (Xcode's `AFT` 14), inline when the attribute fits, a fork under 93% of the bytes, every
    /// chunk given 64 KiB of room. All 167,542 items of Xcode 27.3 beta 2 match byte for byte.
    public static let appleArchive = StoragePolicy(codec: .lzbitmap, allowsInline: true, rule: .bytes(percent: 93), room: .wholeChunk)

    /// `aa extract`'s rules with LZFSE (`AFT` 12). Contents and forms match `aa`; the bytes are the open lzfse
    /// reference's, which differ from Compression's in a few block boundaries.
    public static let appleArchiveLZFSE = StoragePolicy(codec: .lzfse, allowsInline: true, rule: .bytes(percent: 93), room: .wholeChunk)

    /// `xip --expand`: LZVN forks (never inline) for files over 16 KiB that aren't PNGs, when the fork saves a fifth of
    /// the 4 KiB blocks; each chunk given its own size as room. Every file of Xcode 27.2 matches byte for byte.
    public static let xipExpand = StoragePolicy(
        codec: .lzvn, allowsInline: false, minimumSize: 16_385, skipsPNG: true, rule: .blocks(numerator: 4, denominator: 5), room: .chunkSize
    )

    /// `xip --expand`'s rules for any size (an archive that asked for LZVN itself).
    public static let lzvnForks = StoragePolicy(
        codec: .lzvn, allowsInline: false, skipsPNG: true, rule: .blocks(numerator: 4, denominator: 5), room: .chunkSize
    )

    /// zlib (type 3), inline only: small files that compress below 93%.
    package static let zlibInline = StoragePolicy(codec: .zlib, allowsInline: true, rule: .bytes(percent: 93), room: .wholeChunk)

    /// The policy for an archive's `decmpfs` type (`AFT`): `aa extract`'s rules for its codec.
    public static func forArchivedType(_ type: UInt32) -> StoragePolicy? {
        switch DiskCodec(decmpfsType: type) {
        case .lzbitmap: .appleArchive
        case .lzfse: .appleArchiveLZFSE
        case .lzvn: .lzvnForks
        case .zlib: .zlibInline
        case nil: nil
        }
    }

    /// Whether a fork of `forkCount` bytes is worth it for `rawCount` bytes.
    @inline(__always)
    func pays(_ forkCount: Int, _ rawCount: Int) -> Bool {
        switch rule {
        case let .bytes(percent): forkCount * 100 < rawCount * percent
        case let .blocks(numerator, denominator): (forkCount + 4095) / 4096 * denominator <= (rawCount + 4095) / 4096 * numerator
        }
    }

    /// Whether the file whose first bytes are `first` (`size` in all) is stored plain whatever it would save.
    func skips(size: Int, first: RawSpan) -> Bool {
        if size < minimumSize { return true }
        guard skipsPNG, first.byteCount >= 8 else { return false }
        let magic = UInt64(littleEndian: first.load(fromByteOffset: 0, as: UInt64.self))
        return magic == Decmpfs.pngMagic
    }
}

/// How a file is to be stored.
public enum Storage: Sendable, Hashable {
    /// An ordinary file.
    case plain
    /// APFS-compressed by `policy`'s rules (plain when they say it doesn't pay).
    case compressed(StoragePolicy)
}

enum Decmpfs {
    static let chunkSize = 65_536
    static let headerSize = 16
    static let maximumInlineAttribute = 3_584
    static let attribute = "com.apple.decmpfs"
    static let resourceFork = "com.apple.ResourceFork"
    /// Chunks compressed per fork write.
    static let batchChunks = 16
    /// The 8 bytes a PNG file starts with: 89 50 4E 47 0D 0A 1A 0A, little-endian.
    static let pngMagic: UInt64 = 0x0A1A_0A0D_474E_5089

    static func header(type: UInt32, size: Int) -> InlineArray<16, UInt8> {
        var header = InlineArray<16, UInt8>(repeating: 0)
        header[0] = 0x66 // "fpmc"
        header[1] = 0x70
        header[2] = 0x6D
        header[3] = 0x63
        for index in 0..<4 {
            header[4 + index] = UInt8(truncatingIfNeeded: type >> (8 * UInt32(index)))
        }
        for index in 0..<8 {
            header[8 + index] = UInt8(truncatingIfNeeded: UInt64(size) >> (8 * UInt64(index)))
        }
        return header
    }
}

/// A writer's chunk encoders: BytesCompression's `Compressor`, each codec's encoder made on first use and kept (they
/// allocate their tables at creation, and encoding allocates nothing). Used by one writer at a time.
///
/// All three Apple codecs write Compression's streams byte for byte (LZBITMAP, LZFSE, LZVN with Compression's parse),
/// and fail where it fails, so files are stored as `aa extract` and `xip --expand` store them.
final class ChunkEncoders {
    private var compressor = Compressor()

    init() {}

    /// Compresses one chunk (at most 64 KiB) into `output` (room for a whole chunk and one byte more, whatever
    /// `count`): compressed, if that works and is smaller; or the codec's raw marker and the raw bytes.
    ///
    /// - Returns: The bytes written: at most `count + 1`.
    func compress(_ input: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, policy: StoragePolicy) -> Int {
        // The caller's contract: `count` readable bytes at `input` (at most a chunk), and room for a chunk and one byte
        // at `output`, both valid for the call.
        let room = policy.room == .chunkSize ? count : Decmpfs.chunkSize
        // Unsafe: both pointers to `encode`. Safe: `count` bytes of input and `room` of output, `room` at most a chunk
        // (`count` or 64 KiB), which `output` has; `encode` keeps neither pointer.
        let written = unsafe encode(input, count: count, into: output, room: room, codec: policy.codec)
        if written > 0, written < count { return written }
        // Unsafe (the next two): stores the raw marker at `output` and copies the chunk after it. Safe: 1 + `count`
        // bytes, within `output`'s chunk and one byte; `input` has `count` bytes. Every caller's output is a writer's
        // scratch (`WriterCore.output`), apart from its input, so the marker's store doesn't change the input.
        unsafe output.storeBytes(of: policy.codec.rawMarker, as: UInt8.self)
        unsafe (output + 1).copyMemory(from: input, byteCount: count)
        return count + 1
    }

    /// Encodes `count` bytes into `output` with `capacity` bytes of room.
    ///
    /// - Returns: The encoded size, or 0 if it doesn't fit.
    func encode(_ input: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, room capacity: Int, codec: DiskCodec) -> Int {
        // The caller's contract: `count` readable bytes at `input` and `capacity` writable bytes at `output`, valid
        // during the call.
        // Unsafe: a span over the input, with no lifetime the compiler can check. Safe: the caller's `count` bytes;
        // used only by the encoders below, within this call.
        let source = unsafe RawSpan(_unsafeStart: input, byteCount: count)
        // Unsafe: a buffer over the output. Safe: the caller's `capacity` writable bytes; local to this call.
        let buffer = unsafe UnsafeMutableRawBufferPointer(start: output, count: capacity)
        // Unsafe: an output span over that buffer, none of it initialized. Safe: the buffer outlives the span, which
        // is finalized against the same buffer below; the encoders write only through it, so within `capacity`.
        var target = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
        // Every `compressAll` starts a new stream (zlib's encoder resets itself once used); the encoder is chosen again
        // only when the codec changes.
        let format = codec.compressionFormat
        // Disk's codecs are fixed formats with valid parameters: `reset(for:)` can't throw for them.
        if compressor.format != format { try? compressor.reset(for: format) }
        let fits = (try? compressor.compressAll(source, into: &target)) != nil
        // Unsafe: ends the output span, taking its count. Safe: `buffer` is the buffer the span was made over.
        let written = unsafe target.finalize(for: buffer)
        return fits ? written : 0
    }
}

/// Rewrites a file whose resource fork didn't pay as a plain file: each chunk read back from the fork, decompressed,
/// and written to the data fork; then the fork removed. Its buffers and decoders are made once; a writer makes one on
/// first need (rare: Xcode has one such file).
final class ForkUnpacker {
    private let stored = RawStorage(byteCount: Decmpfs.chunkSize + 64)
    private let raw = RawStorage(byteCount: Decmpfs.chunkSize)
    /// BytesCompression's decoder, reset for the fork's codec.
    private var decompressor = Decompressor()

    /// Decompresses one chunk (compressed, or the raw marker and the raw bytes) from `stored` into exactly `rawCount`
    /// bytes of `raw`.
    private func decompressChunk(count: Int, rawCount: Int, codec: DiskCodec) -> Bool {
        // This unpacker's buffers: `stored` holds a chunk and 64 bytes, `raw` a chunk. `unpack`, the only caller, has
        // checked `count <= chunkSize + 1` and filled `count` bytes of `stored`; `rawCount` is at most a chunk.
        guard count > 0 else { return rawCount == 0 }
        // Unsafe: a load of `stored`'s first byte. Safe: `count > 0` bytes of it were filled by `unpack`.
        if unsafe stored.base.load(as: UInt8.self) == codec.rawMarker, count - 1 == rawCount {
            // Unsafe: copies the raw bytes after the marker from `stored` into `raw`. Safe: `rawCount == count - 1`
            // bytes from offset 1, within the `count` filled; `raw` holds a chunk, and the two are separate
            // allocations.
            unsafe raw.base.copyMemory(from: stored.base + 1, byteCount: rawCount)
            return true
        }
        // Unsafe: a span over `stored`, with no lifetime the compiler can check. Safe: the `count` bytes `unpack`
        // filled, in storage `self` owns; used only by the decoders below, within this call.
        let input = unsafe RawSpan(_unsafeStart: stored.base, byteCount: count)
        // Unsafe: a buffer over `raw`. Safe: `rawCount` bytes, at most the chunk `raw` holds; local to this call.
        let rawBuffer = unsafe UnsafeMutableRawBufferPointer(start: raw.base, count: rawCount)
        // Unsafe: an output span over that buffer, none of it initialized. Safe: the buffer outlives the span, which
        // is finalized against it below; the decoders write only through it, so within `rawCount`.
        var output = unsafe OutputRawSpan(buffer: rawBuffer, initializedCount: 0)
        guard codec != .zlib else { return false } // Never in a fork.
        do throws(BytesError) {
            let format = codec.decompressionFormat
            if decompressor.format != format { try decompressor.reset(for: format) }
            _ = try decompressor.decompressAll(input, into: &output, decodedSize: rawCount)
        } catch {
            return false
        }
        // Unsafe: ends the output span, taking its count. Safe: `rawBuffer` is the buffer the span was made over.
        return unsafe output.finalize(for: rawBuffer) == rawCount
    }

    /// Rewrites the open file `descriptor` (`size` bytes, `chunkCount` chunks of `codec` in its fork) plain.
    func unpack(_ descriptor: Int32, size: Int, chunkCount: Int, codec: DiskCodec, path: PathRef) throws(DiskError) {
        var offsets = InlineArray<2, UInt32>(repeating: 0)
        for chunk in 0..<chunkCount {
            let rawStart = chunk * Decmpfs.chunkSize
            let rawCount = min(Decmpfs.chunkSize, size - rawStart)
            // The chunk's table entry and the next: where it starts and ends in the fork (8 bytes into 8).
            var span = offsets.mutableSpan
            // Unsafe: the span's base pointer to `fgetxattr`, which writes up to 8 bytes there. Safe: `offsets` is two
            // `UInt32`s, 8 bytes, valid inside `withUnsafeMutableBytes`; the name is a string literal's C string.
            let read = span.withUnsafeMutableBytes { unsafe Sys.fgetxattr(descriptor, Decmpfs.resourceFork, $0.baseAddress, 8, chunk * 4) }
            guard read == 8 else { throw .system("getxattr fork", path: path, code: errno) }
            let start = Int(UInt32(littleEndian: offsets[0])), end = Int(UInt32(littleEndian: offsets[1]))
            guard end > start, end - start <= Decmpfs.chunkSize + 1 else { throw .invalidMetadata("a resource fork's chunk table, \(path.string)") }
            // Unsafe: `stored`'s base to `fgetxattr`, which writes up to `end - start` bytes there. Safe: at most a
            // chunk and one byte (the guard above), within `stored`'s chunk and 64 bytes, which `self` owns.
            let got = unsafe Sys.fgetxattr(descriptor, Decmpfs.resourceFork, stored.base, end - start, start)
            guard got == end - start else { throw .system("getxattr fork", path: path, code: errno) }
            guard decompressChunk(count: end - start, rawCount: rawCount, codec: codec) else {
                throw .invalidMetadata("a resource fork's chunk doesn't decompress, \(path.string)")
            }
            // Unsafe: `raw`'s base to `writeFully`. Safe: the `rawCount` bytes `decompressChunk` just filled (it
            // returned `true` only for exactly that many), in storage `self` owns; read only during the call.
            try unsafe FileIO.writeFully(descriptor, raw.base, count: rawCount, at: rawStart, path: path)
        }
        // Unsafe: a C string to `fremovexattr`. Safe: a string literal's, valid for the call.
        if unsafe Sys.fremovexattr(descriptor, Decmpfs.resourceFork) != 0 { throw .system("removexattr", path: path, code: errno) }
    }
}

enum FileIO {
    /// Writes `count` bytes at `offset`, retrying short writes and interruptions.
    static func writeFully(_ descriptor: Int32, _ bytes: UnsafeRawPointer, count: Int, at offset: Int, path: PathRef) throws(DiskError) {
        var done = 0
        while done < count {
            // Unsafe: `bytes + done` to `pwrite`. Safe: the caller's `count` readable bytes, valid for this call;
            // `done < count`, so the `count - done` bytes from there are the rest of them.
            let written = unsafe Sys.pwrite(descriptor, bytes + done, count - done, offset + done)
            if written < 0 {
                if errno == EINTR { continue }
                throw .system("write", path: path, code: errno)
            }
            done += written
        }
    }
}
