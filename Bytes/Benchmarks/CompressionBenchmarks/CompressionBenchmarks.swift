import Benchmark
import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import Compression

// Every fixture is made by the setup of a benchmark that uses it, not while registering: see Fixtures.swift.
let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = Fixtures.defaultConfiguration
    registerChecksumBenchmarks()
    registerInflateBenchmarks()
    registerGzipMemberBenchmarks()
    registerDeflateBenchmarks()
    registerBrotliDecodeBenchmarks()
    registerBrotliEncodeBenchmarks()
    registerCodecAllocationBenchmarks()
    registerZstdBenchmarks()
    registerZstdAllocationBenchmarks()
    registerZstdEncodeBenchmarks()
    registerZstdEncodeAllocationBenchmarks()
    registerLZMABenchmarks()
    registerLZMAAllocationBenchmarks()
    registerLZMAStreamingBenchmarks()
    registerDecompressorBenchmarks()
    registerDeflate64Benchmarks()
    registerLZRAVENBenchmarks()
    registerLZRAVENAllocationBenchmarks()
    registerLZBenchmarks()
    registerLZAllocationBenchmarks()
    registerLZEncodeBenchmarks()
    registerLZEncodeAllocationBenchmarks()
    registerLZBitmapBenchmarks()
    registerLZBitmapAllocationBenchmarks()
    registerBZip2Benchmarks()
    registerBZip2AllocationBenchmarks()
    registerBZip2StreamingBenchmarks()
    registerScryptBenchmarks()
    registerX509Benchmarks()
    registerECCBenchmarks()
    registerECCAllocationBenchmarks()
    registerRSABenchmarks()
    registerRSAAllocationBenchmarks()
    registerParallelBenchmarks()
    registerCryptoBenchmarks()
    registerPrimitiveBenchmarks()
    registerPipelineBenchmarks()
    registerCryptoAllocationBenchmarks()
    registerOffloadedBenchmarks()
}

// MARK: - Brotli compression

final class BrotliEncodeFixture {
    let input: [UInt8]
    var output: [UInt8]
    var encoder: BrotliEncoder

    init(_ sample: Fixtures.Sample, quality: Int) {
        input = sample.bytes
        output = [UInt8](repeating: 0, count: BrotliEncoder.maximumCompressedSize(forByteCount: input.count))
        encoder = BrotliEncoder(quality: quality)
    }
}

/// Compresses each sample at qualities 1 and 5 (and 9 for text) with Bytes and Google, window 22; 1 MB of random
/// bytes at quality 5; and Main.js in 64 KB pieces, as a server streams it. Setup checks that Google's decoder
/// decodes each encoding back (the streamed one: that its size is the one-shot encoding's).
func registerBrotliEncodeBenchmarks() {
    for sample in Fixtures.samples + [Fixtures.random] {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let qualities = sample.name == "random" ? [5] : sample.name == "dickens" || sample.name == "Main.js" ? [1, 5, 9] : [1, 5]
        for quality in qualities {
            let fixture = Lazy { BrotliEncodeFixture(sample, quality: quality) }
            let roundTrips = { (f: BrotliEncodeFixture, count: Int) in Fixtures.brotliDecodes(f.output[..<count], to: f.input) }
            register("Brotli encode q\(quality) \(sample.label): Bytes", configuration: configuration, fixture, check: roundTrips) { f in
                brotliEncodeAll(&f.encoder, f.input, into: &f.output)
            }
            // Google's one-shot API allocates its state per call, as any of its clients would.
            register("Brotli encode q\(quality) \(sample.label): Google", configuration: configuration, fixture, check: roundTrips) { f in
                GoogleBrotli.compress(f.input, quality: Int32(quality), into: &f.output)
            }
            if sample.name == "Main.js" && quality == 5 {
                let check = { (f: BrotliEncodeFixture, count: Int) in
                    Fixtures.sizeMatches(count, oneShot: brotliEncodeAll(&f.encoder, f.input, into: &f.output))
                }
                register("Brotli encode q5 \(sample.label): Bytes, streaming 64 KB", configuration: configuration, fixture, check: check) { f in
                    brotliEncodeStreaming(&f.encoder, f.input, chunk: 1 << 16, into: &f.output)
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

/// Compresses an input arriving in `chunk`-byte pieces, finishing with the last, into a 64 KB buffer reused for each
/// piece of output. Returns the total compressed size.
@inline(__always)
func brotliEncodeStreaming(_ encoder: inout BrotliEncoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
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

// MARK: - Brotli decompression

/// A decoding fixture: the original, its encoding, an output buffer, and each decoder's state.
final class DecodeFixture<Decoder: ~Copyable> {
    let original: [UInt8]
    let compressed: [UInt8]
    var output: [UInt8]
    var decoder: Decoder

    init(original: [UInt8], compressed: [UInt8], outputCount: Int, decoder: consuming Decoder) {
        self.original = original
        self.compressed = compressed
        output = [UInt8](repeating: 0, count: outputCount)
        self.decoder = decoder
    }

    /// Whether `count` bytes were decoded, and the output starts with the original.
    func decodedAll(_ count: Int) -> Bool {
        count == original.count && output.prefix(original.count).elementsEqual(original)
    }

    /// For the streaming decoders, which reuse their output's first 64 KB: whether `count` bytes were decoded.
    func decodedCount(_ count: Int) -> Bool {
        count == original.count
    }
}

/// Decodes each sample's encoding by Google's brotli at qualities 5 and 11 (window 22, its default).
func registerBrotliDecodeBenchmarks() {
    for sample in Fixtures.samples {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        for quality: Int32 in [5, 11] where quality == 5 || sample.byteCount <= 12 << 20 {
            let fixture = Lazy {
                let compressed = Fixtures.cached("\(sample.name)-\(sample.byteCount).brotli-1.2.1-q\(quality)") {
                    var compressed = [UInt8](repeating: 0, count: sample.byteCount + sample.byteCount / 8 + 1024)
                    compressed.removeLast(compressed.count - GoogleBrotli.compress(sample.bytes, quality: quality, into: &compressed))
                    return compressed
                }
                return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: sample.byteCount + 64, decoder: BrotliDecoder())
            }
            let apple = Lazy { AppleCompression(algorithm: COMPRESSION_BROTLI) }
            let name = "Brotli decode q\(quality) \(sample.label)"
            register("\(name): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
                brotliDecodeAll(&f.decoder, f.compressed, into: &f.output)
            }
            register("\(name): Bytes, streaming 64 KB", configuration: configuration, fixture, check: { $0.decodedCount($1) }) { f in
                brotliDecodeStreaming(&f.decoder, f.compressed, chunk: 1 << 16, into: &f.output)
            }
            if sample.name == "Main.js" && quality == 5 {
                // Pieces of a few packets, as a client decodes a response while it arrives.
                register("\(name): Bytes, streaming 4 KB", configuration: configuration, fixture, check: { $0.decodedCount($1) }) { f in
                    brotliDecodeStreaming(&f.decoder, f.compressed, chunk: 4 << 10, into: &f.output)
                }
            }
            register("\(name): Google", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
                GoogleBrotli.decompress(f.compressed, into: &f.output)
            }
            register("\(name): Apple Compression", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
                apple.value.decompress(f.compressed, into: &f.output)
            }
        }
    }
}

@inline(__always)
func brotliDecodeAll(_ decoder: inout BrotliDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in // `decompressAll` starts a new stream itself.
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

final class DeflateFixture {
    let input: [UInt8]
    var output: [UInt8]
    var encoder: DeflateEncoder
    var gzipEncoder: DeflateEncoder
    let zlib: ZlibDeflater
    let libdeflate: LibDeflate

    init(_ sample: Fixtures.Sample, level: Int) {
        input = sample.bytes
        output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: input.count, format: .gzip))
        encoder = DeflateEncoder(format: .raw, level: level)
        gzipEncoder = DeflateEncoder(format: .gzip, level: level)
        zlib = ZlibDeflater(level: Int32(level), windowBits: -15)
        libdeflate = LibDeflate(format: .raw, level: Int32(level))
    }
}

/// The zlib format (a 2-byte header and an Adler-32 after the DEFLATE stream: HTTP's `deflate` coding), level 6.
final class ZlibFormatFixture {
    let input: [UInt8]
    var output: [UInt8]
    var encoder = DeflateEncoder(format: .zlib, level: 6)
    let zlib = ZlibDeflater(level: 6, windowBits: 15)

    init(_ sample: Fixtures.Sample) {
        input = sample.bytes
        output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: input.count, format: .zlib))
    }
}

/// Compresses each sample at levels 1 and 6 (and 9 for text) with each encoder, raw DEFLATE; gzip and zlib formats
/// on a few inputs; 1 MB of random bytes. Setup checks that zlib decodes each encoding back (the streamed ones: that
/// their size is the one-shot encoding's).
func registerDeflateBenchmarks() {
    for sample in Fixtures.samples + [Fixtures.random] {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let random = sample.name == "random"
        let levels = sample.name == "dickens" || sample.name == "Main.js" ? [1, 6, 9] : [1, 6]
        for level in levels {
            let fixture = Lazy { DeflateFixture(sample, level: level) }
            let roundTrips = { (f: DeflateFixture, count: Int) in Fixtures.inflates(f.output[..<count], to: f.input) }
            register("Deflate \(level) \(sample.label): Bytes", configuration: configuration, fixture, check: roundTrips) { f in
                encodeAll(&f.encoder, f.input, into: &f.output)
            }
            // Streamed at level 1 (SocketStream's), and at 6 for one input.
            if !random && (level == 1 || (level == 6 && sample.name == "Main.js")) {
                let check = { (f: DeflateFixture, count: Int) in Fixtures.sizeMatches(count, oneShot: encodeAll(&f.encoder, f.input, into: &f.output)) }
                register("Deflate \(level) \(sample.label): Bytes, streaming 64 KB", configuration: configuration, fixture, check: check) { f in
                    encodeStreaming(&f.encoder, f.input, chunk: 1 << 16, into: &f.output)
                }
            }
            // gzip's header and CRC-32 on a large input and a small one (where the header and trailer count).
            if level == 6 && (sample.name == "Main.js" || (sample.name == "JSON" && sample.byteCount < 4 << 10)) {
                let check = { (f: DeflateFixture, count: Int) in Fixtures.inflates(f.output[..<count], to: f.input, windowBits: 31) }
                register("Deflate \(level) gzip \(sample.label): Bytes", configuration: configuration, fixture, check: check) { f in
                    encodeAll(&f.gzipEncoder, f.input, into: &f.output)
                }
            }
            register("Deflate \(level) \(sample.label): zlib", configuration: configuration, fixture, check: roundTrips) { f in
                f.zlib.compress(f.input, into: &f.output)
            }
            register("Deflate \(level) \(sample.label): libdeflate", configuration: configuration, fixture, check: roundTrips) { f in
                f.libdeflate.compress(f.input, into: &f.output)
            }
        }
        guard !random else { continue }
        // Apple's has no levels.
        let fixture = Lazy { DeflateFixture(sample, level: 6) }
        let apple = Lazy { AppleCompression(algorithm: COMPRESSION_ZLIB) }
        register("Deflate \(sample.label): Apple Compression", configuration: configuration, fixture, check: { f, count in
            Fixtures.inflates(f.output[..<count], to: f.input)
        }) { f in
            apple.value.compress(f.input, into: &f.output)
        }
        if sample.name == "Main.js" {
            let fixture = Lazy { ZlibFormatFixture(sample) }
            let roundTrips = { (f: ZlibFormatFixture, count: Int) in Fixtures.inflates(f.output[..<count], to: f.input, windowBits: 15) }
            register("Deflate 6 zlib \(sample.label): Bytes", configuration: configuration, fixture, check: roundTrips) { f in
                encodeAll(&f.encoder, f.input, into: &f.output)
            }
            register("Deflate 6 zlib \(sample.label): zlib", configuration: configuration, fixture, check: roundTrips) { f in
                f.zlib.compress(f.input, into: &f.output)
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

// MARK: - Allocation gates

/// DEFLATE and Brotli, both directions, one call and streamed, allocate nothing once a coder has coded a stream. Zero
/// thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:(Deflate|Inflate|Brotli).*'
func registerCodecAllocationBenchmarks() {
    let configuration = Fixtures.allocationConfiguration
    let content = Lazy { Fixtures.Sample(name: "gate", bytes: Fixtures.gateContent()) }
    let deflate1 = Lazy { DeflateFixture(content.value, level: 1) }
    let deflate6 = Lazy { DeflateFixture(content.value, level: 6) }
    register("Allocations:Deflate_encode_L1", configuration: configuration, deflate1, check: { f, count in
        Fixtures.inflates(f.output[..<count], to: f.input)
    }) { f in
        encodeAll(&f.encoder, f.input, into: &f.output)
    }
    register("Allocations:Deflate_encode_L6_streaming", configuration: configuration, deflate6, check: { f, count in
        Fixtures.sizeMatches(count, oneShot: encodeAll(&f.encoder, f.input, into: &f.output))
    }) { f in
        encodeStreaming(&f.encoder, f.input, chunk: 16 << 10, into: &f.output)
    }
    let raw = Lazy {
        DecodeFixture(original: content.value.bytes, compressed: Fixtures.zlibCompress(content.value.bytes), outputCount: content.value.byteCount + 64,
                      decoder: DeflateDecoder(format: .raw))
    }
    let gzip = Lazy {
        DecodeFixture(original: content.value.bytes, compressed: Fixtures.zlibCompress(content.value.bytes, windowBits: 31),
                      outputCount: content.value.byteCount + 64, decoder: DeflateDecoder(format: .gzip))
    }
    register("Allocations:Inflate_raw", configuration: configuration, raw, check: { $0.decodedAll($1) }) { f in
        decodeAll(&f.decoder, f.compressed, into: &f.output)
    }
    register("Allocations:Inflate_gzip_streaming", configuration: configuration, gzip, check: { $0.decodedCount($1) }) { f in
        decodeStreaming(&f.decoder, f.compressed, chunk: 4 << 10, into: &f.output)
    }
    // gzip members of 4 KB each: a member's start allocates nothing either.
    let members = Lazy {
        let bytes = content.value.bytes
        let compressed = stride(from: 0, to: bytes.count, by: 4 << 10).flatMap { start in
            Fixtures.zlibCompress(Array(bytes[start..<min(start + (4 << 10), bytes.count)]), windowBits: 31)
        }
        return DecodeFixture(original: bytes, compressed: compressed, outputCount: bytes.count + 64, decoder: DeflateDecoder(format: .gzip))
    }
    register("Allocations:Inflate_gzip_members", configuration: configuration, members, check: { $0.decodedAll($1) }) { f in
        decodeAll(&f.decoder, f.compressed, into: &f.output)
    }
    register("Allocations:Inflate_gzip_members_streaming", configuration: configuration, members, check: { $0.decodedCount($1) }) { f in
        decodeStreaming(&f.decoder, f.compressed, chunk: 4 << 10, into: &f.output)
    }

    let brotli5 = Lazy { BrotliEncodeFixture(content.value, quality: 5) }
    let brotli1 = Lazy { BrotliEncodeFixture(content.value, quality: 1) }
    register("Allocations:Brotli_encode_q5", configuration: configuration, brotli5, check: { f, count in
        Fixtures.brotliDecodes(f.output[..<count], to: f.input)
    }) { f in
        brotliEncodeAll(&f.encoder, f.input, into: &f.output)
    }
    register("Allocations:Brotli_encode_q1_streaming", configuration: configuration, brotli1, check: { f, count in
        Fixtures.sizeMatches(count, oneShot: brotliEncodeAll(&f.encoder, f.input, into: &f.output))
    }) { f in
        brotliEncodeStreaming(&f.encoder, f.input, chunk: 16 << 10, into: &f.output)
    }
    let brotliStream = Lazy {
        var compressed = [UInt8](repeating: 0, count: content.value.byteCount + 1024)
        compressed.removeLast(compressed.count - GoogleBrotli.compress(content.value.bytes, quality: 5, into: &compressed))
        return DecodeFixture(original: content.value.bytes, compressed: compressed, outputCount: content.value.byteCount + 64, decoder: BrotliDecoder())
    }
    register("Allocations:Brotli_decode", configuration: configuration, brotliStream, check: { $0.decodedAll($1) }) { f in
        brotliDecodeAll(&f.decoder, f.compressed, into: &f.output)
    }
    register("Allocations:Brotli_decode_streaming", configuration: configuration, brotliStream, check: { $0.decodedCount($1) }) { f in
        brotliDecodeStreaming(&f.decoder, f.compressed, chunk: 4 << 10, into: &f.output)
    }
}

// MARK: - Checksums

func registerChecksumBenchmarks() {
    let data = Lazy { (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) } }
    let small = Lazy { Array(data.value.prefix(64)) }
    let reference = { (_: [UInt8], value: UInt32) in value == ZlibChecksums.adler32(data.value) }
    register("Adler-32 1 MB: Bytes", data, check: reference) { data in
        Adler32.checksum(data.span.bytes)
    }
    register("Adler-32 1 MB: zlib", data, check: reference) { data in
        ZlibChecksums.adler32(data)
    }
    register("Adler-32 1 MB: libdeflate", data, check: reference) { data in
        LibDeflateChecksums.adler32(data)
    }
    register("Adler-32 64 B (×16 K): Bytes", small) { small in
        var value: UInt32 = 1
        for _ in 0..<16_384 {
            value = Adler32.checksum(small.span.bytes, continuing: value)
        }
        return value
    }
    register("Adler-32 64 B (×16 K): zlib", small) { small in
        var value: UInt32 = 1
        for _ in 0..<16_384 {
            value = ZlibChecksums.adler32(small, continuing: value)
        }
        return value
    }

    // CRC-32 (gzip's, zip's, PNG's): 1 MB, an odd size (the tail after the 64-byte folds), and 64-byte messages.
    let crc32Reference = { (data: [UInt8], value: UInt32) in value == ZlibChecksums.crc32(data) }
    register("CRC-32 1 MB: Bytes", data, check: crc32Reference) { data in
        CRC32.checksum(data.span.bytes)
    }
    register("CRC-32 1 MB: zlib", data, check: crc32Reference) { data in
        ZlibChecksums.crc32(data)
    }
    register("CRC-32 1 MB: libdeflate", data, check: crc32Reference) { data in
        LibDeflateChecksums.crc32(data)
    }
    let odd = Lazy { Fixtures.noise(1_000_003, seed: 2) }
    register("CRC-32 1,000,003 B: Bytes", odd, check: crc32Reference) { data in
        CRC32.checksum(data.span.bytes)
    }
    register("CRC-32 1,000,003 B: libdeflate", odd, check: crc32Reference) { data in
        LibDeflateChecksums.crc32(data)
    }
    let crc32Small = { (small: [UInt8], value: UInt32) in
        value == (0..<16_384).reduce(UInt32(0)) { value, _ in ZlibChecksums.crc32(small, continuing: value) }
    }
    register("CRC-32 64 B (×16 K): Bytes", small, check: crc32Small) { small in
        var value: UInt32 = 0
        for _ in 0..<16_384 {
            value = CRC32.checksum(small.span.bytes, continuing: value)
        }
        return value
    }
    register("CRC-32 64 B (×16 K): zlib", small, check: crc32Small) { small in
        var value: UInt32 = 0
        for _ in 0..<16_384 {
            value = ZlibChecksums.crc32(small, continuing: value)
        }
        return value
    }

    // CRC-64 (.xz's), against liblzma's.
    let crc64Reference = { (data: [UInt8], value: UInt64) in value == ReferenceHashes.crc64(data) }
    register("CRC-64 1 MB: Bytes", data, check: crc64Reference) { data in
        CRC64.checksum(data.span.bytes)
    }
    register("CRC-64 1 MB: liblzma", data, check: crc64Reference) { data in
        ReferenceHashes.crc64(data)
    }
    let crc64Small = { (small: [UInt8], value: UInt64) in
        value == (0..<16_384).reduce(UInt64(0)) { value, _ in ReferenceHashes.crc64(small, continuing: value) }
    }
    register("CRC-64 64 B (×16 K): Bytes", small, check: crc64Small) { small in
        var value: UInt64 = 0
        for _ in 0..<16_384 {
            value = CRC64.checksum(small.span.bytes, continuing: value)
        }
        return value
    }
    register("CRC-64 64 B (×16 K): liblzma", small, check: crc64Small) { small in
        var value: UInt64 = 0
        for _ in 0..<16_384 {
            value = ReferenceHashes.crc64(small, continuing: value)
        }
        return value
    }

    // XXH64 (Zstandard's content checksum), against libzstd's copy of xxHash. The 64-byte messages chain through the
    // seed, so no call can be hoisted.
    let xxh64Reference = { (data: [UInt8], value: UInt64) in value == ReferenceHashes.xxh64(data) }
    register("XXH64 1 MB: Bytes", data, check: xxh64Reference) { data in
        XXHash64.hash(data.span.bytes)
    }
    if ReferenceHashes.zstdXXH64 != nil {
        register("XXH64 1 MB: libzstd", data, check: xxh64Reference) { data in
            ReferenceHashes.xxh64(data)
        }
    }
    let xxh64Small = { (small: [UInt8], value: UInt64) in
        value == (0..<16_384).reduce(UInt64(0)) { seed, _ in ReferenceHashes.xxh64(small, seed: seed) }
    }
    register("XXH64 64 B (×16 K): Bytes", small, check: xxh64Small) { small in
        var value: UInt64 = 0
        for _ in 0..<16_384 {
            value = XXHash64.hash(small.span.bytes, seed: value)
        }
        return value
    }
    if let function = ReferenceHashes.zstdXXH64 {
        // The function pointer captured: `ReferenceHashes.xxh64` reads a lazily initialized `static let`, whose
        // `swift_once` token a call per message would check.
        register("XXH64 64 B (×16 K): libzstd", small, check: xxh64Small) { small in
            var value: UInt64 = 0
            for _ in 0..<16_384 {
                value = small.withUnsafeBytes { function($0.baseAddress, $0.count, value) }
            }
            return value
        }
    }
}

// MARK: - Decompression

/// Decodes each sample's zlib level-6 encoding: raw DEFLATE with each decoder, gzip (checksum included) with
/// the ones that check it (the references on two inputs), the zlib format on one; and 1 MB of random bytes (stored
/// blocks).
func registerInflateBenchmarks() {
    for sample in Fixtures.samples + [Fixtures.random] {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let random = sample.name == "random"
        let raw = Lazy {
            let raw = Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.raw") { Fixtures.zlibCompress(sample.bytes) }
            return DecodeFixture(original: sample.bytes, compressed: raw, outputCount: sample.byteCount + 64, decoder: DeflateDecoder(format: .raw))
        }
        let gzip = Lazy {
            let gzip = Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.gz") { Fixtures.zlibCompress(sample.bytes, windowBits: 31) }
            return DecodeFixture(original: sample.bytes, compressed: gzip, outputCount: sample.byteCount + 64, decoder: DeflateDecoder(format: .gzip))
        }
        let zlibRaw = Lazy { ZlibInflater(windowBits: -15) }
        let zlibGzip = Lazy { ZlibInflater(windowBits: 31) }
        let libdeflateRaw = Lazy { LibDeflate(format: .raw) }
        let libdeflateGzip = Lazy { LibDeflate(format: .gzip) }
        let apple = Lazy { AppleCompression(algorithm: COMPRESSION_ZLIB) }

        register("Inflate \(sample.label): Bytes", configuration: configuration, raw, check: { $0.decodedAll($1) }) { f in
            decodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        register("Inflate \(sample.label): libdeflate", configuration: configuration, raw, check: { $0.decodedAll($1) }) { f in
            libdeflateRaw.value.decompress(f.compressed, into: &f.output)
        }
        guard !random else { continue }
        register("Inflate \(sample.label): Bytes, streaming 64 KB", configuration: configuration, raw, check: { $0.decodedCount($1) }) { f in
            decodeStreaming(&f.decoder, f.compressed, chunk: 1 << 16, into: &f.output)
        }
        if sample.name == "Main.js" {
            // Pieces of a few packets, as a client decodes a response while it arrives.
            register("Inflate \(sample.label): Bytes, streaming 4 KB", configuration: configuration, raw, check: { $0.decodedCount($1) }) { f in
                decodeStreaming(&f.decoder, f.compressed, chunk: 4 << 10, into: &f.output)
            }
        }
        register("Inflate \(sample.label): zlib", configuration: configuration, raw, check: { $0.decodedAll($1) }) { f in
            zlibRaw.value.decompress(f.compressed, into: &f.output)
        }
        register("Inflate \(sample.label): Apple Compression", configuration: configuration, raw, check: { $0.decodedAll($1) }) { f in
            apple.value.decompress(f.compressed, into: &f.output)
        }
        register("Inflate gzip \(sample.label): Bytes", configuration: configuration, gzip, check: { $0.decodedAll($1) }) { f in
            decodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        if sample.name == "Main.js" || sample.name == "xml" {
            register("Inflate gzip \(sample.label): zlib", configuration: configuration, gzip, check: { $0.decodedAll($1) }) { f in
                zlibGzip.value.decompress(f.compressed, into: &f.output)
            }
            register("Inflate gzip \(sample.label): libdeflate", configuration: configuration, gzip, check: { $0.decodedAll($1) }) { f in
                libdeflateGzip.value.decompress(f.compressed, into: &f.output)
            }
        }
        if sample.name == "Main.js" {
            let zlibFormat = Lazy {
                let encoded = Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.zlib") { Fixtures.zlibCompress(sample.bytes, windowBits: 15) }
                return DecodeFixture(original: sample.bytes, compressed: encoded, outputCount: sample.byteCount + 64, decoder: DeflateDecoder(format: .zlib))
            }
            let zlibInflater = Lazy { ZlibInflater(windowBits: 15) }
            register("Inflate zlib \(sample.label): Bytes", configuration: configuration, zlibFormat, check: { $0.decodedAll($1) }) { f in
                decodeAll(&f.decoder, f.compressed, into: &f.output)
            }
            register("Inflate zlib \(sample.label): zlib", configuration: configuration, zlibFormat, check: { $0.decodedAll($1) }) { f in
                zlibInflater.value.decompress(f.compressed, into: &f.output)
            }
        }
    }
}

/// Decodes a whole stream into `output` with `decompressAll`, which starts a new stream itself.
@inline(__always)
func decodeAll(_ decoder: inout DeflateDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
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
        // A gzip member's end: another may follow in the input not yet given.
        if progress.status == .finished && offset == span.byteCount { return total }
    }
}

/// gzip files of several members (RFC 1952 §2.2): the same 1 MB of text as one member, 16 of 64 KB, and 256 of 4 KB,
/// each zlib's level 6. Bytes decodes every member in one call (or streamed); zlib member by member, as `gunzip` does
/// (`inflateReset` between).
///
/// Smaller members compress worse and decode slower (no history at each start, a new dynamic block, more literals),
/// so the control is one member with a full flush where each member would start (history forgotten, a block ended):
/// the same DEFLATE data, so the difference is what the members themselves cost (header, trailer, reset).
func registerGzipMemberBenchmarks() {
    guard let sample = Fixtures.silesia("dickens", limit: 1 << 20) else { return }
    let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
    let zlib = Lazy { ZlibInflater(windowBits: 31) }
    for memberSize in [64 << 10, 4 << 10] {
        let fixture = Lazy {
            let flushed = Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.full-flush-\(memberSize).gz") {
                Zlib.compress(sample.bytes, windowBits: 31, level: 6, flushingEvery: memberSize, flushes: [Zlib.fullFlush])
            }
            return DecodeFixture(original: sample.bytes, compressed: flushed, outputCount: sample.byteCount + 64, decoder: DeflateDecoder(format: .gzip))
        }
        let name = "Inflate gzip members \(sample.label), 1 member, full flush every \(memberSize >> 10) KB"
        register("\(name): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            decodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        register("\(name): zlib", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            zlib.value.decompressMembers(f.compressed, into: &f.output)
        }
    }
    for (memberSize, label) in [(1 << 20, "1 member"), (64 << 10, "16 × 64 KB"), (4 << 10, "256 × 4 KB")] {
        let fixture = Lazy {
            let members = Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.members-\(memberSize).gz") {
                stride(from: 0, to: sample.byteCount, by: memberSize).flatMap { start in
                    Fixtures.zlibCompress(Array(sample.bytes[start..<min(start + memberSize, sample.byteCount)]), windowBits: 31)
                }
            }
            return DecodeFixture(original: sample.bytes, compressed: members, outputCount: sample.byteCount + 64, decoder: DeflateDecoder(format: .gzip))
        }
        let name = "Inflate gzip members \(sample.label), \(label)"
        register("\(name): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            decodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        register("\(name): Bytes, streaming 64 KB", configuration: configuration, fixture, check: { $0.decodedCount($1) }) { f in
            decodeStreaming(&f.decoder, f.compressed, chunk: 1 << 16, into: &f.output)
        }
        register("\(name): zlib", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            zlib.value.decompressMembers(f.compressed, into: &f.output)
        }
    }
}
