public import Bytes

/// Brotli compressed on several cores at once: the input cut into chunks, each compressed by its own lane,
/// the lanes' meta-blocks joined in order into one standard stream that any decoder reads.
///
/// Three things make the chunks join. The first chunk alone writes the stream header (the window size), and
/// the last alone the final empty meta-block; every other chunk ends with an empty metadata block padded to
/// a byte (Google's flush), so the next starts on a byte boundary. Each chunk's lane is primed with up to
/// ``historySize`` bytes before the chunk, so matches reach back across the boundary (any distance within
/// the window is valid there: the decoder has those bytes). And since the decoder's last four distances at a
/// chunk's start depend on the chunks before it, which run at the same time, a lane starts with every last
/// distance unknown (`BrotliEngine.forgetDistances()`): it uses the short distance codes only for
/// distances of its own.
///
/// The synchronous and async forms schedule chunks as ``ParallelDeflateEncoder``'s do (`ChunkScheduler`).
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
        // Unsafe: the input and the output's free capacity lent to the workers. Safe: `run` returns only once
        // every worker has.
        let delivery = unsafe input.withLent(output: &output) { source, target in
            unsafe batch(job, input: source, output: target).run()
        }
        try Self.end(delivery)
    }

    // MARK: - The steps of a call, for `BytesAsync`

    /// The workers of a call over lent input and output, to run.
    package mutating func batch(_ job: Job, input: LentBytes, output: LentMutableBytes) -> ChunkBatch {
        let (lanes, slots) = unsafe buffers()
        return unsafe scheduler.batch(
            job, chunkCount: job.chunkCount, format: .raw, lanes: lanes, slots: slots, input: input, output: output, checksum: 0
        )
    }

    /// Ends a call once its workers are done (the delivered bytes already counted in the output).
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if the output ran out of room.
    package static func end(_ delivery: ChunkDelivery) throws(BytesError) {
        guard !delivery.failed else { throw .insufficientCapacity }
    }

    // MARK: - Engine

    /// What one call compresses: the input's size, how it's cut into chunks, and the history to prime.
    package struct Job: Sendable {
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
    package func job(byteCount: Int) -> Job {
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
