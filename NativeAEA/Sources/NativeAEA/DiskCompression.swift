import Bytes
import BytesCompression
import Darwin
import System

// APFS transparent compression (`decmpfs`), as `ditto --hfsCompression`, Apple's `aa extract`, and unxip write
// it. A compressed file has an empty data fork, the `UF_COMPRESSED` flag, and a `com.apple.decmpfs` attribute:
//
//     "fpmc" (the magic 'cmpf', little-endian) | type u32 | uncompressed size u64 | [inline data]
//
// Types come in pairs: the data inline in the attribute (odd), or in the resource fork (even). The fork starts with
// a table of `chunks + 1` 32-bit offsets (from the fork's start), then the chunks, each 64 KiB of the file
// compressed separately. A chunk (or inline data) that doesn't compress is stored as 0xFF then the raw bytes.
//
//     11, 12   LZFSE                13, 14   LZBITMAP (what Xcode's archives ask for, `AFT` 14)
//
// Apple's extractor puts a file inline when the attribute is at most 3,584 bytes, and leaves it uncompressed when
// compressing doesn't make it smaller.

enum Decmpfs {
    static let chunkSize = 65_536
    static let headerSize = 16
    static let maximumInlineAttribute = 3_584
    static let attribute = "com.apple.decmpfs"
    static let resourceFork = "com.apple.ResourceFork"
    /// Chunks compressed per fork write.
    static let batchChunks = 16

    /// The codec for a `decmpfs` type, and the type's inline and fork variants.
    static func codec(_ type: UInt32) -> (codec: DiskCodec, inline: UInt32, fork: UInt32)? {
        switch type {
        case 7, 8: (.lzvn, 7, 8)
        case 11, 12: (.lzfse, 11, 12)
        case 13, 14: (.lzbitmap, 13, 14)
        default: nil
        }
    }

    /// The 8 bytes a PNG file starts with.
    static let pngMagic: UInt64 = 0x0A1A_0A0D_474E_5089 // 89 50 4E 47 0D 0A 1A 0A, little-endian

    /// Whether a file is left uncompressed whatever it would save: `xip --expand` leaves PNGs alone (all 146 of
    /// Xcode's over 16 KiB, however well they compress; recognized here by their content, as identical bytes under
    /// other names always got the same treatment).
    static func skips(_ data: UnsafeRawPointer, count: Int, codec: DiskCodec) -> Bool {
        // `count` bytes at `data`, checked to be 8 or more before the load: safe.
        codec == .lzvn && count >= 8 && UInt64(littleEndian: unsafe data.loadUnaligned(as: UInt64.self)) == pngMagic
    }

    /// Whether a resource fork of `forkCount` bytes is worth it for `rawCount` bytes, by the rule of the extractor
    /// that uses `codec`:
    /// - `aa extract` (LZBITMAP, LZFSE): under 93% of the bytes (Xcode 27.3 beta 2: the highest ratio it compressed
    ///   was 0.9293, the lowest it left plain 0.9304). Inline files are exempt: those always go inline.
    /// - `xip --expand` (LZVN): at most 80% of the 4 KiB blocks (all 27,035 of Xcode 27.2's files over 16 KiB, the
    ///   only ones it compresses: by bytes, ratios from 0.787 to 0.864 went both ways).
    @inline(__always)
    static func pays(_ forkCount: Int, _ rawCount: Int, codec: DiskCodec) -> Bool {
        switch codec {
        case .lzvn: (forkCount + 4095) / 4096 * 5 <= (rawCount + 4095) / 4096 * 4
        case .lzbitmap, .lzfse: forkCount * 100 < rawCount * 93
        }
    }

    static func header(type: UInt32, size: Int) -> InlineArray<16, UInt8> {
        var header = InlineArray<16, UInt8>(repeating: 0)
        var span = header.mutableSpan
        var writer = AlignedBytesWriter(MutableRawSpan(mutating: &span))
        // 16 bytes into 16: it can't run out of room.
        _ = try? writer.write(DecmpfsHeader(type: type, size: UInt64(size)))
        return header
    }

}

/// The codecs `decmpfs` files use here.
enum DiskCodec: Sendable {
    /// Types 7 and 8: what `xip --expand` writes (always the fork, 8).
    case lzvn
    case lzfse
    case lzbitmap

    /// The byte before a chunk stored raw: `0x06` for LZVN (its end-of-stream opcode, which no compressed chunk starts
    /// with), `0xFF` for the others.
    var rawMarker: UInt8 { self == .lzvn ? 0x06 : 0xFF }

    /// Whether a small file may go inline (the attribute's data): `aa extract` puts them there; `xip --expand` writes
    /// every LZVN file as a fork.
    var allowsInline: Bool { self != .lzvn }
}

/// A writer's `decmpfs` chunk encoders, each made on its first use and kept (BytesCompression's: their tables are
/// allocated and zeroed at creation, and encoding allocates nothing). Used by one writer thread at a time.
///
/// An archive's files almost always use one codec (LZBITMAP for `aa`'s, LZVN for a xip's), so making only what's used
/// saves each writer the others' tables: of LZBITMAP's 560 KB, LZFSE's 800 KB, and LZVN's 512 KB, 1.3–1.4 MB a writer.
///
/// All three write Compression's streams byte for byte (LZBITMAP, LZFSE, and LZVN with Compression's parse, 0x900),
/// and fail where it fails, so files are stored as `aa extract` and `xip --expand` store them.
final class ChunkEncoders {
    private var lzbitmap: LZBitmapEncoder?
    private var lzfse: LZFSEEncoder?
    private var lzvn: LZVNEncoder?

    init() {}

    /// Compresses one chunk (at most ``Decmpfs/chunkSize`` bytes) into `output` (room for a whole chunk and one byte
    /// more, whatever `count`): compressed, if that works and is smaller; or the codec's raw marker and the raw bytes.
    ///
    /// The encoders' output depends on their room, and the two Apple extractors give different room:
    /// - `aa extract` (LZBITMAP) gives every chunk a whole chunk's room, short ones (small files, a file's last chunk)
    ///   included: LZBITMAP's compressed path needs working room beyond its result, and with only the chunk's own size,
    ///   1,604 of Xcode's files were stored differently (raw where it compressed). With a whole chunk, all 167,542 of
    ///   its items match `aa extract` byte for byte, stored compressed bytes included.
    /// - `xip --expand` (LZVN) gives each chunk its own size: LZVN needs 1–10 bytes beyond its stream, so a short last
    ///   chunk that shrinks by less is stored raw (42 of Xcode 27.2's files). Full chunks come out the same with any room
    ///   (all 153,662 compressed chunks of Xcode 27.2's forks).
    /// LZFSE (no Apple extractor writes it) gets a whole chunk's room.
    ///
    /// - Returns: The bytes written: at most `count + 1`.
    func compress(_ input: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, codec: DiskCodec) -> Int {
        let room = codec == .lzvn ? count : Decmpfs.chunkSize
        let written = unsafe encode(input, count: count, into: output, room: room, codec: codec)
        if written > 0, written < count { return written }
        unsafe output.storeBytes(of: codec.rawMarker, as: UInt8.self)
        unsafe (output + 1).copyMemory(from: input, byteCount: count)
        return count + 1
    }

    /// Encodes `count` bytes into `output` with `room` bytes of room (the encoders' destination size, which their
    /// output depends on: LZBITMAP's compressed path needs working room beyond its result).
    ///
    /// - Returns: The encoded size, or 0 if it doesn't fit.
    func encode(_ input: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, room capacity: Int, codec: DiskCodec) -> Int {
        // The chunk and the output are the caller's, valid for `count` and `capacity` bytes during the call.
        let source = unsafe RawSpan(_unsafeStart: input, byteCount: count)
        let buffer = unsafe UnsafeMutableRawBufferPointer(start: output, count: capacity)
        var target = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
        let fits: Bool
        switch codec {
        case .lzbitmap:
            if lzbitmap == nil { lzbitmap = LZBitmapEncoder() }
            fits = (try? lzbitmap!.compress(source, into: &target)) != nil
        case .lzfse:
            if lzfse == nil { lzfse = LZFSEEncoder() }
            fits = (try? lzfse!.compressAll(source, into: &target)) != nil
        case .lzvn:
            if lzvn == nil { lzvn = LZVNEncoder() }
            fits = (try? lzvn!.compressAll(source, into: &target)) != nil
        }
        let written = unsafe target.finalize(for: buffer)
        return fits ? written : 0
    }
}

/// Rewrites a file whose resource fork didn't pay as a plain file: each chunk read back from the fork, decompressed
/// (BytesCompression's LZBITMAP or LZFSE decoder), and written to the data fork; then the fork removed. Its buffers
/// and decoders are made once; the context holds a few, used by one writer at a time.
final class ForkUnpacker: @unchecked Sendable {
    private let stored = RawStorage(byteCount: Decmpfs.chunkSize + 64)
    private let raw = RawStorage(byteCount: Decmpfs.chunkSize)
    private var lzbitmap = LZBitmapDecoder()
    private var lzfse = LZFSEDecoder()

    /// Decompresses one chunk (as ``ChunkEncoders/compress(_:count:into:codec:)`` wrote it: compressed, or 0xFF and
    /// the raw bytes) from `stored` into exactly `rawCount` bytes of `raw`.
    private func decompressChunk(count: Int, rawCount: Int, codec: DiskCodec) -> Bool {
        guard count > 0 else { return rawCount == 0 }
        if unsafe stored.base.load(as: UInt8.self) == codec.rawMarker, count - 1 == rawCount {
            unsafe raw.base.copyMemory(from: stored.base + 1, byteCount: rawCount)
            return true
        }
        // Both buffers are this unpacker's, used by one writer at a time; the spans don't outlive the call.
        let input = unsafe RawSpan(_unsafeStart: stored.base, byteCount: count)
        var output = unsafe OutputRawSpan(buffer: UnsafeMutableRawBufferPointer(start: raw.base, count: rawCount), initializedCount: 0)
        do throws(BytesError) {
            switch codec {
            case .lzbitmap: _ = try lzbitmap.decompressAll(input, decodedSize: rawCount, into: &output)
            case .lzfse: _ = try lzfse.decompressAll(input, into: &output)
            case .lzvn: _ = try LZVNDecoder().decompressAll(input, into: &output)
            }
        } catch {
            return false
        }
        return unsafe output.finalize(for: UnsafeMutableRawBufferPointer(start: raw.base, count: rawCount)) == rawCount
    }

    func unpack(_ state: LargeFile) -> AEAError? {
        let descriptor = state.descriptor
        var offsets = InlineArray<2, UInt32>(repeating: 0)
        for chunk in 0..<state.chunkCount {
            let rawStart = chunk * Decmpfs.chunkSize
            let rawCount = min(Decmpfs.chunkSize, state.size - rawStart)
            // The chunk's table entry and the next: where it starts and ends in the fork.
            let read = withUnsafeMutableBytes(of: &offsets) { unsafe fgetxattr(descriptor, Decmpfs.resourceFork, $0.baseAddress, 8, UInt32(chunk * 4), 0) }
            guard read == 8 else { return .fileSystem("getxattr \(Decmpfs.resourceFork)", Errno(rawValue: errno)) }
            let start = Int(UInt32(littleEndian: offsets[0])), end = Int(UInt32(littleEndian: offsets[1]))
            guard end > start, end - start <= Decmpfs.chunkSize + 1 else { return .invalidArchive("a resource fork's chunk table") }
            let got = unsafe fgetxattr(descriptor, Decmpfs.resourceFork, stored.base, end - start, UInt32(start), 0)
            guard got == end - start else { return .fileSystem("getxattr \(Decmpfs.resourceFork)", Errno(rawValue: errno)) }
            guard decompressChunk(count: end - start, rawCount: rawCount, codec: state.codec) else {
                return .invalidArchive("a resource fork's chunk doesn't decompress")
            }
            var done = 0
            while done < rawCount {
                let written = unsafe pwrite(descriptor, raw.base + done, rawCount - done, off_t(rawStart + done))
                if written < 0 {
                    if errno == EINTR { continue }
                    return .fileSystem("write", Errno(rawValue: errno))
                }
                done += written
            }
        }
        if unsafe fremovexattr(descriptor, Decmpfs.resourceFork, 0) != 0 { return .fileSystem("removexattr", Errno(rawValue: errno)) }
        return nil
    }
}

/// An entry's archived times, applied with one `setattrlist` (modification and creation).
struct EntryTimes: Sendable {
    var modification: (seconds: Int64, nanoseconds: UInt32)?
    var creation: (seconds: Int64, nanoseconds: UInt32)?

    init() {}

    init(_ entry: AAEntryHeader) {
        modification = entry.modificationTime
        creation = entry.creationTime
    }

    var isEmpty: Bool { modification == nil && creation == nil }

    /// Calls `body` with the attribute list and its packed values (creation before modification: the bit order).
    func withAttributes<R>(_ body: (inout attrlist, UnsafeMutableRawPointer, Int) -> R) -> R {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let size = MemoryLayout<timespec>.size
        return withUnsafeTemporaryAllocation(byteCount: 2 * size, alignment: 8) { buffer in
            var count = 0
            if let creation {
                list.commonattr |= attrgroup_t(ATTR_CMN_CRTIME)
                unsafe buffer.storeBytes(of: timespec(tv_sec: Int(creation.seconds), tv_nsec: Int(creation.nanoseconds)), toByteOffset: count, as: timespec.self)
                count += size
            }
            if let modification {
                list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME)
                unsafe buffer.storeBytes(of: timespec(tv_sec: Int(modification.seconds), tv_nsec: Int(modification.nanoseconds)), toByteOffset: count, as: timespec.self)
                count += size
            }
            return unsafe body(&list, buffer.baseAddress!, count)
        }
    }

    /// Sets the times on an open file or directory.
    func apply(_ descriptor: Int32) -> Int32 {
        guard !isEmpty else { return 0 }
        return unsafe withAttributes { list, values, count in unsafe fsetattrlist(descriptor, &list, values, count, 0) }
    }

    /// Sets the times on a path relative to `directory`, not following a final symbolic link.
    func apply(_ directory: Int32, _ path: UnsafePointer<CChar>) -> Int32 {
        guard !isEmpty else { return 0 }
        return unsafe withAttributes { list, values, count in
            unsafe setattrlistat(directory, path, &list, values, count, UInt32(FSOPT_NOFOLLOW))
        }
    }
}
