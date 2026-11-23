import Bytes
import BytesAsync
import Disk
import Foundation
import Synchronization
import System

/// How segments' stored bytes are read from the archive.
public enum SegmentInput: String, Sendable, CaseIterable {
    /// Positioned reads into one buffer per decoder: memory bounded by the decoders.
    case read
    /// The whole archive mapped, decoders reading the mapping: no copy, the kernel pages it in. If another process
    /// truncates the file while it's read, the process gets SIGBUS (positioned reads would get an error instead).
    case mapped
}

/// One decoded chunk of a stream, in a pool buffer the consumer releases.
struct DecodedChunk: Sendable {
    var index: Int
    var buffer: Int
    /// Where its bytes are in the decoded stream, and how many.
    var rawOffset: Int
    var rawSize: Int
}

/// Decoded chunks of a stream in order, each in a buffer of `pool`: AEA segments, `pbz` blocks, or slices of a
/// plain file.
///
/// ``run()`` decodes, in child tasks of its own, until the stream is decoded, fails, or is stopped; meanwhile one
/// consumer (the walker) calls ``prepare()``, then takes the chunks with ``nextChunk()`` until it returns `nil`,
/// releasing each buffer. ``withDecoding(onCancel:_:)`` puts the two together.
protocol ChunkSource: AnyObject, Sendable {
    /// The pool chunks come in: valid once ``prepare()`` has returned.
    var pool: SegmentBufferPool { get }
    /// Every pool the source decodes into (an upstream's and staging too), for checking that none leaks.
    var pools: [SegmentBufferPool] { get }
    /// Decodes the stream with child tasks, returning when they've all ended.
    nonisolated(nonsending) func run() async
    /// What the consumer calls first, while ``run()`` decodes: a source that must look at the decoded stream to know
    /// how to read it (``AEAPayload``) waits for its first chunk here.
    nonisolated(nonsending) func prepare() async throws(AEAError)
    /// The next chunk, suspending until it's decoded; `nil` after the last.
    ///
    /// - Throws: The first decoding failure, or ``AEAError/cancelled`` once stopped with it.
    nonisolated(nonsending) func nextChunk() async throws(AEAError) -> DecodedChunk?
    /// Stops decoding: no more chunks will be taken. Decoders waiting for a buffer or a job end; a consumer waiting
    /// for a chunk throws `failure` if one is given. Any thread may call it, any number of times.
    func stop(_ failure: AEAError?)
    /// Releases the buffers decoded but not taken. Called after ``run()`` has returned.
    func releaseUnconsumed()
    /// Time the decoders were busy, spent reading, and the consumer waited.
    var counters: ChunkCounters { get }
}

/// Nanoseconds a source's decoders were busy (summed) and spent reading, and its consumer waited.
final class ChunkCounters: Sendable {
    let busy = Atomic<Int>(0)
    let read = Atomic<Int>(0)
    let wait = Atomic<Int>(0)
}

extension ChunkSource {
    nonisolated(nonsending) func prepare() async throws(AEAError) {}

    /// Runs the decoders as child tasks while `consume` takes chunks on this task (it may add child tasks of its own
    /// to the group: writers), then stops them, waits for every child task, and releases what was decoded and not
    /// taken.
    ///
    /// Cancelling the task calls `onCancel`, stops the decoders, and makes the consumer's next ``nextChunk()`` throw
    /// ``AEAError/cancelled``: the operation's one cancellation handler. `consume` then returns, and the children end.
    nonisolated(nonsending) func withDecoding<R>(
        onCancel: @escaping @Sendable () -> Void = {}, _ consume: (inout DiscardingTaskGroup) async -> R
    ) async -> R {
        defer { releaseUnconsumed() }
        return await withTaskCancellationHandler {
            await withDiscardingTaskGroup(returning: R.self) { group in
                group.addTask { await self.run() }
                let result = await consume(&group)
                stop(nil)
                return result
            }
        } onCancel: {
            onCancel()
            stop(.cancelled)
        }
    }
}

/// Decodes an archive's segments with several tasks and hands them out in order.
///
/// Each decoder takes a free buffer from the pool, then the next segment (in that order, so the segment the
/// consumer waits for always has a buffer), reads and checks it, decodes it into the buffer, checks the
/// checksum, and publishes it. The consumer takes segments 0, 1, 2... and releases each buffer through the pool when
/// it's done with it.
final class SegmentStream: ChunkSource, @unchecked Sendable {
    let archive: AEAArchive
    let pool: SegmentBufferPool
    private let decoderCount: Int
    private let verifyMACs: Bool
    private let verifyChecksums: Bool
    private let input: SegmentInput
    /// The archive mapped read-only (Disk's `MappedFile`, read front to back), for ``SegmentInput/mapped``.
    private let mapping: MappedFile?

    private let nextSegment = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)

    private struct State {
        /// Each segment's buffer once decoded (-1 before, -2 once taken).
        var slots: [Int]
        var failure: AEAError?
        /// The consumer, suspended until segment `waitingFor` is published (or a failure).
        var consumer: Continuation<Void>?
        var waitingFor = -1
    }

    private let state: Mutex<State>

    let counters = ChunkCounters()

    /// The segments decoded: all of them, or those a partial decryption needs.
    let range: Range<Int>

    var pools: [SegmentBufferPool] { [pool] }

    /// The consumer's position: touched only by the consumer (its task).
    private var consumed: Int

    init(
        archive: AEAArchive, pool: SegmentBufferPool, decoders: Int,
        verifyMACs: Bool, verifyChecksums: Bool, input: SegmentInput, segments range: Range<Int>? = nil
    ) throws(AEAError) {
        self.archive = archive
        self.pool = pool
        self.range = range ?? 0..<archive.segments.count
        nextSegment.store(self.range.lowerBound, ordering: .relaxed)
        consumed = self.range.lowerBound
        decoderCount = max(1, min(decoders, self.range.count))
        self.verifyMACs = verifyMACs
        self.verifyChecksums = verifyChecksums
        self.input = input
        if input == .mapped {
            // The whole file: its size is the container's (checked when the archive opened).
            do throws(DiskError) {
                mapping = try archive.file.map(access: .sequential)
            } catch {
                throw AEAError(error)
            }
        } else {
            mapping = nil
        }
        state = Mutex(State(slots: Array(repeating: -1, count: archive.segments.count)))
    }

    nonisolated(nonsending) func run() async {
        await withDiscardingTaskGroup { group in
            for _ in 0..<decoderCount { group.addTask { await self.decodeTask() } }
        }
    }

    nonisolated(nonsending) func nextChunk() async throws(AEAError) -> DecodedChunk? {
        let index = consumed
        guard index < range.upperBound else { return nil }
        let buffer = try await next(index)
        consumed = index + 1
        let segment = archive.segments[index]
        return DecodedChunk(index: index, buffer: buffer, rawOffset: segment.rawOffset, rawSize: segment.rawSize)
    }

    /// The consumer's next chunk once it's decoded, without taking it (``nextChunk()`` still returns it): for looking
    /// at the stream's first bytes while the decoders run (``AEAPayload``).
    ///
    /// - Returns: `nil` past the last segment.
    nonisolated(nonsending) func peek() async throws(AEAError) -> DecodedChunk? {
        let index = consumed
        guard index < range.upperBound else { return nil }
        let buffer = try await next(index, taking: false)
        let segment = archive.segments[index]
        return DecodedChunk(index: index, buffer: buffer, rawOffset: segment.rawOffset, rawSize: segment.rawSize)
    }

    /// Waits for segment `index` and takes its buffer (the consumer's, to release), or with `taking` false only
    /// looks at it.
    nonisolated(nonsending) func next(_ index: Int, taking: Bool = true) async throws(AEAError) -> Int {
        let start = MonotonicClock.now
        defer { counters.wait.add(MonotonicClock.nanoseconds(since: start), ordering: .relaxed) }
        while true {
            switch state.withLock({ Self.take(index, taking: taking, &$0) }) {
            case .some(.success(let buffer)): return buffer
            case .some(.failure(let error)): throw error
            case nil:
                await withContinuation { (continuation: Continuation<Void>) in
                    // Checked again under the lock decoders publish under: no wakeup is lost.
                    let ready = state.withLock { state in
                        if state.failure != nil || state.slots[index] >= 0 { return true }
                        state.consumer = continuation
                        state.waitingFor = index
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }
    }

    /// The segment's buffer if it's published, the failure if there is one, or `nil` to wait.
    private static func take(_ index: Int, taking: Bool, _ state: inout State) -> Result<Int, AEAError>? {
        if let failure = state.failure { return .failure(failure) }
        let buffer = state.slots[index]
        guard buffer >= 0 else { return nil }
        if taking { state.slots[index] = -2 }
        return .success(buffer)
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
        // Decoders waiting for a buffer end.
        pool.close()
    }

    func releaseUnconsumed() {
        state.withLock { state in
            for index in state.slots.indices where state.slots[index] >= 0 {
                pool.release(state.slots[index])
                state.slots[index] = -2
            }
        }
    }

    nonisolated(nonsending) private func decodeTask() async {
        var codec = SegmentCodec(compression: archive.rootHeader.compression)
        let readBuffer = makeReadBuffer()
        while !cancelled.load(ordering: .relaxed), !Task.isCancelled {
            guard let buffer = await pool.acquire() else { return }
            // No yield between segments: yielding (after every segment, or after resuming the consumer), with or
            // without decoders at a lower priority than the walker, measured no different.
            guard decodeNext(into: buffer, codec: &codec, readBuffer: readBuffer) else { return }
        }
    }

    /// A decoder's read buffer: for positioned reads, and for decrypting (mapped input too).
    private func makeReadBuffer() -> RawStorage? {
        input == .read || archive.isEncrypted ? RawStorage(byteCount: archive.largestCompressedSegment + 64) : nil
    }

    /// Takes the next segment and decodes it into `buffer`, publishing it.
    ///
    /// - Returns: `false` when there's nothing more to decode (the end, a failure, or a stop).
    private func decodeNext(into buffer: Int, codec: inout SegmentCodec, readBuffer: RawStorage?) -> Bool {
        guard let index = nextSegment.claim(below: range.upperBound), !cancelled.load(ordering: .relaxed) else {
            pool.release(buffer)
            return false
        }
        let started = MonotonicClock.now
        do throws(AEAError) {
            try decode(index, into: buffer, codec: &codec, readBuffer: readBuffer)
        } catch {
            pool.release(buffer)
            stop(error)
            return false
        }
        counters.busy.add(MonotonicClock.nanoseconds(since: started), ordering: .relaxed)
        let consumer: Continuation<Void>? = state.withLock { state in
            state.slots[index] = buffer
            guard state.waitingFor == index else { return nil }
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume()
        return true
    }

    private func decode(_ index: Int, into buffer: Int, codec: inout SegmentCodec, readBuffer: RawStorage?) throws(AEAError) {
        let segment = archive.segments[index]
        // The buffer is this decoder's until it's published: nothing else writes it.
        let output = unsafe UnsafeMutableRawBufferPointer(start: pool.segmentBase(buffer), count: segment.rawSize)
        if segment.isStored, mapping == nil {
            // Stored as is: read straight into the output, then MACed, decrypted in place, and checked there, with no
            // copy through the read buffer (as `BlockStream` reads stored blocks).
            let readStart = MonotonicClock.now
            try unsafe AEAArchive.readFully(archive.file, at: segment.fileOffset, into: output) // `rawSize` == `compressedSize` bytes: safe.
            counters.read.add(MonotonicClock.nanoseconds(since: readStart), ordering: .relaxed)
            if verifyMACs {
                try unsafe SegmentChecks.verifyMAC(archive, segment: index, stored: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output))) // The output, this decoder's: safe.
            }
            if archive.isEncrypted {
                var bytes = unsafe MutableRawSpan(_unsafeBytes: output) // Same.
                archive.segmentKeys[index].crypt(&bytes)
            }
            if verifyChecksums {
                try unsafe SegmentChecks.verifyChecksum(archive, segment: index, raw: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output))) // Same.
            }
            return
        }
        if let readBuffer { readBuffer.reuse(segment.compressedSize) }
        defer { if let readBuffer { readBuffer.giveBack(segment.compressedSize) } }
        // `read` and `stored` are constants, each set once on every path: a `var` here, assigned in branches and
        // borrowed by the spans below, was boxed on the heap (one allocation per segment).
        let read: UnsafeRawBufferPointer
        if let mapping {
            // Unsafe: a buffer into the mapping. Safe: within it (segment offsets are checked against the file's size
            // when the archive opens, and `buffer` checks again); the stream keeps the mapping while decoders run.
            unsafe read = mapping.buffer(segment.fileOffset..<segment.fileOffset + segment.compressedSize)
        } else {
            let readBuffer = readBuffer!
            let readStart = MonotonicClock.now
            // The read buffer holds the largest segment: `compressedSize` fits.
            let destination = unsafe UnsafeMutableRawBufferPointer(start: readBuffer.base, count: segment.compressedSize)
            try unsafe AEAArchive.readFully(archive.file, at: segment.fileOffset, into: destination)
            counters.read.add(MonotonicClock.nanoseconds(since: readStart), ordering: .relaxed)
            unsafe read = UnsafeRawBufferPointer(destination)
        }
        if verifyMACs {
            try unsafe SegmentChecks.verifyMAC(archive, segment: index, stored: RawSpan(_unsafeBytes: read)) // `read` outlives the call: safe.
        }
        let stored: UnsafeRawBufferPointer
        if archive.isEncrypted {
            // MACed as stored, then decrypted: a segment stored uncompressed (mapped input) straight into the output; a
            // compressed one into the read buffer (in place when it was read there), then decoded from it.
            let key = archive.segmentKeys[index]
            let target = unsafe segment.isStored ? output : UnsafeMutableRawBufferPointer(start: readBuffer!.base, count: segment.compressedSize)
            var targetSpan = unsafe MutableRawSpan(_unsafeBytes: target) // Within the output or the read buffer, both this decoder's: safe.
            unsafe key.crypt(RawSpan(_unsafeBytes: read), into: &targetSpan)
            if segment.isStored {
                if verifyChecksums {
                    try unsafe SegmentChecks.verifyChecksum(archive, segment: index, raw: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output)))
                }
                return
            }
            unsafe stored = UnsafeRawBufferPointer(target)
        } else {
            unsafe stored = read
        }
        try unsafe codec.decode(stored, into: output, segment: index)
        if verifyChecksums {
            try unsafe SegmentChecks.verifyChecksum(archive, segment: index, raw: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output))) // Same.
        }
    }
}
