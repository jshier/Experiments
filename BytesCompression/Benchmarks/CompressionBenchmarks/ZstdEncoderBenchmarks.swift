import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CZstd

// Zstandard encoding: Bytes' `ZstdEncoder` against libzstd 1.5.7 (Homebrew; `ZSTD_versionNumber()` 10507) with the
// same parameters set one by one (`ZSTD_c_strategy`, `ZSTD_c_windowLog`, `ZSTD_c_hashLog`, `ZSTD_c_chainLog`,
// `ZSTD_c_searchLog`, `ZSTD_c_minMatch`, `ZSTD_c_targetLength`), so libzstd's tables for small inputs don't apply
// (both still shrink the window and tables to a known content size, as libzstd always does). Both reuse their state
// across iterations. Each setup checks the frames are identical, byte for byte. Results: RESULTS-zstd-encoder.md.

/// libzstd's encoder, its context reused, parameters set explicitly.
final class LibZstdEncoder {
    private let context = ZSTD_createCCtx()!

    init(parameters: ZstdEncoder.Parameters, checksum: Bool = false) {
        precondition(ZSTD_versionNumber() == 10507, "the results are for libzstd 1.5.7")
        let settings: [(ZSTD_cParameter, Int32)] = [
            (ZSTD_c_strategy, Int32(parameters.strategy.rawValue)), (ZSTD_c_windowLog, Int32(parameters.windowLog)),
            (ZSTD_c_hashLog, Int32(parameters.hashLog)), (ZSTD_c_chainLog, Int32(parameters.chainLog)), (ZSTD_c_searchLog, 1),
            (ZSTD_c_minMatch, Int32(parameters.minimumMatchLength)), (ZSTD_c_targetLength, Int32(parameters.targetLength)),
            (ZSTD_c_checksumFlag, checksum ? 1 : 0),
        ]
        for (parameter, value) in settings {
            precondition(ZSTD_isError(ZSTD_CCtx_setParameter(context, parameter, value)) == 0)
        }
    }

    deinit {
        ZSTD_freeCCtx(context)
    }

    /// One call: `ZSTD_compress2`, content size stated.
    func compress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        let size = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                ZSTD_compress2(context, output.baseAddress, output.count, input.baseAddress, input.count)
            }
        }
        precondition(ZSTD_isError(size) == 0)
        return size
    }

    /// `ZSTD_compressStream2` with `chunk`-byte pieces of input (size unknown), into a 64 KB buffer reused for each
    /// piece of output. Returns the total compressed size.
    func compressStreaming(_ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
        ZSTD_CCtx_reset(context, ZSTD_reset_session_only)
        var total = 0
        return input.withUnsafeBytes { all in
            output.withUnsafeMutableBytes { buffer in
                var offset = 0
                while true {
                    let end = min(offset + chunk, all.count)
                    let isLast = end == all.count
                    var inBuffer = ZSTD_inBuffer(src: all.baseAddress! + offset, size: end - offset, pos: 0)
                    while true {
                        var outBuffer = ZSTD_outBuffer(dst: buffer.baseAddress, size: min(buffer.count, 1 << 16), pos: 0)
                        let remaining = ZSTD_compressStream2(context, &outBuffer, &inBuffer, isLast ? ZSTD_e_end : ZSTD_e_continue)
                        precondition(ZSTD_isError(remaining) == 0)
                        total += outBuffer.pos
                        if isLast ? remaining == 0 : inBuffer.pos == inBuffer.size && outBuffer.pos < outBuffer.size { break }
                    }
                    offset = end
                    if isLast { return total }
                }
            }
        }
    }
}

final class ZstdEncodeFixture {
    let input: [UInt8]
    var output: [UInt8]
    var encoder: ZstdEncoder
    let reference: LibZstdEncoder

    init(_ input: [UInt8], parameters: ZstdEncoder.Parameters) {
        self.input = input
        output = [UInt8](repeating: 0, count: ZstdEncoder.maximumCompressedSize(forByteCount: input.count) + 64)
        encoder = ZstdEncoder(parameters: parameters)
        reference = LibZstdEncoder(parameters: parameters)
    }

    /// Whether the encoder's frame (`count` bytes of `output`) is libzstd's.
    func matchesReference(_ count: Int) -> Bool {
        var expected = [UInt8](repeating: 0, count: output.count)
        let size = reference.compress(input, into: &expected)
        return size == count && output[..<count] == expected[..<size]
    }
}

/// Encodes a whole frame with `compressAll`.
@inline(__always)
func zstdEncodeAll(_ encoder: inout ZstdEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Encodes an input arriving in `chunk`-byte pieces, finishing with the last, into a 64 KB buffer reused for each
/// piece of output. Returns the total compressed size.
@inline(__always)
func zstdEncodeStreaming(_ encoder: inout ZstdEncoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
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

/// Registers the comparisons: the corpus files at levels 1 and 3 (2 and 4 for text and JavaScript, the HTTP window at
/// level 3 for the large ones); HTTP-sized bodies (the first 1, 4, 16, 64 KB of text, XML, JavaScript, and CSS, and
/// the whole HTML page) at levels 1 and 3 with the HTTP window; Main.js streamed in 64 KB pieces; and random bytes.
func registerZstdEncodeBenchmarks() {
    let large = Fixtures.samples + [Fixtures.silesia("mozilla")].compactMap(\.self)
    for sample in large {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        var settings: [(label: String, parameters: ZstdEncoder.Parameters)] = [1, 3].map { ("L\($0)", .init(level: $0)) }
        if sample.name == "dickens" || sample.name == "Main.js" {
            settings += [2, 4].map { ("L\($0)", .init(level: $0)) }
        }
        if sample.byteCount > 1 << 20 {
            settings.append(("L3 w19", .init(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)))
        }
        for (label, parameters) in settings {
            let fixture = Lazy { ZstdEncodeFixture(sample.bytes, parameters: parameters) }
            register("Zstd encode \(label) \(sample.label): Bytes", configuration: configuration, fixture, check: { $0.matchesReference($1) }) { f in
                zstdEncodeAll(&f.encoder, f.input, into: &f.output)
            }
            register("Zstd encode \(label) \(sample.label): libzstd", configuration: configuration, fixture, check: { $0.matchesReference($1) }) { f in
                f.reference.compress(f.input, into: &f.output)
            }
        }
    }

    // HTTP bodies, with the HTTP window (frames shrink it to the body anyway).
    var bodies: [Fixtures.Sample] = []
    for (name, path) in [("dickens", "silesia/dickens"), ("xml", "silesia/xml"), ("Main.js", "web/Main.js"), ("Main.css", "web/Main.css")] {
        for kilobytes in [1, 4, 16, 64] {
            if let sample = Fixtures.Sample(name: "\(name) \(kilobytes) KB", corpusPath: path, limit: kilobytes << 10) { bodies.append(sample) }
        }
    }
    if let page = Fixtures.Sample(name: "Main.html", corpusPath: "web/Main.html") { bodies.append(page) }
    bodies.append(Fixtures.Sample(name: "JSON 1.6 KB", bytes: Fixtures.json(count: 16)))
    for body in bodies {
        for level in [1, 3] {
            let parameters = ZstdEncoder.Parameters(level: level, windowLog: ZstdEncoder.Parameters.httpWindowLog)
            let fixture = Lazy { ZstdEncodeFixture(body.bytes, parameters: parameters) }
            register("Zstd encode L\(level) body \(body.name): Bytes", fixture, check: { $0.matchesReference($1) }) { f in
                zstdEncodeAll(&f.encoder, f.input, into: &f.output)
            }
            register("Zstd encode L\(level) body \(body.name): libzstd", fixture, check: { $0.matchesReference($1) }) { f in
                f.reference.compress(f.input, into: &f.output)
            }
        }
    }

    // Main.js in 64 KB pieces, as a server streams it: sizes within 1% of the one-shot frame's.
    if let script = Fixtures.Sample(name: "Main.js", corpusPath: "web/Main.js") {
        let parameters = ZstdEncoder.Parameters(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)
        let fixture = Lazy { ZstdEncodeFixture(script.bytes, parameters: parameters) }
        let check = { (f: ZstdEncodeFixture, count: Int) in
            var copy = f.output
            return Fixtures.sizeMatches(count, oneShot: f.reference.compress(f.input, into: &copy))
        }
        let configuration = Fixtures.configuration(forByteCount: script.byteCount)
        register("Zstd encode L3 w19 \(script.label): Bytes, streaming 64 KB", configuration: configuration, fixture, check: check) { f in
            zstdEncodeStreaming(&f.encoder, f.input, chunk: 1 << 16, into: &f.output)
        }
        register("Zstd encode L3 w19 \(script.label): libzstd, streaming 64 KB", configuration: configuration, fixture, check: check) { f in
            f.reference.compressStreaming(f.input, chunk: 1 << 16, into: &f.output)
        }
    }

    // 1 MB of random bytes: raw blocks.
    let random = Fixtures.random
    let randomFixture = Lazy { ZstdEncodeFixture(random.bytes, parameters: .init(level: 3)) }
    register("Zstd encode L3 \(random.label): Bytes", configuration: Fixtures.largeConfiguration, randomFixture, check: { $0.matchesReference($1) }) { f in
        zstdEncodeAll(&f.encoder, f.input, into: &f.output)
    }
    register("Zstd encode L3 \(random.label): libzstd", configuration: Fixtures.largeConfiguration, randomFixture, check: { $0.matchesReference($1) }) { f in
        f.reference.compress(f.input, into: &f.output)
    }
}

/// Allocation checks: a reused encoder allocates nothing, one call or streamed (once its window has grown, in setup's
/// run). Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:Zstd_encode.*'
func registerZstdEncodeAllocationBenchmarks() {
    let content = Lazy { Fixtures.gateContent() }
    for level in [1, 3] {
        let fixture = Lazy { ZstdEncodeFixture(content.value, parameters: .init(level: level, windowLog: ZstdEncoder.Parameters.httpWindowLog)) }
        register("Allocations:Zstd_encode_L\(level)", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.matchesReference($1) }) { f in
            zstdEncodeAll(&f.encoder, f.input, into: &f.output)
        }
        register("Allocations:Zstd_encode_L\(level)_streaming", configuration: Fixtures.allocationConfiguration, fixture, check: { f, count in
            var copy = f.output
            return Fixtures.sizeMatches(count, oneShot: f.reference.compress(f.input, into: &copy))
        }) { f in
            zstdEncodeStreaming(&f.encoder, f.input, chunk: 16 << 10, into: &f.output)
        }
    }
}
