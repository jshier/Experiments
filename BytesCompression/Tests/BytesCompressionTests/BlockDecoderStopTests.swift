import Bytes
import BytesCompression
import BytesCompressionAsync
import BytesTestSupport
import Synchronization
import Testing

// How `ParallelBlockDecoder` ends (review 2026-11-23 §1.4, §1.5; fix plan A4): a stop never leaves a task waiting
// (a `pbz` stream inside upstream blocks, stopped while its producer is in the middle of a block that spans more
// upstream blocks than are in flight, hung: `big.aea`), and failures reach the consumer in block order, after the blocks
// before them (the lowest failing block's error, whichever task failed first).

/// Runs `upstream` beside `source`'s decoders, as NativeAEA's payload does (in one task group, so both have ended
/// before `source` releases what wasn't taken), while `consume` takes blocks from `source`.
func withUpstream<Upstream: OrderedBlockSource, Source: OrderedBlockSource, R>(
    _ upstream: Upstream, _ source: Source, _ consume: () async -> R
) async -> R {
    await source.withDecoding { group in
        group.addTask { await upstream.run() }
        return await consume()
    }
}

/// The blocks `source` hands out, by index, until it ends or fails.
func collect<Source: OrderedBlockSource>(_ source: Source) async -> (blocks: [Int], failure: Source.Failure?) {
    var blocks: [Int] = []
    do throws(Source.Failure) {
        try await source.prepare()
        while let block = try await source.nextBlock() {
            blocks.append(block.index)
            source.pool.release(block.buffer)
        }
        return (blocks, nil)
    } catch {
        return (blocks, error)
    }
}

@Suite struct BlockDecoderStopTests {
    /// A `pbz` stream in 512 KiB blocks, each half text and half random (so stored in well over 100 KB): carried in
    /// 4 KiB "segments", a block spans dozens of them, while the segments' pool holds at most a dozen (`big.aea`'s
    /// shape: 64 MiB blocks in 1 MiB segments).
    static let blockSize = 524_288
    static let big = Result {
        let data = (0..<6).flatMap { SampleBytes.text(262_144, seed: UInt64($0)) + SampleBytes.random(262_144, seed: UInt64($0)) }
        return try pbzStream(data, blockSize: blockSize)
    }

    /// Where each block's stored bytes are in a `pbz` stream of the big stream's block size.
    static func storedRanges(_ stream: [UInt8]) throws -> [Range<Int>] { try storedRanges(stream, blockSize: blockSize) }

    enum Stop: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The consumer returns before taking a block.
        case beforeAnyBlock
        /// It takes one block and returns.
        case afterOneBlock
        /// It takes one block and fails on its own.
        case withItsOwnError
        /// Block 1 doesn't decode.
        case blockFails

        var testDescription: String { rawValue }
    }

    /// A `pbz` stream in upstream blocks, stopped while its producer is in the middle of a block that spans more upstream
    /// blocks than are in flight: everything ends (the upstream is stopped with a failure, which wakes the producer),
    /// with every buffer of every pool back, and the consumer's own result is the result.
    @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 8], Stop.allCases)
    func stoppingMidBlockEnds(decoders: Int, stop: Stop) async throws {
        var stream = try Self.big.get()
        let ranges = try Self.storedRanges(stream)
        #expect(ranges.count == 6 && ranges.allSatisfy { $0.count > 100_000 && $0.count < Self.blockSize })
        if stop == .blockFails {
            let damaged = ranges[1].lowerBound + 200 // In the compressed text.
            stream[damaged] ^= 0xFF
            stream[damaged + 1] ^= 0xFF
        }
        let segments = BlockDecoderTests.segments(of: stream, size: 4_096, decoders: decoders, extraBuffers: 2)
        #expect(segments.pool.count < ranges[0].count / 4_096)
        let blocks = ParallelBlockDecoder(pbz: .zlib, blockSize: Self.blockSize, upstream: segments, decoders: decoders, extraBuffers: 1)
        let outcome: Result<Int, TestFailure> = await withUpstream(segments, blocks) {
            do throws(TestFailure) {
                try await blocks.prepare()
                if stop == .beforeAnyBlock { return .success(0) }
                var taken = 0
                while let block = try await blocks.nextBlock() {
                    blocks.pool.release(block.buffer)
                    taken += 1
                    if stop == .afterOneBlock { return .success(taken) }
                    if stop == .withItsOwnError { return .failure(.consumer) }
                }
                return .success(taken)
            } catch {
                return .failure(error)
            }
        }
        switch stop {
        case .beforeAnyBlock: #expect(outcome == .success(0))
        case .afterOneBlock: #expect(outcome == .success(1))
        case .withItsOwnError: #expect(outcome == .failure(.consumer))
        case .blockFails:
            guard case .failure(.engine(.decoding(_, block: 1, kind: .pbz))) = outcome else {
                Issue.record("expected block 1's decoding failure, got \(outcome)")
                return
            }
        }
        #expect(blocks.pools.count == 3)
        #expect(blocks.pools.allSatisfy { $0.buffersInUse == 0 })
    }

    /// A stop with no failure (`stop(nil)`: the consumer is done) wakes a consumer waiting for a block with the
    /// cancellation failure; it doesn't wait for the block. What `withDecoding` returns is still the consumer's own.
    @Test(.timeLimit(.minutes(1))) func stopWakesAWaitingConsumer() async throws {
        let (plain, _) = try BlockDecoderTests.indexedStream(blockSize: 20_000)
        var stage = plain
        let gate = Gate()
        stage.held = [1]
        stage.gate = gate
        let source = ParallelBlockDecoder(
            stage: stage, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: 2, extraBuffers: 1,
            scratchCapacity: 20_064
        )
        let outcome: Result<Int, TestFailure> = await source.withDecoding { group in
            // Block 1 is held until after the stop.
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                source.stop(nil)
                gate.open()
            }
            do throws(TestFailure) {
                guard let first = try await source.nextBlock() else { return .success(0) }
                source.pool.release(first.buffer)
                let second = try await source.nextBlock()
                return .success(second == nil ? 1 : 2)
            } catch {
                return .failure(error)
            }
        }
        #expect(outcome == .failure(.engine(.cancelled)))
        #expect(source.pool.buffersInUse == 0)

        // A consumer that finishes and stops the source itself (as NativeAEA's extraction does after its walk): its own
        // result, though another block asked for after the stop is the cancellation failure.
        let again = ParallelBlockDecoder(
            stage: plain, blocks: 0..<plain.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: 2, extraBuffers: 1,
            scratchCapacity: 20_064
        )
        let done: Result<Int, TestFailure> = await again.withDecoding { _ in
            var taken = 0
            do throws(TestFailure) {
                while let block = try await again.nextBlock() {
                    again.pool.release(block.buffer)
                    taken += 1
                }
            } catch {
                return .failure(error)
            }
            again.stop(nil)
            do throws(TestFailure) {
                _ = try await again.nextBlock()
                return .failure(.consumer)
            } catch {
                #expect(error == .engine(.cancelled))
            }
            return .success(taken)
        }
        #expect(done == .success(plain.blocks.count))
        #expect(again.pool.buffersInUse == 0)
    }

    /// Failures come in block order: block 5 fails at once, block 2 only after a while; the consumer gets blocks 0 and 1,
    /// then block 2's failure, every time (it was block 5's, or whichever came first in time).
    @Test(.timeLimit(.minutes(1)), arguments: [2, 8])
    func failuresComeInBlockOrder(decoders: Int) async throws {
        let (plain, _) = try BlockDecoderTests.indexedStream(blockSize: 20_000)
        var stage = plain
        stage.failing = [2: 30_000, 5: 0]
        let stream = try pbzStream(BlockDecoderTests.text, blockSize: 20_000)
        var fileStage = MemoryStage(bytes: stream, blocks: [])
        fileStage.failing = [2: 30_000, 5: 0]
        for _ in 0..<3 {
            let indexed = ParallelBlockDecoder(
                stage: stage, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: decoders,
                extraBuffers: 4, scratchCapacity: 20_064
            )
            let (indexedBlocks, indexedFailure) = await indexed.withDecoding { _ in await collect(indexed) }
            #expect(indexedBlocks == [0, 1] && indexedFailure == .verify(2))
            #expect(indexed.pool.buffersInUse == 0)

            let file = ParallelBlockDecoder(
                stage: fileStage, pbz: .zlib, blockSize: 20_000, file: 0..<stream.count, decoders: decoders, extraBuffers: 4
            )
            let (fileBlocks, fileFailure) = await file.withDecoding { _ in await collect(file) }
            #expect(fileBlocks == [0, 1] && fileFailure == .verify(2))
            #expect(file.pools.allSatisfy { $0.buffersInUse == 0 })
        }

        // The producer's failure (a block header cut short, block 6) comes first in time; block 1's, later, is lower.
        let ranges = try Self.storedRanges(stream, blockSize: 20_000)
        let cut = Array(stream.prefix(ranges[5].upperBound + 5))
        var cutStage = MemoryStage(bytes: cut, blocks: [])
        cutStage.failing = [1: 30_000]
        let short = ParallelBlockDecoder(stage: cutStage, pbz: .zlib, blockSize: 20_000, file: 0..<cut.count, decoders: decoders, extraBuffers: 4)
        let (shortBlocks, shortFailure) = await short.withDecoding { _ in await collect(short) }
        #expect(shortBlocks == [0] && shortFailure == .verify(1))
        // Alone, the producer's failure comes after the blocks it queued.
        let plainShort = ParallelBlockDecoder(
            stage: MemoryStage(bytes: cut, blocks: []), pbz: .zlib, blockSize: 20_000, file: 0..<cut.count, decoders: decoders, extraBuffers: 4
        )
        let (plainShortBlocks, plainShortFailure) = await plainShort.withDecoding { _ in await collect(plainShort) }
        #expect(plainShortBlocks == Array(0..<6) && plainShortFailure == .engine(.framing(.blockHeaderCutShort)))
        #expect(plainShort.pool.buffersInUse == 0)
    }

    /// An upstream block's failure reaches a `pbz` stream's consumer after every block that ends before it.
    @Test(.timeLimit(.minutes(1)), arguments: [1, 8])
    func upstreamFailuresComeInOrder(decoders: Int) async throws {
        let stream = try Self.big.get()
        let ranges = try Self.storedRanges(stream)
        // The segment in the middle of block 3's stored bytes.
        let failing = (ranges[3].lowerBound + ranges[3].count / 2) / 4_096
        let segments = BlockDecoderTests.segments(of: stream, size: 4_096, decoders: decoders, extraBuffers: 2) { stage in
            var stage = stage
            stage.failing = [failing: 0]
            return stage
        }
        let blocks = ParallelBlockDecoder(pbz: .zlib, blockSize: Self.blockSize, upstream: segments, decoders: decoders, extraBuffers: 1)
        let (taken, failure) = await withUpstream(segments, blocks) { await collect(blocks) }
        #expect(taken == [0, 1, 2] && failure == .verify(failing))
        #expect(blocks.pools.allSatisfy { $0.buffersInUse == 0 })
    }

    /// Where each block's stored bytes are in a `pbz` stream.
    static func storedRanges(_ stream: [UInt8], blockSize: Int) throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = PBZ.headerSize
        while offset < stream.count {
            let (_, stored) = try PBZ.blockSizes(Array(stream[offset..<(offset + 16)]).span.bytes, index: ranges.count, blockSize: blockSize)
            ranges.append((offset + 16)..<(offset + 16 + stored))
            offset += 16 + stored
        }
        return ranges
    }
}
