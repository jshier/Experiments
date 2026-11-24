import BytesAsync
import Disk
import Foundation
import Synchronization
import System

extension AEAArchive {
    /// The archive's decoded contents as a chunk source (not yet running): its segments when they hold a plain Apple
    /// Archive stream, or a ``BlockStream`` decoding the `pbz` stream they hold, decided once the first segment is
    /// decoded (``AEAPayload``).
    ///
    /// - Parameter held: Buffers the consumer's side holds beyond decoding (writers' references).
    func payload(_ options: AEAReadOptions, heldBeyondDecoding held: Int) throws(AEAError) -> AEAPayload {
        // At least one decoder, and a buffer beyond what the consumer holds (fewer would wait forever).
        let decoders = max(1, options.decodeThreads)
        // Sized for writers holding segment buffers, which they do only when the segments hold the archive itself; until
        // the first segment says so (``AEAPayload/prepare()``), only what a `pbz` stream's producer needs is handed out.
        // The block stream's producer, the segments' one consumer then, holds one segment at a time (`UpstreamReader`):
        // a buffer per decoder, the extra ones, the producer's, and one more so a decoder can always take the next
        // segment. (Limiting the pool once the stream was known was too late: stored segments decode so fast that the
        // decoders had touched every buffer before the walker's task ran.)
        let pool = SegmentBufferPool(
            count: decoders + max(0, options.extraBuffers) + max(0, held) + 1, segmentCapacity: rootHeader.segmentSize,
            active: decoders + max(0, options.extraBuffers) + 2
        )
        let stream = try SegmentStream(
            archive: self, pool: pool, decoders: decoders,
            verifyMACs: options.verifyMACs, verifyChecksums: options.verifyChecksums, input: options.input
        )
        return AEAPayload(stream, options: options, held: held)
    }
}

/// An AEA archive's decoded contents: its segments, or the `pbz` stream they hold, decoded by a ``BlockStream`` over
/// them. Which one is known only from the first segment's bytes, so ``run()`` starts the segments' decoders at once,
/// and ``prepare()`` (the consumer's first call) waits for the first segment, looks at it without taking it, and
/// decides; ``run()`` then starts the block stream's tasks if there is one. The first segment is decoded once, in
/// parallel with the others.
///
/// (Decoding it on the caller's task before starting the decoders cost every `.aea` operation one segment's decoding
/// time, about 0.15 s on Xcode's: 5% of listing it.)
final class AEAPayload: ChunkSource {
    let segments: SegmentStream
    private let options: AEAReadOptions
    private let held: Int

    private struct State {
        var decided = false
        /// The block stream, if the segments hold a `pbz` stream.
        var blocks: BlockStream?
        /// ``run()`` waiting for the decision.
        var runner: Continuation<BlockStream?>?
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
    var blocks: BlockStream? { state.withLock { $0.blocks } }

    var pool: SegmentBufferPool { current.pool }
    var pools: [SegmentBufferPool] { current.pools }
    var counters: ChunkCounters { current.counters }

    nonisolated(nonsending) func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.segments.run() }
            if let blocks = await decision() { await blocks.run() }
        }
    }

    /// Suspends until ``prepare()`` decides (or the source is stopped first: `nil`).
    nonisolated(nonsending) private func decision() async -> BlockStream? {
        await withContinuation { (continuation: Continuation<BlockStream?>) in
            let decided: BlockStream?? = state.withLock { state in
                if state.decided { return .some(state.blocks) }
                state.runner = continuation
                return nil
            }
            if let decided { continuation.resume(returning: decided) }
        }
    }

    /// Records the decision, unless the source was stopped first, and lets ``run()`` go on.
    private func decide(_ blocks: BlockStream?) {
        let runner: Continuation<BlockStream?>? = state.withLock { state in
            guard !state.decided else { return nil }
            state.decided = true
            state.blocks = blocks
            defer { state.runner = nil }
            return state.runner
        }
        runner?.resume(returning: blocks)
    }

    nonisolated(nonsending) func prepare() async throws(AEAError) {
        if state.withLock({ $0.decided }) { return }
        let blocks: BlockStream?
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
    nonisolated(nonsending) private func pbzStream() async throws(AEAError) -> BlockStream? {
        guard let first = try await segments.peek() else { return nil }
        let pool = segments.pool
        // The first chunk's first bytes, published and held until the consumer takes it.
        let head = pool.bytes(first.buffer, at: 0, count: min(first.rawSize, PBZ.headerSize))
        guard let compression = PBZ.compression(head) else { return nil }
        guard first.rawSize >= PBZ.headerSize else { throw .invalidArchive("a pbz header is cut short") }
        let blockSize = try PBZ.blockSize(head)
        // The segments' pool stays as it started: writers hold the block stream's buffers (its pool is sized for them).
        return BlockStream(
            .upstream(segments), layout: .pbz(compression, blockSize: blockSize),
            decoders: options.decodeThreads, extraBuffers: options.extraBuffers + held
        )
    }

    nonisolated(nonsending) func nextChunk() async throws(AEAError) -> DecodedChunk? {
        try await current.nextChunk()
    }

    func stop(_ failure: AEAError?) {
        // Undecided: ``run()`` stops waiting, starting no block stream.
        decide(nil)
        if let blocks { blocks.stop(failure) } else { segments.stop(failure) } // A block stream stops its upstream too.
    }

    func releaseUnconsumed() {
        if let blocks { blocks.releaseUnconsumed() } else { segments.releaseUnconsumed() } // Same.
    }
}

/// An Apple Archive file (`.aar`), plain or compressed (`pbz`, `aa archive`'s default), extracted and listed as
/// archives inside AEA containers are.
public final class AppleArchiveFile: Sendable {
    public let path: FilePath
    /// The block compression, or `nil` for a plain stream.
    public let compression: AEACompression?
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
            let detected = PBZ.compression(head.span.bytes)
            if let detected {
                guard head.count == PBZ.headerSize else { throw AEAError.invalidArchive("a pbz header is cut short") }
                compression = detected
                blockSize = try PBZ.blockSize(head.span.bytes)
            } else {
                let isArchive = PBZ.isAppleArchive(head.span.bytes)
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
    func source(_ options: AEAReadOptions, heldBeyondDecoding held: Int) -> BlockStream {
        let layout: BlockStream.Layout = if let compression { .pbz(compression, blockSize: blockSize) } else { .plain(sliceSize: blockSize) }
        return BlockStream(
            .file(file, start: 0, end: size), layout: layout, decoders: options.decodeThreads,
            extraBuffers: options.extraBuffers + held
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
