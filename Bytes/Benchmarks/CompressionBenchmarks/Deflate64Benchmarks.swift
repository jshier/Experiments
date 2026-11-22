import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport

// Deflate64 (zip method 9), and decoding into the caller's buffer with the history in front
// (`decompress(_:into:historyCount:)`), as NativeZip's ZipDecoder does: 1 MB at a time after 64 KB of history, the
// last window moved to the front after each call.
//
// No library writes Deflate64, but a DEFLATE stream with no length-258 matches (the one length Deflate64 codes
// differently) is a Deflate64 stream: zlib's level-6 streams of x-ray and Main.css have none (checked by each
// benchmark's setup against the original). They run Deflate64's own copy of the decode loop on the same input as
// the DEFLATE rows.

func registerDeflate64Benchmarks() {
    for sample in Fixtures.samples where ["dickens", "x-ray", "Main.css"].contains(sample.name) {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let compressed = Lazy {
            Fixtures.cached("\(sample.name)-\(sample.byteCount).zlib-6.raw") { Fixtures.zlibCompress(sample.bytes) }
        }
        let history = Lazy {
            DecodeFixture(
                original: sample.bytes, compressed: compressed.value, outputCount: (64 << 10) + (1 << 20),
                decoder: DeflateDecoder(variant: .deflate)
            )
        }
        register("Inflate \(sample.label): Bytes, history 1 MB", configuration: configuration, history, check: { $0.decodedCount($1) }) { f in
            decodeWithHistory(&f.decoder, f.compressed, into: &f.output)
        }
        guard sample.name != "dickens" else { continue } // It has length-258 matches.
        let all64 = Lazy {
            DecodeFixture(
                original: sample.bytes, compressed: compressed.value, outputCount: sample.byteCount + 64,
                decoder: DeflateDecoder(variant: .deflate64)
            )
        }
        let history64 = Lazy {
            DecodeFixture(
                original: sample.bytes, compressed: compressed.value, outputCount: (64 << 10) + (1 << 20),
                decoder: DeflateDecoder(variant: .deflate64)
            )
        }
        register("Inflate64 \(sample.label): Bytes", configuration: configuration, all64, check: { $0.decodedAll($1) }) { f in
            decodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        register("Inflate64 \(sample.label): Bytes, history 1 MB", configuration: configuration, history64, check: { $0.decodedCount($1) }) { f in
            decodeWithHistory(&f.decoder, f.compressed, into: &f.output)
        }
    }
}

/// Decodes a whole stream with `decompress(_:into:historyCount:)` into `output` (the history, then 1 MB), moving
/// the last `historySize` bytes to its front after each call. Returns the total decoded.
@inline(__always)
func decodeWithHistory(_ decoder: inout DeflateDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    decoder.reset()
    let historySize = decoder.historySize
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var raw = MutableRawSpan(mutating: &bytes)
    var consumed = 0
    var history = 0
    var total = 0
    while true {
        let progress = try! decoder.decompress(span.extracting(consumed...), into: &raw, historyCount: history)
        consumed += progress.consumed
        total += progress.produced
        if progress.status == .finished { return total }
        precondition(progress.status == .needsOutput, "Truncated stream")
        let end = history + progress.produced
        let kept = min(historySize, end)
        raw.copyBytes(within: (end - kept)..<end, toByteOffset: 0)
        history = kept
    }
}
