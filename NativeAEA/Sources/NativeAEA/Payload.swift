import BytesAsync
import BytesCompression
import BytesCompressionAsync
import Disk
import Foundation
import Synchronization
import System

/// A `pbz` stream inside an AEA archive's segments, decoded from them (BytesCompressionAsync's engine, its blocks
/// copied out of the segments into staging).
public typealias PBZInSegments = ParallelBlockDecoder<UpstreamBlocks<AEAError>>

/// A file read in `pbz` blocks or plain slices: an `.aar`, a `.xip`'s content.
public typealias FileBlocks = ParallelBlockDecoder<ArchiveFileStage>

public extension AEAArchive {
    /// The archive's decoded contents as a chunk source (not yet running): its segments when they hold a plain Apple
    /// Archive stream, or a ``PBZInSegments`` decoding the `pbz` stream they hold, decided once the first segment is
    /// decoded (``AEAPayload``).
    ///
    /// - Parameter held: Buffers the consumer's side holds beyond decoding (writers' references).
    func payload(_ options: AEAReadOptions, heldBeyondDecoding held: Int) throws(AEAError) -> AEAPayload {
        // The pool is sized for writers holding segment buffers, which they do only when the segments hold the archive
        // itself; until the first segment says so (``AEAPayload/prepare()``), only what a `pbz` stream's producer needs
        // is handed out: the block stream's producer, the segments' one consumer then, holds one segment at a time
        // (the engine's upstream reader). (Limiting the pool once the stream was known was too late: stored segments
        // decode so fast that the decoders had touched every buffer before the walker's task ran.)
        // A walker reads the segments when they hold the archive itself: they carry its headers across segments.
        let stream = try segmentStream(
            options, heldBuffers: held, consumerBuffers: ExtractionSink.walkBuffers(held: held, blockCapacity: rootHeader.segmentSize),
            heldUntilActivated: 1, carryCapacity: AppleArchive.headerCarryCapacity
        )
        return AEAPayload(stream, options: options, held: held)
    }
}

/// An AEA archive's decoded contents: its segments, or the `pbz` stream they hold, decoded by a second
/// `ParallelBlockDecoder` over them (``PBZInSegments``). Which one is known only from the first segment's bytes, so ``run()`` starts the segments' decoders at once,
/// and ``prepare()`` (the consumer's first call) waits for the first segment, looks at it without taking it, and
/// decides; ``run()`` then starts the block stream's tasks if there is one. The first segment is decoded once, in
/// parallel with the others.
///
/// (Decoding it on the caller's task before starting the decoders cost every `.aea` operation one segment's decoding
/// time, about 0.15 s on Xcode's: 5% of listing it.)
public final class AEAPayload: OrderedBlockSource {
    public typealias Failure = AEAError

    public let segments: SegmentStream
    private let options: AEAReadOptions
    private let held: Int

    private struct State: ~Copyable {
        var decided = false
        /// The block stream, if the segments hold a `pbz` stream.
        var blocks: PBZInSegments?
        /// ``run()`` waiting for the decision.
        var runner: Continuation<PBZInSegments?, Never>?
    }

    private let state = Mutex(State())

    init(_ segments: SegmentStream, options: AEAReadOptions, held: Int) {
        self.segments = segments
        self.options = options
        self.held = held
    }

    /// The source the consumer reads: the block stream once decided, the segments otherwise.
    private var current: any ChunkSource { state.withLock { $0.blocks } ?? segments }

    /// The block stream, if ``prepare()`` found a `pbz` stream.
    public var blocks: PBZInSegments? { state.withLock { $0.blocks } }

    public var pool: BlockBufferPool { current.pool }
    public var pools: [BlockBufferPool] { current.pools }
    public var counters: BlockDecodingCounters { current.counters }

    public nonisolated(nonsending) func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.segments.run() }
            if let blocks = await decision() { await blocks.run() }
        }
    }

    /// Suspends until ``prepare()`` decides (or the source is stopped first: `nil`).
    private nonisolated(nonsending) func decision() async -> PBZInSegments? {
        await wait(in: state) { state, continuation in
            if state.decided { return .some(state.blocks) }
            precondition(state.runner == nil, "AEAPayload: one task runs it")
            state.runner = continuation.take()
            return nil
        }
    }

    /// Records the decision, unless the source was stopped first, and lets ``run()`` go on.
    private func decide(_ blocks: PBZInSegments?) {
        let runner = state.withLock { state -> Continuation<PBZInSegments?, Never>? in
            guard !state.decided else { return nil }
            state.decided = true
            state.blocks = blocks
            return state.runner.take()
        }
        if let runner { runner.resume(returning: blocks) }
    }

    public nonisolated(nonsending) func prepare() async throws(AEAError) {
        if state.withLock({ $0.decided }) { return }
        let blocks: PBZInSegments?
        do throws(AEAError) {
            blocks = try await pbzStream()
        } catch {
            decide(nil)
            throw error
        }
        // The segments hold the archive: writers will hold their buffers, so the whole pool is handed out.
        if blocks == nil { segments.pool.activateAll() }
        // If the source was stopped meanwhile (cancelled), this does nothing: the segments are stopped, and the next
        // chunk throws.
        decide(blocks)
    }

    /// A block stream over the segments if the first one starts a `pbz` stream.
    private nonisolated(nonsending) func pbzStream() async throws(AEAError) -> PBZInSegments? {
        guard let first = try await segments.peek() else { return nil }
        let pool = segments.pool
        // The first chunk's first bytes, published and held until the consumer takes it.
        let head = pool.bytes(first.buffer.index, at: 0, count: min(first.rawSize, PBZ.headerSize))
        let header: (compression: AppleArchiveCompression, blockSize: Int)?
        do throws(PBZError) {
            header = try PBZ.header(head)
        } catch {
            throw AEAError(.framing(error))
        }
        guard let (compression, blockSize) = header else { return nil }
        // The segments' pool stays as it started: writers hold the block stream's buffers (its pool is sized for them,
        // within what the segments' buffers leave of the budget). The walker reads the blocks: they carry its headers.
        return PBZInSegments(
            pbz: compression, blockSize: blockSize, upstream: segments, decoders: options.decodeThreads, extraBuffers: options.extraBuffers,
            heldBuffers: held, consumerBuffers: ExtractionSink.walkBuffers(held: held, blockCapacity: blockSize),
            carryCapacity: AppleArchive.headerCarryCapacity, budget: options.bufferBudget - segments.bufferByteCount
        )
    }

    public nonisolated(nonsending) func nextBlock() async throws(AEAError) -> DecodedBlock? {
        try await current.nextBlock()
    }

    public func stop(_ failure: AEAError?) {
        // Undecided: ``run()`` stops waiting, starting no block stream.
        decide(nil)
        if let blocks { blocks.stop(failure) } else { segments.stop(failure) } // A block stream stops its upstream too.
    }

    public func releaseUnconsumed() {
        if let blocks { blocks.releaseUnconsumed() } else { segments.releaseUnconsumed() } // Same.
    }
}

/// An Apple Archive file (`.aar`), plain or compressed (`pbz`, `aa archive`'s default), extracted and listed as
/// archives inside AEA containers are.
public final class AppleArchiveFile: Sendable {
    public let path: FilePath
    /// The block compression, or `nil` for a plain stream.
    public let compression: AppleArchiveCompression?
    /// The largest block (`pbz`), or the slice plain streams are read in.
    public let blockSize: Int
    /// The archive file, open for reading (Disk's `InputFile`).
    private let file: InputFile
    private let size: Int

    public init(path: FilePath) throws(AEAError) {
        // Closed by `close()`, or here if `init` throws.
        let file = try AEAArchive.open(path)
        self.file = file
        self.path = path
        do throws(AEAError) {
            size = file.count
            let head = try AEAArchive.read(file, at: 0, count: min(size, PBZ.headerSize))
            let header: (compression: AppleArchiveCompression, blockSize: Int)?
            do throws(PBZError) {
                header = try PBZ.header(head.span.bytes)
            } catch {
                throw AEAError(.framing(error))
            }
            if let header {
                compression = header.compression
                blockSize = header.blockSize
            } else {
                let isArchive = AppleArchive.startsAnArchive(head.span.bytes)
                guard size == 0 || isArchive else {
                    throw AEAError.invalidArchive("not an Apple Archive (no AA01 or pbz magic)")
                }
                compression = nil
                blockSize = 16 << 20
            }
        } catch {
            file.close()
            throw error
        }
    }

    /// Closes the archive's file: the end of reading it (see ``AEAArchive/close()``). Safe to call more than once.
    public func close() {
        file.close()
    }

    /// The decoded contents as a chunk source (not yet running).
    public func source(_ options: AEAReadOptions, heldBeyondDecoding held: Int) -> FileBlocks {
        let stage = ArchiveFileStage(file: file)
        let walk = ExtractionSink.walkBuffers(held: held, blockCapacity: blockSize)
        // The walker reads the blocks: they carry its headers.
        let carry = AppleArchive.headerCarryCapacity
        guard let compression else {
            return FileBlocks(
                stage: stage, slices: blockSize, file: 0..<size, decoders: options.decodeThreads, extraBuffers: options.extraBuffers,
                heldBuffers: held, consumerBuffers: walk, carryCapacity: carry, budget: options.bufferBudget
            )
        }
        return FileBlocks(
            stage: stage, pbz: compression, blockSize: blockSize, file: 0..<size, decoders: options.decodeThreads,
            extraBuffers: options.extraBuffers, heldBuffers: held, consumerBuffers: walk, carryCapacity: carry, budget: options.bufferBudget
        )
    }

    /// Extracts the archive beneath `destination`; see ``AEAArchive/extract(to:options:)``. The extraction's progress (`options.disk.progress`)
    /// starts from the file's size as its estimate of the bytes (the stream's, for a plain archive; low for `pbz`).
    @concurrent @discardableResult
    public func extract(to destination: FilePath, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        let target = try Extractor.open(destination, options: options, archivePath: path, quarantinesDestination: true)
        return try await Extractor.extract(source(options.read, heldBeyondDecoding: options.heldBuffers), into: target, options: options, expectedBytes: size)
    }

    /// Extracts the archive into `destination`, a directory the caller opened; see ``AEAArchive/extract(into:options:)``.
    @concurrent @discardableResult
    public func extract(into destination: Destination, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        let target = try Extractor.reopen(destination, options: options)
        return try await Extractor.extract(source(options.read, heldBeyondDecoding: options.heldBuffers), into: target, options: options, expectedBytes: size)
    }

    /// Decodes the archive and calls `body` with each entry, in order; see ``AEAArchive/forEachEntry(options:_:)``.
    @concurrent @discardableResult
    public func forEachEntry(options: AEAReadOptions = .init(), _ body: @escaping (AAEntry) -> Void) async throws(AEAError) -> AEAStatistics {
        try await Lister.list(source(options, heldBeyondDecoding: 0), body)
    }

    /// Decodes the archive and parses every entry without making entries; see ``AEAArchive/verify(options:)``.
    @concurrent @discardableResult
    public func verify(options: AEAReadOptions = .init()) async throws(AEAError) -> AEAStatistics {
        try await Lister.list(source(options, heldBeyondDecoding: 0), nil)
    }
}
