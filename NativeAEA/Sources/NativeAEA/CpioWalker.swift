import Bytes
import BytesCompressionAsync
import Darwin

// The cpio "odc" format (POSIX.1 portable, `070707`), what an Xcode `.xip`'s `Content` holds once its pbzx blocks are
// decoded: per entry a 76-byte header of octal ASCII fields, the NUL-terminated name, then the file's bytes (a
// symbolic link's target, for links), with no padding; a `TRAILER!!!` entry ends the archive.
//
//     magic 6 | dev 6 | ino 6 | mode 6 | uid 6 | gid 6 | nlink 6 | rdev 6 | mtime 11 | namesize 6 | filesize 11
//
// Hard links share `dev` and `ino`.

public enum Cpio {
    static let headerSize = 76

    /// One entry's header fields.
    public struct Header {
        public var dev = 0
        public var ino = 0
        public var mode = 0
        public var uid = 0
        public var gid = 0
        public var nlink = 0
        public var rdev = 0
        public var mtime = 0
        public var nameSize = 0
        public var fileSize = 0
    }

    /// Parses the 76 header bytes that start `bytes`.
    ///
    /// - Throws: ``AEAError/invalidArchive(_:)`` for another magic or a field that isn't octal.
    public static func parseHeader(_ bytes: RawSpan) throws(AEAError) -> Header {
        // Exactly the header (a constant count lets the reader's checks fold).
        var reader = AlignedBytesReader(bytes.extracting(0..<headerSize))
        // The magic, "070707", as one comparison of 6 bytes.
        do throws(BytesError) {
            try reader.expect(Byte6(ascii: "070707"))
        } catch {
            throw .invalidArchive("no cpio (odc) magic")
        }
        var header = Header()
        // Each field is one or two 8-byte loads, checked and combined a word at a time (`asciiOctalDigits`).
        do throws(BytesError) {
            header.dev = try reader.read(Int.self, asciiOctalDigits: 6)
            header.ino = try reader.read(Int.self, asciiOctalDigits: 6)
            header.mode = try reader.read(Int.self, asciiOctalDigits: 6)
            header.uid = try reader.read(Int.self, asciiOctalDigits: 6)
            header.gid = try reader.read(Int.self, asciiOctalDigits: 6)
            header.nlink = try reader.read(Int.self, asciiOctalDigits: 6)
            header.rdev = try reader.read(Int.self, asciiOctalDigits: 6)
            header.mtime = try reader.read(Int.self, asciiOctalDigits: 11)
            header.nameSize = try reader.read(Int.self, asciiOctalDigits: 6)
            header.fileSize = try reader.read(Int.self, asciiOctalDigits: 11)
        } catch {
            throw .invalidArchive("a cpio header field isn't octal")
        }
        // Six octal digits hold up to 0o777777; a mode has 16 bits (type and permissions). More is a damaged or
        // tampered header (it trapped converting to `mode_t`, found fuzzing: 2026-11-23).
        guard header.mode <= 0o177777 else {
            throw .invalidArchive("a cpio mode wider than 16 bits (\(String(header.mode, radix: 8)))")
        }
        return header
    }

    /// The entry type for `mode`'s file type bits.
    public static func type(_ mode: Int) -> AAEntryType? {
        // Truncating: a mode is 16 bits (the header parser rejects wider ones), and no input may trap here.
        switch mode_t(truncatingIfNeeded: mode) & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        case S_IFIFO: .fifo
        case S_IFCHR: .characterDevice
        case S_IFBLK: .blockDevice
        case S_IFSOCK: .socket
        default: nil
        }
    }
}

/// Walks a cpio (odc) stream across decoded chunks, routing its entries to an ``ArchiveSink`` as Apple Archive
/// entries: the same extraction and listing.
///
/// Each entry's header and name (and a link's target) are made contiguous, as ``ArchiveWalker`` makes Apple Archive
/// headers, by copying a partial one into the next buffer's carry region; file contents are never copied.
enum CpioWalker {
    /// The longest header, name, and link target handled (within the carry region, ``AppleArchive/headerCarryCapacity``).
    static let maximumHeaderAndName = 65_535

    /// `xip --expand` compresses only files larger than this (16 KiB: every one of Xcode 27.2's files of 16,384
    /// bytes or fewer is plain, and every larger one is compressed unless it's a PNG or doesn't pay).
    static let xipCompressionThreshold = 16_384

    nonisolated(nonsending) static func walk<Sink: ArchiveSink & ~Copyable>(_ source: some ChunkSource, into sink: inout Sink) async throws(AEAError) {
        let pool = source.pool
        var position = 0 // In the stream.
        var inHeader = true
        var ended = false
        var dataStart = 0, dataEnd = 0 // The current file's contents in the stream.
        // The previous chunk, held until the next one has its partial header (the lease releases its buffer).
        var previous: DecodedBlock?
        var previousStart = 0
        var carry = 0
        var streamEnd = 0
        while let chunk = try await source.nextBlock() {
            let buffer = chunk.buffer.index, segment = chunk.index
            let start = chunk.rawOffset
            let end = start + chunk.rawSize
            streamEnd = end
            if carry > 0, let from = previous?.buffer.index {
                // The partial header goes just before this chunk's bytes; the previous buffer is still held.
                pool.carry(carry, from: from, at: position - previousStart, to: buffer)
                carry = 0
            }
            previousStart = start
            previous = consume chunk // Releases the one before.
            if ended { continue } // Padding after the trailer.

            // Stream positions from `start - carry` to `end` are at `p - start` in the buffer.
            while true {
                if inHeader {
                    let available = end - position
                    if available == 0 { break }
                    if available < Cpio.headerSize {
                        carry = available
                        break
                    }
                    // The fixed part is in this buffer (or carried before it).
                    let header = try Cpio.parseHeader(pool.bytes(buffer, at: position - start, count: Cpio.headerSize))
                    guard header.nameSize >= 1, header.nameSize <= PATH_MAX else { throw .invalidArchive("a cpio name size \(header.nameSize)") }
                    let type = Cpio.type(header.mode)
                    // A link's target is its contents: part of the header here, so that it's contiguous.
                    let isLink = type == .symbolicLink
                    if isLink, header.fileSize > Int(PATH_MAX) { throw .invalidArchive("a cpio link target of \(header.fileSize) bytes") }
                    let count = Cpio.headerSize + header.nameSize + (isLink ? header.fileSize : 0)
                    if available < count {
                        guard count <= maximumHeaderAndName else { throw .invalidArchive("a cpio header of \(count) bytes") }
                        carry = available
                        break
                    }
                    let headerBytes = pool.bytes(buffer, at: position - start, count: count)
                    // The name ends with its NUL, which must be its last byte.
                    guard headerBytes.load(fromByteOffset: Cpio.headerSize + header.nameSize - 1, as: UInt8.self) == 0 else {
                        throw .invalidArchive("a cpio name without its NUL")
                    }
                    let nameCount = header.nameSize - 1
                    if nameCount == 10,
                       headerBytes.extracting(Cpio.headerSize..<(Cpio.headerSize + nameCount)).hasPrefix(Byte10(ascii: "TRAILER!!!")) {
                        position += count
                        ended = true
                        break
                    }
                    let entry = try entryHeader(header, type: type, bytes: headerBytes)
                    try await sink.entry(entry, header: headerBytes, buffer: buffer)
                    position += count
                    if let data = entry.data, !data.isEmpty {
                        inHeader = false
                        dataStart = position
                        dataEnd = position + data.count
                    } else {
                        try await sink.endEntry()
                        continue
                    }
                }
                let stop = min(dataEnd, end)
                if position < stop {
                    try await sink.data(
                        pool.bytes(buffer, at: position - start, count: stop - position), offset: position - start,
                        fileOffset: position - dataStart, buffer: buffer, segment: segment
                    )
                }
                position = stop
                guard position == dataEnd else { break }
                try await sink.endEntry()
                inHeader = true
            }
        }
        // After the trailer only padding may follow (archivers pad to a block); before it, nothing may end.
        guard ended, position <= streamEnd else { throw .invalidArchive("the cpio stream ends without its trailer") }
    }

    /// The Apple Archive form of a cpio entry whose header (and name, and a link's target) is `bytes`.
    static func entryHeader(_ cpio: Cpio.Header, type: AAEntryType?, bytes header: RawSpan) throws(AEAError) -> AAEntryHeader {
        guard let type else { throw .invalidArchive("a cpio entry of an unknown type (mode \(String(cpio.mode, radix: 8)))") }
        var entry = AAEntryHeader()
        entry.byteCount = header.byteCount
        entry.type = type
        // Names are relative, `./a/b` or `.` for the root: the path without `./`, empty for the root.
        var nameOffset = Cpio.headerSize, nameCount = cpio.nameSize - 1
        if nameCount >= 2, header.load(fromByteOffset: nameOffset, as: UInt8.self) == 0x2E,
           header.load(fromByteOffset: nameOffset + 1, as: UInt8.self) == 0x2F {
            nameOffset += 2
            nameCount -= 2
        } else if nameCount == 1, header.load(fromByteOffset: nameOffset, as: UInt8.self) == 0x2E {
            nameCount = 0
        }
        entry.path = AAHeaderRange(offset: nameOffset, count: nameCount)
        entry.mode = UInt16(truncatingIfNeeded: cpio.mode & 0o7777)
        entry.uid = UInt32(truncatingIfNeeded: cpio.uid)
        entry.gid = UInt32(truncatingIfNeeded: cpio.gid)
        // Files keep their time; links get the extraction's, as `xip --expand` leaves them, and so do directories
        // unless the extraction asks for theirs (``AEAExtractionOptions/restoresXIPDirectoryTimes``; the sink drops them).
        if type == .regularFile || type == .directory { entry.modificationTime = (Int64(cpio.mtime), 0) }
        switch type {
        case .symbolicLink:
            entry.linkTarget = AAHeaderRange(offset: Cpio.headerSize + cpio.nameSize, count: cpio.fileSize)
        case .regularFile:
            entry.data = AAHeaderRange(offset: 0, count: cpio.fileSize)
            // `xip --expand`'s compression: LZVN forks for files over 16 KiB, stored by Disk's `StoragePolicy.lzvnForks`
            // (whether one pays, and PNGs, are decided with the data: the rest of `.xipExpand`'s rules).
            if cpio.fileSize > xipCompressionThreshold { entry.diskCompression = 8 }
            entry.blobByteCount = cpio.fileSize
            // A file with other names: the first one written, the others linked to it.
            if cpio.nlink > 1 { entry.hardLinkCluster = UInt64(truncatingIfNeeded: cpio.dev) &<< 32 | UInt64(truncatingIfNeeded: cpio.ino) }
        case .characterDevice, .blockDevice:
            entry.device = UInt64(truncatingIfNeeded: cpio.rdev)
        default:
            guard cpio.fileSize == 0 else { throw .invalidArchive("a cpio \(type) entry with contents") }
        }
        return entry
    }
}
