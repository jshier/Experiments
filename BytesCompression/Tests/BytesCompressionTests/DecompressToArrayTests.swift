import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import CLZMA
import Compression
import CZstd
import Testing

/// `Decompressor.decompressAll(_:maximumSize:decodedSize:)` without a decoded size (open item 15): `maximumSize` is a
/// limit, not the reservation. The array starts at a size the stream states (or four times the input, at least
/// 64 KiB) and grows fourfold, decoding again, up to the limit; it reserved the whole limit before.
@Suite struct DecompressToArrayTests {
    static func decode(_ stream: [UInt8], _ format: DecompressionFormat, maximumSize: Int) -> Result<[UInt8], BytesError> {
        do throws(BytesError) {
            var decompressor = try Decompressor(for: format)
            return try .success(decompressor.decompressAll(stream.span.bytes, maximumSize: maximumSize))
        } catch {
            return .failure(error)
        }
    }

    /// Every format whose whole buffers need no decoded size: decoded under a generous limit, exactly at the decoded
    /// size, and refused one byte under it; the array no more than four times the size (plus 64 KiB).
    @Test func everyFormat() throws {
        for (format, stream, data) in DecompressorTests.encodings where format != .lz4(framed: false) {
            #expect(Self.decode(stream, format, maximumSize: 1 << 30) == .success(data), "\(format)")
            #expect(Self.decode(stream, format, maximumSize: data.count) == .success(data), "\(format), exact")
            #expect(Self.decode(stream, format, maximumSize: data.count - 1) == .failure(.limitExceeded), "\(format), one short")
            var decompressor = try Decompressor(for: format)
            let bytes = try decompressor.decompressAll(stream.span.bytes, maximumSize: 1 << 30)
            // bzip2 starts at its block size (900,000 bytes at level 9); malloc rounds up a little.
            let bound = max(4 * data.count + (64 << 10), format == .bzip2 ? 900_000 : 0) + 4096
            #expect(bytes.capacity <= bound, "\(format): \(bytes.capacity) for \(data.count)")
        }
    }

    /// A limit no buffer could have (it was reserved whole, and trapped): decoding takes only what the stream needs.
    @Test func limitsAreNotReservations() throws {
        let data = DecompressorTests.data
        for format in [DecompressionFormat.deflate(.raw), .deflate(.gzip), .zstd(), .bzip2, .xz(), .brotli] {
            let stream = DecompressorTests.encodings.first { $0.format == format }!.stream
            var decompressor = try Decompressor(for: format)
            let bytes = try decompressor.decompressAll(stream.span.bytes, maximumSize: .max)
            #expect(bytes == data, "\(format)")
            #expect(bytes.capacity < 16 * data.count, "\(format): \(bytes.capacity)")
        }
    }

    /// Streams decoding to far more than four times their size (zeros): several tries for those that state nothing,
    /// one for those that do; every format's whole-buffer decoder stops where its room ends, and is tried again.
    @Test func growsPastTheEstimate() throws {
        let zeros = [UInt8](repeating: 0, count: 5 << 20)
        var compressor = Compressor()
        func encoded(_ format: CompressionFormat) throws -> [UInt8] {
            try compressor.reset(for: format)
            return try compressor.compressAll(zeros.span.bytes)
        }
        let streams: [(DecompressionFormat, [UInt8])] = try [
            (.deflate(.raw), encodeAll(zeros, format: .raw, level: 6)),
            (.deflate(.zlib), encodeAll(zeros, format: .zlib, level: 1)),
            (.deflate(.gzip), encodeAll(zeros, format: .gzip, level: 1)),
            (.brotli, brotliEncodeAll(zeros, quality: 5)),
            (.bzip2, bzip2Compress(zeros, level: 1)),
            (.zstd(), zstdCompress(zeros, parameters: [(ZSTD_c_contentSizeFlag, 0)])),
            (.zstd(), zstdCompress(zeros)),
            (.lzma(DecompressorTests.lzmaProperties), lzma1Compress(zeros, options: lzmaOptions(preset: 6, dictionary: 1 << 20), marker: true)),
            (.xz(), xzCompress(zeros, preset: 1)),
            (.lzfse, encoded(.lzfse)),
            (.lzvn, encoded(.lzvn)),
            (.lzbitmap, encoded(.lzbitmap)),
            (.lz4(framed: true), AppleCompression.encode(zeros, COMPRESSION_LZ4)),
            (.lzraven, lzravenCompress(zeros)),
        ]
        for (format, stream) in streams {
            #expect(Self.decode(stream, format, maximumSize: 64 << 20) == .success(zeros), "\(format)")
            #expect(Self.decode(stream, format, maximumSize: zeros.count - 1) == .failure(.limitExceeded), "\(format)")
        }
    }

    /// Stated sizes that are low: a gzip file whose last member is empty (BGZF's end: ISIZE 0), a zstd frame stating
    /// 0 before a large one, an xz file whose last stream is empty. Each still grows to the whole.
    @Test func statedSizesThatLie() {
        let data = DecompressorTests.data
        let gzip = encodeAll(data, format: .gzip, level: 6) + encodeAll([], format: .gzip, level: 6)
        #expect(Self.decode(gzip, .deflate(.gzip), maximumSize: 1 << 30) == .success(data))
        let zstd = zstdCompress([]) + zstdCompress(data)
        #expect(Self.decode(zstd, .zstd(), maximumSize: 1 << 30) == .success(data))
        let xz = xzCompress(data, preset: 1) + xzCompress([], preset: 1)
        #expect(Self.decode(xz, .xz(), maximumSize: 1 << 30) == .success(data))
    }

    /// Empty streams, and a limit of 0.
    @Test func empty() {
        for (format, stream) in [(DecompressionFormat.deflate(.gzip), encodeAll([], format: .gzip, level: 6)), (.zstd(), zstdCompress([])), (.bzip2, bzip2Compress([], level: 9))] {
            #expect(Self.decode(stream, format, maximumSize: 0) == .success([]), "\(format)")
            #expect(Self.decode(stream, format, maximumSize: 1 << 20) == .success([]), "\(format)")
        }
        #expect(Self.decode(encodeAll([1], format: .gzip, level: 6), .deflate(.gzip), maximumSize: 0) == .failure(.limitExceeded))
    }
}
