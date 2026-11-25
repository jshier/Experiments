@testable import NativeAEA
import BytesAsync
import BytesCompressionAsync
import BytesTestSupport
import Foundation
import Synchronization
import System
import Testing

/// Cancellation and failure: every part of an operation is a child task of the caller's, so cancelling the caller (or a
/// decoder failing) ends the whole operation promptly, with every pool buffer back and nothing left waiting.
@Suite(.diskLifetimes) struct CancellationTests {
    /// How the archive's stream is decoded.
    enum Layout: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// AEA segments holding an Apple Archive (``SegmentStream``).
        case segments
        /// AEA segments holding a `pbz` stream (``BlockStream`` over a ``SegmentStream``).
        case pbzInAEA
        /// A `pbz` `.aar` file (``BlockStream`` reading the file).
        case pbzFile

        var testDescription: String { rawValue }
    }

    /// An archive of many small files and a few spanning many segments (pieces mid-write when cancelled), in small
    /// segments or blocks: chunks to cancel between.
    private static func makeArchive(_ layout: Layout, in directory: TemporaryDirectory) throws -> (url: URL, keys: SigningKeys, files: Int) {
        let keys = try SharedFixtures.keys.get()
        let source = directory.path("source")
        var files = 0
        for folder in 0..<20 {
            let path = source.appending(path: "d\(folder)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            for index in 0..<20 {
                try Data(testBytes(8_000 + index * 300, seed: UInt64(folder * 100 + index), compressible: true))
                    .write(to: path.appending(path: "f\(index)"))
                files += 1
            }
        }
        for index in 0..<3 {
            try Data(testBytes(3_000_000, seed: UInt64(5_000 + index), compressible: index != 1)).write(to: source.appending(path: "large\(index)"))
            files += 1
        }
        let stream = directory.path("tree.aar")
        let algorithm = layout == .segments ? "raw" : "lzfse"
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", algorithm, "-b", "256k", "-d", source.path, "-o", stream.path])
        switch layout {
        case .segments: return try (makeAEA(stream, keys: keys, in: directory, compression: "lzfse", blockSize: "64k"), keys, files)
        case .pbzInAEA: return try (makeAEA(stream, keys: keys, in: directory, compression: "copy", blockSize: "100k"), keys, files)
        case .pbzFile: return (stream, keys, files)
        }
    }

    /// Each layout's archive, made once (in its own directory) and only read by the tests.
    private static let segmentsArchive = SharedFixtures.make { try makeArchive(.segments, in: $0) }
    private static let pbzInAEAArchive = SharedFixtures.make { try makeArchive(.pbzInAEA, in: $0) }
    private static let pbzFileArchive = SharedFixtures.make { try makeArchive(.pbzFile, in: $0) }

    private func makeArchive(_ layout: Layout, in _: TemporaryDirectory) throws -> (url: URL, keys: SigningKeys, files: Int) {
        switch layout {
        case .segments: try Self.segmentsArchive.get()
        case .pbzInAEA: try Self.pbzInAEAArchive.get()
        case .pbzFile: try Self.pbzFileArchive.get()
        }
    }

    /// The archive's source as its extraction or listing would make it, and the archive (which owns the descriptor
    /// the source reads: keep it alive while the source runs, as its methods do).
    private func source(_ layout: Layout, _ url: URL, _ keys: SigningKeys, _ options: AEAReadOptions, held: Int) throws -> (any ChunkSource, AnyObject) {
        switch layout {
        case .segments, .pbzInAEA:
            let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
            return try (archive.payload(options, heldBeyondDecoding: held), archive)
        case .pbzFile:
            let file = try AppleArchiveFile(path: FilePath(url.path))
            return (file.source(options, heldBeyondDecoding: held), file)
        }
    }

    /// Closes what `source(_:_:_:_:held:)` opened (its archive, which the source reads from, stays open until then).
    private static func close(_ owner: AnyObject) {
        (owner as? AEAArchive)?.close()
        (owner as? AppleArchiveFile)?.close()
    }

    private static func buffersInUse(_ source: any ChunkSource) -> Int {
        source.pools.reduce(0) { $0 + $1.buffersInUse }
    }

    /// Runs `body` as a child task (which it may cancel), returning its error.
    private static func inChildTask(_ body: @escaping @Sendable () async throws(AEAError) -> Void) async -> AEAError? {
        await withTaskGroup(of: AEAError?.self) { group in
            group.addTask {
                do throws(AEAError) {
                    try await body()
                    return nil
                } catch {
                    return error
                }
            }
            return await group.next()!
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Layout.allCases, [1, 3, 8])
    func cancellingAnExtractionStopsEverything(_ layout: Layout, _ cancelAt: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, _) = try makeArchive(layout, in: directory)
        var options = AEAExtractionOptions()
        options.read.decodeThreads = 4
        options.disk.writers = 4
        options.disk.fileSystemWidth = 2
        let (inner, owner) = try source(layout, url, keys, options.read, held: options.heldBuffers)
        defer { Self.close(owner) }
        let settings = options
        let cancelling = CancellingSource(inner, cancelAt: cancelAt)
        let destination = FilePath(directory.path("out").path)
        let error = await Self.inChildTask { () throws(AEAError) in
            let target = try Extractor.open(destination, options: settings, archivePath: FilePath(url.path), quarantinesDestination: false)
            _ = try await Extractor.extract(cancelling, into: target, options: settings)
        }
        #expect(error == .cancelled)
        #expect(Self.buffersInUse(inner) == 0)
        #expect(cancelling.taken == cancelAt)
    }

    @Test(.timeLimit(.minutes(1)), arguments: Layout.allCases)
    func cancellingAListingStopsIt(_ layout: Layout) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, files) = try makeArchive(layout, in: directory)
        var options = AEAReadOptions()
        options.decodeThreads = 4
        let (inner, owner) = try source(layout, url, keys, options, held: 0)
        defer { Self.close(owner) }
        let listed = RelaxedCounter()
        let error = await Self.inChildTask { () throws(AEAError) in
            // The callback cancels its own task (the listing's) at the 50th entry.
            _ = try await Lister.list(inner) { _ in
                if listed.add() == 50 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        #expect(error == .cancelled)
        #expect(listed.value < files)
        #expect(Self.buffersInUse(inner) == 0)
    }

    /// Through the public API, from a task cancelled before it starts: nothing is walked.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledTaskThrowsAtOnce() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, _) = try makeArchive(.segments, in: directory)
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        let destination = FilePath(directory.path("out").path)
        let errors = await withTaskGroup(of: AEAError?.self) { group in
            group.cancelAll() // Tasks added from now on start cancelled.
            group.addTask {
                do throws(AEAError) {
                    try await archive.extract(to: destination)
                    return nil
                } catch {
                    return error
                }
            }
            group.addTask {
                do throws(AEAError) {
                    try await archive.forEachEntry { _ in }
                    return nil
                } catch {
                    return error
                }
            }
            var errors: [AEAError?] = []
            for await error in group {
                errors.append(error)
            }
            return errors
        }
        #expect(errors == [.cancelled, .cancelled])
        // Nothing in the destination: the walk never started.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.string).isEmpty)
    }

    /// A segment that fails its MAC: the decoder's failure ends the walk with that error, and the extraction's tasks
    /// end with every buffer back.
    @Test(.timeLimit(.minutes(1)), arguments: [Layout.segments, .pbzInAEA])
    func aDecoderFailureReleasesEverything(_ layout: Layout) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, _) = try makeArchive(layout, in: directory)
        let original = try AEAArchive(url: url, signingKey: keys.signingKey)
        let segment = original.segments[5]
        original.close()
        var bytes = try Data(contentsOf: url)
        bytes[segment.fileOffset + 10] ^= 0x40
        let tampered = directory.path("tampered.aea")
        try bytes.write(to: tampered)

        var options = AEAExtractionOptions()
        options.read.decodeThreads = 4
        options.disk.writers = 4
        let (inner, owner) = try source(layout, tampered, keys, options.read, held: options.heldBuffers)
        defer { Self.close(owner) }
        let settings = options
        let destination = FilePath(directory.path("out").path)
        let error = await Self.inChildTask { () throws(AEAError) in
            let target = try Extractor.open(destination, options: settings, archivePath: FilePath(tampered.path), quarantinesDestination: false)
            _ = try await Extractor.extract(inner, into: target, options: settings)
        }
        #expect(error == .authenticationFailed("segment 5"))
        #expect(Self.buffersInUse(inner) == 0)

        // Listing too, through the public API.
        await #expect(throws: AEAError.authenticationFailed("segment 5")) {
            let opened = try AEAArchive(url: tampered, signingKey: keys.signingKey)
            defer { opened.close() }
            try await opened.forEachEntry { _ in }
        }
    }

    /// An Apple Archive stream followed by bytes that aren't one, in `pbz` blocks of 2 MiB stored as they are, in AEA
    /// segments of 64 KiB (`big.aea`'s shape: each block spans 32 segments, more than are decoded at once).
    private static let largeBlocksArchive = SharedFixtures.make { directory -> (url: URL, keys: SigningKeys) in
        let keys = try SharedFixtures.keys.get()
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data(testBytes(20_000, seed: UInt64(index), compressible: true)).write(to: source.appending(path: "f\(index)"))
        }
        let plain = directory.path("plain.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", plain.path])
        let bytes = try Array(Data(contentsOf: plain)) + testBytes(5_000_000, seed: 99, compressible: false)
        func bigEndian(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) } }
        let blockSize = 2 << 20
        var stream = Array("pbzz".utf8) + bigEndian(blockSize)
        for start in stride(from: 0, to: bytes.count, by: blockSize) {
            let block = bytes[start..<min(start + blockSize, bytes.count)]
            stream += bigEndian(block.count) + bigEndian(block.count) + block
        }
        let url = directory.path("large-blocks.pbz")
        try Data(stream).write(to: url)
        return try (makeAEA(url, keys: keys, in: directory, compression: "copy", blockSize: "64k"), keys)
    }

    /// A walk that fails while the block stream's producer is in the middle of a block spanning more segments than are
    /// decoded at once: listing and extracting end with the walk's error, every buffer back. (The stop after the walk
    /// passed no failure to the segments, so the producer waited forever for a segment no decoder would decode.)
    @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 8])
    func aWalkFailingInsideALargeBlockEnds(_ decoders: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys) = try Self.largeBlocksArchive.get()
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        func isInvalidArchive(_ error: any Error?) -> Bool {
            if case .invalidArchive? = error as? AEAError { true } else { false }
        }
        var options = AEAExtractionOptions()
        options.read.decodeThreads = decoders
        options.disk.writers = 2
        // The segments' pool hands out at most 8 + 8 + 2 buffers until the payload knows it holds a `pbz` stream, and no
        // more after: fewer than a block's 32 segments.
        let listed = try archive.payload(options.read, heldBeyondDecoding: 0)
        let listing = await Self.inChildTask { () throws(AEAError) in _ = try await Lister.list(listed, nil) }
        #expect(isInvalidArchive(listing))
        #expect(listed.blocks != nil)
        #expect(Self.buffersInUse(listed) == 0)

        let extracted = try archive.payload(options.read, heldBeyondDecoding: options.heldBuffers)
        let settings = options
        let destination = FilePath(directory.path("out").path)
        let extraction = await Self.inChildTask { () throws(AEAError) in
            let target = try Extractor.open(destination, options: settings, archivePath: FilePath(url.path), quarantinesDestination: false)
            _ = try await Extractor.extract(extracted, into: target, options: settings)
        }
        #expect(isInvalidArchive(extraction))
        #expect(Self.buffersInUse(extracted) == 0)
        // Through the public API too.
        await #expect { try await archive.verify(options: settings.read) } throws: { isInvalidArchive($0) }
    }

    /// An AEA archive's payload decides from its first decoded segment whether it holds a `pbz` stream: the segments'
    /// decoders run meanwhile, and the first segment, looked at without taking it, is then read through the stream
    /// chosen.
    @Test(arguments: [Layout.segments, .pbzInAEA])
    func findsAPBZStreamInTheFirstSegment(_ layout: Layout) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, files) = try makeArchive(layout, in: directory)
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        for decoders in [1, 3] {
            var options = AEAReadOptions()
            options.decodeThreads = decoders
            let source = try archive.payload(options, heldBeyondDecoding: 0)
            #expect(source.blocks == nil) // Undecided.
            var count = 0
            let statistics = try await Lister.list(source) { entry in
                if entry.header.type == .regularFile { count += 1 }
            }
            #expect(count == files)
            #expect((source.blocks != nil) == (layout == .pbzInAEA))
            #expect(statistics.unreleasedBuffers == 0)
            #expect(source.segments.pool.buffersInUse == 0)
        }
    }
}

/// A chunk source that cancels the task consuming it as it hands out chunk `cancelAt` (counting from 1): a
/// cancellation at a known point of the walk, with decoders and writers mid-flight.
final class CancellingSource: OrderedBlockSource, @unchecked Sendable {
    typealias Failure = AEAError

    let inner: any ChunkSource
    let cancelAt: Int
    /// Chunks asked for: touched only by the consumer's task.
    private(set) var taken = 0
    let counters = BlockDecodingCounters()

    init(_ inner: any ChunkSource, cancelAt: Int) {
        self.inner = inner
        self.cancelAt = cancelAt
    }

    var pool: BlockBufferPool { inner.pool }
    var pools: [BlockBufferPool] { inner.pools }
    nonisolated(nonsending) func run() async { await inner.run() }
    nonisolated(nonsending) func prepare() async throws(AEAError) { try await inner.prepare() }

    nonisolated(nonsending) func nextBlock() async throws(AEAError) -> DecodedBlock? {
        taken += 1
        if taken == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
        return try await inner.nextBlock()
    }

    func stop(_ failure: AEAError?) { inner.stop(failure) }
    func releaseUnconsumed() { inner.releaseUnconsumed() }
}
