internal import Bytes
internal import Dispatch
internal import Synchronization

/// One lane of a parallel encoder, as the scheduler drives it: compresses a chunk, then hands its output to
/// a slot.
protocol ChunkLane: ~Copyable, SendableMetatype {
    associatedtype Job: Sendable
    /// Compresses chunk `index` of `job` into the lane's staged output.
    mutating func compress(_ input: RawSpan, index: Int, job: Job)
    /// Moves the chunk's output into `slot` without copying it (swapping buffers), with its checksum.
    mutating func handOff(into slot: inout ChunkSlot)
}

/// A compressed chunk waiting its turn to be delivered: a staging buffer swapped out of the lane that
/// compressed it, so the lane can go on to another chunk.
@usableFromInline
struct ChunkSlot: ~Copyable {
    var buffer: StagingBuffer
    /// Where the chunk's bytes are in `buffer`.
    var range = 0..<0
    /// The chunk's checksum (CRC-32 or Adler-32 of its input, or 0) and input length, for combining.
    var checksum: UInt32 = 0
    var inputLength = 0
    /// The chunk the slot holds, or -1. Read and written only under the scheduler's lock.
    var index = -1

    /// A slot with an uninitialized buffer of `capacity` bytes: a lane writes it before it's read.
    init(capacity: Int) {
        buffer = StagingBuffer(count: capacity)
    }
}

/// Runs a parallel encoder's chunks on worker threads, each taking the next chunk as it finishes the last,
/// and delivers their output in order as it becomes ready.
///
/// Against rounds of one chunk per lane with a barrier after each: the threads are woken once per call, not
/// once per round (a wake took 0.1–0.7 ms on an M3 Ultra, and some threads started at lower clocks), and
/// output is copied while other chunks are still being compressed, by whichever worker finishes the next
/// chunk in order, instead of while every lane waits.
///
/// Chunk `i`'s output goes to slot `i % slotCount`. A worker hands its output over once that slot's previous
/// chunk is delivered, so with a few more slots than workers, workers don't wait.
@usableFromInline
final class ChunkScheduler: Sendable {
    struct State: InOrderDelivery {
        /// Chunks delivered so far: the next to deliver.
        var delivered = 0
        /// Whether a worker is copying a chunk to the output.
        var delivering = false
        /// Output bytes delivered.
        var produced = 0
        var checksum: UInt32 = 0
        /// Set when the output ran out of room: workers stop taking chunks.
        var failed = false
        /// The call's chunks: a stop counts as a cancellation only if it left some undelivered.
        var chunkCount = 0
    }

    let state = Mutex(State())
    let next = Atomic(0)

    init() {}

    /// Prepares for a call: no chunks taken or delivered, every slot empty (a slot still naming a chunk of the last
    /// call would look ready).
    func start(checksum: UInt32, chunkCount: Int, slots: UnsafeLanes<ChunkSlot>) {
        next.store(0, ordering: .relaxed)
        state.withLock { state in
            state = State(checksum: checksum, chunkCount: chunkCount)
            // Unsafe: writes the slots. Safe: no worker is running.
            for slot in unsafe slots.buffer.indices {
                unsafe slots.buffer[slot].index = -1
            }
        }
    }

    /// Prepares a call over lent input and output: the workers, each a closure, run by ``ChunkBatch/run()`` on
    /// `concurrentPerform` or by `BytesCompressionAsync`'s task group, and stopped by the batch's ``StopFlag``.
    func batch<Lane: ChunkLane & ~Copyable>(
        _ job: Lane.Job, chunkCount: Int, format: DeflateFormat, lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>,
        input: LentBytes, output: LentMutableBytes, checksum: UInt32
    ) -> ChunkBatch {
        unsafe start(checksum: checksum, chunkCount: chunkCount, slots: slots)
        let workers = min(unsafe lanes.buffer.count, chunkCount)
        let stop = StopFlag()
        // Unsafe: lane `w` from worker `w`, slots and output as the protocol in `work` allows; the input and
        // output are lent for as long as the batch runs.
        return ChunkBatch(workerCount: workers, scheduler: self, stop: stop) { w in
            unsafe self.work(w, job, chunkCount: chunkCount, format: format, lanes: lanes, slots: slots, input: input, output: output, stop: stop)
        }
    }

    /// Runs a call over lent input and output on `concurrentPerform`, which returns when every chunk is
    /// delivered (or the output is full): ``batch(_:chunkCount:format:lanes:slots:input:output:checksum:)``'s
    /// workers called directly, without a ``ChunkBatch`` (whose escaping closure is an allocation per call), and
    /// never stopped.
    func run<Lane: ChunkLane & ~Copyable>(
        _ job: Lane.Job, chunkCount: Int, format: DeflateFormat, lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>,
        input: LentBytes, output: LentMutableBytes, checksum: UInt32
    ) -> ChunkDelivery {
        unsafe start(checksum: checksum, chunkCount: chunkCount, slots: slots)
        let workers = min(unsafe lanes.buffer.count, chunkCount)
        // Unsafe: as in `batch`. Safe: `concurrentPerform` returns only once every worker has.
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            unsafe self.work(w, job, chunkCount: chunkCount, format: format, lanes: lanes, slots: slots, input: input, output: output, stop: nil)
        }
        return finish(stop: nil)
    }

    /// What the call delivered, once its workers are done: cancelled if `stop` was set before every chunk was
    /// delivered.
    fileprivate func finish(stop: StopFlag?) -> ChunkDelivery {
        let stopped = stop?.isStopped ?? false
        return state.withLock {
            ChunkDelivery(
                produced: $0.produced, checksum: $0.checksum, failed: $0.failed,
                cancelled: stopped && $0.delivered < $0.chunkCount
            )
        }
    }

    /// Worker `w`'s loop: take a chunk, compress it in lane `w`, wait for its slot, hand the output over,
    /// deliver whatever is ready.
    ///
    /// Unsafe: lanes, slots, input, and output are shared pointers. Safe: lane `w` is only this worker's; a
    /// slot is written by the worker holding its chunk only after the slot's previous chunk was delivered,
    /// and read by the one delivering worker only after its chunk was published, both under the lock;
    /// output bytes are written only by the delivering worker.
    private func work<Lane: ChunkLane & ~Copyable>(
        _ w: Int, _ job: Lane.Job, chunkCount: Int, format: DeflateFormat,
        lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>, input: LentBytes, output: LentMutableBytes, stop: StopFlag?
    ) {
        let slotCount = unsafe slots.buffer.count
        let source = unsafe input.span
        while true {
            let index = next.wrappingAdd(1, ordering: .relaxed).oldValue
            // Stopped: no more chunks (those taken are finished and delivered).
            guard index < chunkCount, stop?.isStopped != true else { break }
            unsafe lanes.buffer[w].compress(source, index: index, job: job)
            // Wait for the slot: its previous chunk, `index - slotCount`, delivered. Rare with a few spare slots;
            // meanwhile, deliver what's ready (the chunk this one waits for may be).
            var failed = false
            while true {
                let free = state.withLock { state in
                    failed = state.failed
                    return state.delivered > index &- slotCount
                }
                if free || failed { break }
                unsafe deliverReady(chunkCount: chunkCount, format: format, slots: slots, output: output)
                sched_yield()
            }
            if failed { break }
            let slot = index % slotCount
            unsafe lanes.buffer[w].handOff(into: &slots.buffer[slot])
            state.withLock { _ in unsafe slots.buffer[slot].index = index }
            unsafe deliverReady(chunkCount: chunkCount, format: format, slots: slots, output: output)
        }
    }

    /// Copies chunks to the output in order while the next one is ready and no other worker is copying
    /// (``InOrderDelivery``); stops at one that doesn't fit (the call fails).
    ///
    /// Unsafe: slots and output are shared pointers. Safe: as in `work`.
    private func deliverReady(chunkCount: Int, format: DeflateFormat, slots: UnsafeLanes<ChunkSlot>, output: LentMutableBytes) {
        let slotCount = unsafe slots.buffer.count
        state.deliverInOrder { state -> (index: Int, offset: Int)? in
            let index = state.delivered
            guard !state.failed, index < chunkCount, unsafe slots.buffer[index % slotCount].index == index else { return nil }
            return (index, state.produced)
        } copy: { claimed -> (fits: Bool, length: Int, checksum: UInt32, inputLength: Int) in
            let slot = claimed.index % slotCount
            let range = unsafe slots.buffer[slot].range
            let fits = unsafe range.count <= output.buffer.count &- claimed.offset
            if fits && !range.isEmpty {
                // Unsafe: a raw copy from the slot's buffer into the output. Safe: within both (checked just
                // above); only this worker is delivering.
                unsafe slots.buffer[slot].buffer.span.withUnsafeBytes { source in
                    unsafe output.buffer.baseAddress!.advanced(by: claimed.offset)
                        .copyMemory(from: source.baseAddress!.advanced(by: range.lowerBound), byteCount: range.count)
                }
            }
            return unsafe (fits, range.count, slots.buffer[slot].checksum, slots.buffer[slot].inputLength)
        } record: { state, _, copied in
            guard copied.fits else {
                state.failed = true
                return false
            }
            state.delivered &+= 1
            state.produced &+= copied.length
            state.checksum = format.combine(state.checksum, copied.checksum, secondLength: copied.inputLength)
            return true
        }
    }
}

/// A parallel call's delivery state, under its lock: what ``Mutex/deliverInOrder(claim:copy:record:)`` needs of it.
protocol InOrderDelivery: Sendable {
    /// Whether a worker is copying a piece to the output: one at a time.
    var delivering: Bool { get set }
}

extension Mutex where Value: InOrderDelivery {
    /// The in-order delivery the synchronous parallel codecs share (the encoders' ``ChunkScheduler``, the decoder's
    /// segments in `ParallelDeflateDecoder`): pieces (compressed chunks, decoded segments) finish on any worker in any
    /// order, and each is copied to the output as soon as every piece before it is, by whichever worker makes it ready,
    /// one worker at a time, while the others go on working. A worker calls this after each piece it finishes: while
    /// no other worker is copying and the next piece is ready, it claims it under the lock, copies it outside the lock,
    /// and records it under the lock.
    ///
    /// - Parameters:
    ///   - claim: Under the lock, with no worker copying: the next piece in order if it's ready to copy, or `nil`.
    ///   - copy: Outside the lock, by the one copying worker: copies the claimed piece; returns what `record` needs.
    ///   - record: Under the lock, the copy done: records it; returns whether to look for the next piece.
    @inline(__always)
    func deliverInOrder<Claim: Sendable, Copied: Sendable>(
        claim: (inout Value) -> Claim?, copy: (Claim) -> Copied, record: (inout Value, Claim, Copied) -> Bool
    ) {
        while true {
            let claimed: Claim? = withLock { state in
                guard !state.delivering, let claimed = claim(&state) else { return nil }
                state.delivering = true
                return claimed
            }
            guard let claimed else { return }
            let copied = copy(claimed)
            let goesOn = withLock { state in
                state.delivering = false
                return record(&state, claimed, copied)
            }
            if !goesOn { return }
        }
    }
}

/// A request to stop a parallel call early, shared with its workers: set from any thread (an async call's task
/// cancellation handler), checked as each worker takes its next piece of work (a chunk, a segment). The one stop
/// flag of the synchronous parallel codecs: each call that can be stopped has its own (``ChunkBatch``'s, the one
/// `ParallelDeflateDecoder`'s async forms pass), so nothing is left set for the next call.
package final class StopFlag: Sendable {
    private let stopped = Atomic(false)

    package init() {}

    /// Asks the call to stop.
    package func stop() {
        stopped.store(true, ordering: .relaxed)
    }

    /// Whether ``stop()`` was called.
    package var isStopped: Bool {
        stopped.load(ordering: .relaxed)
    }
}

/// What one call of a parallel encoder delivered.
package struct ChunkDelivery: Sendable {
    /// Output bytes delivered, from the start of the lent output.
    package var produced: Int
    /// The data's checksum, combined from the chunks'.
    package var checksum: UInt32
    /// Whether the output ran out of room.
    package var failed: Bool
    /// Whether the call was stopped (``ChunkBatch/stop()``) before every chunk was delivered.
    package var cancelled: Bool

    package init(produced: Int = 0, checksum: UInt32 = 0, failed: Bool = false, cancelled: Bool = false) {
        self.produced = produced
        self.checksum = checksum
        self.failed = failed
        self.cancelled = cancelled
    }
}

/// One call's workers, ready to run over lent input and output: ``run()`` runs them on `concurrentPerform`;
/// `BytesCompressionAsync` runs ``work(_:)`` in a task group, then ``finish()``.
///
/// Each worker takes the next chunk as it finishes the last, so any number of threads can run them; the
/// input and output must stay lent until the last worker returns.
package struct ChunkBatch: Sendable {
    /// The workers to run, one each.
    package let workerCount: Int
    let scheduler: ChunkScheduler
    /// The call's stop request (``stop()``), which its workers check.
    let stopFlag: StopFlag
    let worker: @Sendable (Int) -> Void

    init(workerCount: Int, scheduler: ChunkScheduler, stop: StopFlag, worker: @escaping @Sendable (Int) -> Void) {
        self.workerCount = workerCount
        self.scheduler = scheduler
        stopFlag = stop
        self.worker = worker
    }

    /// Runs worker `index`, 0 through ``workerCount`` - 1: chunks until none are left.
    package func work(_ index: Int) {
        worker(index)
    }

    /// Stops the call early: the workers take no more chunks (those under way finish), and ``finish()`` reports
    /// it cancelled. For an async call's task cancellation handler; safe from any thread, before or while the batch
    /// runs.
    package func stop() {
        stopFlag.stop()
    }

    /// What the workers delivered, once they've all returned.
    package func finish() -> ChunkDelivery {
        scheduler.finish(stop: stopFlag)
    }

    /// Runs the workers on `concurrentPerform`, which returns when every chunk is delivered (or the output is
    /// full).
    package func run() -> ChunkDelivery {
        DispatchQueue.concurrentPerform(iterations: workerCount) { w in work(w) }
        return finish()
    }
}

extension RawSpan {
    /// This span and `output`'s free capacity lent to `body`, which returns what it delivered; counts the
    /// delivered bytes as initialized.
    func withLent(output: inout OutputRawSpan, _ body: (LentBytes, LentMutableBytes) -> ChunkDelivery) -> ChunkDelivery {
        unsafe withLentBytes { source in
            var delivery = ChunkDelivery()
            _ = unsafe output.withLentFreeCapacity { target in
                delivery = unsafe body(source, target)
                return delivery.produced
            }
            return delivery
        }
    }
}
