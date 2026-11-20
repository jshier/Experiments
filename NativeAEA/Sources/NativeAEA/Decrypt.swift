import Darwin
import Foundation
import System

extension AEAArchive {
    /// Decrypts (and decompresses) the archive's contents to a file, as `aea decrypt` does: the raw stream, whatever
    /// it is (an Apple Archive, a disk image, any file).
    ///
    /// Segments decode with ``AEAReadOptions/decodeThreads`` child tasks into the pool's buffers; the calling task
    /// writes each at its offset with positioned writes as it comes, in order. Only the segments a range needs are
    /// read. Runs off the caller's actor; cancelling the task stops it and throws ``AEAError/cancelled`` (the file
    /// keeps what was written).
    ///
    /// - Parameters:
    ///   - destination: The file to write; replaced if it exists and `overwrite` is set.
    ///   - range: The part of the contents to write (`aea decrypt -range-offset -range-size`), or `nil` for all.
    /// - Returns: Counts and timings.
    @concurrent @discardableResult
    public func decrypt(
        to destination: FilePath, range: Range<Int>? = nil, overwrite: Bool = false, options: AEAReadOptions = .init()
    ) async throws(AEAError) -> AEAStatistics {
        let started = DispatchTime.now().uptimeNanoseconds
        let wanted = range.map { $0.clamped(to: 0..<rootHeader.rawSize) } ?? 0..<rootHeader.rawSize
        // The segments overlapping the range (raw offsets are increasing).
        let first = segments.firstIndex { $0.rawOffset + $0.rawSize > wanted.lowerBound } ?? segments.count
        let end = segments[first...].firstIndex { $0.rawOffset >= wanted.upperBound } ?? segments.count
        let needed = wanted.isEmpty ? first..<first : first..<end

        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (overwrite ? O_TRUNC : O_EXCL)
        let output = unsafe open(destination.string, flags, 0o644)
        guard output >= 0 else { throw .fileSystem("open \(destination)", Errno(rawValue: errno)) }
        defer { close(output) }

        // At least one decoder, and a buffer beyond the one being written (fewer would wait forever).
        let decoders = max(1, options.decodeThreads)
        let pool = SegmentBufferPool(count: decoders + max(0, options.extraBuffers) + 1, segmentCapacity: rootHeader.segmentSize)
        let stream = try SegmentStream(
            archive: self, pool: pool, decoders: decoders, backend: options.decoder,
            verifyMACs: options.verifyMACs, verifyChecksums: options.verifyChecksums, input: options.input, segments: needed
        )
        var written = 0
        var writeNanoseconds = 0
        let failure: AEAError? = await stream.withDecoding { _ in
            do throws(AEAError) {
                for index in needed {
                    let buffer = try await stream.next(index)
                    defer { pool.release(buffer) }
                    let segment = segments[index]
                    // The part of this segment inside the range.
                    let low = max(wanted.lowerBound, segment.rawOffset), high = min(wanted.upperBound, segment.rawOffset + segment.rawSize)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let base = unsafe UnsafeRawPointer(pool.segmentBase(buffer)) + (low - segment.rawOffset)
                    var done = 0
                    while done < high - low {
                        // Within the segment's decoded bytes: safe.
                        let count = unsafe pwrite(output, base + done, high - low - done, off_t(low - wanted.lowerBound + done))
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw .fileSystem("write \(destination)", Errno(rawValue: errno))
                        }
                        done += count
                    }
                    written += done
                    writeNanoseconds += Int(DispatchTime.now().uptimeNanoseconds - start)
                }
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
        var statistics = AEAStatistics()
        statistics.fileBytes = written
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        statistics.decodeSeconds = Double(stream.counters.busy.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(stream.counters.read.load(ordering: .relaxed)) / 1e9
        statistics.writeSeconds = Double(writeNanoseconds) / 1e9
        statistics.walkWaitForSegments = Double(stream.counters.wait.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = pool.peakInUse.load(ordering: .relaxed)
        statistics.unreleasedBuffers = pool.buffersInUse
        return statistics
    }
}
