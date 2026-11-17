import Benchmark
import Bytes
import BytesCompression
import Compression

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 2,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )
    registerChecksumBenchmarks()
    registerInflateBenchmarks()
    registerDeflateBenchmarks()
    registerBrotliDecodeBenchmarks()
    registerBrotliEncodeBenchmarks()
    registerParallelBenchmarks()
    registerCryptoBenchmarks()
    registerPipelineBenchmarks()
}

// MARK: - Brotli compression

/// Compresses each sample at qualities 1 and 5 (and 9 for text) with Bytes and Google, window 22.
func registerBrotliEncodeBenchmarks() {
    for sample in Fixtures.samples {
        var output = [UInt8](repeating: 0, count: BrotliEncoder.maximumCompressedSize(forByteCount: sample.bytes.count))
        let qualities = sample.name == "dickens" || sample.name == "Main.js" ? [1, 5, 9] : [1, 5]
        for quality in qualities {
            var encoder = BrotliEncoder(quality: quality)
            precondition(brotliEncodeAll(&encoder, sample.bytes, into: &output) > 0)
            Benchmark("Brotli encode q\(quality) \(sample.label): Bytes") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(brotliEncodeAll(&encoder, sample.bytes, into: &output))
                }
            }
            // Google's one-shot API allocates its state per call, as any of its clients would.
            Benchmark("Brotli encode q\(quality) \(sample.label): Google") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(GoogleBrotli.compress(sample.bytes, quality: Int32(quality), into: &output))
                }
            }
        }
    }
}

@inline(__always)
func brotliEncodeAll(_ encoder: inout BrotliEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    encoder.reset()
    return output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

// MARK: - Brotli decompression

/// Decodes each sample's encoding by Google's brotli at qualities 5 and 11 (window 22, its default).
func registerBrotliDecodeBenchmarks() {
    for sample in Fixtures.samples {
        var output = [UInt8](repeating: 0, count: sample.bytes.count + 64)
        for quality: Int32 in [5, 11] where quality == 5 || sample.bytes.count <= 12 << 20 {
            let compressed = Fixtures.cached("\(sample.name)-\(sample.bytes.count).brotli-1.2.1-q\(quality)") {
                var compressed = [UInt8](repeating: 0, count: sample.bytes.count + sample.bytes.count / 8 + 1024)
                compressed.removeLast(compressed.count - GoogleBrotli.compress(sample.bytes, quality: quality, into: &compressed))
                return compressed
            }
            var decoder = BrotliDecoder()
            precondition(brotliDecodeAll(&decoder, compressed, into: &output) == sample.bytes.count
                && Array(output.prefix(sample.bytes.count)) == sample.bytes)
            precondition(brotliDecodeStreaming(&decoder, compressed, chunk: 1 << 16, into: &output) == sample.bytes.count)
            let apple = AppleCompression(algorithm: COMPRESSION_BROTLI)
            Benchmark("Brotli decode q\(quality) \(sample.label): Bytes") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(brotliDecodeAll(&decoder, compressed, into: &output))
                }
            }
            Benchmark("Brotli decode q\(quality) \(sample.label): Bytes, streaming 64 KB") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(brotliDecodeStreaming(&decoder, compressed, chunk: 1 << 16, into: &output))
                }
            }
            Benchmark("Brotli decode q\(quality) \(sample.label): Google") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(GoogleBrotli.decompress(compressed, into: &output))
                }
            }
            Benchmark("Brotli decode q\(quality) \(sample.label): Apple Compression") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(apple.decompress(compressed, into: &output))
                }
            }
        }
    }
}

@inline(__always)
func brotliDecodeAll(_ decoder: inout BrotliDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    decoder.reset()
    return output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

@inline(__always)
func brotliDecodeStreaming(_ decoder: inout BrotliDecoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
    decoder.reset()
    var offset = 0
    var total = 0
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var window = bytes._mutatingExtracting(..<min(bytes.count, 1 << 16))
    while true {
        let end = min(offset + chunk, span.byteCount)
        let progress = window.withOutputRawSpan { out in
            let progress = try! decoder.decompress(span.extracting(offset..<end), into: &out)
            total += out.byteCount
            return progress
        }
        offset += progress.consumed
        if progress.status == .finished { return total }
    }
}

// MARK: - Compression

/// Compresses each sample at levels 1 and 6 (and 9 for text) with each encoder, raw DEFLATE.
func registerDeflateBenchmarks() {
    for sample in Fixtures.samples {
        var output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: sample.bytes.count, format: .gzip))
        let levels = sample.name == "dickens" || sample.name == "Main.js" ? [1, 6, 9] : [1, 6]
        for level in levels {
            var encoder = DeflateEncoder(format: .raw, level: level)
            let size = encodeAll(&encoder, sample.bytes, into: &output)
            precondition(size > 0 && encodeStreaming(&encoder, sample.bytes, chunk: 1 << 16, into: &output) > 0)
            var gzipEncoder = DeflateEncoder(format: .gzip, level: level)
            let zlib = ZlibDeflater(level: Int32(level), windowBits: -15)
            let libdeflate = LibDeflate(format: .raw, level: Int32(level))

            Benchmark("Deflate \(level) \(sample.label): Bytes") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(encodeAll(&encoder, sample.bytes, into: &output))
                }
            }
            Benchmark("Deflate \(level) \(sample.label): Bytes, streaming 64 KB") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(encodeStreaming(&encoder, sample.bytes, chunk: 1 << 16, into: &output))
                }
            }
            Benchmark("Deflate \(level) gzip \(sample.label): Bytes") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(encodeAll(&gzipEncoder, sample.bytes, into: &output))
                }
            }
            Benchmark("Deflate \(level) \(sample.label): zlib") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(zlib.compress(sample.bytes, into: &output))
                }
            }
            Benchmark("Deflate \(level) \(sample.label): libdeflate") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(libdeflate.compress(sample.bytes, into: &output))
                }
            }
        }
        // Apple's has no levels.
        let apple = AppleCompression(algorithm: COMPRESSION_ZLIB)
        Benchmark("Deflate \(sample.label): Apple Compression") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(apple.compress(sample.bytes, into: &output))
            }
        }
    }
}

/// Compresses a whole input with `compressAll`.
@inline(__always)
func encodeAll(_ encoder: inout DeflateEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    encoder.reset()
    return output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Compresses an input arriving in `chunk`-byte pieces, finishing with the last, into a 64 KB buffer reused
/// for each piece of output. Returns the total compressed size.
@inline(__always)
func encodeStreaming(_ encoder: inout DeflateEncoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
    encoder.reset()
    var offset = 0
    var total = 0
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var window = bytes._mutatingExtracting(..<min(bytes.count, 1 << 16))
    while true {
        let end = min(offset + chunk, span.byteCount)
        let progress = window.withOutputRawSpan { out in
            let progress = try! encoder.compress(span.extracting(offset..<end), into: &out, flush: end == span.byteCount ? .finish : .none)
            total += out.byteCount
            return progress
        }
        offset += progress.consumed
        if progress.status == .finished { return total }
    }
}

// MARK: - Checksums

func registerChecksumBenchmarks() {
    let data = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }
    let small = Array(data.prefix(64))
    precondition(Adler32.checksum(data.span.bytes) == ZlibChecksums.adler32(data))
    Benchmark("Adler-32 1 MB: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Adler32.checksum(data.span.bytes))
        }
    }
    Benchmark("Adler-32 1 MB: zlib") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ZlibChecksums.adler32(data))
        }
    }
    Benchmark("Adler-32 1 MB: libdeflate") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(LibDeflateChecksums.adler32(data))
        }
    }
    Benchmark("Adler-32 64 B (×16 K): Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            var value: UInt32 = 1
            for _ in 0..<16_384 {
                value = Adler32.checksum(small.span.bytes, continuing: value)
            }
            blackHole(value)
        }
    }
    Benchmark("Adler-32 64 B (×16 K): zlib") { benchmark in
        for _ in benchmark.scaledIterations {
            var value: UInt32 = 1
            for _ in 0..<16_384 {
                value = ZlibChecksums.adler32(small, continuing: value)
            }
            blackHole(value)
        }
    }
}

// MARK: - Decompression

/// Decodes each sample's zlib level-6 encoding: raw DEFLATE with each decoder, gzip (checksum included) with
/// the ones that check it.
func registerInflateBenchmarks() {
    for sample in Fixtures.samples {
        let raw = Fixtures.cached("\(sample.name)-\(sample.bytes.count).zlib-6.raw") { Fixtures.zlibCompress(sample.bytes) }
        let gzip = Fixtures.cached("\(sample.name)-\(sample.bytes.count).zlib-6.gz") { Fixtures.zlibCompress(sample.bytes, windowBits: 31) }
        var output = [UInt8](repeating: 0, count: sample.bytes.count + 64)

        var rawDecoder = DeflateDecoder(format: .raw)
        precondition(decodeAll(&rawDecoder, raw, into: &output) == sample.bytes.count && Array(output.prefix(sample.bytes.count)) == sample.bytes)
        precondition(decodeStreaming(&rawDecoder, raw, chunk: 1 << 16, into: &output) == sample.bytes.count)
        var gzipDecoder = DeflateDecoder(format: .gzip)
        precondition(decodeAll(&gzipDecoder, gzip, into: &output) == sample.bytes.count)
        let zlibRaw = ZlibInflater(windowBits: -15)
        let zlibGzip = ZlibInflater(windowBits: 31)
        let libdeflateRaw = LibDeflate(format: .raw)
        let libdeflateGzip = LibDeflate(format: .gzip)
        let apple = AppleCompression(algorithm: COMPRESSION_ZLIB)

        Benchmark("Inflate \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(decodeAll(&rawDecoder, raw, into: &output))
            }
        }
        Benchmark("Inflate \(sample.label): Bytes, streaming 64 KB") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(decodeStreaming(&rawDecoder, raw, chunk: 1 << 16, into: &output))
            }
        }
        Benchmark("Inflate \(sample.label): zlib") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(zlibRaw.decompress(raw, into: &output))
            }
        }
        Benchmark("Inflate \(sample.label): libdeflate") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(libdeflateRaw.decompress(raw, into: &output))
            }
        }
        Benchmark("Inflate \(sample.label): Apple Compression") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(apple.decompress(raw, into: &output))
            }
        }
        Benchmark("Inflate gzip \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(decodeAll(&gzipDecoder, gzip, into: &output))
            }
        }
        Benchmark("Inflate gzip \(sample.label): zlib") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(zlibGzip.decompress(gzip, into: &output))
            }
        }
        Benchmark("Inflate gzip \(sample.label): libdeflate") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(libdeflateGzip.decompress(gzip, into: &output))
            }
        }
    }
}

/// Decodes a whole stream into `output` with `decompressAll`.
@inline(__always)
func decodeAll(_ decoder: inout DeflateDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    decoder.reset()
    return output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Decodes a stream arriving in `chunk`-byte pieces into a 64 KB buffer reused for each piece of output, as
/// a network client does. Returns the total decoded.
@inline(__always)
func decodeStreaming(_ decoder: inout DeflateDecoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
    decoder.reset()
    var offset = 0
    var total = 0
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var window = bytes._mutatingExtracting(..<min(bytes.count, 1 << 16))
    while true {
        let end = min(offset + chunk, span.byteCount)
        let progress = window.withOutputRawSpan { out in
            let progress = try! decoder.decompress(span.extracting(offset..<end), into: &out)
            total += out.byteCount
            return progress
        }
        offset += progress.consumed
        if progress.status == .finished { return total }
    }
}
