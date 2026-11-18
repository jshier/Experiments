import Compression
import Darwin

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

    /// The Compression algorithm for a `decmpfs` type, and the type's inline and fork variants.
    static func algorithm(_ type: UInt32) -> (algorithm: compression_algorithm, inline: UInt32, fork: UInt32)? {
        switch type {
        case 11, 12: (COMPRESSION_LZFSE, 11, 12)
        case 13, 14: (COMPRESSION_LZBITMAP, 13, 14)
        default: nil
        }
    }

    static func header(type: UInt32, size: Int) -> InlineArray<16, UInt8> {
        var header = InlineArray<16, UInt8>(repeating: 0)
        let magic: UInt32 = 0x636D_7066 // "cmpf"
        for index in 0..<4 { header[index] = UInt8(truncatingIfNeeded: magic >> (8 * index)) }
        for index in 0..<4 { header[4 + index] = UInt8(truncatingIfNeeded: type >> (8 * index)) }
        for index in 0..<8 { header[8 + index] = UInt8(truncatingIfNeeded: UInt64(size) >> (8 * index)) }
        return header
    }

    /// Compresses one chunk into `output` (room for `count + 1` bytes): compressed, or 0xFF and the raw bytes.
    ///
    /// - Returns: The bytes written.
    @inline(__always)
    static func compressChunk(
        _ input: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer,
        scratch: UnsafeMutableRawPointer, algorithm: compression_algorithm
    ) -> Int {
        // Room for `count` compressed bytes: anything longer is stored raw.
        let written = unsafe compression_encode_buffer(
            output.assumingMemoryBound(to: UInt8.self), count, input.assumingMemoryBound(to: UInt8.self), count, scratch, algorithm
        )
        if written > 0, written < count { return written }
        unsafe output.storeBytes(of: 0xFF, as: UInt8.self)
        unsafe (output + 1).copyMemory(from: input, byteCount: count)
        return count + 1
    }
}

extension Decmpfs {
    /// Whether a resource fork of `forkCount` bytes is worth it for `rawCount` bytes: under 93% of them. Apple's
    /// extractor leaves files plain from a ratio of 0.930 up (Xcode 27.3 beta 2: the highest it compressed was
    /// 0.9293, the lowest it left plain 0.9304). Inline files are exempt: those always go inline.
    @inline(__always)
    static func pays(_ forkCount: Int, _ rawCount: Int) -> Bool {
        forkCount * 100 < rawCount * 93
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
