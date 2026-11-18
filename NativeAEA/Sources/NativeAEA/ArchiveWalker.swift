import Bytes

/// Receives an Apple Archive stream's entries as the walker finds them, in order.
///
/// Pointers are into segment buffers: valid until the walker releases the buffer (after
/// ``segmentFinished(buffer:)``) unless the sink retains it through the pool.
protocol ArchiveSink: ~Copyable {
    /// An entry's header. `header` points at its first byte, in buffer `buffer`.
    mutating func entry(_ entry: AAEntryHeader, header: UnsafeRawPointer, buffer: Int) throws(AEAError)
    /// A piece of the current entry's file contents, at `fileOffset` in the file.
    mutating func data(_ bytes: UnsafeRawPointer, count: Int, fileOffset: Int, buffer: Int, segment: Int) throws(AEAError)
    /// A piece of the current entry's extended attributes blob.
    mutating func extendedAttributes(_ bytes: UnsafeRawPointer, count: Int, offset: Int) throws(AEAError)
    /// The current entry's blobs are complete.
    mutating func endEntry() throws(AEAError)
}

/// Walks the Apple Archive stream across segments: headers, then each entry's blobs, routed to a sink.
///
/// Headers that cross a segment's end are made contiguous by copying their first bytes into the next buffer's
/// carry region; file contents are never copied (the sink gets pointers into the buffers).
enum ArchiveWalker {
    static func walk<Sink: ArchiveSink & ~Copyable>(_ stream: SegmentStream, into sink: inout Sink) throws(AEAError) {
        let archive = stream.archive
        let pool = stream.pool
        var position = 0 // In the stream.
        var inHeader = true
        var entry = AAEntryHeader()
        var blobsStart = 0
        var blobsEnd = 0
        var previousBuffer = -1
        var carry = 0 // Bytes of a partial header at the end of the previous segment.
        var consumed = 0
        defer {
            if previousBuffer >= 0 { pool.release(previousBuffer) }
            stream.finish(consumedThrough: consumed)
        }
        for segment in archive.segments {
            let buffer = try stream.next(segment.index)
            consumed = segment.index + 1
            let base = unsafe pool.segmentBase(buffer)
            let start = segment.rawOffset
            let end = start + segment.rawSize
            if carry > 0 {
                // The partial header goes just before this segment's bytes. `carry` is under the carry
                // region's size (a header is at most 65,535 bytes), and the previous buffer is still held.
                unsafe (base - carry).copyMemory(from: pool.segmentBase(previousBuffer) + (position - (start - archive.segments[segment.index - 1].rawSize)), byteCount: carry)
                carry = 0
            }
            if previousBuffer >= 0 { pool.release(previousBuffer) }
            previousBuffer = buffer

            // `pointer(p)` for stream positions from `start - carry` to `end`.
            func pointer(_ p: Int) -> UnsafeMutableRawPointer { unsafe base + (p - start) }

            while true {
                if inHeader {
                    let available = end - position
                    if available == 0 { break }
                    if available < AppleArchive.minimumHeaderByteCount {
                        carry = available
                        break
                    }
                    let count = try unsafe AppleArchive.headerByteCount(RawSpan(_unsafeStart: pointer(position), byteCount: AppleArchive.minimumHeaderByteCount)) // Within the buffer: safe.
                    if available < count {
                        carry = available
                        break
                    }
                    entry = try unsafe AppleArchive.parseHeader(RawSpan(_unsafeStart: pointer(position), byteCount: count)) // Same.
                    try unsafe sink.entry(entry, header: pointer(position), buffer: buffer)
                    position += count
                    if entry.blobByteCount == 0 {
                        try sink.endEntry()
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
                        try unsafe sink.data(pointer(low), count: high - low, fileOffset: low - dataStart, buffer: buffer, segment: segment.index)
                    }
                }
                if let attributes = entry.extendedAttributes, attributes.count > 0 {
                    let attributesStart = blobsStart + attributes.offset
                    let low = max(position, attributesStart), high = min(stop, attributesStart + attributes.count)
                    if low < high {
                        try unsafe sink.extendedAttributes(pointer(low), count: high - low, offset: low - attributesStart)
                    }
                }
                position = stop
                guard position == blobsEnd else { break }
                try sink.endEntry()
                inHeader = true
            }
        }
        guard inHeader, carry == 0, position == archive.rootHeader.rawSize else {
            throw .invalidArchive("the stream ends inside an entry")
        }
    }
}
