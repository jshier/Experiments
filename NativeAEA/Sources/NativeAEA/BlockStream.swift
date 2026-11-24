import Bytes
import BytesAsync
import Disk
import Foundation
import Synchronization

// Apple Archive streams compressed by `aa archive -a ALGORITHM` (its default, LZFSE):
//
//     "pbz" | algorithm (u8) | block size (u64, big-endian)
//     per block: raw size (u64 BE) | stored size (u64 BE) | stored bytes
//
// Algorithms: `e` LZFSE, `x` LZMA (an xz stream), `z` zlib (RFC 1950), `4` LZ4 (Compression's `bv41` frames), `b`
// LZBITMAP, `m` LZRAVEN; the same letters as AEA segments. A block whose sizes are equal is stored as is. Blocks
// are independent, so they decode in parallel like AEA segments.

enum PBZ {
    static let headerSize = 12
    static let blockHeaderSize = 16

    /// Whether `bytes` (at least 4) start a `pbz` stream, and its algorithm.
    static func compression(_ bytes: RawSpan) -> AEACompression? {
        guard bytes.byteCount >= 4 else { return nil }
        let magic = bytes.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        guard magic >> 8 == 0x70_627A else { return nil } // "pbz"
        return AEACompression(rawValue: UInt8(truncatingIfNeeded: magic))
    }

    /// Whether `bytes` start a plain Apple Archive stream.
    static func isAppleArchive(_ bytes: RawSpan) -> Bool {
        guard bytes.byteCount >= 4 else { return false }
        let magic = bytes.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        return magic == 0x4141_3031 || magic == 0x5941_4131 // "AA01", "YAA1"
    }

    /// A stream's block size, from its 12-byte header.
    static func blockSize(_ bytes: RawSpan) throws(AEAError) -> Int {
        var reader = AlignedBytesReader(bytes)
        // Every pool and read buffer is sized from this: capped at 256 MiB each, so a hostile header can't ask for more.
        guard let header = try? reader.read(PBZHeader.self), header.blockSize > 0, header.blockSize <= 256 << 20 else {
            throw .invalidArchive("a pbz header")
        }
        return header.blockSize
    }

    /// A block's raw and stored sizes, from its 16-byte header.
    static func blockSizes(_ bytes: RawSpan, index: Int) throws(AEAError) -> (raw: Int, stored: Int) {
        var reader = AlignedBytesReader(bytes)
        guard let header = try? reader.read(PBZBlockHeader.self) else { throw .invalidArchive("pbz block \(index) sizes") }
        return (header.raw, header.stored)
    }
}

/// Chunks of a stream that isn't in AEA segments: the blocks of a `pbz` stream, read from a file or from an
/// AEA archive's decoded segments (``BlockStream/Input/upstream(_:)``), or slices of a plain Apple Archive file.
///
/// A producer task finds the blocks (reading each block header) and queues them; decoder tasks each take a free
/// output buffer, then the next block (in that order, so the block the consumer waits for always has a buffer), get
/// its stored bytes (a positioned read, or a copy the producer made from upstream buffers into a staging buffer),
/// decode them, and publish the buffer.
final class BlockStream: ChunkSource, @unchecked Sendable {
    enum Input {
        /// A file (Disk's `InputFile`, kept open while the stream runs), from `start` to `end`.
        case file(InputFile, start: Int, end: Int)
        /// The decoded chunks of another source (an AEA archive's segments), run by whoever made this one
        /// (``AEAPayload``).
        case upstream(any ChunkSource)
    }

    enum Layout {
        /// `pbz` blocks of at most `blockSize` raw bytes.
        case pbz(AEACompression, blockSize: Int)
        /// A plain stream, read in slices of `sliceSize`.
        case plain(sliceSize: Int)
    }

    private struct Job: Sendable {
        var index: Int
        var rawOffset: Int
        var rawSize: Int
        var storedSize: Int
        /// Where the stored bytes are in the file, or -1 when they're in staging buffer `staging`.
        var fileOffset: Int
        var staging: Int
    }

    /// A decoded block waiting for the consumer.
    private struct Slot {
        var index = -1
        var buffer = -1
        var rawOffset = 0
        var rawSize = 0
    }

    let pool: SegmentBufferPool
    private let input: Input
    private let layout: Layout
    private let decoderCount: Int
    /// Copies of blocks' stored bytes from upstream buffers (their blocks cross them freely).
    private let staging: SegmentBufferPool?
    /// Blocks to decode, from the producer to the decoders (BytesAsync's bounded queue).
    private let jobs: AsyncQueue<Job>

    private let cancelled = Atomic<Bool>(false)

    private struct State {
        /// Decoded blocks, block `i` at `i % slots.count`. Every block between the consumer's and a published one holds
        /// a buffer (decoders take jobs in order, each with a buffer), so at most `pool.count` are published at once
        /// and none overwrites another.
        var slots: [Slot]
        /// How many blocks there are, once the producer knows.
        var blockCount: Int?
        var failure: AEAError?
        /// The consumer, suspended until block `waitingFor` is published (or the count is known, or a failure).
        var consumer: Continuation<Void>?
        var waitingFor = -1
    }

    private let state: Mutex<State>
    /// The consumer's position: touched only by the consumer (its task).
    private var consumed = 0

    let counters = ChunkCounters()

    /// - Parameters:
    ///   - extraBuffers: Decoded blocks held at once beyond one per decoder (the consumer's and writers' too).
    init(_ input: Input, layout: Layout, decoders: Int, extraBuffers: Int) {
        self.input = input
        self.layout = layout
        decoderCount = max(1, decoders)
        let capacity = switch layout {
        case .pbz(_, let blockSize): blockSize
        case .plain(let sliceSize): sliceSize
        }
        // A buffer beyond the decoders' and what the consumer holds, so a decoder can always take the next block.
        pool = SegmentBufferPool(count: decoderCount + max(0, extraBuffers) + 1, segmentCapacity: capacity)
        if case .upstream = input {
            // Stored bytes are at most the raw size (`aa` stores a block that doesn't compress).
            staging = SegmentBufferPool(count: decoderCount + 2, segmentCapacity: capacity)
        } else {
            staging = nil
        }
        jobs = AsyncQueue(capacity: decoderCount * 2 + 2, waiters: decoderCount)
        state = Mutex(State(slots: Array(repeating: Slot(), count: pool.count)))
    }

    /// The pool's capacity per buffer: the largest block.
    var chunkCapacity: Int { pool.segmentCapacity }

    var pools: [SegmentBufferPool] {
        var pools = [pool]
        if let staging { pools.append(staging) }
        if case .upstream(let upstream) = input { pools += upstream.pools }
        return pools
    }

    nonisolated(nonsending) func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.produce() }
            for _ in 0..<decoderCount { group.addTask { await self.decodeTask() } }
        }
    }

    nonisolated(nonsending) func nextChunk() async throws(AEAError) -> DecodedChunk? {
        let start = MonotonicClock.now
        defer { counters.wait.add(MonotonicClock.nanoseconds(since: start), ordering: .relaxed) }
        let index = consumed
        while true {
            switch state.withLock({ Self.take(index, &$0) }) {
            case .some(.success(let chunk)):
                if chunk != nil { consumed = index + 1 }
                return chunk
            case .some(.failure(let error)):
                throw error
            case nil:
                await withContinuation { (continuation: Continuation<Void>) in
                    // Checked again under the lock publishing takes: no wakeup is lost.
                    let ready = state.withLock { state in
                        if state.failure != nil || (state.blockCount.map { index >= $0 } ?? false) || state.slots[index % state.slots.count].index == index {
                            return true
                        }
                        state.consumer = continuation
                        state.waitingFor = index
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }
    }

    /// Block `index` if it's published (`nil` past the last), the failure if there is one, or `nil` to wait.
    private static func take(_ index: Int, _ state: inout State) -> Result<DecodedChunk?, AEAError>? {
        if let failure = state.failure { return .failure(failure) }
        if let blockCount = state.blockCount, index >= blockCount { return .success(nil) }
        let position = index % state.slots.count
        let slot = state.slots[position]
        guard slot.index == index else { return nil }
        state.slots[position].index = -1
        return .success(DecodedChunk(index: index, buffer: slot.buffer, rawOffset: slot.rawOffset, rawSize: slot.rawSize))
    }

    func stop(_ failure: AEAError?) {
        cancelled.store(true, ordering: .relaxed)
        let consumer: Continuation<Void>? = state.withLock { state in
            guard let failure else { return nil }
            if state.failure == nil { state.failure = failure }
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume()
        // The producer waiting for room or a staging buffer, and decoders waiting for a buffer or a job, end.
        jobs.close()
        pool.close()
        staging?.close()
        if case .upstream(let upstream) = input { upstream.stop(failure) }
    }

    func releaseUnconsumed() {
        state.withLock { state in
            for position in state.slots.indices where state.slots[position].index >= 0 {
                pool.release(state.slots[position].buffer)
                state.slots[position].index = -1
            }
        }
        // Jobs queued but not decoded hold staging buffers.
        jobs.drain { job in
            if job.staging >= 0 { staging?.release(job.staging) }
        }
        if case .upstream(let upstream) = input { upstream.releaseUnconsumed() }
    }

    private func fail(_ error: AEAError) {
        stop(error)
    }

    // MARK: Producing

    private func finishProducing(_ count: Int) {
        let consumer: Continuation<Void>? = state.withLock { state in
            state.blockCount = count
            guard state.waitingFor >= count else { return nil }
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume()
        jobs.close()
    }

    nonisolated(nonsending) private func produce() async {
        do throws(AEAError) {
            switch input {
            case .file(let file, let start, let end):
                try await produce(from: file, start: start, end: end)
            case .upstream(let upstream):
                try await produce(from: upstream)
            }
        } catch {
            fail(error)
        }
    }

    /// Reads block headers from the file; decoders read the blocks themselves.
    nonisolated(nonsending) private func produce(from file: InputFile, start: Int, end: Int) async throws(AEAError) {
        var index = 0, rawOffset = 0
        switch layout {
        case .plain(let sliceSize):
            var offset = start
            while offset < end, !cancelled.load(ordering: .relaxed) {
                let count = min(sliceSize, end - offset)
                guard await jobs.push(Job(index: index, rawOffset: rawOffset, rawSize: count, storedSize: count, fileOffset: offset, staging: -1)) else { return }
                offset += count
                rawOffset += count
                index += 1
            }
        case .pbz(_, let blockSize):
            var offset = start + PBZ.headerSize
            var header = [UInt8](repeating: 0, count: PBZ.blockHeaderSize)
            while offset < end, !cancelled.load(ordering: .relaxed) {
                guard end - offset >= PBZ.blockHeaderSize else { throw .invalidArchive("a pbz block header is cut short") }
                try AEAArchive.read(file, at: offset, into: &header)
                let (raw, stored) = try PBZ.blockSizes(header.span.bytes, index: index)
                offset += PBZ.blockHeaderSize
                guard raw > 0, raw <= blockSize, stored > 0, stored <= raw, stored <= end - offset else {
                    throw .invalidArchive("pbz block \(index) sizes \(raw)/\(stored)")
                }
                guard await jobs.push(Job(index: index, rawOffset: rawOffset, rawSize: raw, storedSize: stored, fileOffset: offset, staging: -1)) else { return }
                offset += stored
                rawOffset += raw
                index += 1
            }
        }
        if !cancelled.load(ordering: .relaxed) { finishProducing(index) }
    }

    /// Reads the `pbz` stream out of the upstream's decoded chunks, copying each block's stored bytes into a staging
    /// buffer (blocks cross chunks).
    nonisolated(nonsending) private func produce(from upstream: any ChunkSource) async throws(AEAError) {
        guard case .pbz(_, let blockSize) = layout, let staging else { return }
        var reader = UpstreamReader(source: upstream)
        defer { reader.release() }
        try await reader.skip(PBZ.headerSize)
        var index = 0, rawOffset = 0
        let header = RawStorage(byteCount: PBZ.blockHeaderSize, alignment: RawStorage.small)
        while !cancelled.load(ordering: .relaxed) {
            let got = try await unsafe reader.read(into: header.base, count: PBZ.blockHeaderSize) // The header storage's size: safe.
            if got == 0 { break }
            guard got == PBZ.blockHeaderSize else { throw .invalidArchive("a pbz block header is cut short") }
            let (raw, stored) = try unsafe PBZ.blockSizes(RawSpan(_unsafeStart: header.base, byteCount: PBZ.blockHeaderSize), index: index) // The header storage's 16 bytes: safe.
            guard raw > 0, raw <= blockSize, stored > 0, stored <= raw else { throw .invalidArchive("pbz block \(index) sizes \(raw)/\(stored)") }
            guard let buffer = await staging.acquire() else { return } // Stopped.
            let copied: Int
            do throws(AEAError) {
                copied = try await unsafe reader.read(into: staging.segmentBase(buffer), count: stored) // `stored` ≤ the buffer's capacity.
            } catch {
                staging.release(buffer)
                throw error
            }
            guard copied == stored else {
                staging.release(buffer)
                throw .invalidArchive("pbz block \(index) is cut short")
            }
            guard await jobs.push(Job(index: index, rawOffset: rawOffset, rawSize: raw, storedSize: stored, fileOffset: -1, staging: buffer)) else {
                staging.release(buffer)
                return
            }
            rawOffset += raw
            index += 1
        }
        if !cancelled.load(ordering: .relaxed) { finishProducing(index) }
    }

    // MARK: Decoding

    nonisolated(nonsending) private func decodeTask() async {
        let compression: AEACompression = if case .pbz(let compression, _) = layout { compression } else { .none }
        var codec = SegmentCodec(compression: compression, framedLZ4: true)
        let readBuffer: RawStorage? = if case .file = input, case .pbz = layout { RawStorage(byteCount: pool.segmentCapacity + 64) } else { nil }
        while !cancelled.load(ordering: .relaxed), !Task.isCancelled {
            guard let buffer = await pool.acquire() else { return }
            guard let job = await jobs.pop() else {
                pool.release(buffer)
                return
            }
            if cancelled.load(ordering: .relaxed) {
                pool.release(buffer)
                if job.staging >= 0 { staging?.release(job.staging) }
                return
            }
            let started = MonotonicClock.now
            do throws(AEAError) {
                try decode(job, into: buffer, codec: &codec, readBuffer: readBuffer)
            } catch {
                pool.release(buffer)
                if job.staging >= 0 { staging?.release(job.staging) }
                fail(error)
                return
            }
            if job.staging >= 0 { staging?.release(job.staging) }
            counters.busy.add(MonotonicClock.nanoseconds(since: started), ordering: .relaxed)
            let consumer: Continuation<Void>? = state.withLock { state in
                state.slots[job.index % state.slots.count] = Slot(index: job.index, buffer: buffer, rawOffset: job.rawOffset, rawSize: job.rawSize)
                guard state.waitingFor == job.index else { return nil }
                defer { state.consumer = nil }
                return state.consumer
            }
            consumer?.resume()        }
    }

    private func decode(_ job: Job, into buffer: Int, codec: inout SegmentCodec, readBuffer: RawStorage?) throws(AEAError) {
        // The output buffer is this decoder's until it's published.
        let output = unsafe UnsafeMutableRawBufferPointer(start: pool.segmentBase(buffer), count: job.rawSize)
        let stored: UnsafeRawBufferPointer
        if job.staging >= 0, let staging {
            unsafe stored = UnsafeRawBufferPointer(start: staging.segmentBase(job.staging), count: job.storedSize)
        } else if case .file(let file, _, _) = input {
            let readStart = MonotonicClock.now
            defer { counters.read.add(MonotonicClock.nanoseconds(since: readStart), ordering: .relaxed) }
            if job.storedSize == job.rawSize {
                // Stored (or a plain slice): straight into the output.
                try unsafe AEAArchive.readFully(file, at: job.fileOffset, into: output)
                return
            }
            readBuffer!.reuse(job.storedSize)
            let destination = unsafe UnsafeMutableRawBufferPointer(start: readBuffer!.base, count: job.storedSize) // Stored ≤ raw ≤ its size.
            try unsafe AEAArchive.readFully(file, at: job.fileOffset, into: destination)
            unsafe stored = UnsafeRawBufferPointer(destination)
        } else {
            return
        }
        // The read buffer's pages past its floor go back once the block is decoded (a staged block doesn't use it).
        defer { if job.staging < 0 { readBuffer?.giveBack(job.storedSize) } }
        try unsafe codec.decode(stored, into: output, segment: job.index)
    }
}

/// Reads bytes sequentially across an upstream source's chunks, releasing each when it's used up.
struct UpstreamReader: ~Copyable {
    let source: any ChunkSource
    private var chunk: DecodedChunk?
    private var offset = 0
    /// Whether the first chunk was taken: before it, `chunk == nil` means "not yet"; after, the stream's end.
    private var started = false

    init(source: any ChunkSource) {
        self.source = source
    }

    /// The current chunk, taking the first if none was taken yet.
    nonisolated(nonsending) private mutating func current() async throws(AEAError) -> DecodedChunk? {
        if !started {
            started = true
            chunk = try await source.nextChunk()
        }
        return chunk
    }

    /// Copies up to `count` bytes to `destination`; fewer only at the stream's end.
    nonisolated(nonsending) mutating func read(into destination: UnsafeMutableRawPointer, count: Int) async throws(AEAError) -> Int {
        var done = 0
        while done < count {
            guard let current = try await current() else { break }
            let available = current.rawSize - offset
            if available == 0 {
                try await advance(past: current)
                continue
            }
            let take = min(available, count - done)
            // Within the chunk's decoded bytes and the destination's `count`: safe.
            unsafe (destination + done).copyMemory(from: source.pool.segmentBase(current.buffer) + offset, byteCount: take)
            offset += take
            done += take
        }
        return done
    }

    nonisolated(nonsending) mutating func skip(_ count: Int) async throws(AEAError) {
        var left = count
        while left > 0 {
            guard let current = try await current() else { throw .invalidArchive("the stream ends early") }
            let take = min(current.rawSize - offset, left)
            offset += take
            left -= take
            if offset == current.rawSize { try await advance(past: current) }
        }
    }

    /// Releases `current` and takes the next chunk. `chunk` is cleared first, so if taking the next one throws, the
    /// released buffer isn't released again (by ``release()``) while another decoder may already be using it.
    nonisolated(nonsending) private mutating func advance(past current: DecodedChunk) async throws(AEAError) {
        chunk = nil
        source.pool.release(current.buffer)
        offset = 0
        chunk = try await source.nextChunk()
    }

    /// Releases the chunk still held.
    mutating func release() {
        if let chunk { source.pool.release(chunk.buffer) }
        chunk = nil
    }
}
