import Bytes
import BytesCompression
import BytesTestSupport
import Testing

/// `Compressor`'s parameters (plan B7, review §1.12): a Zstandard window out of 10–27 trapped (`ZstdEncoder`'s
/// precondition) where every other parameter was clamped, and level 0 ran as level 1 (libzstd's 0 is its default, 3).
/// Now parameters no encoder takes throw, high levels still run as each encoder's highest, and a `Compressor` is a
/// `Pipeline` stage like a `Decompressor`.
@Suite struct CompressorTests {
    static let text = SampleBytes.text(50_000, seed: 31)

    static func encoded(_ format: CompressionFormat) throws -> [UInt8] {
        var compressor = Compressor()
        try compressor.reset(for: format)
        var output = [UInt8](repeating: 0, count: 100_000)
        let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try compressor.compressAll(text.span.bytes, into: &span)
            return span.byteCount
        }
        return Array(output.prefix(count))
    }

    @Test(arguments: [
        CompressionFormat.zstd(level: 3, windowLog: 9), .zstd(level: 3, windowLog: 28), .zstd(level: -1, windowLog: 9),
        .brotli(quality: -1), .brotli(quality: 5, windowBits: 9), .brotli(quality: 5, windowBits: 25), .deflate(.raw, level: -1),
    ])
    func parametersNoEncoderTakesThrow(_ format: CompressionFormat) throws {
        var compressor = Compressor()
        try compressor.reset(for: .lzfse)
        #expect(throws: BytesError.invalidValue) { try compressor.reset(for: format) }
        #expect(compressor.format == .lzfse) // Unchanged.
        #expect(throws: BytesError.invalidValue) { _ = try Compressor(for: format) }
    }

    /// Negative Zstandard levels are libzstd's fast levels: valid there, not encoded here.
    @Test func negativeZstandardLevelsAreUnsupported() throws {
        var compressor = try Compressor(for: .lzvn)
        for level in [-1, -5, -131_072] {
            #expect(throws: BytesError.unsupported) { try compressor.reset(for: .zstd(level: level)) }
        }
        #expect(compressor.format == .lzvn)
    }

    /// `init(for:)` is `reset(for:)` on a new encoder; a whole-buffer format refuses streaming (`unsupported`); calls
    /// before any format, `invalidValue`.
    @Test func makingAndMisusing() throws {
        var compressor = try Compressor(for: .zstd(level: 3))
        #expect(try compressor.compressAll(Self.text.span.bytes) == Self.encoded(.zstd(level: 3)))
        try compressor.reset(for: .lzbitmap)
        var output = [UInt8](repeating: 0, count: 64)
        #expect(throws: BytesError.unsupported) {
            _ = try output.withOutputRawSpan { span throws(BytesError) in try compressor.compress(Self.text.span.bytes, into: &span, flush: .finish) }
        }
        var fresh = Compressor()
        #expect(throws: BytesError.invalidValue) { _ = try fresh.compressAll(Self.text.span.bytes) }
        #expect(throws: BytesError.invalidValue) {
            _ = try output.withOutputRawSpan { span throws(BytesError) in try fresh.compress(Self.text.span.bytes, into: &span, flush: .finish) }
        }
    }

    /// Every format's bound holds for inputs that compress worst (random bytes, which every encoder stores or nearly),
    /// at every size 0–300, around block sizes, and large: `compressAll` into exactly the bound succeeds, and the array
    /// form gives the same bytes.
    @Test(arguments: [
        CompressionFormat.deflate(.raw, level: 0), .deflate(.gzip, level: 1), .deflate(.zlib, level: 9), .brotli(quality: 1),
        .brotli(quality: 9, windowBits: 10), .zstd(level: 1), .zstd(level: 4), .lzfse, .lzvn, .lzbitmap,
    ])
    func boundsHold(_ format: CompressionFormat) throws {
        var compressor = try Compressor(for: format)
        var rng = SplitMix64(seed: 99)
        let random = (0..<300_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        var sizes = Array(0...300)
        for block in [16 << 10, 32 << 10, 64 << 10, 128 << 10, 256 << 10] {
            sizes += [block - 1, block, block + 1]
        }
        sizes.append(random.count)
        for size in sizes {
            let input = Array(random.prefix(size))
            let bound = format.maximumCompressedSize(forByteCount: size)
            var output = [UInt8](repeating: 0, count: bound)
            let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
                try compressor.compressAll(input.span.bytes, into: &span)
                return span.byteCount
            }
            #expect(count <= bound, "\(format), \(size) bytes")
            #expect(try compressor.compressAll(input.span.bytes) == Array(output.prefix(count)), "\(format), \(size) bytes")
        }
        #expect(format.maximumCompressedSize(forByteCount: .max) == .max)
    }

    /// After `releaseMemory()`, coding throws until a reset; `reset()` makes the same format's encoder again, and its
    /// output is a fresh encoder's (for a DEFLATE level change too, which reuses the encoder otherwise).
    @Test(arguments: [CompressionFormat.deflate(.gzip, level: 6), .brotli(quality: 5), .zstd(level: 3), .lzfse])
    func releasingMemory(_ format: CompressionFormat) throws {
        var compressor = try Compressor(for: format)
        _ = try compressor.compressAll(Self.text.span.bytes)
        compressor.releaseMemory()
        #expect(compressor.format == format)
        #expect(throws: BytesError.invalidValue) { _ = try compressor.compressAll(Self.text.span.bytes) }
        compressor.reset()
        #expect(try compressor.compressAll(Self.text.span.bytes) == Self.encoded(format))
        compressor.releaseMemory()
        try compressor.reset(for: format)
        #expect(try compressor.compressAll(Self.text.span.bytes) == Self.encoded(format))
        if case let .deflate(container, _) = format {
            compressor.releaseMemory()
            try compressor.reset(for: .deflate(container, level: 1))
            #expect(try compressor.compressAll(Self.text.span.bytes) == Self.encoded(.deflate(container, level: 1)))
        }
    }

    /// HTTP's Zstandard: frames state a window no larger than 8 MiB (they state 512 KiB, or their content's size),
    /// and decode under the decoding side's limit, for a body larger than both.
    @Test func zstdForHTTP() throws {
        let body = Array(largeSample().prefix(10 << 20))
        var compressor = try Compressor(for: .zstdForHTTP(level: 3))
        let frame = try compressor.compressAll(body.span.bytes)
        let header = try #require(try ZstdFrameHeader(parsing: frame.span.bytes))
        #expect(header.windowSize <= 8 << 20)
        var decompressor = try Decompressor(for: .zstdForHTTP)
        let result = streamDecode(frame, outputChunk: 1 << 16, split: [1 << 16]) { input, output throws(BytesError) in
            try decompressor.decompress(input, into: &output)
        }
        #expect((try? result.get())?.output == body)
    }

    /// Zstandard's level 0 is libzstd's default (3); levels past each encoder's highest run as it.
    @Test func levelsRunAsDocumented() throws {
        #expect(try Self.encoded(.zstd(level: 0)) == Self.encoded(.zstd(level: 3)))
        #expect(try Self.encoded(.zstd(level: 19)) == Self.encoded(.zstd(level: 4)))
        #expect(try Self.encoded(.brotli(quality: 11)) == Self.encoded(.brotli(quality: 9)))
        #expect(try Self.encoded(.deflate(.zlib, level: 12)) == Self.encoded(.deflate(.zlib, level: 9)))
    }

    /// A `Compressor` and a `Decompressor` as `Pipeline` stages, with small buffers.
    @Test(arguments: [CompressionFormat.deflate(.gzip, level: 6), .brotli(quality: 5), .zstd(level: 3)])
    func roundTripsThroughAPipeline(_ format: CompressionFormat) throws {
        var compressor = Compressor()
        try compressor.reset(for: format)
        var decompressor = Decompressor()
        try decompressor.reset(for: #require(DecompressionFormat(compressing: format)))
        var pipeline = compressor.then(decompressor, bufferCapacity: 4_096)
        var output: [UInt8] = []
        _ = try pipeline.transform(Self.text.span.bytes, appending: &output, flush: .finish)
        #expect(output == Self.text)
    }
}
