import Bytes
import BytesCompression
import BytesCompressionAsync
import BytesTestSupport
import Foundation
import Synchronization
import Testing

// The layers NativeZip, NativeAEA, Disk, and HTTPBytes share (2026-11-23, ARCHITECTURE.md): containers' identifiers
// mapped to formats, `pbz` framing, `Compressor`, `ChunkedDecompressor`, and the parallel block decoder. The clients'
// suites (NativeAEA's extraction and cancellation tests, NativeZip's methods and encryption, Disk's `decmpfs`) cover
// them end to end; these check each piece alone.

/// A client's failure type for the engine's tests.
enum TestFailure: BlockDecodingFailure, Equatable {
    case engine(BlockDecodingError)
    case read(Int)
    /// A block's ``BlockReadingStage/verify(_:raw:)`` failed.
    case verify(Int)
    /// The consumer's own failure.
    case consumer

    init(_ error: BlockDecodingError) { self = .engine(error) }
}

/// A switch a test opens to let blocks held by a ``MemoryStage`` go on.
final class Gate: Sendable {
    let isOpen = Atomic<Bool>(false)

    func open() { isOpen.store(true, ordering: .releasing) }

    /// Waits for the gate, up to 20 seconds (a test's time limit ends it before then).
    func wait() {
        for _ in 0..<200_000 where !isOpen.load(ordering: .acquiring) {
            usleep(100)
        }
    }
}

/// A stream held in memory: its blocks described up front (an indexed stream), or read as a file; with the reading
/// stage's hooks, AEA's shape (its bytes mapped, masked as encryption would, and checked after decoding).
struct MemoryStage: IndexedBlockStage, BlockReadingStage {
    typealias Failure = TestFailure

    let bytes: [UInt8]
    let blocks: [BlockJob]
    /// Reads at this offset fail (a damaged file).
    var failingOffset = -1
    /// Blocks whose `verify` fails, after waiting this many microseconds.
    var failing: [Int: UInt32] = [:]
    /// Blocks whose `verify` waits for the gate first.
    var held: Set<Int> = []
    var gate: Gate?
    /// `bytes` in memory the stage hands out (``storedBytes(of:)``) instead of reading: as a mapped file.
    var mapping: RawStorage?
    /// Every stored byte is XORed with this (``prepare(_:stored:into:)`` undoes it), as encryption would.
    var mask: UInt8?
    /// What the blocks decode to, checked by `verify`.
    var expected: [UInt8]?

    init(bytes: [UInt8], blocks: [BlockJob], failingOffset: Int = -1, mapped: Bool = false, mask: UInt8? = nil, expected: [UInt8]? = nil) {
        let stored = mask.map { mask in bytes.map { $0 ^ mask } } ?? bytes
        self.bytes = stored
        self.blocks = blocks
        self.failingOffset = failingOffset
        if mapped {
            let mapping = RawStorage(byteCount: stored.count)
            // The storage holds `stored.count` bytes: safe.
            stored.withUnsafeBytes { unsafe mapping.base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            self.mapping = mapping
        }
        self.mask = mask
        self.expected = expected
    }

    func block(_ index: Int) -> BlockJob { blocks[index] }

    @unsafe
    func read(at offset: Int, into destination: UnsafeMutableRawBufferPointer) throws(TestFailure) {
        guard offset != failingOffset else { throw .read(offset) }
        precondition(offset >= 0 && offset + destination.count <= bytes.count, "a read past the stream")
        // The destination is the engine's (valid for the call); the source is within `bytes` (checked above).
        bytes.withUnsafeBytes { unsafe destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + destination.count)])) }
    }

    @unsafe
    func storedBytes(of job: BlockJob) -> UnsafeRawBufferPointer? {
        guard let mapping else { return nil }
        precondition(job.fileOffset >= 0 && job.fileOffset + job.storedSize <= bytes.count, "a block past the mapping")
        // Within the storage (checked above), which the stage keeps while the engine runs.
        return unsafe UnsafeRawBufferPointer(start: mapping.base + job.fileOffset, count: job.storedSize)
    }

    @unsafe
    func prepare(_ job: BlockJob, stored: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer) throws(TestFailure) -> Bool {
        guard let mask else { return false }
        precondition(destination.count == stored.count, "no room to unmask into")
        // Both `count` bytes, valid for the call (the engine's promise); byte by byte, so in place works too.
        for index in 0..<stored.count {
            unsafe destination[index] = stored[index] ^ mask
        }
        return true
    }

    func verify(_ job: BlockJob, raw: RawSpan) throws(TestFailure) {
        if held.contains(job.index) { gate?.wait() }
        if let delay = failing[job.index] {
            usleep(delay)
            throw .verify(job.index)
        }
        guard let expected else { return }
        guard [UInt8](copying: raw) == Array(expected[job.rawOffset..<(job.rawOffset + raw.byteCount)]) else { throw .verify(job.index) }
    }
}

/// Encodes `data` as one whole stream of `format`.
func compressed(_ data: [UInt8], _ format: CompressionFormat) throws -> [UInt8] {
    var compressor = try Compressor(for: format)
    var output = [UInt8](repeating: 0, count: data.count * 2 + 4_096)
    let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
        try compressor.compressAll(data.span.bytes, into: &span)
        return span.byteCount
    }
    return Array(output.prefix(count))
}

/// A `pbz` stream of `data` in blocks of `blockSize`, compressed with zlib (`z`); incompressible blocks are stored.
func pbzStream(_ data: [UInt8], blockSize: Int) throws -> [UInt8] {
    func bigEndian(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) } }
    var stream = Array("pbzz".utf8) + bigEndian(blockSize)
    var start = 0
    while start < data.count {
        let block = Array(data[start..<min(start + blockSize, data.count)])
        let packed = try compressed(block, .deflate(.zlib, level: 6))
        let stored = packed.count < block.count ? packed : block
        stream += bigEndian(block.count) + bigEndian(stored.count) + stored
        start += block.count
    }
    return stream
}

/// Takes every block of `source` in order, as a consumer does, and joins them.
func drain<Source: OrderedBlockSource>(_ source: Source) async throws(Source.Failure) -> [UInt8] {
    let result: Result<[UInt8], Source.Failure> = await source.withDecoding { _ in
        do throws(Source.Failure) {
            try await source.prepare()
            var joined: [UInt8] = []
            var expected = 0
            while let block = try await source.nextBlock() {
                #expect(block.rawOffset == joined.count)
                #expect(block.index == expected)
                expected += 1
                joined.append(copying: source.pool.bytes(block.buffer, at: 0, count: block.rawSize))
                source.pool.release(block.buffer)
            }
            return .success(joined)
        } catch {
            return .failure(error)
        }
    }
    return try result.get()
}

@Suite struct BlockDecoderTests {
    static let text = SampleBytes.mixed(300_000, seed: 7)
    /// Text with random runs: blocks of it that compress and blocks stored as they are.
    static let textAndRandom = SampleBytes.text(100_000, seed: 3) + SampleBytes.random(40_000, seed: 4) + SampleBytes.text(100_000, seed: 5)
        + SampleBytes.random(60_000, seed: 6)

    // MARK: Identities

    @Test func mapsContainersToFormats() throws {
        #expect(DecompressionFormat(zipMethod: 8, uncompressedSize: nil) == .deflate(.raw))
        #expect(DecompressionFormat(zipMethod: 9, uncompressedSize: 5) == .deflate64)
        #expect(DecompressionFormat(zipMethod: 12, uncompressedSize: 5) == .bzip2)
        #expect(DecompressionFormat(zipMethod: 93, uncompressedSize: 5) == .zstd(sizeHint: 5))
        #expect(DecompressionFormat(zipMethod: 95, uncompressedSize: 5) == .xz(sizeHint: 5))
        for method: UInt16 in [0, 1, 6, 14, 98, 99] {
            #expect(DecompressionFormat(zipMethod: method, uncompressedSize: 5) == nil)
        }

        #expect(DecompressionFormat(aeaSegment: .lz4) == .lz4(framed: false))
        #expect(DecompressionFormat(pbzBlock: .lz4) == .lz4(framed: true))
        #expect(DecompressionFormat(aeaSegment: .lzma) == .xz())
        #expect(DecompressionFormat(pbzBlock: .zlib) == .deflate(.zlib))
        #expect(DecompressionFormat(aeaSegment: .none) == nil)

        // ZIP's LZMA header: version 2 bytes, properties size 5 (2 bytes), lc/lp/pb, dictionary size.
        let header: [UInt8] = [9, 20, 5, 0, 0x5D, 0, 0, 0x80, 0]
        let properties = try LZMAProperties(zipHeader: header.span.bytes)
        #expect(properties.byte == 0x5D && properties.dictionarySize == 1 << 23)
        let short = Array(header.prefix(8))
        #expect(throws: BytesError.insufficientData) { _ = try LZMAProperties(zipHeader: short.span.bytes) }
        let wrongSize: [UInt8] = [9, 20, 4, 0] + header[4...]
        #expect(throws: BytesError.invalidValue) { _ = try LZMAProperties(zipHeader: wrongSize.span.bytes) }
        #expect(DecompressionFormat.zipLZMA(properties, uncompressedSize: 9, hasEndMarker: true) == .lzma(properties, uncompressedSize: nil, maximumSize: 9))
        #expect(DecompressionFormat.zipLZMA(properties, uncompressedSize: 9, hasEndMarker: false) == .lzma(properties, uncompressedSize: 9))
    }

    @Test func readsPBZFraming() throws {
        let stream = try pbzStream(Self.text, blockSize: 65_536)
        #expect(PBZ.compression(stream.span.bytes) == .zlib)
        #expect(PBZ.compression(Array("pbzq".utf8).span.bytes) == nil)
        #expect(PBZ.compression(Array("AA01".utf8).span.bytes) == nil)
        let streamHeader = try #require(try PBZ.header(stream.span.bytes))
        #expect(streamHeader.compression == .zlib && streamHeader.blockSize == 65_536)
        // Not `pbz`: no magic, an unknown letter, too few bytes to tell.
        for bytes in ["AA01\0\0\0\0\0\0\0\0", "pbzq\0\0\0\0\0\0\0\u{1}", "pbz", ""] {
            #expect(try PBZ.header(Array(bytes.utf8).span.bytes) == nil, "\(bytes)")
        }
        // `pbz` with a known letter, cut short anywhere in the 12 bytes: the stream ends inside its header.
        for count in 4..<PBZ.headerSize {
            #expect(throws: PBZError.headerCutShort) { _ = try PBZ.header(Array(stream.prefix(count)).span.bytes) }
        }
        // Block sizes of 0 and over 256 MiB; 256 MiB itself is the largest accepted.
        #expect(throws: PBZError.header) { _ = try PBZ.header(Array("pbzz\0\0\0\0\0\0\0\0".utf8).span.bytes) }
        let largest: [UInt8] = Array("pbzx".utf8) + [0, 0, 0, 0, 0x10, 0, 0, 0]
        #expect(try PBZ.header(largest.span.bytes)?.blockSize == 256 << 20)
        let tooLarge: [UInt8] = Array("pbzx".utf8) + [0, 0, 0, 0, 0x10, 0, 0, 1]
        #expect(throws: PBZError.header) { _ = try PBZ.header(tooLarge.span.bytes) }
        let header = Array(stream[12..<28])
        let sizes = try PBZ.blockSizes(header.span.bytes, index: 0, blockSize: 65_536)
        #expect(sizes.raw == 65_536 && sizes.stored > 0 && sizes.stored <= sizes.raw)
        #expect(throws: PBZError.blockSizes(block: 3, raw: 65_536, stored: sizes.stored)) {
            _ = try PBZ.blockSizes(header.span.bytes, index: 3, blockSize: 65_536, available: sizes.stored - 1)
        }
        let cut = Array(header.prefix(15))
        #expect(throws: PBZError.blockHeaderCutShort) { _ = try PBZ.blockSizes(cut.span.bytes, index: 0, blockSize: 65_536) }
    }

    // MARK: Compressor

    /// `Compressor` writes what each format's own encoder writes, and starts every whole stream anew.
    @Test(arguments: [
        CompressionFormat.deflate(.raw, level: 1), .deflate(.zlib, level: 6), .deflate(.gzip, level: 9), .brotli(quality: 5),
        .zstd(level: 3), .lzfse, .lzvn, .lzbitmap,
    ])
    func compressorMatchesEachEncoder(_ format: CompressionFormat) throws {
        let input = Array(Self.text.prefix(60_000))
        var expected = [UInt8](repeating: 0, count: 200_000)
        let count = try expected.withOutputRawSpan { span throws(BytesError) -> Int in
            switch format {
            case let .deflate(container, level):
                var encoder = DeflateEncoder(format: container, level: level)
                try encoder.compressAll(input.span.bytes, into: &span)
            case let .brotli(quality, windowBits):
                var encoder = BrotliEncoder(quality: quality, windowBits: windowBits)
                try encoder.compressAll(input.span.bytes, into: &span)
            case let .zstd(level, windowLog):
                var encoder = ZstdEncoder(level: level, windowLog: windowLog)
                try encoder.compressAll(input.span.bytes, into: &span)
            case .lzfse:
                var encoder = LZFSEEncoder()
                try encoder.compressAll(input.span.bytes, into: &span)
            case .lzvn:
                var encoder = LZVNEncoder()
                try encoder.compressAll(input.span.bytes, into: &span)
            case .lzbitmap:
                var encoder = LZBitmapEncoder()
                try encoder.compressAll(input.span.bytes, into: &span)
            }
            return span.byteCount
        }
        // Twice through one compressor: the second whole stream is the first's bytes again.
        #expect(try compressed(input, format) == Array(expected.prefix(count)))
        var compressor = try Compressor(for: format)
        var twice = [UInt8](repeating: 0, count: 400_000)
        let both = try twice.withOutputRawSpan { span throws(BytesError) -> Int in
            try compressor.compressAll(input.span.bytes, into: &span)
            try compressor.compressAll(input.span.bytes, into: &span)
            return span.byteCount
        }
        #expect(Array(twice.prefix(both)) == Array(expected.prefix(count)) + Array(expected.prefix(count)))
        #expect(format.isStreamable == (DecompressionFormat(compressing: format) != nil))
    }

    // MARK: Chunked decompression

    /// Borrowed and staged input (fed a few bytes at a time) give the same chunks, in each mode: whole, history
    /// (DEFLATE), and stream (Zstandard).
    @Test(arguments: [CompressionFormat.deflate(.raw, level: 6), .zstd(level: 3), .deflate(.gzip, level: 1)])
    func stagedInputMatchesBorrowed(_ format: CompressionFormat) throws {
        let decoded = SampleBytes.mixed(2_500_000, seed: 3)
        let stream = try compressed(decoded, format)
        let decodeFormat = DecompressionFormat(compressing: format)!
        for decodedSize in [decoded.count, nil] {
            var chunks = ChunkedDecompressor()
            #expect(try Self.decode(&chunks, stream, decodeFormat, decodedSize: decodedSize, staged: nil) == decoded)
            for piece in [1_000, 70_000] {
                #expect(try Self.decode(&chunks, stream, decodeFormat, decodedSize: decodedSize, staged: piece) == decoded)
            }
        }
        // Small and borrowed with its size: one call (whole), the size checked.
        let small = Array(decoded.prefix(10_000))
        let smallStream = try compressed(small, format)
        var chunks = ChunkedDecompressor()
        #expect(try Self.decode(&chunks, smallStream, decodeFormat, decodedSize: small.count, staged: nil) == small)
        #expect(throws: BytesError.mismatch) { _ = try Self.decode(&chunks, smallStream, decodeFormat, decodedSize: small.count - 1, staged: nil) }
        // Borrowed input cut short.
        #expect(throws: BytesError.insufficientData) { _ = try Self.decode(&chunks, Array(stream.prefix(stream.count / 2)), decodeFormat, decodedSize: nil, staged: nil) }
    }

    /// Decodes `stream` through `chunks`, alternating buffers; staged input is appended `staged` bytes at a time.
    static func decode(
        _ chunks: inout ChunkedDecompressor, _ stream: [UInt8], _ format: DecompressionFormat, decodedSize: Int?, staged: Int?
    ) throws(BytesError) -> [UInt8] {
        var output: [UInt8] = []
        // The span's typed-throws form (an array's `withUnsafeBytes` is untyped `rethrows`: AGENTS.md).
        try stream.span.bytes.withUnsafeBytes { buffer throws(BytesError) in
            var fed = 0
            if staged != nil { chunks.stageInput() } else { unsafe chunks.borrowInput(buffer) }
            try chunks.start(format, decodedSize: decodedSize)
            var target = 0
            loop: while true {
                switch try unsafe chunks.nextChunk(into: target) {
                case let .chunk(bytes, finished):
                    output.append(copying: unsafe RawSpan(_unsafeBytes: bytes))
                    if finished { break loop }
                    target ^= 1
                case .needsInput:
                    // Adding nothing ends the input: the next call finishes the stream or throws.
                    _ = try chunks.fillInput { span in
                        let count = min(staged!, stream.count - fed, span.byteCount)
                        span.withUnsafeMutableBytes { unsafe $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[fed..<(fed + count)])) }
                        fed += count
                        return count
                    }
                }
            }
        }
        return output
    }

    // MARK: The parallel block decoder

    /// An indexed stream (AEA segments' shape): blocks described up front, read and decoded by the stage's default.
    @Test(arguments: [1, 3, 8])
    func decodesIndexedBlocksInOrder(decoders: Int) async throws {
        let (stage, raw) = try Self.indexedStream(blockSize: 20_000)
        let source = ParallelBlockDecoder(
            stage: stage, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: decoders,
            extraBuffers: 1, scratchCapacity: 20_064
        )
        #expect(try await drain(source) == raw)
        #expect(source.pool.buffersInUse == 0)
    }

    /// The reading stage's hooks, in every combination AEA segments use: stored bytes read (a stored block straight into
    /// its output, a compressed one into the read buffer) or handed out by the stage (mapped), prepared (unmasked, as
    /// decryption: in place where they were read, into the output or the read buffer from a mapping) or not, decoded or
    /// copied, and verified.
    @Test(arguments: [false, true], [nil, UInt8(0x5A)])
    func readingStageHooks(mapped: Bool, mask: UInt8?) async throws {
        let (plain, raw) = try Self.indexedStream(blockSize: 20_000, of: Self.textAndRandom)
        #expect(plain.blocks.contains { $0.isStored } && plain.blocks.contains { !$0.isStored })
        let stage = MemoryStage(bytes: plain.bytes, blocks: plain.blocks, mapped: mapped, mask: mask, expected: raw)
        // A read buffer only where something is read or unmasked into it (AEA's rule).
        let scratch = !mapped || mask != nil ? 20_064 : nil
        let source = ParallelBlockDecoder(
            stage: stage, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: 3, extraBuffers: 1,
            scratchCapacity: scratch
        )
        #expect(try await drain(source) == raw)
        #expect(source.pool.buffersInUse == 0)
        // Reads are timed, mapped blocks aren't read.
        #expect((source.counters.read.load(ordering: .relaxed) > 0) == !mapped)

        // A verification that fails names its block.
        var failing = stage
        failing.expected = raw.map { $0 ^ 1 }
        let checked = ParallelBlockDecoder(
            stage: failing, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 20_000, decoders: 3,
            extraBuffers: 1, scratchCapacity: scratch
        )
        await #expect(throws: TestFailure.verify(0)) { _ = try await drain(checked) }
    }

    /// A `pbz` file, and the same `pbz` stream inside an indexed stream's blocks (as inside AEA segments): the upstream
    /// reader and staging.
    @Test(arguments: [1, 4])
    func decodesPBZFromAFileAndFromUpstream(decoders: Int) async throws {
        let stream = try pbzStream(Self.text, blockSize: 32_768)
        let file = ParallelBlockDecoder(
            stage: MemoryStage(bytes: stream, blocks: []), pbz: .zlib, blockSize: 32_768, file: 0..<stream.count, decoders: decoders,
            extraBuffers: 1
        )
        #expect(try await drain(file) == Self.text)
        #expect(file.pools.allSatisfy { $0.buffersInUse == 0 })

        // The stream cut into stored "segments" of 10,000 bytes, which blocks cross.
        let segments = Self.segments(of: stream, size: 10_000, decoders: decoders, extraBuffers: 2)
        let blocks = ParallelBlockDecoder(pbz: .zlib, blockSize: 32_768, upstream: segments, decoders: decoders, extraBuffers: 1)
        // Whoever makes a source over an upstream runs the upstream too (NativeAEA's payload runs both); stopping the
        // source stops its upstream.
        let decoded: Result<[UInt8], TestFailure> = await withDiscardingTaskGroup { group in
            group.addTask { await segments.run() }
            do throws(TestFailure) {
                return try await .success(drain(blocks))
            } catch {
                return .failure(error)
            }
        }
        #expect(try decoded.get() == Self.text)
        #expect(blocks.pools.allSatisfy { $0.buffersInUse == 0 })
    }

    /// Plain slices of a file, stored.
    @Test func readsSlices() async throws {
        let file = ParallelBlockDecoder(
            stage: MemoryStage(bytes: Self.text, blocks: []), slices: 50_000, file: 0..<Self.text.count, decoders: 3, extraBuffers: 0
        )
        #expect(try await drain(file) == Self.text)
        #expect(file.pool.buffersInUse == 0)
    }

    /// A failure reaches the consumer after the blocks before it: a block that doesn't decode (named as a `pbz`
    /// block), framing, a read; every buffer comes back.
    @Test func failuresReachTheConsumer() async throws {
        var stream = try pbzStream(Self.text, blockSize: 32_768)
        let (_, firstStored) = try PBZ.blockSizes(Array(stream[12..<28]).span.bytes, index: 0, blockSize: 32_768)
        let secondHeader = 28 + firstStored
        let (_, secondStored) = try PBZ.blockSizes(Array(stream[secondHeader..<(secondHeader + 16)]).span.bytes, index: 1, blockSize: 32_768)
        // Damage block 1's stored bytes past its zlib header.
        let damaged = secondHeader + 16 + secondStored / 2
        stream[damaged] ^= 0xFF
        stream[damaged + 1] ^= 0xFF
        let file = ParallelBlockDecoder(
            stage: MemoryStage(bytes: stream, blocks: []), pbz: .zlib, blockSize: 32_768, file: 0..<stream.count, decoders: 4,
            extraBuffers: 0
        )
        await #expect {
            _ = try await drain(file)
        } throws: { error in
            guard case let .engine(engine) = error as? TestFailure, case let .decoding(_, block, kind) = engine else { return false }
            return block == 1 && kind == .pbz && engine.description.hasPrefix("pbz block 1 failed to decompress")
        }
        #expect(file.pools.allSatisfy { $0.buffersInUse == 0 })

        // A stream cut inside a block header.
        let cut = Array(stream.prefix(secondHeader + 5))
        let short = ParallelBlockDecoder(
            stage: MemoryStage(bytes: cut, blocks: []), pbz: .zlib, blockSize: 32_768, file: 0..<cut.count, decoders: 2, extraBuffers: 0
        )
        await #expect(throws: TestFailure.engine(.framing(.blockHeaderCutShort))) { _ = try await drain(short) }

        // A read that fails.
        let unreadable = ParallelBlockDecoder(
            stage: MemoryStage(bytes: stream, blocks: [], failingOffset: secondHeader), pbz: .zlib, blockSize: 32_768,
            file: 0..<stream.count, decoders: 2, extraBuffers: 0
        )
        await #expect(throws: TestFailure.read(secondHeader)) { _ = try await drain(unreadable) }
    }

    /// Cancelling the consumer's task stops everything, and throws the cancellation failure.
    @Test(.timeLimit(.minutes(1))) func cancellationStopsEverything() async throws {
        let (stage, _) = try Self.indexedStream(blockSize: 4_096)
        let source = ParallelBlockDecoder(
            stage: stage, blocks: 0..<stage.blocks.count, format: .deflate(.zlib), blockCapacity: 4_096, decoders: 2, extraBuffers: 1,
            scratchCapacity: 4_160
        )
        let pool = source.pool
        #expect(pool.count == 4)
        let failure: TestFailure? = await Task {
            let result: TestFailure? = await source.withDecoding { _ in
                do throws(TestFailure) {
                    var taken = 0
                    while let block = try await source.nextBlock() {
                        source.pool.release(block.buffer)
                        taken += 1
                        if taken == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                    return nil
                } catch {
                    return error
                }
            }
            return result
        }.value
        #expect(failure == .engine(.cancelled))
        #expect(pool.buffersInUse == 0)
    }

    /// A pool that starts with some buffers inactive (an AEA payload, until it knows whether writers will hold segment
    /// buffers) hands out only the active ones, recirculating them; activating the rest gives them to a waiting task
    /// first, then to the free list behind the buffers already used. (Moved from NativeAEA with the pool.)
    @Test func poolActivatesTheRestLater() async {
        let pool = BlockBufferPool(count: 6, blockCapacity: 1_024, active: 3)
        #expect((0..<3).compactMap { _ in pool.tryAcquire() } == [0, 1, 2])
        #expect(pool.tryAcquire() == nil)
        pool.release(1)
        #expect(pool.tryAcquire() == 1) // Recirculated: 3–5 untouched.
        pool.release(1)
        #expect(pool.tryAcquire() == 1)
        // A task waiting for a buffer gets the first activated one.
        async let waited = pool.acquire()
        while pool.waiting == 0 {
            await Task.yield()
        }
        pool.activateAll()
        #expect(await waited == 3)
        pool.release(2)
        // The buffer just freed first, then the activated ones.
        #expect((0..<3).compactMap { _ in pool.tryAcquire() } == [2, 4, 5])
        #expect(pool.tryAcquire() == nil)
        for index in 0..<6 {
            pool.release(index)
        }
        #expect(pool.buffersInUse == 0)
        #expect(pool.peakInUse.load(ordering: .relaxed) == 6)
    }

    /// Pools are sized in one place: a buffer per decoder, the extra ones, the ones held beyond decoding (or, until
    /// activated, what's held then), and one more.
    @Test func poolsAreSizedFromCounts() {
        let plain = BlockBufferPool.sized(blockCapacity: 1_024, decoders: 4, extraBuffers: 8)
        #expect(plain.count == 13)
        #expect((0..<14).compactMap { _ in plain.tryAcquire() }.count == 13)
        // An AEA payload's: 4 writers' references beyond decoding, but only the `pbz` producer's one until activated.
        let deferred = BlockBufferPool.sized(blockCapacity: 1_024, decoders: 4, extraBuffers: 8, heldBuffers: 4, heldUntilActivated: 1)
        #expect(deferred.count == 17)
        #expect((0..<17).compactMap { _ in deferred.tryAcquire() }.count == 14)
        deferred.activateAll()
        #expect((0..<17).compactMap { _ in deferred.tryAcquire() }.count == 3)
        // A consumer that keeps earlier blocks while it waits (an extraction's walk in small AEA segments): its buffers
        // count too, and are deferred with the held ones.
        let walking = BlockBufferPool.sized(
            blockCapacity: 1_024, decoders: 4, extraBuffers: 8, heldBuffers: 4, consumerBuffers: 4, heldUntilActivated: 1
        )
        #expect(walking.count == 20 && walking.heldBuffers == 4)
        #expect((0..<20).compactMap { _ in walking.tryAcquire() }.count == 14)
        // No decoders or negative counts still leave a decoder's buffer and the one more.
        #expect(BlockBufferPool.sized(blockCapacity: 1_024, decoders: 0, extraBuffers: -3, heldBuffers: -1).count == 2)
    }

    /// Within a byte budget (review 2026-11-23 §1.6, fix plan B1), pools of the blocks `pbz` and AEA allow (up to 256
    /// MiB) stay within it, or at the least that can run when even that is over: held buffers come down first (to what
    /// fits beside one decoder), then extra buffers, then decoders; read buffers and staging count.
    @Test(arguments: [1 << 20, 16 << 20, 64 << 20, 128 << 20, 256 << 20])
    func poolsStayWithinTheBudget(blockSize: Int) {
        let budget = 1 << 30
        let stride = BlockBufferPool.stride(blockCapacity: blockSize)
        for (decoders, extra, held, consumer) in [(1, 0, 0, 1), (10, 8, 0, 1), (10, 8, 8, 1), (32, 8, 24, 1), (4, 0, 1, 1), (10, 8, 8, 4)] {
            for (scratch, staged) in [(nil, false), (blockSize + 64, false), (nil, true)] {
                let sizing = BlockBufferPool.sizing(
                    blockCapacity: blockSize, decoders: decoders, extraBuffers: extra, heldBuffers: held, consumerBuffers: consumer,
                    scratchCapacity: scratch, staged: staged, budget: budget
                )
                let label = "\(blockSize >> 20) MiB, \(decoders)/\(extra)/\(held)/\(consumer), scratch \(scratch != nil), staged \(staged)"
                // What the counts take, counted independently.
                let staging = staged ? (sizing.decoders + 2) * stride : 0
                let bytes = sizing.bufferCount * stride + sizing.decoders * (scratch ?? 0) + staging
                #expect(sizing.byteCount == bytes, "\(label)")
                // Never more than asked, never below the least that runs; the consumer's never cut.
                #expect(sizing.consumerBuffers == consumer, "\(label)")
                #expect(sizing.decoders >= 1 && sizing.decoders <= decoders, "\(label)")
                #expect(sizing.extraBuffers >= 0 && sizing.extraBuffers <= extra, "\(label)")
                #expect(sizing.heldBuffers >= min(held, 1) && sizing.heldBuffers <= held, "\(label)")
                let least = sizing.decoders == 1 && sizing.extraBuffers == 0 && sizing.heldBuffers == min(held, 1)
                #expect(bytes <= budget || least, "\(label)")
                // Each cut was needed: one more of what was cut first doesn't fit.
                if sizing.heldBuffers < held, !least {
                    #expect(BlockBufferPool.sizing(
                        blockCapacity: blockSize, decoders: 1, extraBuffers: 0, heldBuffers: sizing.heldBuffers + 1, consumerBuffers: consumer,
                        scratchCapacity: scratch, staged: staged
                    ).byteCount > budget, "\(label)")
                }
                if sizing.extraBuffers < extra, sizing.decoders == decoders {
                    #expect(bytes + stride > budget, "\(label)")
                }
                if sizing.decoders < decoders {
                    #expect(sizing.extraBuffers == 0, "\(label)")
                    #expect(bytes + stride + (scratch ?? 0) + (staged ? stride : 0) > budget, "\(label)")
                }
                // Without a budget, the counts as asked.
                let unlimited = BlockBufferPool.sizing(
                    blockCapacity: blockSize, decoders: decoders, extraBuffers: extra, heldBuffers: held, scratchCapacity: scratch, staged: staged
                )
                #expect(unlimited.decoders == decoders && unlimited.extraBuffers == extra && unlimited.heldBuffers == held, "\(label)")
            }
        }
        // The review's archive: 256 MiB blocks, listed (no writers) with 10 decoders and 8 extra buffers, was 19 buffers
        // and 10 read buffers (7.3 GiB); now one decoder, two buffers and its read buffer.
        let listing = BlockBufferPool.sizing(
            blockCapacity: 256 << 20, decoders: 10, extraBuffers: 8, scratchCapacity: (256 << 20) + 64, budget: budget
        )
        #expect(listing == BlockPoolSizing(decoders: 1, extraBuffers: 0, heldBuffers: 0, byteCount: 2 * BlockBufferPool.stride(blockCapacity: 256 << 20) + (256 << 20) + 64))
        // Extracting it: one writer, at the least that runs (just over the budget).
        let extracting = BlockBufferPool.sizing(
            blockCapacity: 256 << 20, decoders: 10, extraBuffers: 8, heldBuffers: 8, scratchCapacity: (256 << 20) + 64, budget: budget
        )
        #expect(extracting.decoders == 1 && extracting.extraBuffers == 0 && extracting.heldBuffers == 1)
        // 128 MiB segments (stored read buffers small): writers to fit beside one decoder, then decoders.
        let segments = BlockBufferPool.sizing(
            blockCapacity: 128 << 20, decoders: 10, extraBuffers: 8, heldBuffers: 8, scratchCapacity: 65_600, budget: budget
        )
        #expect(segments.heldBuffers == 5 && segments.extraBuffers == 0 && segments.decoders == 1)
        // 16 MiB blocks with this Mac's defaults (10 decoders, 8 writers) aren't cut.
        let xcode = BlockBufferPool.sizing(
            blockCapacity: 16 << 20, decoders: 10, extraBuffers: 8, heldBuffers: 8, scratchCapacity: (16 << 20) + 64, budget: budget
        )
        #expect(xcode.decoders == 10 && xcode.extraBuffers == 8 && xcode.heldBuffers == 8)
        // The pool made from a sizing has its buffers and records its held ones; a deferred tail stays deferred.
        let pool = BlockBufferPool(sizing: segments, blockCapacity: 1_024, heldUntilActivated: 1)
        #expect(pool.count == segments.bufferCount && pool.heldBuffers == 5)
        #expect((0..<pool.count).compactMap { _ in pool.tryAcquire() }.count == segments.decoders + segments.extraBuffers + 2)
    }

    /// An engine given a budget runs the decoders its pool was sized for, and still decodes everything: a `pbz` file and
    /// the same stream inside an indexed stream's blocks (staging), at the least that runs.
    @Test func enginesDecodeWithinTheBudget() async throws {
        let stream = try pbzStream(Self.text, blockSize: 32_768)
        let stride = BlockBufferPool.stride(blockCapacity: 32_768)
        // Room for two buffers and a read buffer: one decoder, one writer's buffer, the one more (over: the least).
        let file = ParallelBlockDecoder(
            stage: MemoryStage(bytes: stream, blocks: []), pbz: .zlib, blockSize: 32_768, file: 0..<stream.count, decoders: 8,
            extraBuffers: 8, heldBuffers: 4, budget: 3 * stride
        )
        #expect(file.pool.count == 3 && file.pool.heldBuffers == 1)
        #expect(file.bufferByteCount == 3 * stride + 32_768 + 64)
        #expect(try await drain(file) == Self.text)
        #expect(file.pools.allSatisfy { $0.buffersInUse == 0 })

        let segments = Self.segments(of: stream, size: 10_000, decoders: 4, extraBuffers: 2)
        let blocks = ParallelBlockDecoder(
            pbz: .zlib, blockSize: 32_768, upstream: segments, decoders: 4, extraBuffers: 4, heldBuffers: 2, budget: 0
        )
        // One decoder, its buffer, a writer's, and the one more; staging of one decoder's and two more.
        #expect(blocks.pool.count == 3 && blocks.pool.heldBuffers == 1 && blocks.pools[1].count == 3)
        let decoded: Result<[UInt8], TestFailure> = await withDiscardingTaskGroup { group in
            group.addTask { await segments.run() }
            do throws(TestFailure) {
                return try await .success(drain(blocks))
            } catch {
                return .failure(error)
            }
        }
        #expect(try decoded.get() == Self.text)
        #expect(blocks.pools.allSatisfy { $0.buffersInUse == 0 })
    }

    /// The carry region is the client's (fix plan D8): none unless asked for, the stride and the sizing's bytes grow by
    /// what's asked, a carry of that many bytes lands just before the next block's bytes, and an engine's pool has the
    /// region its initializer was given (staging none).
    @Test func carryRegionIsTheClients() async throws {
        #expect(BlockBufferPool.stride(blockCapacity: 1_024) == 16_384)
        #expect(BlockBufferPool.stride(blockCapacity: 1_024, carryCapacity: 65_536) == 81_920)
        #expect(BlockBufferPool(count: 2, blockCapacity: 1_024).carryCapacity == 0)
        let sizing = BlockBufferPool.sizing(blockCapacity: 20_000, carryCapacity: 100, decoders: 1, extraBuffers: 0)
        #expect(sizing.carryCapacity == 100 && sizing.byteCount == 2 * 32_768)
        let pool = BlockBufferPool(sizing: sizing, blockCapacity: 20_000)
        #expect(pool.carryCapacity == 100)
        let first = try #require(pool.tryAcquire()), second = try #require(pool.tryAcquire())
        pool.withMutableBytes(first, at: 20_000 - 100, count: 100) { span in
            for i in 0..<100 {
                span.storeBytes(of: UInt8(i), toByteOffset: i, as: UInt8.self)
            }
        }
        pool.carry(100, from: first, at: 20_000 - 100, to: second)
        let carried = pool.bytes(second, at: -100, count: 100)
        var isCarried = true
        for i in 0..<100 where carried.load(fromByteOffset: i, as: UInt8.self) != UInt8(i) {
            isCarried = false
        }
        #expect(isCarried)
        pool.release(first)
        pool.release(second)

        let stream = try pbzStream(Self.text, blockSize: 32_768)
        let file = ParallelBlockDecoder(
            stage: MemoryStage(bytes: stream, blocks: []), pbz: .zlib, blockSize: 32_768, file: 0..<stream.count, decoders: 2,
            extraBuffers: 1, carryCapacity: 65_536
        )
        #expect(file.pool.carryCapacity == 65_536 && file.pool.activeByteCount == file.pool.count * BlockBufferPool.stride(blockCapacity: 32_768, carryCapacity: 65_536))
        #expect(try await drain(file) == Self.text)
        let segments = Self.segments(of: stream, size: 10_000, decoders: 2, extraBuffers: 1)
        let blocks = ParallelBlockDecoder(pbz: .zlib, blockSize: 32_768, upstream: segments, decoders: 2, extraBuffers: 1, carryCapacity: 65_536)
        #expect(blocks.pool.carryCapacity == 65_536 && blocks.pools[1].carryCapacity == 0)
        let decoded: Result<[UInt8], TestFailure> = await withDiscardingTaskGroup { group in
            group.addTask { await segments.run() }
            do throws(TestFailure) {
                return try await .success(drain(blocks))
            } catch {
                return .failure(error)
            }
        }
        #expect(try decoded.get() == Self.text)
    }

    /// `stream` cut into stored "segments" of `size` bytes (as AEA segments holding a `pbz` stream), as an indexed
    /// source; `stage` changes the segments' stage (failing ones).
    static func segments(
        of stream: [UInt8], size: Int, decoders: Int, extraBuffers: Int, stage: (MemoryStage) -> MemoryStage = { $0 }
    ) -> ParallelBlockDecoder<MemoryStage> {
        let jobs = stride(from: 0, to: stream.count, by: size).enumerated().map { index, start in
            let count = min(size, stream.count - start)
            return BlockJob(index: index, rawOffset: start, rawSize: count, storedSize: count, fileOffset: start)
        }
        return ParallelBlockDecoder(
            stage: stage(MemoryStage(bytes: stream, blocks: jobs)), blocks: 0..<jobs.count, format: nil, blockCapacity: size,
            decoders: decoders, extraBuffers: extraBuffers, scratchCapacity: nil
        )
    }

    /// The text in zlib blocks of `blockSize` (stored where they don't compress), laid end to end, and the blocks.
    static func indexedStream(blockSize: Int, of text: [UInt8] = BlockDecoderTests.text) throws -> (MemoryStage, [UInt8]) {
        var bytes: [UInt8] = []
        var jobs: [BlockJob] = []
        var start = 0
        while start < text.count {
            let block = Array(text[start..<min(start + blockSize, text.count)])
            let packed = try compressed(block, .deflate(.zlib, level: 6))
            let stored = packed.count < block.count ? packed : block
            jobs.append(BlockJob(index: jobs.count, rawOffset: start, rawSize: block.count, storedSize: stored.count, fileOffset: bytes.count))
            bytes += stored
            start += block.count
        }
        return (MemoryStage(bytes: bytes, blocks: jobs), text)
    }
}

extension DecompressionFormat {
    /// The decoding of what `format` encodes, for the streaming formats.
    init?(compressing format: CompressionFormat) {
        switch format {
        case let .deflate(container, _): self = .deflate(container)
        case .brotli: self = .brotli
        case .zstd: self = .zstd()
        case .lzfse, .lzvn, .lzbitmap: return nil
        }
    }
}
