import Benchmark
import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import HTTP1
import HTTPPayload

// Bodies: content codings through HTTPBytes' HTTP layers (BytesCompression underneath), measuring what the HTTP
// framing adds: a gzip body arriving as 4 KB chunks, its chunk data handed straight from the chunked decoder's slices to
// the content decoder (no copy), against the same body decoded whole, and against system zlib decoding it whole.
// Per iteration: one 1 MB body.

/// 1 MB of compressible text (words from a vocabulary), gzip-coded and also chunked in 4 KB chunks.
struct CodedBody {
    let plain: [UInt8]
    let gzip: [UInt8]
    let brotli: [UInt8]
    let gzipChunked: [UInt8]

    init() {
        var generator = SplitMix64(seed: 3)
        let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "HTTP", "field", "value", "header",
                     "request", "response", "stream", "frame"].map { Array($0.utf8) + [0x20] }
        var plain: [UInt8] = []
        while plain.count < 1 << 20 { plain += words[Int(generator.next() % 16)] }
        self.plain = plain
        gzip = Self.encode(plain, .gzip)
        brotli = Self.encode(plain, .brotli)
        var chunked: [UInt8] = []
        var offset = 0
        while offset < gzip.count {
            let size = min(4_096, gzip.count - offset)
            chunked += Array(String(size, radix: 16).utf8) + [0x0D, 0x0A] + gzip[offset..<offset + size] + [0x0D, 0x0A]
            offset += size
        }
        gzipChunked = chunked + Array("0\r\n\r\n".utf8)
    }

    static func encode(_ plain: [UInt8], _ coding: HTTPContentCoding) -> [UInt8] {
        var encoder = try! HTTPContentEncoder(coding)
        var output = [UInt8](repeating: 0, count: plain.count + 4_096)
        let written = try! output.withOutputRawSpan { (span) throws(HTTPPayloadError) in
            var progress = try encoder.encode(plain.span.bytes, into: &span, flush: .finish)
            while progress.status != .finished { progress = try encoder.encode(RawSpan(), into: &span, flush: .finish) }
            return span.byteCount
        }
        return Array(output[..<written])
    }
}

let codedBody = Lazy { CodedBody() }

/// Decodes `body` (coded with `encoding`) into a reused 64 KiB output; the decoded byte count.
@inline(never)
func decodeWhole(_ body: [UInt8], encoding: [UInt8], output: inout [UInt8]) -> Int {
    guard var decoder = try? HTTPContentDecoder(contentEncoding: encoding.span.bytes) else { return -1 }
    var unread = body.span.bytes
    var total = 0
    while true {
        guard let progress = try? output.withOutputRawSpan({ (span) throws(HTTPPayloadError) in try decoder.decode(unread, into: &span) })
        else { return -2 }
        total &+= progress.produced
        unread = unread.extracting(droppingFirst: progress.consumed)
        if progress.status == .finished { return total }
        if progress.consumed == 0, progress.produced == 0 { return -3 }
    }
}

/// A chunked, gzip-coded body: chunk data slices go straight into the content decoder.
@inline(never)
func decodeChunkedGzip(_ message: [UInt8], output: inout [UInt8]) -> Int {
    guard var decoder = try? HTTPContentDecoder(applied: .gzip) else { return -1 }
    return decodeChunked(message, decoder: &decoder, output: &output)
}

/// As `decodeChunkedGzip`, with a decoder reset for each body (as a server keeps one per connection).
@inline(never)
func decodeChunkedGzip(_ message: [UInt8], reusing decoder: inout HTTPContentDecoder, output: inout [UInt8]) -> Int {
    guard (try? decoder.reset(applied: .gzip)) != nil else { return -1 }
    return decodeChunked(message, decoder: &decoder, output: &output)
}

@inline(__always)
func decodeChunked(_ message: [UInt8], decoder: inout HTTPContentDecoder, output: inout [UInt8]) -> Int {
    var chunks = HTTP1ChunkedDecoder()
    var unread = message.span.bytes
    var total = 0
    do {
        while true {
            var consumed = 0
            switch try chunks.next(in: unread, consumed: &consumed) {
            case .data(let data):
                var pending = data
                while pending.byteCount > 0 {
                    let progress = try output.withOutputRawSpan { (span) throws(HTTPPayloadError) in try decoder.decode(pending, into: &span) }
                    total &+= progress.produced
                    pending = pending.extracting(droppingFirst: progress.consumed)
                    if progress.consumed == 0, progress.produced == 0 { return -4 }
                }
            case .trailer: break
            case .end: return total
            case .needsMore: return -2
            }
            unread = unread.extracting(droppingFirst: consumed)
        }
    } catch { return -3 }
}

func registerPayloadBenchmarks() {
    nonisolated(unsafe) var output = [UInt8](repeating: 0, count: 64 << 10)
    func register(_ name: String, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(run() == codedBody.value.plain.count, "\(name): wrong length")
        }
    }
    register("Body 1 MB text, gzip, chunked in 4 KB: HTTPBytes chunked → content decoder") {
        decodeChunkedGzip(codedBody.value.gzipChunked, output: &output)
    }
    register("Body 1 MB text, gzip, whole: HTTPBytes content decoder") {
        decodeWhole(codedBody.value.gzip, encoding: Array("gzip".utf8), output: &output)
    }
    register("Body 1 MB text, gzip, whole: zlib (system)") {
        Zlib.decompress(codedBody.value.gzip, windowBits: Zlib.Container.gzip.windowBits)?.count ?? -1
    }
    register("Body 1 MB text, br, whole: HTTPBytes content decoder") {
        decodeWhole(codedBody.value.brotli, encoding: Array("br".utf8), output: &output)
    }

    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // A decoder reused across bodies: its first body makes the codec's state (6 allocations), later ones nothing.
    Benchmark("Allocations:Body_chunked_gzip", configuration: zeroAllocations) { benchmark in
        let message = codedBody.value.gzipChunked
        var decoder = try! HTTPContentDecoder(applied: .gzip)
        precondition(decodeChunkedGzip(message, reusing: &decoder, output: &output) == codedBody.value.plain.count)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations { blackHole(decodeChunkedGzip(message, reusing: &decoder, output: &output)) }
    }
}
