import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CBZip2

// bzip2 decoding with bounded output, as NativeZip decodes zip entries (method 12): Bytes' `BZip2Decoder.decompress`
// given the whole rest of the stream on every call and 1 MiB of output each time, against libbzip2's
// `BZ2_bzDecompress` with the same output. Compare with the one-call rows (`BZip2Benchmarks.swift`: "BZip2 decode -9
// NAME: Bytes" and ": libbz2"), on the same inputs.

/// The output size of each call.
let bzip2StreamingChunk = 1 << 20

/// Decodes `input` with `decompress(_:into:)` into the first `chunk` bytes of `output`, over and over: the whole rest of
/// the stream on every call.
///
/// - Returns: The bytes decoded.
func bzip2DecodeStreamed(
    _ decoder: inout BZip2Decoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8], check: ((RawSpan, Int) -> Void)? = nil
) -> Int {
    decoder.reset()
    var offset = 0
    var total = 0
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var window = bytes._mutatingExtracting(..<min(bytes.count, chunk))
    while true {
        let progress = window.withOutputRawSpan { out in
            let progress = try! decoder.decompress(span.extracting(offset...), into: &out)
            check?(out.bytes, total)
            return progress
        }
        total += progress.produced
        offset += progress.consumed
        if progress.status == .finished { return total }
        precondition(progress.status == .needsOutput, "Input ended early")
    }
}

/// libbzip2's streaming decoder (`BZ2_bzDecompress`), from its setup to its end: the whole input at once, output into
/// the first `chunk` bytes of `output` over and over.
///
/// - Returns: The bytes decoded.
func libbz2DecodeStreamed(_ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
    var stream = bz_stream()
    precondition(BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK)
    defer { BZ2_bzDecompressEnd(&stream) }
    var input = input
    var total = 0
    input.withUnsafeMutableBytes { input in
        output.withUnsafeMutableBytes { output in
            stream.next_in = input.baseAddress!.assumingMemoryBound(to: CChar.self)
            stream.avail_in = UInt32(input.count)
            while true {
                stream.next_out = output.baseAddress!.assumingMemoryBound(to: CChar.self)
                stream.avail_out = UInt32(min(chunk, output.count))
                let status = BZ2_bzDecompress(&stream)
                total += min(chunk, output.count) - Int(stream.avail_out)
                if status == BZ_STREAM_END { return }
                precondition(status == BZ_OK, "BZ2_bzDecompress: \(status)")
            }
        }
    }
    return total
}

/// Whether streaming `fixture`'s stream gives its original, piece by piece.
func bzip2StreamsOriginal(_ fixture: DecodeFixture<BZip2Decoder>) -> Bool {
    var matches = true
    let original = fixture.original
    let count = bzip2DecodeStreamed(&fixture.decoder, fixture.compressed, chunk: bzip2StreamingChunk, into: &fixture.output) { piece, offset in
        guard offset + piece.byteCount <= original.count else {
            matches = false
            return
        }
        for index in 0..<piece.byteCount where piece.unsafeLoad(fromByteOffset: index, as: UInt8.self) != original[offset + index] {
            matches = false
            return
        }
    }
    return matches && count == original.count
}

/// Registers the streaming rows on `BZip2Benchmarks`' inputs; each benchmark's setup checks its decoder's output.
func registerBZip2StreamingBenchmarks() {
    for sample in BZip2Fixtures.samples() {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy {
            let compressed = Fixtures.cached("\(sample.name)-\(sample.byteCount).bzip2-1.0.8-9") {
                BZip2Fixtures.compress(sample.bytes, level: 9)
            }
            return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: bzip2StreamingChunk, decoder: BZip2Decoder())
        }
        register(
            "BZip2 decode -9 \(sample.label): Bytes, streaming 1 MiB", configuration: configuration, fixture,
            check: { f, count in count == f.original.count && bzip2StreamsOriginal(f) }
        ) { f in
            bzip2DecodeStreamed(&f.decoder, f.compressed, chunk: bzip2StreamingChunk, into: &f.output)
        }
        register(
            "BZip2 decode -9 \(sample.label): libbz2, streaming 1 MiB", configuration: configuration, fixture,
            check: { $0.decodedCount($1) }
        ) { f in
            libbz2DecodeStreamed(f.compressed, chunk: bzip2StreamingChunk, into: &f.output)
        }
    }

    // Allocation check: streaming allocates nothing either (the same two streams as `Allocations:BZip2_decode`, in
    // 4 KiB of output at a time).
    let allocationFixture = Lazy {
        let content = Fixtures.json(count: 1_200) + [UInt8](repeating: 0x20, count: 5_000) + Fixtures.json(count: 16)
        let compressed = BZip2Fixtures.compress(content, level: 1) + BZip2Fixtures.compress(Array(content.prefix(70_000)), level: 9)
        let expected = content + content.prefix(70_000)
        return DecodeFixture(original: expected, compressed: compressed, outputCount: 4096, decoder: BZip2Decoder())
    }
    register(
        "Allocations:BZip2_decode_streaming", configuration: Fixtures.allocationConfiguration, allocationFixture,
        check: { $0.decodedCount($1) }
    ) { f in
        bzip2DecodeStreamed(&f.decoder, f.compressed, chunk: 4096, into: &f.output)
    }
}
