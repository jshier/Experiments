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
    var buffer: UniqueArray<UInt8>
    /// Where the chunk's bytes are in `buffer`.
    var range = 0..<0
    /// The chunk's checksum (CRC-32 or Adler-32 of its input, or 0) and input length, for combining.
    var checksum: UInt32 = 0
    var inputLength = 0
    /// The chunk the slot holds, or -1. Read and written only under the scheduler's lock.
    var index = -1

    init(capacity: Int) {
        buffer = UniqueArray(repeating: 0, count: capacity)
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
    struct State {
        /// Chunks delivered so far: the next to deliver.
        var delivered = 0
        /// Whether a worker is copying a chunk to the output.
        var delivering = false
        /// Output bytes delivered.
        var produced = 0
        var checksum: UInt32 = 0
        /// Set when the output ran out of room: workers stop taking chunks.
        var failed = false
    }

    let state = Mutex(State())
    let next = Atomic(0)

    init() {}

    /// What one call delivers.
    struct Delivery {
        var produced: Int
        var checksum: UInt32
        var failed: Bool
    }

    /// Prepares for a call: no chunks taken or delivered, every slot empty (a slot still naming a chunk of
    /// the last call would look ready).
    func start(checksum: UInt32, slots: UnsafeLanes<ChunkSlot>) {
        next.store(0, ordering: .relaxed)
        state.withLock { state in
            state = State(checksum: checksum)
            // Unsafe: writes the slots. Safe: no worker is running.
            for slot in unsafe slots.buffer.indices {
                unsafe slots.buffer[slot].index = -1
            }
        }
    }

    /// The synchronous form: workers on `concurrentPerform`, which returns when every chunk is delivered (or
    /// the output is full).
    func run<Lane: ChunkLane & ~Copyable>(
        _ job: Lane.Job, chunkCount: Int, format: DeflateFormat, lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>,
        input: UnsafeBytes, output: UnsafeMutableBytes, checksum: UInt32
    ) -> Delivery {
        unsafe start(checksum: checksum, slots: slots)
        let workers = min(unsafe lanes.buffer.count, chunkCount)
        // Unsafe: lane `w` from thread `w`, slots and output as the protocol in `work` allows.
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            unsafe work(w, job, chunkCount: chunkCount, format: format, lanes: lanes, slots: slots, input: input, output: output)
        }
        return finish()
    }

    /// The task-group form: one child task per worker.
    func runConcurrently<Lane: ChunkLane & ~Copyable>(
        _ job: Lane.Job, chunkCount: Int, format: DeflateFormat, lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>,
        input: UnsafeBytes, output: UnsafeMutableBytes, checksum: UInt32
    ) async -> Delivery {
        unsafe start(checksum: checksum, slots: slots)
        let workers = min(unsafe lanes.buffer.count, chunkCount)
        await withDiscardingTaskGroup { group in
            for w in 0..<workers {
                group.addTask {
                    unsafe self.work(w, job, chunkCount: chunkCount, format: format, lanes: lanes, slots: slots, input: input, output: output)
                }
            }
        }
        return finish()
    }

    private func finish() -> Delivery {
        state.withLock { Delivery(produced: $0.produced, checksum: $0.checksum, failed: $0.failed) }
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
        lanes: UnsafeLanes<Lane>, slots: UnsafeLanes<ChunkSlot>, input: UnsafeBytes, output: UnsafeMutableBytes
    ) {
        let slotCount = unsafe slots.buffer.count
        let source = unsafe RawSpan(_unsafeBytes: input.buffer)
        while true {
            let index = next.wrappingAdd(1, ordering: .relaxed).oldValue
            guard index < chunkCount else { break }
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

    /// Copies chunks to the output in order while the next one is ready and no other worker is copying.
    private func deliverReady(chunkCount: Int, format: DeflateFormat, slots: UnsafeLanes<ChunkSlot>, output: UnsafeMutableBytes) {
        let slotCount = unsafe slots.buffer.count
        while true {
            let claimed: (index: Int, offset: Int)? = state.withLock { state in
                let index = state.delivered
                guard !state.delivering, !state.failed, index < chunkCount, unsafe slots.buffer[index % slotCount].index == index else {
                    return nil
                }
                state.delivering = true
                return (index, state.produced)
            }
            guard let claimed else { return }
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
            let chunkChecksum = unsafe slots.buffer[slot].checksum
            let length = unsafe slots.buffer[slot].inputLength
            state.withLock { state in
                state.delivering = false
                guard fits else {
                    state.failed = true
                    return
                }
                state.delivered &+= 1
                state.produced &+= range.count
                switch format {
                case .raw: break
                case .zlib: state.checksum = Adler32.combine(state.checksum, chunkChecksum, secondLength: length)
                case .gzip: state.checksum = CRC32.combine(state.checksum, chunkChecksum, secondLength: length)
                }
            }
            if !fits { return }
        }
    }
}
