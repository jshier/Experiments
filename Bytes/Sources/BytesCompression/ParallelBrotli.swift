public import Bytes
public import Dispatch

/// Brotli compressed on several cores at once: the input cut into chunks, each compressed by its own lane,
/// the lanes' meta-blocks joined in order into one standard stream that any decoder reads.
///
/// Three things make the chunks join. The first chunk alone writes the stream header (the window size), and
/// the last alone the final empty meta-block; every other chunk ends with an empty metadata block padded to
/// a byte (Google's flush), so the next starts on a byte boundary. Each chunk's lane is primed with up to
/// ``historySize`` bytes before the chunk, so matches reach back across the boundary (any distance within
/// the window is valid there: the decoder has those bytes). And since the decoder's last four distances at a
/// chunk's start depend on the chunks before it, which run at the same time, a lane starts with every last
/// distance unknown (``BrotliEngine/forgetDistances()``): it uses the short distance codes only for
/// distances of its own.
///
/// The synchronous and async forms schedule chunks as ``ParallelDeflateEncoder``'s do (``ChunkScheduler``).
/// Lanes and output slots are allocated once, at initialization.
@safe
public struct ParallelBrotliEncoder: ~Copyable {
    /// The quality, 1 through 9.
    public let quality: Int
    /// The window: `2^windowBits - 16` bytes.
    public let windowBits: Int
    /// The most bytes of input per chunk.
    public let chunkSize: Int
    /// The most bytes before a chunk inserted into its lane's table.
    public let historySize: Int
    /// The number of chunks compressed at once.
    public var laneCount: Int { lanes.count }

    private var lanes: UniqueArray<BrotliLane>
    private var slots: UniqueArray<ChunkSlot>
    private let scheduler = ChunkScheduler()

    /// The largest chunk: two meta-blocks, which a lane's staging buffer holds even uncompressed.
    public static var maximumChunkSize: Int { 512 << 10 }

    /// Creates an encoder.
    ///
    /// - Parameters:
    ///   - quality: 1 through 9 (clamped).
    ///   - windowBits: 10 through 24 (clamped).
    ///   - chunkSize: The most bytes of input per chunk, 32 KB through ``maximumChunkSize`` (clamped).
    ///   - historySize: The most bytes before each chunk to insert into its lane's table: more finds more
    ///     matches across the boundary, at the cost of inserting them. At most the window. At quality 5 on
    ///     24 lanes, 256 KB came within 1.1% (dickens) and 2.4% (a JavaScript bundle) of one stream's size at
    ///     full speed; 1 MB within 0.35% and 0.5%, 15–40% slower.
    ///   - lanes: How many chunks to compress at once, at least 1.
    public init(quality: Int = 5, windowBits: Int = 22, chunkSize: Int = 256 << 10, historySize: Int = 256 << 10, lanes: Int) {
        self.quality = min(max(quality, 1), 9)
        self.windowBits = min(max(windowBits, 10), 24)
        self.chunkSize = min(max(chunkSize, 32 << 10), Self.maximumChunkSize)
        self.historySize = min(max(historySize, 0), (1 << self.windowBits) &- 16)
        let quality = self.quality
        let windowBits = self.windowBits
        let laneCount = max(lanes, 1)
        var lanes = UniqueArray<BrotliLane>(capacity: laneCount)
        for _ in 0..<laneCount {
            lanes.append(BrotliLane(quality: quality, windowBits: windowBits))
        }
        self.lanes = lanes
        let slotCount = ParallelDeflateEncoder.slotCount(lanes: laneCount)
        var slots = UniqueArray<ChunkSlot>(capacity: slotCount)
        for _ in 0..<slotCount {
            slots.append(ChunkSlot(capacity: BrotliEngine.stagingCapacity))
        }
        self.slots = slots
    }

    /// The most bytes compressing `byteCount` bytes can produce.
    public func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        let chunks = max(1, (byteCount &+ chunkSize &- 1) / chunkSize) &+ lanes.count
        return BrotliEncoder.maximumCompressedSize(forByteCount: byteCount) &+ chunks &* 16
    }

    // MARK: - Synchronous

    /// Compresses all of `input` into `output` as one stream, compressing up to ``laneCount`` chunks at once.
    /// Blocks the calling thread until done.
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` runs out of room (what was written stays
    ///   written).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        let job = job(byteCount: input.byteCount)
        let (lanes, slots) = unsafe buffers()
        // Unsafe: the input and the output's free capacity as pointers, for the workers. Safe: both are
        // borrowed until the scheduler returns, after every worker is done; only what it delivered is counted.
        let source = input.withUnsafeBytes { unsafe UnsafeBytes(buffer: $0) }
        let target = unsafe ParallelDeflateEncoder.freeCapacity(of: &output)
        let delivery = unsafe scheduler.run(
            job, chunkCount: job.chunkCount, format: .raw, lanes: lanes, slots: slots, input: source, output: target, checksum: 0
        )
        try Self.commit(delivery, into: &output)
    }

    // MARK: - Async

    /// Compresses all of `input` into `output` as ``compressAll(_:into:)`` does, on `queue`: the calling task
    /// suspends until it's done, and its thread is free meanwhile.
    ///
    /// - Throws: As ``compressAll(_:into:)``.
    public nonisolated(nonsending) mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue) async throws(BytesError) {
        let job = job(byteCount: input.byteCount)
        let (lanes, slots) = unsafe buffers()
        // Unsafe and safe as in the synchronous form: this call waits for the closure.
        let source = input.withUnsafeBytes { unsafe UnsafeBytes(buffer: $0) }
        let target = unsafe ParallelDeflateEncoder.freeCapacity(of: &output)
        let scheduler = scheduler
        let delivery: ChunkScheduler.Delivery = await unsafe withUnsafeContinuation { continuation in
            queue.async {
                unsafe continuation.resume(returning: unsafe scheduler.run(
                    job, chunkCount: job.chunkCount, format: .raw, lanes: lanes, slots: slots, input: source, output: target,
                    checksum: 0
                ))
            }
        }
        try Self.commit(delivery, into: &output)
    }

    /// Compresses all of `input` into `output` as ``compressAll(_:into:)`` does, the workers child tasks of a
    /// task group on Swift's cooperative thread pool.
    ///
    /// - Throws: As ``compressAll(_:into:)``.
    public nonisolated(nonsending) mutating func compressAllConcurrently(_ input: RawSpan, into output: inout OutputRawSpan) async throws(BytesError) {
        let job = job(byteCount: input.byteCount)
        let (lanes, slots) = unsafe buffers()
        // Unsafe and safe as in the synchronous form: the task group ends before this call does.
        let source = input.withUnsafeBytes { unsafe UnsafeBytes(buffer: $0) }
        let target = unsafe ParallelDeflateEncoder.freeCapacity(of: &output)
        let delivery = await unsafe scheduler.runConcurrently(
            job, chunkCount: job.chunkCount, format: .raw, lanes: lanes, slots: slots, input: source, output: target, checksum: 0
        )
        try Self.commit(delivery, into: &output)
    }

    /// Counts what the workers delivered as initialized output.
    static func commit(_ delivery: ChunkScheduler.Delivery, into output: inout OutputRawSpan) throws(BytesError) {
        // Unsafe: counts the delivered bytes as initialized. Safe: the workers initialized exactly those, at
        // the start of the free capacity.
        unsafe output.withUnsafeMutableBytes { _, initializedCount in
            initializedCount &+= delivery.produced
        }
        guard !delivery.failed else { throw .insufficientCapacity }
    }

    // MARK: - Engine

    /// What one call compresses: the input's size, how it's cut into chunks, and the history to prime.
    struct Job: Sendable {
        let byteCount: Int
        let size: Int
        let chunkCount: Int
        let historySize: Int

        /// Chunk `index`'s range of the input.
        @inline(__always)
        func chunk(_ index: Int) -> Range<Int> {
            let start = min(index &* size, byteCount)
            return start..<min(start &+ size, byteCount)
        }
    }

    /// The job for `byteCount` bytes: equal chunks, at most ``chunkSize`` and at least 32 KB, a whole number
    /// per lane.
    func job(byteCount: Int) -> Job {
        let laneCount = lanes.count
        let rounds = max(1, (byteCount &+ laneCount &* chunkSize &- 1) / (laneCount &* chunkSize))
        let size = max(32 << 10, (byteCount &+ rounds &* laneCount &- 1) / (rounds &* laneCount))
        return Job(byteCount: byteCount, size: size, chunkCount: max(1, (byteCount &+ size &- 1) / size), historySize: historySize)
    }

    /// The lanes' and slots' storage, for the scheduler's workers.
    private mutating func buffers() -> (UnsafeLanes<BrotliLane>, UnsafeLanes<ChunkSlot>) {
        var laneSpan = lanes.mutableSpan
        var slotSpan = slots.mutableSpan
        // Unsafe: the storage as pointers that outlive the closures. Safe: `lanes` and `slots` never change
        // size after initialization, and callers use the pointers only within the method that took them.
        let lanes = laneSpan.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
        let slots = slotSpan.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
        return unsafe (lanes, slots)
    }
}

/// One lane of a parallel Brotli encoder: an engine of its own (tables, commands, staged output).
///
/// `@usableFromInline`: clients inline the encoder's destructor, which references this type's metadata (see
/// `BrotliCommand`).
@usableFromInline
struct BrotliLane: ~Copyable, ChunkLane {
    var engine: BrotliEngine

    init(quality: Int, windowBits: Int) {
        engine = BrotliEngine(quality: quality, windowBits: windowBits)
    }

    /// Moves the chunk's compressed bytes to `slot`, swapping staging buffers. (Brotli has no checksum.)
    mutating func handOff(into slot: inout ChunkSlot) {
        slot.range = engine.takeStaged(swapping: &slot.buffer)
    }

    /// Compresses chunk `index` of the job: the stream header first if it's the first chunk, otherwise
    /// primed history and unknown last distances; then its meta-blocks; then the final empty meta-block if
    /// it's the last chunk, or a flush to a byte boundary.
    mutating func compress(_ input: RawSpan, index: Int, job: ParallelBrotliEncoder.Job) {
        let chunk = job.chunk(index)
        engine.reset()
        let buffer = input.extracting(0..<chunk.upperBound)
        if index == 0 {
            engine.writeStreamHeader()
        } else {
            engine.forgetDistances()
            engine.prime(buffer, from: max(0, chunk.lowerBound &- job.historySize), to: chunk.lowerBound, origin: 0)
        }
        var position = chunk.lowerBound
        while position < chunk.upperBound {
            position = engine.compressMetablock(buffer, from: position, limit: chunk.upperBound, dataEnd: chunk.upperBound, origin: 0)
        }
        if index == job.chunkCount &- 1 {
            engine.writeLastEmptyMetablock()
        } else {
            engine.writeFlushMarker()
        }
    }
}
