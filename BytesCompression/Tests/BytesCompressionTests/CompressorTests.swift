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
        CompressionFormat.zstd(level: 3, windowLog: 9), .zstd(level: 3, windowLog: 28), .zstd(level: -1),
        .brotli(quality: -1), .brotli(quality: 5, windowBits: 9), .brotli(quality: 5, windowBits: 25), .deflate(.raw, level: -1),
    ])
    func parametersNoEncoderTakesThrow(_ format: CompressionFormat) throws {
        var compressor = Compressor()
        try compressor.reset(for: .lzfse)
        #expect(throws: BytesError.invalidValue) { try compressor.reset(for: format) }
        #expect(compressor.format == .lzfse) // Unchanged.
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
