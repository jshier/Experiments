public import Bytes
public import BytesAsync
public import BytesCompression
public import Synchronization

// One engine for every stream of independent blocks: an Apple Encrypted Archive's segments, a `pbz` stream's blocks
// (an `.aar`, or one inside AEA segments), a `.xip`'s pbzx blocks of xz, and a plain stream read in slices. Decoder
// tasks take a free buffer, then the next block, decode it, and publish it; one consumer takes the blocks in order.
// What's the client's (reading its file, an AEA segment's MAC, decryption, and checksum) is its stage: a `BlockStage`,
// with the requirements its source needs (`IndexedBlockStage`, `BlockReadingStage`). ARCHITECTURE.md §3. (Until
// 2026-11-23 these were NativeAEA's `SegmentStream` and `BlockStream`.)
//
// Everything is inlinable, with `@usableFromInline` state, so a client's `ParallelBlockDecoder<ItsStage>` is
// specialized in the client's module: no generic dispatch per block.

/// One decoded block of a stream, holding its pool buffer: dropping the block releases the buffer.
///
/// Release a block before waiting for another one (a consumer holds the buffers its sizing's `consumerBuffers` count):
/// `block = try await source.nextBlock()` keeps the old block until the call returns, so set `block = nil` first, or
/// move it into what keeps it (`previous = consume block`) before the next wait.
public struct DecodedBlock: ~Copyable, Sendable {
    /// The block's place in the stream: 0, 1, 2, … (an indexed source's own indices).
    public var index: Int
    /// The pool buffer holding it: its ``BlockBufferPool/Buffer/index`` for the pool's byte accessors.
    public var buffer: BlockBufferPool.Buffer
    /// Where its bytes are in the decoded stream, and how many.
    public var rawOffset: Int
    public var rawSize: Int

    @inlinable
    public init(index: Int, buffer: consuming BlockBufferPool.Buffer, rawOffset: Int, rawSize: Int) {
        self.index = index
        self.buffer = buffer
        self.rawOffset = rawOffset
        self.rawSize = rawSize
    }
}

/// Nanoseconds a source's decoders were busy (summed) and spent reading, and its consumer waited.
public final class BlockDecodingCounters: Sendable {
    public let busy = Atomic<Int>(0)
    public let read = Atomic<Int>(0)
    public let wait = Atomic<Int>(0)

    @inlinable
    public init() {}
}

/// What a stream's blocks are, so a client can name one in its errors (NativeAEA: "segment 3" of an indexed stream, an
/// AEA archive's; "block 3" of a `pbz` stream).
public enum BlockKind: String, Sendable, Hashable {
    /// Blocks an ``IndexedBlockStage`` describes up front (AEA segments).
    case indexed
    /// `pbz` blocks: an `.aar`'s, a `.xip`'s pbzx blocks, a `pbz` stream inside AEA segments.
    case pbz
    /// Slices of a plain stream.
    case slice
}

/// Why the engine itself stopped: a block that didn't decode, framing it couldn't read, or cancellation. A client's
/// failure type is made from it (``BlockDecodingFailure``), so nothing is boxed.
public enum BlockDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Block `block` (of a stream of `kind`) didn't decode to its raw size: the decoder's error (``BytesError/mismatch``
    /// for another size, ``BytesError/trailingData`` for a stream that ended before its stored bytes did).
    case decoding(BytesError, block: Int, kind: BlockKind)
    /// A block of a stream with no compression (``AppleArchiveCompression/none``) isn't stored as is.
    case notCompressed(block: Int)
    /// The `pbz` framing can't be read.
    case framing(PBZError)
    /// The task was cancelled, or the source stopped with no failure of its own.
    case cancelled

    public var description: String {
        switch self {
        case let .decoding(error, block, kind):
            switch kind {
            case .indexed: "block \(block) failed to decompress: \(error)"
            case .pbz: "pbz block \(block) failed to decompress: \(error)"
            case .slice: "slice \(block) failed to decompress: \(error)"
            }
        case let .notCompressed(block): "block \(block) is compressed in a stream without compression"
        case let .framing(error): error.description
        case .cancelled: "cancelled"
        }
    }
}

/// A client's error type, which the engine's own failures become: a composition, as NativeAEA's `AEAError` makes one
/// from a ``BlockDecodingError`` (its `.decompressionFailed(segment:_:)`, `.invalidArchive(_:)`, `.cancelled`).
public protocol BlockDecodingFailure: Error, Sendable {
    init(_ error: BlockDecodingError)
}

/// Decoded blocks of a stream in order, each in a buffer of ``pool``.
///
/// ``run()`` decodes, in child tasks of its own, until the stream is decoded, fails, or is stopped; meanwhile one
/// consumer calls ``prepare()``, then takes the blocks with ``nextBlock()`` until it returns `nil`, releasing each
/// buffer. ``withDecoding(onCancel:_:)`` puts the two together. ``ParallelBlockDecoder`` is the engine; a client may
/// wrap one (NativeAEA's AEA payload, which decides from the first segment whether its blocks are the archive or a
/// `pbz` stream).
public protocol OrderedBlockSource<Failure>: AnyObject, Sendable {
    associatedtype Failure: BlockDecodingFailure
    /// The pool blocks come in: valid once ``prepare()`` has returned.
    var pool: BlockBufferPool { get }
    /// Every pool the source decodes into (an upstream's and staging too), for checking that none leaks.
    var pools: [BlockBufferPool] { get }
    /// Decodes the stream with child tasks, returning when they've all ended.
    nonisolated(nonsending) func run() async
    /// What the consumer calls first, while ``run()`` decodes: a source that must look at the decoded stream to know
    /// how to read it waits for its first block here.
    nonisolated(nonsending) func prepare() async throws(Failure)
    /// The next block, suspending until it's decoded; `nil` after the last.
    ///
    /// - Throws: A block's failure once the consumer reaches that block (blocks before it come first: the error is the
    ///   lowest failing block's, as a sequential decoder would report), or, once stopped, the stop's.
    nonisolated(nonsending) func nextBlock() async throws(Failure) -> DecodedBlock?
    /// Stops decoding: no more blocks will be taken. Decoders waiting for a buffer or a job end; a consumer waiting
    /// for a block throws `failure`, or the cancellation failure (``BlockDecodingError/cancelled``) if none is given
    /// (unless a block's failure came first: that one). A source reading another's blocks stops that one too. Any
    /// thread may call it, any number of times.
    func stop(_ failure: Failure?)
    /// Releases the buffers decoded but not taken. Called after ``run()`` has returned.
    func releaseUnconsumed()
    /// Time the decoders were busy, spent reading, and the consumer waited.
    var counters: BlockDecodingCounters { get }
}

public extension OrderedBlockSource {
    @inlinable
    nonisolated(nonsending) func prepare() async throws(Failure) {}

    /// Runs the decoders as child tasks while `consume` takes blocks on this task (it may add child tasks of its own
    /// to the group: writers), then stops them, waits for every child task, and releases what was decoded and not
    /// taken.
    ///
    /// Cancelling the task calls `onCancel`, stops the decoders, and makes the consumer's next ``nextBlock()`` throw
    /// the cancellation failure (``BlockDecodingError/cancelled``, as `Failure`): the operation's one cancellation
    /// handler. `consume` then returns, and the children end. What `consume` returns is the result: the stop after it
    /// (which a consumer asking for another block would see as the cancellation failure) never is.
    @inlinable
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
            stop(Failure(.cancelled))
        }
    }
}

/// A block to decode: its place in the decoded stream and where its stored bytes are.
public struct BlockJob: Sendable {
    public var index: Int
    public var rawOffset: Int
    public var rawSize: Int
    public var storedSize: Int
    /// Where the stored bytes are in the stage's input (`-1` when they're in a staging buffer).
    public var fileOffset: Int
    /// The staging buffer holding the stored bytes (copied from an upstream source), or -1.
    public var staging: Int

    @inlinable
    public init(index: Int, rawOffset: Int, rawSize: Int, storedSize: Int, fileOffset: Int, staging: Int = -1) {
        self.index = index
        self.rawOffset = rawOffset
        self.rawSize = rawSize
        self.storedSize = storedSize
        self.fileOffset = fileOffset
        self.staging = staging
    }

    /// Whether the block is stored as is (its sizes are equal).
    @inlinable
    public var isStored: Bool { storedSize == rawSize }
}

/// A decoder task's own state, made once per task: its ``Decompressor`` (made for the stream's format only: every
/// decoder's tables are zeroed when made, so unused ones would cost memory per task), its read buffer, and the
/// stream's counters.
public struct BlockContext: ~Copyable {
    @usableFromInline var decompressor: Decompressor
    /// What the stream's blocks are, for naming one that fails.
    public let kind: BlockKind
    /// The task's read buffer, if the stream reads stored bytes into one: room for the largest stored block (and 64
    /// bytes). Its pages past a floor go back after each use (`reuse` before, `giveBack` after).
    public let scratch: RawStorage?
    public let counters: BlockDecodingCounters

    @inlinable
    init(format: DecompressionFormat?, kind: BlockKind, scratchCapacity: Int?, counters: BlockDecodingCounters) {
        decompressor = Decompressor()
        // Throws only for a negative size or hint, which a block format has none of.
        if let format { try? decompressor.reset(for: format) }
        self.kind = kind
        scratch = scratchCapacity.map { RawStorage(byteCount: $0) }
        self.counters = counters
    }

    /// Decodes block `block`'s stored bytes `input` into `output`, exactly its raw size: copied when the sizes are equal
    /// (a block stored as is), otherwise decoded with the stream's format.
    ///
    /// Unsafe: `input` and `output` must be valid, `output` the task's own (a buffer it holds), during the call.
    ///
    /// - Throws: ``BlockDecodingError/decoding(_:block:kind:)`` if it doesn't decode to exactly `output`'s size, or
    ///   leaves input unconsumed; ``BlockDecodingError/notCompressed(block:)`` for a stream with no format.
    @unsafe @inlinable
    public mutating func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, block: Int) throws(BlockDecodingError) {
        if input.count == output.count {
            // Stored: blocks that don't compress are kept as they are.
            unsafe output.copyMemory(from: input) // Both are `count` bytes: safe.
            return
        }
        guard decompressor.format != nil else { throw .notCompressed(block: block) }
        // `output` is the block's room in a buffer this task holds until it publishes the block.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let consumed: Int
        do throws(BytesError) {
            // Exactly the block's size (anything else throws); returns the input it took.
            consumed = try unsafe decompressor.decompressAll(RawSpan(_unsafeBytes: input), into: &span, decodedSize: output.count)
        } catch {
            throw .decoding(error, block: block, kind: kind)
        }
        let written = unsafe span.finalize(for: output)
        guard written == output.count, consumed == input.count else {
            throw .decoding(written == output.count ? .trailingData : .mismatch, block: block, kind: kind)
        }
    }
}

/// The client's work for each block, on the decoder's task: getting it decoded into its output buffer. The engine
/// handles the rest: tasks, buffers, order, failure, and cancellation.
///
/// A stage has the requirements its source needs, so none traps by default: an indexed stream's stage describes its
/// blocks (``IndexedBlockStage``); a stream read from the stage's input reads it (``BlockReadingStage``, whose default
/// ``decode(_:into:context:)`` reads, prepares, decodes, and verifies each block with the stage's hooks); a stream
/// read from an upstream source's blocks needs neither (``UpstreamBlocks``).
public protocol BlockStage: Sendable {
    associatedtype Failure: BlockDecodingFailure

    /// Gets block `job` into `output` (exactly its raw size, in a buffer the task holds), decoding its stored bytes with
    /// ``BlockContext/decompress(_:into:block:)``. Blocks copied from an upstream source never come here: the engine
    /// decodes them from staging.
    ///
    /// Unsafe: `output` must be valid and the task's own during the call.
    @unsafe func decode(_ job: BlockJob, into output: UnsafeMutableRawBufferPointer, context: inout BlockContext) throws(Failure)
}

/// The stage of an indexed stream (``ParallelBlockDecoder/init(stage:blocks:format:blockCapacity:decoders:extraBuffers:heldBuffers:heldUntilActivated:scratchCapacity:)``):
/// it describes each block.
public protocol IndexedBlockStage: BlockStage {
    /// Block `index`: its sizes and where it's stored.
    func block(_ index: Int) -> BlockJob
}

/// The stage of a stream whose stored bytes are in the stage's input (a file): it reads them, and may check or
/// transform them around decoding with its hooks, each a no-op by default.
///
/// The default ``decode(_:into:context:)`` gets a block's stored bytes (``storedBytes(of:)``, or ``read(at:into:)``:
/// a stored block straight into its output, others into the context's read buffer), lets ``prepare(_:stored:into:)``
/// check and transform them (an AEA segment's MAC, decryption: into the output for a stored block, the read buffer
/// otherwise), decodes them unless the block is stored, and lets ``verify(_:raw:)`` check the result (a checksum).
public protocol BlockReadingStage: BlockStage {
    /// Reads `destination.count` bytes at `offset` of the stage's input (a stream read from a file: its block headers
    /// and blocks).
    ///
    /// Unsafe: `destination` must be valid and writable during the call.
    @unsafe func read(at offset: Int, into destination: UnsafeMutableRawBufferPointer) throws(Failure)

    /// Block `job`'s stored bytes if the stage has them without reading (a mapping of its input), or `nil` to read
    /// them. The default: `nil`.
    ///
    /// Unsafe: the bytes must stay valid while the engine's tasks run.
    @unsafe func storedBytes(of job: BlockJob) -> UnsafeRawBufferPointer?

    /// Checks block `job`'s stored bytes and may transform them into `destination` (`job.storedSize` bytes: the block's
    /// output when it's stored, the context's read buffer otherwise; empty when the context has none), which can be
    /// `stored` itself (in place). Returns whether it wrote `destination`: the bytes decoded from then on. The default
    /// checks nothing and returns `false`.
    ///
    /// Unsafe: `stored` and `destination` must be valid during the call, `destination` the task's own.
    @unsafe func prepare(_ job: BlockJob, stored: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer) throws(Failure) -> Bool

    /// Checks block `job`'s decoded bytes. The default checks nothing.
    func verify(_ job: BlockJob, raw: RawSpan) throws(Failure)
}

public extension BlockReadingStage {
    @unsafe @inlinable
    func storedBytes(of job: BlockJob) -> UnsafeRawBufferPointer? { nil }

    @unsafe @inlinable
    func prepare(_ job: BlockJob, stored: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer) throws(Failure) -> Bool {
        false
    }

    @inlinable
    func verify(_ job: BlockJob, raw: RawSpan) throws(Failure) {}

    @unsafe @inlinable
    func decode(_ job: BlockJob, into output: UnsafeMutableRawBufferPointer, context: inout BlockContext) throws(Failure) {
        // A compressed block's stored bytes go to the read buffer, which holds the largest block (stored ≤ raw ≤ its
        // size); its pages past its floor go back once the block is decoded.
        let readBuffer = job.isStored ? nil : context.scratch
        if let readBuffer { readBuffer.reuse(job.storedSize) }
        defer { if let readBuffer { readBuffer.giveBack(job.storedSize) } }
        let scratch = unsafe UnsafeMutableRawBufferPointer(start: readBuffer?.base, count: readBuffer == nil ? 0 : job.storedSize)
        // `stored` and `input` are constants, each set once on every path: a `var` assigned in branches and borrowed
        // later can be boxed on the heap (AGENTS.md).
        let stored: UnsafeRawBufferPointer
        if let mapped = unsafe storedBytes(of: job) {
            unsafe stored = mapped
        } else {
            // A stored block (or a plain slice) straight into the output, a compressed one into the read buffer.
            let target = unsafe job.isStored ? output : scratch
            precondition(target.count == job.storedSize, "a compressed block read with no read buffer")
            let readStart = MonotonicClock.now
            try unsafe read(at: job.fileOffset, into: target) // `storedSize` bytes of this task's own (checked above): safe.
            context.counters.read.add(MonotonicClock.nanoseconds(since: readStart), ordering: .relaxed)
            unsafe stored = UnsafeRawBufferPointer(target)
        }
        let destination = unsafe job.isStored ? output : scratch
        let input: UnsafeRawBufferPointer
        // Both valid for the call (above); `destination` is this task's own.
        if try unsafe prepare(job, stored: stored, into: destination) {
            unsafe input = UnsafeRawBufferPointer(destination)
        } else {
            unsafe input = stored
        }
        if job.isStored {
            // Already there when read into the output (or prepared into it); otherwise copied (the sizes are equal).
            if unsafe input.baseAddress != UnsafeRawPointer(output.baseAddress) { unsafe output.copyMemory(from: input) }
        } else {
            do throws(BlockDecodingError) {
                try unsafe context.decompress(input, into: output, block: job.index) // Valid for the call (above): safe.
            } catch {
                throw Failure(error)
            }
        }
        // The output, this task's own, decoded: safe.
        try verify(job, raw: unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output)))
    }
}

/// The stage of a stream whose blocks all come from an upstream source (a `pbz` stream inside AEA segments): it reads
/// nothing itself.
public struct UpstreamBlocks<Failure: BlockDecodingFailure>: BlockStage {
    @inlinable
    public init() {}

    @unsafe @inlinable
    public func decode(_ job: BlockJob, into output: UnsafeMutableRawBufferPointer, context: inout BlockContext) throws(Failure) {
        // Unreachable by construction: an upstream stream's jobs all carry a staging buffer, which the engine decodes
        // from itself.
        preconditionFailure("an upstream stream's blocks are decoded from staging")
    }
}

/// Decodes a stream of independent blocks with several tasks and hands them out in order: the engine behind every
/// ``OrderedBlockSource`` (ARCHITECTURE.md §3).
///
/// Each decoder takes a free buffer from the pool, then the next block (in that order, so the block the consumer waits
/// for always has a buffer), gets it decoded into the buffer (its stage's ``BlockStage/decode(_:into:context:)``), and
/// publishes it. Blocks come from one of four sources, one per initializer, each asking of its stage what it needs:
/// - **Indexed** (``IndexedBlockStage``): all described up front (AEA segments); decoders claim the next index with
///   an atomic add.
/// - **`pbz` in a file** (``BlockReadingStage``): a producer task reads each block header from the stage's input and
///   queues the block; decoders read the blocks themselves.
/// - **`pbz` in an upstream source's blocks** (``UpstreamBlocks``): the producer reads the headers and copies each
///   block's stored bytes into a staging pool (blocks cross the upstream's), and decoders decode from staging.
/// - **Slices** (``BlockReadingStage``): a plain stream, read from the stage's input in slices.
///
/// The consumer takes blocks 0, 1, 2, … and releases each buffer through the pool when it's done with it.
///
/// **Failures come in block order.** A block that fails (to read, prepare, decode, or verify; or its framing) stops
/// decoding past it, while the blocks before it, all claimed already (claims go in order), are still decoded and handed
/// out; the consumer then gets the failure. A lower block failing later replaces it, so the error is the lowest failing
/// block's, the one a sequential decoder would report, whichever task failed first. ``stop(_:)`` instead ends
/// everything at once.
public final class ParallelBlockDecoder<Stage: BlockStage>: OrderedBlockSource, @unchecked Sendable {
    public typealias Failure = Stage.Failure

    /// An indexed stage's ``IndexedBlockStage/block(_:)``, taken where the stage is known to be one (in the
    /// initializer, which a client specializes): no generic dispatch per block. It captures nothing.
    @usableFromInline typealias DescribeBlock = @Sendable (Stage, Int) -> BlockJob
    /// The producer of a `pbz` stream in a reading stage's input (``produceFromFile(index:)``, which calls the stage's
    /// ``BlockReadingStage/read(at:into:)`` directly), taken the same way; called once per run.
    @usableFromInline typealias ProduceFromFile = nonisolated(nonsending) @Sendable (ParallelBlockDecoder, inout Int) async throws(Failure) -> Void

    /// Where the blocks come from: one case per initializer, so a combination no initializer makes (slices of an
    /// upstream source's blocks) can't be written.
    @usableFromInline
    enum Source: Sendable {
        /// Blocks `range`, each described by the stage.
        case indexed(Range<Int>, describe: DescribeBlock)
        /// `pbz` blocks of at most `blockSize` raw bytes in the stage's input, `file` (its 12-byte header first).
        case pbz(blockSize: Int, file: Range<Int>, produce: ProduceFromFile)
        /// `pbz` blocks of at most `blockSize` raw bytes in another source's decoded blocks, run by whoever made this
        /// one.
        case upstream(blockSize: Int, any OrderedBlockSource<Failure>)
        /// Slices of `size` of the stage's input.
        case slices(size: Int, file: Range<Int>)
    }

    /// A decoded block waiting for the consumer.
    @usableFromInline
    struct Slot {
        @usableFromInline var index = -1
        @usableFromInline var buffer = -1
        @usableFromInline var rawOffset = 0
        @usableFromInline var rawSize = 0

        @inlinable init() {}

        @inlinable
        init(index: Int, buffer: Int, rawOffset: Int, rawSize: Int) {
            self.index = index
            self.buffer = buffer
            self.rawOffset = rawOffset
            self.rawSize = rawSize
        }
    }

    @usableFromInline
    struct State: ~Copyable {
        /// Decoded blocks, block `i` at `i % slots.count`. Every block between the consumer's and a published one holds
        /// a buffer (decoders take a buffer, then a block, in order), so at most `pool.count` are published at once and
        /// none overwrites another.
        @usableFromInline var slots: [Slot]
        /// The index past the last block, once known (from the start for an indexed stream; from the producer at the
        /// end of a framed one).
        @usableFromInline var endIndex: Int?
        /// What a consumer asking for block ``limit`` or later gets.
        @usableFromInline var failure: Failure?
        /// The first block not handed out: `Int.max` while decoding, the lowest failing block's index after a failure,
        /// `Int.min` once stopped.
        @usableFromInline var limit = Int.max
        /// The consumer, suspended until block `waitingFor` is published (or the end is known, or a failure).
        @usableFromInline var consumer: Continuation<Void, Never>?
        @usableFromInline var waitingFor = -1

        @inlinable
        init(slots: [Slot], endIndex: Int?) {
            self.slots = slots
            self.endIndex = endIndex
            consumer = nil
        }
    }

    public let pool: BlockBufferPool
    public let counters = BlockDecodingCounters()
    @usableFromInline let stage: Stage
    @usableFromInline let source: Source
    @usableFromInline let kind: BlockKind
    /// The blocks' format (`nil`: every block is stored).
    @usableFromInline let format: DecompressionFormat?
    @usableFromInline let decoderCount: Int
    /// Each decoder's read buffer's size, if they read into one.
    @usableFromInline let scratchCapacity: Int?
    /// Copies of blocks' stored bytes from upstream buffers (their blocks cross them freely).
    @usableFromInline let staging: BlockBufferPool?
    /// A framed stream's blocks to decode, from the producer to the decoders (BytesAsync's bounded queue).
    @usableFromInline let jobs: AsyncQueue<BlockJob>?
    /// An indexed stream's next block to claim.
    @usableFromInline let nextIndex = Atomic<Int>(0)
    /// ``State/limit``, for the decoders and the producer to check without the lock: only lowered, under it.
    @usableFromInline let limit = Atomic<Int>(.max)
    @usableFromInline let state: Mutex<State>
    /// The consumer's position: touched only by the consumer (its task).
    @usableFromInline var consumed: Int

    @usableFromInline
    init(
        stage: Stage, source: Source, kind: BlockKind, format: DecompressionFormat?, decoders: Int, pool: BlockBufferPool,
        scratchCapacity: Int?, staging: BlockBufferPool?
    ) {
        self.stage = stage
        self.source = source
        self.kind = kind
        self.format = format
        decoderCount = decoders
        self.pool = pool
        self.scratchCapacity = scratchCapacity
        self.staging = staging
        let endIndex: Int?
        if case let .indexed(range, _) = source {
            jobs = nil
            nextIndex.store(range.lowerBound, ordering: .relaxed)
            consumed = range.lowerBound
            endIndex = range.upperBound
        } else {
            jobs = AsyncQueue(capacity: decoders * 2 + 2, waiters: decoders)
            consumed = 0
            endIndex = nil
        }
        state = Mutex(State(slots: Array(repeating: Slot(), count: pool.count), endIndex: endIndex))
    }

    /// An indexed stream: blocks `blocks` (the stage's ``IndexedBlockStage/block(_:)`` describes each), decoded into a
    /// pool of its own (``BlockBufferPool/sizing(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:scratchCapacity:staged:budget:)``).
    ///
    /// - Parameters:
    ///   - format: The blocks' format (`nil`: every block is stored).
    ///   - blockCapacity: The largest block's raw size.
    ///   - decoders: Decoder tasks (at most one per block).
    ///   - extraBuffers: Decoded blocks held at once beyond one per decoder.
    ///   - heldBuffers: Buffers the consumer's side holds beyond decoding (writers' references).
    ///   - consumerBuffers: Buffers the consumer holds while it waits for its next block (the one it read, and earlier
    ///     ones it keeps).
    ///   - heldUntilActivated: What it holds, beyond one buffer, until the pool's ``BlockBufferPool/activateAll()``, if
    ///     not `heldBuffers` and `consumerBuffers` from the start.
    ///   - scratchCapacity: Each decoder's read buffer's size, if the stage reads into one.
    ///   - carryCapacity: The room before each block for what the consumer carries into it from the block before
    ///     (``BlockBufferPool/carry(_:from:at:to:)``): the most its format carries, or 0.
    ///   - budget: Bytes for the pool and the read buffers, or `nil` for no limit: the counts above come down to fit
    ///     (the pool's ``BlockBufferPool/heldBuffers`` says how many writers it allows).
    @inlinable
    public convenience init(
        stage: Stage, blocks: Range<Int>, format: DecompressionFormat?, blockCapacity: Int, decoders: Int, extraBuffers: Int,
        heldBuffers: Int = 0, consumerBuffers: Int = 1, heldUntilActivated: Int? = nil, scratchCapacity: Int?, carryCapacity: Int = 0,
        budget: Int? = nil
    ) where Stage: IndexedBlockStage {
        let sizing = BlockBufferPool.sizing(
            blockCapacity: blockCapacity, carryCapacity: carryCapacity, decoders: min(decoders, blocks.count), extraBuffers: extraBuffers,
            heldBuffers: heldBuffers, consumerBuffers: consumerBuffers, scratchCapacity: scratchCapacity, budget: budget
        )
        self.init(
            stage: stage, source: .indexed(blocks, describe: { stage, index in stage.block(index) }), kind: .indexed, format: format,
            decoders: sizing.decoders,
            pool: BlockBufferPool(sizing: sizing, blockCapacity: blockCapacity, heldUntilActivated: heldUntilActivated),
            scratchCapacity: scratchCapacity, staging: nil
        )
    }

    /// A `pbz` stream in the stage's input, `file` (its 12-byte header first), its blocks of at most `blockSize` raw
    /// bytes compressed with `compression`, decoded into a pool of its own.
    ///
    /// - Parameters:
    ///   - decoders: Decoder tasks.
    ///   - extraBuffers: Decoded blocks held at once beyond one per decoder.
    ///   - heldBuffers: Buffers the consumer's side holds beyond decoding (writers' references).
    ///   - consumerBuffers: Buffers the consumer holds while it waits for its next block.
    ///   - carryCapacity: The room before each block for what the consumer carries into it (as for indexed streams).
    ///   - budget: Bytes for the pool and the decoders' read buffers (`blockSize + 64` each), or `nil` for no limit.
    @inlinable
    public convenience init(
        stage: Stage, pbz compression: AppleArchiveCompression, blockSize: Int, file: Range<Int>, decoders: Int, extraBuffers: Int,
        heldBuffers: Int = 0, consumerBuffers: Int = 1, carryCapacity: Int = 0, budget: Int? = nil
    ) where Stage: BlockReadingStage {
        let sizing = BlockBufferPool.sizing(
            blockCapacity: blockSize, carryCapacity: carryCapacity, decoders: decoders, extraBuffers: extraBuffers, heldBuffers: heldBuffers,
            consumerBuffers: consumerBuffers, scratchCapacity: blockSize + 64, budget: budget
        )
        let produce: ProduceFromFile = { engine, index throws(Failure) in try await engine.produceFromFile(index: &index) }
        self.init(
            stage: stage, source: .pbz(blockSize: blockSize, file: file, produce: produce), kind: .pbz,
            format: DecompressionFormat(pbzBlock: compression), decoders: sizing.decoders,
            pool: BlockBufferPool(sizing: sizing, blockCapacity: blockSize), scratchCapacity: blockSize + 64, staging: nil
        )
    }

    /// A plain stream in the stage's input, `file`, read in slices of `size`, into a pool of its own.
    ///
    /// - Parameters:
    ///   - decoders: Decoder tasks (readers here).
    ///   - extraBuffers: Slices held at once beyond one per decoder.
    ///   - heldBuffers: Buffers the consumer's side holds beyond decoding (writers' references).
    ///   - consumerBuffers: Buffers the consumer holds while it waits for its next slice.
    ///   - carryCapacity: The room before each slice for what the consumer carries into it (as for indexed streams).
    ///   - budget: Bytes for the pool, or `nil` for no limit.
    @inlinable
    public convenience init(
        stage: Stage, slices size: Int, file: Range<Int>, decoders: Int, extraBuffers: Int, heldBuffers: Int = 0, consumerBuffers: Int = 1,
        carryCapacity: Int = 0, budget: Int? = nil
    ) where Stage: BlockReadingStage {
        let sizing = BlockBufferPool.sizing(
            blockCapacity: size, carryCapacity: carryCapacity, decoders: decoders, extraBuffers: extraBuffers, heldBuffers: heldBuffers,
            consumerBuffers: consumerBuffers, budget: budget
        )
        self.init(
            stage: stage, source: .slices(size: size, file: file), kind: .slice, format: nil, decoders: sizing.decoders,
            pool: BlockBufferPool(sizing: sizing, blockCapacity: size), scratchCapacity: nil, staging: nil
        )
    }

    /// A `pbz` stream in `upstream`'s decoded blocks (an AEA archive's segments), its blocks of at most `blockSize` raw
    /// bytes compressed with `compression`, decoded into a pool of its own. Whoever makes it runs `upstream` too;
    /// stopping it stops `upstream`.
    ///
    /// - Parameters:
    ///   - decoders: Decoder tasks.
    ///   - extraBuffers: Decoded blocks held at once beyond one per decoder.
    ///   - heldBuffers: Buffers the consumer's side holds beyond decoding (writers' references).
    ///   - consumerBuffers: Buffers the consumer holds while it waits for its next block.
    ///   - carryCapacity: The room before each block for what the consumer carries into it (as for indexed streams;
    ///     staging has none).
    ///   - budget: Bytes for the pool and staging (not `upstream`'s: subtract its ``bufferByteCount`` first), or `nil`
    ///     for no limit.
    @inlinable
    public convenience init<UpstreamFailure>(
        pbz compression: AppleArchiveCompression, blockSize: Int, upstream: any OrderedBlockSource<UpstreamFailure>, decoders: Int,
        extraBuffers: Int, heldBuffers: Int = 0, consumerBuffers: Int = 1, carryCapacity: Int = 0, budget: Int? = nil
    ) where Stage == UpstreamBlocks<UpstreamFailure> {
        let sizing = BlockBufferPool.sizing(
            blockCapacity: blockSize, carryCapacity: carryCapacity, decoders: decoders, extraBuffers: extraBuffers, heldBuffers: heldBuffers,
            consumerBuffers: consumerBuffers, staged: true, budget: budget
        )
        self.init(
            stage: UpstreamBlocks(), source: .upstream(blockSize: blockSize, upstream), kind: .pbz,
            format: DecompressionFormat(pbzBlock: compression), decoders: sizing.decoders,
            pool: BlockBufferPool(sizing: sizing, blockCapacity: blockSize), scratchCapacity: nil,
            // Stored bytes are at most the raw size (`aa` stores a block that doesn't compress): one per decoder, the one
            // the producer fills, and one more (what `sizing` counted as staging).
            staging: .sized(blockCapacity: blockSize, decoders: sizing.decoders, extraBuffers: 0, heldBuffers: 1)
        )
    }

    /// The bytes this source's own buffers can take at once: its pool's buffers handed out now, its decoders' read
    /// buffers, and its staging (not an upstream source's). For a source made over this one, its budget is what's left.
    @inlinable
    public var bufferByteCount: Int {
        pool.activeByteCount + decoderCount * (scratchCapacity ?? 0) + (staging?.activeByteCount ?? 0)
    }

    @inlinable
    public var pools: [BlockBufferPool] {
        var pools = [pool]
        if let staging { pools.append(staging) }
        if case let .upstream(_, upstream) = source { pools += upstream.pools }
        return pools
    }

    @inlinable
    public nonisolated(nonsending) func run() async {
        await withDiscardingTaskGroup { group in
            if jobs != nil { group.addTask { await self.produce() } }
            for _ in 0..<decoderCount {
                group.addTask { await self.decodeTask() }
            }
        }
    }

    // MARK: Consuming

    @inlinable
    public nonisolated(nonsending) func nextBlock() async throws(Failure) -> DecodedBlock? {
        let index = consumed
        let block = try await next(index, taking: true)
        if block != nil { consumed = index + 1 }
        return block
    }

    /// The consumer's next block once it's decoded, without taking it (``nextBlock()`` still returns it): for looking at
    /// the stream's first bytes while the decoders run. Its buffer is a reference of its own (the slot keeps the one
    /// ``nextBlock()`` hands over), released when the peeked block is dropped.
    ///
    /// - Returns: `nil` past the last block.
    @inlinable
    public nonisolated(nonsending) func peek() async throws(Failure) -> DecodedBlock? {
        try await next(consumed, taking: false)
    }

    /// Waits for block `index` and takes its buffer (the consumer's, to release), or with `taking` false only looks at it.
    @inlinable
    nonisolated(nonsending) func next(_ index: Int, taking: Bool) async throws(Failure) -> DecodedBlock? {
        let start = MonotonicClock.now
        defer { counters.wait.add(MonotonicClock.nanoseconds(since: start), ordering: .relaxed) }
        while true {
            switch state.withLock({ take(index, taking: taking, &$0) }) {
            case let .taken(block):
                return block
            case .end:
                return nil
            case let .failed(error):
                throw error
            case .wait:
                await wait(in: state) { state, continuation in
                    // Checked again under the lock publishing, failing, and stopping take: no wakeup is lost.
                    if index >= state.limit || (state.endIndex.map { index >= $0 } ?? false) || state.slots[index % state.slots.count].index == index {
                        return ()
                    }
                    precondition(state.consumer == nil, "ParallelBlockDecoder: one task consumes it")
                    state.consumer = continuation.take()
                    state.waitingFor = index
                    return nil
                }
            }
        }
    }

    /// What the consumer finds for a block, under the lock.
    @usableFromInline
    enum Take: ~Copyable {
        /// The block, published.
        case taken(DecodedBlock)
        /// Past the last block.
        case end
        /// At or past a failing block, or stopped.
        case failed(Failure)
        /// Not published yet.
        case wait
    }

    /// Block `index` if it's published, the end, the failure if it's at or past a failing block (or the source is
    /// stopped), or a wait. Taking it hands the slot's reference to the block; looking at it (`taking` false) gives the
    /// block a reference of its own, so the slot's is still there for the consumer.
    @inlinable
    func take(_ index: Int, taking: Bool, _ state: inout State) -> Take {
        // Set together with `limit` (below `Int.max`, a failure is stored).
        if index >= state.limit, let failure = state.failure { return .failed(failure) }
        if let endIndex = state.endIndex, index >= endIndex { return .end }
        let position = index % state.slots.count
        let slot = state.slots[position]
        guard slot.index == index else { return .wait }
        if taking {
            state.slots[position].index = -1
        } else {
            pool.retain(slot.buffer)
        }
        return .taken(DecodedBlock(index: index, buffer: .init(adopting: slot.buffer, in: pool), rawOffset: slot.rawOffset, rawSize: slot.rawSize))
    }

    @inlinable
    public func stop(_ failure: Failure?) {
        let consumer: Continuation<Void, Never>? = state.withLock { state in
            if state.limit != .min {
                state.limit = .min
                limit.store(.min, ordering: .relaxed)
                // A block's failure already stored stays: it's what a consumer still asking gets.
                if state.failure == nil { state.failure = failure ?? Failure(.cancelled) }
            }
            return state.consumer.take()
        }
        consumer?.resume()
        // The producer waiting for room or a staging buffer, and decoders waiting for a buffer or a job, end.
        jobs?.close()
        pool.close()
        staging?.close()
        // The upstream's only consumer is this source's producer: stopped with a failure, so a producer waiting in the
        // middle of a block for an upstream block that no decoder will now decode wakes (it would wait forever).
        if case let .upstream(_, upstream) = source { upstream.stop(failure ?? Failure(.cancelled)) }
    }

    /// Block `index` failed with `failure`: nothing past it is decoded or handed out, while the blocks before it still
    /// are (they're all claimed: claims go in order), and the consumer gets `failure` when it reaches `index`, unless a
    /// lower block fails too (its failure then replaces this one) or the source is stopped first.
    @inlinable
    func fail(_ failure: Failure, at index: Int) {
        var lowered = false
        let consumer: Continuation<Void, Never>? = state.withLock { state in
            guard index < state.limit else { return nil }
            lowered = true
            state.limit = index
            limit.store(index, ordering: .relaxed)
            state.failure = failure
            guard state.consumer != nil, state.waitingFor >= index else { return nil }
            return state.consumer.take()
        }
        guard lowered else { return }
        consumer?.resume()
        // No block past `index` is needed: the producer stops (it's past `index`; the jobs it queued are below it, still
        // decoded, after a failure of its own, or past it, dropped by the decoders that take them), and so does what it
        // reads from upstream. The output pool stays open until the consumer stops the source: decoders may still need
        // buffers for the blocks before `index`. (Staging is the producer's alone.)
        jobs?.close()
        staging?.close()
        if case let .upstream(_, upstream) = source { upstream.stop(Failure(.cancelled)) }
    }

    @inlinable
    public func releaseUnconsumed() {
        state.withLock { state in
            for position in state.slots.indices where state.slots[position].index >= 0 {
                pool.release(state.slots[position].buffer)
                state.slots[position].index = -1
            }
        }
        // Jobs queued but not decoded hold staging buffers.
        jobs?.drain { job in
            if job.staging >= 0 { staging?.release(job.staging) }
        }
        if case let .upstream(_, upstream) = source { upstream.releaseUnconsumed() }
    }

    // MARK: Producing

    @inlinable
    func finishProducing(_ count: Int) {
        let consumer: Continuation<Void, Never>? = state.withLock { state in
            state.endIndex = count
            guard state.waitingFor >= count else { return nil }
            return state.consumer.take()
        }
        consumer?.resume()
        jobs?.close()
    }

    @inlinable
    nonisolated(nonsending) func produce() async {
        guard let jobs else { return }
        // The block being produced: a failure is this block's (the ones before it are queued).
        var index = 0
        do throws(Failure) {
            switch source {
            case .indexed:
                return
            case let .pbz(_, _, produceFromFile):
                try await produceFromFile(self, &index)
            case let .upstream(blockSize, upstream):
                guard let staging else { return }
                try await produce(blockSize: blockSize, from: upstream, staging: staging, into: jobs, index: &index)
            case let .slices(size, file):
                await produce(slices: size, file: file, into: jobs, index: &index)
            }
        } catch {
            fail(error, at: index)
        }
    }

    /// Queues slices of the stage's input; decoders read them.
    @inlinable
    nonisolated(nonsending) func produce(slices size: Int, file: Range<Int>, into jobs: AsyncQueue<BlockJob>, index: inout Int) async {
        var offset = file.lowerBound, rawOffset = 0
        while offset < file.upperBound {
            guard index < limit.load(ordering: .relaxed) else { return }
            let count = min(size, file.upperBound - offset)
            guard await jobs.push(BlockJob(index: index, rawOffset: rawOffset, rawSize: count, storedSize: count, fileOffset: offset)) else { return }
            offset += count
            rawOffset += count
            index += 1
        }
        finishProducing(index)
    }

    /// Reads the `pbz` stream out of the upstream's decoded blocks, copying each block's stored bytes into a staging
    /// buffer (blocks cross the upstream's).
    @inlinable
    nonisolated(nonsending) func produce(
        blockSize: Int, from upstream: any OrderedBlockSource<Failure>, staging: BlockBufferPool, into jobs: AsyncQueue<BlockJob>,
        index: inout Int
    ) async throws(Failure) {
        var reader = UpstreamReader(source: upstream)
        defer { reader.release() }
        try await reader.skip(PBZ.headerSize)
        var rawOffset = 0
        let header = RawStorage(byteCount: PBZ.blockHeaderSize, alignment: RawStorage.small)
        while index < limit.load(ordering: .relaxed) {
            let got = try await unsafe reader.read(into: header.base, count: PBZ.blockHeaderSize) // The header storage's size: safe.
            if got == 0 {
                finishProducing(index)
                return
            }
            guard got == PBZ.blockHeaderSize else { throw Failure(.framing(.blockHeaderCutShort)) }
            let raw: Int, stored: Int
            do throws(PBZError) {
                (raw, stored) = try PBZ.blockSizes(header.bytes(0..<PBZ.blockHeaderSize), index: index, blockSize: blockSize)
            } catch {
                throw Failure(.framing(error))
            }
            // Released however this iteration ends, unless the job takes it.
            guard let buffer = await staging.acquire() else { return } // Stopped.
            // `stored` ≤ the buffer's capacity.
            let copied = try await unsafe reader.read(into: staging.blockBase(buffer.index), count: stored)
            guard copied == stored else { throw Failure(.framing(.blockCutShort(block: index))) }
            // The job holds the staging buffer by index (jobs are copyable), until a decoder releases it.
            let held = buffer.detach()
            guard await jobs.push(BlockJob(index: index, rawOffset: rawOffset, rawSize: raw, storedSize: stored, fileOffset: -1, staging: held)) else {
                staging.release(held)
                return
            }
            rawOffset += raw
            index += 1
        }
    }

    // MARK: Decoding

    @inlinable
    nonisolated(nonsending) func decodeTask() async {
        var context = BlockContext(format: format, kind: kind, scratchCapacity: scratchCapacity, counters: counters)
        // An indexed stream's end and its stage's description of each block (`nil`: blocks come from the producer).
        let indexed: (end: Int, describe: DescribeBlock)? = if case let .indexed(range, describe) = source { (range.upperBound, describe) } else { nil }
        while !Task.isCancelled {
            // This decoder's until it's published; released on every other way out.
            guard let buffer = await pool.acquire() else { return }
            // No yield between blocks: yielding (after every block, or after resuming the consumer), with or without
            // decoders at a lower priority than the consumer, measured no different (NativeAEA/ARCHITECTURE.md §9).
            let job: BlockJob
            if let indexed {
                // Past a failing block (or stopped): not needed, and neither is any later one (claims go in order).
                guard let index = nextIndex.claim(below: indexed.end), index < limit.load(ordering: .relaxed) else { return }
                job = indexed.describe(stage, index)
            } else {
                guard let jobs, let next = await jobs.pop() else { return }
                // The same (the queue holds jobs in order).
                guard next.index < limit.load(ordering: .relaxed) else {
                    releaseStaging(next)
                    return
                }
                job = next
            }
            let started = MonotonicClock.now
            do throws(Failure) {
                try decode(job, into: buffer.index, context: &context)
            } catch {
                releaseStaging(job)
                fail(error, at: job.index)
                return
            }
            releaseStaging(job)
            counters.busy.add(MonotonicClock.nanoseconds(since: started), ordering: .relaxed)
            // Published: the slot holds the reference, by index, until the consumer takes it.
            let held = buffer.detach()
            let consumer: Continuation<Void, Never>? = state.withLock { state in
                state.slots[job.index % state.slots.count] = Slot(index: job.index, buffer: held, rawOffset: job.rawOffset, rawSize: job.rawSize)
                guard state.waitingFor == job.index else { return nil }
                return state.consumer.take()
            }
            consumer?.resume()
        }
    }

    @inlinable
    func releaseStaging(_ job: BlockJob) {
        if job.staging >= 0 { staging?.release(job.staging) }
    }

    /// Gets `job` decoded into `buffer`: from its staging buffer here, otherwise by the stage.
    @inlinable
    func decode(_ job: BlockJob, into buffer: Int, context: inout BlockContext) throws(Failure) {
        // The output buffer is this decoder's until it's published.
        let output = unsafe UnsafeMutableRawBufferPointer(start: pool.blockBase(buffer), count: job.rawSize)
        if job.staging >= 0, let staging {
            // The staging buffer holds `storedSize` bytes, the producer's copy, this decoder's until it releases it.
            let stored = unsafe UnsafeRawBufferPointer(start: staging.blockBase(job.staging), count: job.storedSize)
            do throws(BlockDecodingError) {
                try unsafe context.decompress(stored, into: output, block: job.index)
            } catch {
                throw Failure(error)
            }
        } else {
            try unsafe stage.decode(job, into: output, context: &context)
        }
    }
}

extension ParallelBlockDecoder where Stage: BlockReadingStage {
    /// A `pbz` stream in the stage's input: reads its block headers and queues the blocks; decoders read the blocks
    /// themselves. (Called through ``Source/pbz(blockSize:file:produce:)``, which the initializer that knows the stage
    /// reads forms.)
    @inlinable
    nonisolated(nonsending) func produceFromFile(index: inout Int) async throws(Failure) {
        guard case let .pbz(blockSize, file, _) = source, let jobs else { return }
        let end = file.upperBound
        var offset = file.lowerBound + PBZ.headerSize, rawOffset = 0
        let header = RawStorage(byteCount: PBZ.blockHeaderSize, alignment: RawStorage.small)
        while offset < end {
            guard index < limit.load(ordering: .relaxed) else { return }
            guard end - offset >= PBZ.blockHeaderSize else { throw Failure(.framing(.blockHeaderCutShort)) }
            // The header storage's 16 bytes: safe.
            try unsafe stage.read(at: offset, into: UnsafeMutableRawBufferPointer(start: header.base, count: PBZ.blockHeaderSize))
            offset += PBZ.blockHeaderSize
            let raw: Int, stored: Int
            do throws(PBZError) {
                (raw, stored) = try PBZ.blockSizes(
                    header.bytes(0..<PBZ.blockHeaderSize), index: index, blockSize: blockSize, available: end - offset
                )
            } catch {
                throw Failure(.framing(error))
            }
            guard await jobs.push(BlockJob(index: index, rawOffset: rawOffset, rawSize: raw, storedSize: stored, fileOffset: offset)) else { return }
            offset += stored
            rawOffset += raw
            index += 1
        }
        finishProducing(index)
    }
}

/// Reads bytes sequentially across an upstream source's blocks, releasing each when it's used up.
@usableFromInline
struct UpstreamReader<Failure: BlockDecodingFailure>: ~Copyable {
    @usableFromInline let source: any OrderedBlockSource<Failure>
    /// The block being read: its buffer is held while it's here.
    @usableFromInline var block: DecodedBlock?
    @usableFromInline var offset = 0
    /// Whether the first block was taken: before it, `block == nil` means "not yet"; after, the stream's end.
    @usableFromInline var started = false

    @inlinable
    init(source: any OrderedBlockSource<Failure>) {
        self.source = source
        block = nil
    }

    /// The current block's buffer and size (taking the first block if none was taken yet), or `nil` at the end.
    @inlinable
    nonisolated(nonsending) mutating func current() async throws(Failure) -> (buffer: Int, rawSize: Int)? {
        if !started {
            started = true
            block = try await source.nextBlock()
        }
        switch block {
        case let .some(block): return (block.buffer.index, block.rawSize)
        case .none: return nil
        }
    }

    /// Copies up to `count` bytes to `destination`; fewer only at the stream's end.
    @unsafe @inlinable
    nonisolated(nonsending) mutating func read(into destination: UnsafeMutableRawPointer, count: Int) async throws(Failure) -> Int {
        var done = 0
        while done < count {
            guard let current = try await current() else { break }
            let available = current.rawSize - offset
            if available == 0 {
                try await advance()
                continue
            }
            let take = min(available, count - done)
            // Within the block's decoded bytes and the destination's `count`: safe.
            unsafe (destination + done).copyMemory(from: source.pool.blockBase(current.buffer) + offset, byteCount: take)
            offset += take
            done += take
        }
        return done
    }

    @inlinable
    nonisolated(nonsending) mutating func skip(_ count: Int) async throws(Failure) {
        var left = count
        while left > 0 {
            guard let current = try await current() else { throw Failure(.framing(.headerCutShort)) }
            let take = min(current.rawSize - offset, left)
            offset += take
            left -= take
            if offset == current.rawSize { try await advance() }
        }
    }

    /// Releases the current block, then takes the next. Released first, explicitly: `block = try await …` alone would
    /// hold the old block until the call returns, a buffer more than the consumer's share of the pool while it waits
    /// (the decoders get it back only after the next block arrives). Not a deadlock with the smallest pools (one decoder,
    /// no extra buffers: a decoder takes a buffer before it takes its block, so the next block is already being decoded
    /// when the reader waits; `smallestPoolsFinish` finishes either way), but the buffer is free sooner.
    @inlinable
    nonisolated(nonsending) mutating func advance() async throws(Failure) {
        block = nil
        offset = 0
        block = try await source.nextBlock()
    }

    /// Releases the block still held.
    @inlinable
    mutating func release() {
        block = nil
    }
}
