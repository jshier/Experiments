import Bytes

/// Receives an Apple Archive stream's entries as the walker finds them, in order.
///
/// Spans are of segment buffers, for the call: a sink that keeps bytes past it retains their buffer through the pool
/// and finds them again by buffer and offset.
protocol ArchiveSink: ~Copyable {
    /// An entry's header: `header` is its bytes, in buffer `buffer`.
    nonisolated(nonsending) mutating func entry(_ entry: AAEntryHeader, header: RawSpan, buffer: Int) async throws(AEAError)
    /// A piece of the current entry's file contents, at `fileOffset` in the file: `bytes`, `offset` bytes from buffer
    /// `buffer`'s segment base.
    nonisolated(nonsending) mutating func data(_ bytes: RawSpan, offset: Int, fileOffset: Int, buffer: Int, segment: Int) async throws(AEAError)
    /// A piece of one of the current entry's metadata blobs, `offset` bytes into it.
    mutating func metadata(_ blob: AAMetadataBlob, _ bytes: RawSpan, offset: Int) throws(AEAError)
    /// The current entry's blobs are complete.
    nonisolated(nonsending) mutating func endEntry() async throws(AEAError)
}

/// The blobs an entry may carry besides its contents.
enum AAMetadataBlob: Sendable {
    /// `XAT`: extended attributes, entries of u32 size (the entry's, itself included), NUL-terminated name, value.
    case extendedAttributes
    /// `ACL`: access control entries, each u32 size, type, u64 flags, u64 permissions, qualifier type, qualifier.
    case accessControlList
}

/// Walks the Apple Archive stream across segments: headers, then each entry's blobs, routed to a sink.
///
/// Headers that cross a segment's end are made contiguous by copying their first bytes into the next buffer's
/// carry region; file contents are never copied (the sink gets spans of the buffers).
enum ArchiveWalker {
    nonisolated(nonsending) static func walk<Sink: ArchiveSink & ~Copyable>(_ source: some ChunkSource, into sink: inout Sink) async throws(AEAError) {
        let pool = source.pool
        var position = 0 // In the stream.
        var inHeader = true
        var entry = AAEntryHeader()
        var blobsStart = 0
        var blobsEnd = 0
        var previousBuffer = -1
        var previousStart = 0 // The previous chunk's offset in the stream.
        var carry = 0 // Bytes of a partial header at the end of the previous chunk.
        var streamEnd = 0
        defer {
            if previousBuffer >= 0 { pool.release(previousBuffer) }
        }
        while let chunk = try await source.nextChunk() {
            let buffer = chunk.buffer
            let start = chunk.rawOffset
            let end = start + chunk.rawSize
            streamEnd = end
            if carry > 0 {
                // The partial header goes just before this chunk's bytes. `carry` is under the carry region's size
                // (a header is at most 65,535 bytes), and the previous buffer is still held.
                pool.carry(carry, from: previousBuffer, at: position - previousStart, to: buffer)
                carry = 0
            }
            previousStart = start
            if previousBuffer >= 0 { pool.release(previousBuffer) }
            previousBuffer = buffer

            // Stream positions from `start - carry` to `end` are at `p - start` in the buffer.
            while true {
                if inHeader {
                    let available = end - position
                    if available == 0 { break }
                    if available < AppleArchive.minimumHeaderByteCount {
                        carry = available
                        break
                    }
                    let count = try AppleArchive.headerByteCount(pool.bytes(buffer, at: position - start, count: AppleArchive.minimumHeaderByteCount))
                    if available < count {
                        carry = available
                        break
                    }
                    let header = pool.bytes(buffer, at: position - start, count: count)
                    entry = try AppleArchive.parseHeader(header)
                    try await sink.entry(entry, header: header, buffer: buffer)
                    position += count
                    if entry.blobByteCount == 0 {
                        try await sink.endEntry()
                        continue
                    }
                    inHeader = false
                    blobsStart = position
                    blobsEnd = position + entry.blobByteCount
                }
                let stop = min(blobsEnd, end)
                if let data = entry.data, data.count > 0 {
                    let dataStart = blobsStart + data.offset
                    let low = max(position, dataStart), high = min(stop, dataStart + data.count)
                    if low < high {
                        try await sink.data(
                            pool.bytes(buffer, at: low - start, count: high - low), offset: low - start, fileOffset: low - dataStart,
                            buffer: buffer, segment: chunk.index
                        )
                    }
                }
                if let blob = entry.extendedAttributes, blob.count > 0 {
                    let blobStart = blobsStart + blob.offset
                    let low = max(position, blobStart), high = min(stop, blobStart + blob.count)
                    if low < high {
                        try sink.metadata(.extendedAttributes, pool.bytes(buffer, at: low - start, count: high - low), offset: low - blobStart)
                    }
                }
                if let blob = entry.accessControlList, blob.count > 0 {
                    let blobStart = blobsStart + blob.offset
                    let low = max(position, blobStart), high = min(stop, blobStart + blob.count)
                    if low < high {
                        try sink.metadata(.accessControlList, pool.bytes(buffer, at: low - start, count: high - low), offset: low - blobStart)
                    }
                }
                position = stop
                guard position == blobsEnd else { break }
                try await sink.endEntry()
                inHeader = true
            }
        }
        guard inHeader, carry == 0, position == streamEnd else {
            throw .invalidArchive("the stream ends inside an entry")
        }
    }
}
