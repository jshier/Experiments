public import Bytes
internal import Dispatch

/// DEFLATE (raw, zlib, or gzip) compressed on several cores at once, pigz-style: the input is cut into
/// chunks, each compressed by its own lane, and the lanes' output joined in order into one standard stream
/// that any decoder reads.
///
/// Each chunk's compressor is primed with the 32 KB before the chunk (`DeflateCompressor.prime(_:from:to:)`),
/// so matches reach back across chunk boundaries as in a sequential stream, and every chunk but the last
/// ends with a sync flush (an empty stored block) so the next starts on a byte boundary. Against one
/// sequential stream that costs the flush (5 bytes per chunk), the priming (inserting 32 KB per chunk), and
/// fresh Huffman codes at each chunk's start: 0.02–0.06% of the size on Silesia's dickens. gzip's CRC-32
/// and zlib's Adler-32 are computed per chunk by the lanes and combined.
///
/// With ``independentChunks``, chunks aren't primed: no match crosses a chunk boundary, so a decoder can
/// decode the chunks in parallel too (``ParallelDeflateDecoder``), for a little compression.
///
/// Lanes (a compressor each) and output slots are allocated once, at initialization; Bytes' own code then
/// allocates nothing per call (Dispatch and Swift concurrency allocate their own bookkeeping: tens of small
/// blocks per call). The input is cut into equal chunks of at most ``chunkSize``, a whole number per lane.
/// One worker per lane takes the next chunk as it finishes the last, hands its output to a slot (swapping
/// buffers, no copy), and whichever worker finishes the next chunk in order copies it to the output while
/// the others go on compressing (`ChunkScheduler`). Three ways to run the workers:
///
/// - ``compressAll(_:into:)``: synchronous. Dispatch's `concurrentPerform` runs them, the calling thread
///   among them, and the call returns when all are done. For threads that may block: a dedicated I/O thread,
///   a command-line tool.
/// - ``compressAll(_:into:on:)``: async, on Dispatch. The whole call moves to a Dispatch queue and runs
///   there as the synchronous form does; the calling task suspends until it's done, its thread free for
///   other tasks, and Swift's cooperative threads never run the compression.
/// - ``compressAllConcurrently(_:into:)``: async, with Swift concurrency. The workers are child tasks of a
///   task group on the cooperative thread pool. The fastest of the three on an M3 Ultra (10% ahead of
///   `concurrentPerform`, whose last workers started later), but it occupies the cooperative pool's threads
///   for the whole call.
@safe
public struct ParallelDeflateEncoder: ~Copyable {
    /// The container: raw DEFLATE, zlib, or gzip.
    public let format: DeflateFormat
    /// The compression level, 0 through 9.
    public let level: Int
    /// The most bytes of input per chunk.
    public let chunkSize: Int
    /// Whether chunks are compressed without the previous chunk's history, so they can be decoded in
    /// parallel.
    public let independentChunks: Bool
    /// The number of chunks compressed at once.
    public var laneCount: Int { lanes.count }

    private var lanes: UniqueArray<DeflateLane>
    /// The one-shot forms' output slots and scheduler (`ChunkScheduler`).
    private var slots: UniqueArray<ChunkSlot>
    private let scheduler = ChunkScheduler()

    // Streaming (``compress(_:into:flush:)``): the window (32 KB of history, then up to one round of input),
    // allocated on first use; where the history ends and the input ends; the lanes of the last round still
    // to deliver; and the container's header or trailer bytes waiting.
    private var window = UniqueArray<UInt8>(capacity: 0)
    private var historyCount = 0
    private var windowEnd = 0
    private var started = false
    private var finished = false
    private var streamChecksum: UInt32 = 0
    private var streamLength = 0
    private var deliveryLane = 0
    private var deliveryEnd = 0
    private var trailerQueued = false
    private var trailerStaged = false
    private var small = InlineArray<16, UInt8>(repeating: 0)
    private var smallStart = 0
    private var smallEnd = 0

    /// The largest chunk: the most a lane's staging buffer holds compressed, with every block's worst case.
    public static var maximumChunkSize: Int { 512 << 10 }

    /// Creates an encoder.
    ///
    /// - Parameters:
    ///   - format: The container.
    ///   - level: The compression level, 0 through 9 (clamped).
    ///   - chunkSize: The most bytes of input per chunk, 32 KB through ``maximumChunkSize`` (clamped).
    ///     Larger chunks lose less to chunk boundaries; smaller ones spread a short input over more lanes.
    ///   - lanes: How many chunks to compress at once, at least 1: usually the number of performance cores
    ///     (efficiency cores finish their chunks last, and the call waits for them).
    ///   - independentChunks: Whether to compress each chunk without the previous one's history.
    public init(
        format: DeflateFormat = .raw, level: Int = 6, chunkSize: Int = 256 << 10, lanes: Int,
        independentChunks: Bool = false
    ) {
        self.format = format
        self.level = min(max(level, 0), 9)
        self.chunkSize = min(max(chunkSize, 32 << 10), Self.maximumChunkSize)
        self.independentChunks = independentChunks
        let level = self.level
        let laneCount = max(lanes, 1)
        var lanes = UniqueArray<DeflateLane>(capacity: laneCount)
        for _ in 0..<laneCount {
            lanes.append(DeflateLane(level: level))
        }
        self.lanes = lanes
        let slotCount = Self.slotCount(lanes: laneCount)
        var slots = UniqueArray<ChunkSlot>(capacity: slotCount)
        for _ in 0..<slotCount {
            slots.append(ChunkSlot(capacity: DeflateCompressor.stagingCapacity))
        }
        self.slots = slots
    }

    /// Slots for compressed chunks waiting to be delivered: a few more than lanes, so a lane rarely waits for
    /// one to free up.
    static func slotCount(lanes: Int) -> Int {
        lanes &+ max(2, lanes / 2)
    }

    /// The most bytes compressing `byteCount` bytes can produce, container included.
    ///
    /// - Parameter byteCount: The input's size.
    /// - Returns: A size no stream of that input exceeds.
    public func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        let chunks = max(1, (byteCount &+ chunkSize &- 1) / chunkSize) &+ lanes.count
        return byteCount &+ byteCount / 800 &+ chunks &* 1024 &+ 64
    }

    // MARK: - Synchronous

    /// Compresses all of `input` into `output` as one stream, header and trailer included, compressing up to
    /// ``laneCount`` chunks at once. Blocks the calling thread until done.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the stream, header and trailer included.
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` runs out of room (what was written stays
    ///   written).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        let job = try begin(byteCount: input.byteCount, into: &output)
        // Unsafe: the input and the output's free capacity lent to the workers. Safe: `run` returns only once
        // every worker has.
        let delivery = unsafe input.withLent(output: &output) { source, target in
            unsafe batch(job, input: source, output: target).run()
        }
        try Self.end(delivery, job: job, into: &output)
    }

    // MARK: - The steps of a call, for `BytesAsync`

    /// Starts a call over `byteCount` bytes: its job, and the container header written to `output`.
    package mutating func begin(byteCount: Int, into output: inout OutputRawSpan) throws(BytesError) -> Job {
        let job = job(byteCount: byteCount)
        try Self.write(header: job.format, level: job.level, into: &output)
        return job
    }

    /// The call's workers over lent input and output, to run.
    package mutating func batch(_ job: Job, input: LentBytes, output: LentMutableBytes) -> ChunkBatch {
        let (lanes, slots) = unsafe buffers()
        return unsafe scheduler.batch(
            job, chunkCount: job.chunkCount, format: job.format, lanes: lanes, slots: slots, input: input, output: output,
            checksum: job.initialChecksum
        )
    }

    /// Ends a call once its workers are done (the delivered bytes already counted in `output`): the trailer.
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if the output ran out of room.
    package static func end(_ delivery: ChunkDelivery, job: Job, into output: inout OutputRawSpan) throws(BytesError) {
        guard !delivery.failed else { throw .insufficientCapacity }
        try write(trailer: job.format, checksum: delivery.checksum, length: job.byteCount, into: &output)
    }

    // MARK: - Engine

    /// What one call compresses: the input's size, how it's cut into chunks, and the container.
    package struct Job: Sendable {
        /// Where the data starts in the buffer (bytes before it are history), and how much there is.
        let base: Int
        let byteCount: Int
        let size: Int
        let chunkCount: Int
        let format: DeflateFormat
        let level: Int
        let history: Bool
        /// Whether the last chunk ends the stream (otherwise every chunk ends with a sync flush).
        let finishing: Bool

        var initialChecksum: UInt32 { format == .zlib ? 1 : 0 }

        /// Chunk `index`'s range of the buffer.
        @inline(__always)
        func chunk(_ index: Int) -> Range<Int> {
            let start = base &+ min(index &* size, byteCount)
            return start..<min(start &+ size, base &+ byteCount)
        }

        /// Whether chunk `index` ends the stream.
        func isLast(_ index: Int) -> Bool { finishing && index == chunkCount &- 1 }
    }

    /// The job for `byteCount` bytes: chunks of equal size, at most ``chunkSize`` and at least 32 KB, a whole
    /// number per lane, so every worker has the same work: the call lasts as long as the busiest worker (with
    /// rounds, a last round of 7 chunks on 16 lanes took as long as a full one).
    func job(byteCount: Int, base: Int = 0, finishing: Bool = true) -> Job {
        let laneCount = lanes.count
        let rounds = max(1, (byteCount &+ laneCount &* chunkSize &- 1) / (laneCount &* chunkSize))
        let size = max(32 << 10, (byteCount &+ rounds &* laneCount &- 1) / (rounds &* laneCount))
        return Job(
            base: base, byteCount: byteCount, size: size, chunkCount: max(1, (byteCount &+ size &- 1) / size),
            format: format, level: level, history: !independentChunks, finishing: finishing
        )
    }

    /// The lanes' storage, for threads and tasks.
    private mutating func laneBuffer() -> UnsafeLanes<DeflateLane> {
        var span = lanes.mutableSpan
        // Unsafe: the lanes' storage as a pointer that outlives the closure. Safe: a `UniqueArray`'s storage
        // moves only when the array changes size or is replaced, and `lanes` never changes after
        // initialization; callers use the pointer only within the method that took it, while `self` is
        // borrowed.
        return span.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
    }

    /// The lanes' and slots' storage, for the scheduler's workers.
    private mutating func buffers() -> (UnsafeLanes<DeflateLane>, UnsafeLanes<ChunkSlot>) {
        var span = slots.mutableSpan
        // Unsafe and safe as `laneBuffer()`: `slots` never changes after initialization either.
        let slots = span.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
        return unsafe (laneBuffer(), slots)
    }

    /// Copies `bytes` to the end of `output`.
    static func append(_ bytes: RawSpan, to output: inout OutputRawSpan) throws(BytesError) {
        guard output.freeCapacity >= bytes.byteCount else { throw .insufficientCapacity }
        output.append(copying: bytes)
    }

    /// The container's header: nothing for raw DEFLATE.
    static func header(_ format: DeflateFormat, level: Int) -> (bytes: InlineArray<16, UInt8>, count: Int) {
        var bytes = InlineArray<16, UInt8>(repeating: 0)
        switch format {
        case .raw:
            return (bytes, 0)
        case .zlib:
            let header = ZlibHeader.header(level: level)
            bytes[0] = UInt8(header >> 8)
            bytes[1] = UInt8(header & 0xFF)
            return (bytes, 2)
        case .gzip:
            // Magic, DEFLATE, no flags, no time, extra flags (2 slowest, 4 fastest), unknown OS.
            let header: InlineArray<10, UInt8> = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, level >= 8 ? 2 : level <= 1 ? 4 : 0, 255]
            for index in 0..<10 {
                bytes[index] = header[index]
            }
            return (bytes, 10)
        }
    }

    /// The container's trailer: the checksum (and for gzip, the length modulo 2^32).
    static func trailer(_ format: DeflateFormat, checksum: UInt32, length: Int) -> (bytes: InlineArray<16, UInt8>, count: Int) {
        var bytes = InlineArray<16, UInt8>(repeating: 0)
        switch format {
        case .raw:
            return (bytes, 0)
        case .zlib:
            for index in 0..<4 {
                bytes[index] = UInt8(truncatingIfNeeded: checksum &>> (24 &- 8 &* index))
            }
            return (bytes, 4)
        case .gzip:
            let length = UInt32(truncatingIfNeeded: length)
            for index in 0..<4 {
                bytes[index] = UInt8(truncatingIfNeeded: checksum &>> (8 &* index))
                bytes[4 &+ index] = UInt8(truncatingIfNeeded: length &>> (8 &* index))
            }
            return (bytes, 8)
        }
    }

    /// Writes the container's header.
    static func write(header format: DeflateFormat, level: Int, into output: inout OutputRawSpan) throws(BytesError) {
        let header = header(format, level: level)
        try append(header.bytes.span.bytes.extracting(0..<header.count), to: &output)
    }

    /// Writes the container's trailer.
    static func write(trailer format: DeflateFormat, checksum: UInt32, length: Int, into output: inout OutputRawSpan) throws(BytesError) {
        let trailer = trailer(format, checksum: checksum, length: length)
        try append(trailer.bytes.span.bytes.extracting(0..<trailer.count), to: &output)
    }

    // MARK: - Streaming

    /// Compresses `input` as part of one stream, for pipelines: the bytes are copied into the encoder's
    /// window, and when it holds a round of input (``laneCount`` chunks), or at a flush, everything waiting is
    /// compressed in parallel as the synchronous form does, the call blocking until done. Every chunk ends
    /// with a sync flush, so a `.flush` costs nothing more; `.finish` ends the stream with the trailer.
    ///
    /// The window (32 KB of history plus ``laneCount`` × ``chunkSize``) is allocated on the first call and
    /// kept across ``reset()``: after that, streaming allocates nothing.
    ///
    /// - Returns: The progress: input consumed (copied into the window), output produced, and whether more
    ///   input or output room is needed or the stream is finished.
    /// - Throws: Nothing in practice; the signature matches the other encoders'.
    public mutating func compress(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush = .none) throws(BytesError) -> TransformProgress {
        if window.count == 0 {
            window = UniqueArray(repeating: 0, count: Deflate.windowSize &+ lanes.count &* chunkSize)
        }
        if !started {
            started = true
            streamChecksum = format == .zlib ? 1 : 0
            (small, smallEnd) = Self.header(format, level: level)
            smallStart = 0
        }
        var consumed = 0
        var produced = 0
        while true {
            produced &+= deliver(into: &output)
            if smallStart < smallEnd || deliveryLane < deliveryEnd || trailerQueued {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            if finished {
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            }
            if consumed < input.byteCount {
                // At most one round of input past the history (the first window has none, and room for more).
                let room = historyCount &+ lanes.count &* chunkSize &- windowEnd
                if room > 0 {
                    let count = min(room, input.byteCount &- consumed)
                    var span = window.mutableSpan
                    span.copyBytes(from: input.extracting(consumed..<(consumed &+ count)), toByteOffset: windowEnd)
                    windowEnd &+= count
                    consumed &+= count
                } else {
                    compressWindow(finishing: false)
                }
                continue
            }
            switch flush {
            case .none:
                return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
            case .flush:
                guard windowEnd > historyCount else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                compressWindow(finishing: false)
            case .finish:
                compressWindow(finishing: true)
            }
        }
    }

    /// Forgets the stream, for a new one, keeping the lanes and the window.
    public mutating func reset() {
        historyCount = 0
        windowEnd = 0
        started = false
        finished = false
        streamLength = 0
        deliveryLane = 0
        deliveryEnd = 0
        trailerQueued = false
        trailerStaged = false
        smallStart = 0
        smallEnd = 0
    }

    /// Compresses the window's input in one parallel round, then keeps its last 32 KB as history.
    private mutating func compressWindow(finishing: Bool) {
        let pending = windowEnd &- historyCount
        let job = job(byteCount: pending, base: historyCount, finishing: finishing)
        let lanes = unsafe laneBuffer()
        do {
            let data = window.span.bytes.extracting(0..<windowEnd)
            // Unsafe: lane `j` from thread `j`. Safe: each thread touches only its own lane, and
            // `concurrentPerform` returns only when every iteration has finished.
            DispatchQueue.concurrentPerform(iterations: job.chunkCount) { j in
                unsafe lanes.buffer[j].compress(data, index: j, job: job)
            }
        }
        for j in 0..<job.chunkCount {
            // Unsafe: reads lane `j`. Safe: the round is over.
            let laneChecksum = unsafe lanes.buffer[j].checksum
            let length = job.chunk(j).count
            switch format {
            case .raw: break
            case .zlib: streamChecksum = Adler32.combine(streamChecksum, laneChecksum, secondLength: length)
            case .gzip: streamChecksum = CRC32.combine(streamChecksum, laneChecksum, secondLength: length)
            }
        }
        streamLength &+= pending
        deliveryLane = 0
        deliveryEnd = job.chunkCount
        trailerQueued = finishing
        let keep = min(Deflate.windowSize, windowEnd)
        var span = window.mutableSpan
        span.copyBytes(within: (windowEnd &- keep)..<windowEnd, toByteOffset: 0)
        historyCount = keep
        windowEnd = keep
    }

    /// Delivers what's waiting, in stream order: the header, the last round's chunks, then the trailer.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        var produced = 0
        while true {
            if smallStart < smallEnd {
                let count = min(smallEnd &- smallStart, output.freeCapacity)
                guard count > 0 else { return produced }
                output.append(copying: small.span.bytes.extracting(smallStart..<(smallStart &+ count)))
                smallStart &+= count
                produced &+= count
                continue
            }
            if deliveryLane < deliveryEnd {
                guard output.freeCapacity > 0 else { return produced }
                let (count, done) = lanes[deliveryLane].deliverSome(into: &output)
                produced &+= count
                if done { deliveryLane &+= 1 }
                continue
            }
            if trailerQueued {
                trailerQueued = false
                trailerStaged = true
                (small, smallEnd) = Self.trailer(format, checksum: streamChecksum, length: streamLength)
                smallStart = 0
                continue
            }
            if trailerStaged {
                finished = true
            }
            return produced
        }
    }
}

extension ParallelDeflateEncoder: ResettableByteTransform {
    /// What compressing throws: `insufficientCapacity` and nothing else in practice.
    public typealias Failure = BytesError

    /// Compresses as much of `input` as it can into `output`: ``compress(_:into:flush:)`` as a pipeline stage.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the stream.
    ///   - flush: `.flush` ends the output so far on a byte boundary; `.finish` ends the stream.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` as ``compress(_:into:flush:)`` does.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

/// One lane of a parallel encoder: a compressor of its own (tables and staged output) and its chunk's
/// checksum.
///
/// `@usableFromInline`: clients inline the encoder's destructor, which references this type's metadata (see
/// `BrotliCommand`).
@usableFromInline
struct DeflateLane: ~Copyable, ChunkLane {
    var compressor: DeflateCompressor
    var checksum: UInt32 = 0
    /// The input length of the chunk last compressed.
    var inputLength = 0

    init(level: Int) {
        compressor = DeflateCompressor(level: level)
    }

    /// Moves the chunk's compressed bytes to `slot`, swapping staging buffers.
    mutating func handOff(into slot: inout ChunkSlot) {
        slot.range = compressor.takeStaged(swapping: &slot.buffer)
        slot.checksum = checksum
        slot.inputLength = inputLength
    }

    /// Copies as many of the chunk's compressed bytes as fit to the end of `output`.
    ///
    /// - Returns: How many, and whether the chunk is now all delivered.
    mutating func deliverSome(into output: inout OutputRawSpan) -> (count: Int, done: Bool) {
        let count = min(compressor.stagedBytes.byteCount, output.freeCapacity)
        output.append(copying: compressor.stagedBytes.extracting(0..<count))
        compressor.consumeStaged(count)
        return (count, compressor.stagedBytes.byteCount == 0)
    }

    /// Compresses chunk `index` of the job into the staged output, as DEFLATE blocks ending in a sync flush
    /// (or for the last chunk, the final block), primed with the 32 KB before the chunk if the job keeps
    /// history, and checksums it.
    mutating func compress(_ input: RawSpan, index: Int, job: ParallelDeflateEncoder.Job) {
        let chunk = job.chunk(index)
        let isLast = job.isLast(index)
        inputLength = chunk.count
        compressor.reset()
        let buffer = input.extracting(0..<chunk.upperBound)
        if job.history && chunk.lowerBound > 0 {
            compressor.prime(buffer, from: max(0, chunk.lowerBound &- Deflate.windowSize), to: chunk.lowerBound)
        }
        if chunk.isEmpty {
            compressor.writeEmptyFinalBlock() // Only the last chunk of an empty input is empty.
        }
        var position = chunk.lowerBound
        while position < chunk.upperBound {
            position = compressor.compressBlock(buffer, from: position, limit: chunk.upperBound, dataEnd: chunk.upperBound, isFinal: isLast)
        }
        if isLast {
            compressor.alignOutput()
        } else {
            compressor.writeSyncMarker()
        }
        let bytes = input.extracting(chunk)
        switch job.format {
        case .raw: checksum = 0
        case .zlib: checksum = Adler32.checksum(bytes)
        case .gzip: checksum = CRC32.checksum(bytes)
        }
    }
}

/// The lanes' storage, for the threads or tasks of a round. Unsafe: a pointer shared between threads, each
/// using only its own lane.
@unsafe
struct UnsafeLanes<Lane: ~Copyable>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Lane>
}

