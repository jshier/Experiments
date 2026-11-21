import Benchmark
import Bytes
import BytesAsync
import BytesCompression
import BytesTestSupport
import Darwin
import Dispatch

// MARK: - Parallel compression

/// The performance cores: the lane count the parallel encoders are meant to run with (efficiency cores
/// finish their chunks last, and each round waits for them).
let performanceCores: Int = {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else { return 4 }
    return Int(count)
}()

/// Every core, efficiency cores included: with several chunks or segments per lane the parallel DEFLATE codecs
/// gain from them, and lane counts past the performance cores cut streams at other places (the parallel decoder
/// once fell back to one segment at 32 lanes on Silesia's mozilla).
let allCores: Int = {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else { return performanceCores }
    return Int(count)
}()

/// The large samples (but xml, which added nothing to dickens and samba), plus a 256 KB slice of dickens, where a
/// round's fixed costs show.
private func parallelSamples() -> [Fixtures.Sample] {
    var samples = Fixtures.samples.filter { $0.byteCount >= 1 << 20 && $0.name != "x-ray" && $0.name != "xml" }
    if let dickens = Fixtures.Sample(name: "dickens", corpusPath: "silesia/dickens", limit: 256 << 10) {
        samples.append(dickens)
    }
    return samples
}

/// An output buffer for the async forms, which can't borrow an array across a suspension: allocated once,
/// never freed (the benchmark process registers it for its whole life).
private func outputBuffer(_ byteCount: Int) -> UnsafeMutableRawBufferPointer {
    UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 64)
}

/// Parallel codecs' timings vary more than one thread's (thread wake-ups, cores' clocks): up to 1,000 samples in
/// 300 ms (2–13 ms an operation: 23–150 samples). No malloc counting in timed runs (Fixtures.swift).
private var parallelConfiguration: Benchmark.Configuration {
    .init(
        metrics: [.wallClock, .instructions, .throughput],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .milliseconds(300),
        maxIterations: 1_000
    )
}

final class ParallelEncodeFixture<Encoder: ~Copyable> {
    let input: [UInt8]
    var encoder: Encoder
    var output: [UInt8]
    let buffer: UnsafeMutableRawBufferPointer

    init(input: [UInt8], encoder: consuming Encoder, outputCount: Int) {
        self.input = input
        self.encoder = encoder
        output = [UInt8](repeating: 0, count: outputCount)
        buffer = outputBuffer(outputCount)
    }
}

final class ParallelDecodeFixture {
    let original: [UInt8]
    let compressed: [UInt8]
    var decoder: ParallelDeflateDecoder
    var sequential = DeflateDecoder(format: .raw)
    var output: [UInt8]
    let buffer: UnsafeMutableRawBufferPointer

    init(_ sample: Fixtures.Sample, chunkSize: Int, lanes: Int) {
        original = sample.bytes
        // Independent chunks, so the decoder can split the stream.
        var independent = ParallelDeflateEncoder(format: .raw, level: 6, chunkSize: chunkSize, lanes: lanes, independentChunks: true)
        var scratch = [UInt8](repeating: 0, count: independent.maximumCompressedSize(forByteCount: original.count))
        // (The size into a local first: `scratch.prefix(encode(into: &scratch))` reads `scratch` before
        // the encoder writes it.)
        let compressedSize = parallelEncodeAll(&independent, original, into: &scratch)
        compressed = Array(scratch.prefix(compressedSize))
        decoder = ParallelDeflateDecoder(format: .raw, lanes: lanes)
        output = [UInt8](repeating: 0, count: original.count + 64)
        buffer = outputBuffer(output.count)
        precondition(parallelDecodeAll(&decoder, compressed, into: &output) == original.count
            && output.prefix(original.count).elementsEqual(original) && decoder.lastSegmentCount > 1)
    }
}

/// Compresses each large sample with the parallel DEFLATE encoder on `performanceCores` and 8 lanes, at levels
/// 1 and 6, and on `allCores` at level 6, synchronously (`concurrentPerform` rounds); and in its async forms (on a
/// Dispatch queue, and as task groups) at level 1 on samba and the 256 KB input, on the performance cores. Raw
/// format, 256 KB chunks (64 KB for the 256 KB input, so it fills 4 lanes). Compare with the sequential "Deflate N
/// sample: Bytes" rows.
///
/// Then decodes an independent-chunk encoding of each (level 6) with the parallel decoder on the same lane counts
/// and, for reference, the sequential one. Setups check that zlib (or Google's brotli) decodes each encoding back.
func registerParallelBenchmarks() {
    let queue = DispatchQueue(label: "compression")
    let configuration = parallelConfiguration
    for sample in parallelSamples() {
        let chunkSize = sample.byteCount <= 256 << 10 ? 64 << 10 : 256 << 10
        // The async forms' own costs (hops, task groups) show on the small input and one large one: on the
        // performance cores only.
        let asyncInput = sample.name == "samba" || sample.byteCount <= 256 << 10
        // Every core for the large inputs only: the 256 KB one is 4 chunks.
        let laneCounts = sample.byteCount <= 256 << 10 ? [performanceCores, 8] : [allCores, performanceCores, 8]
        for lanes in Set(laneCounts).sorted(by: >) {
            let async = asyncInput && lanes == performanceCores
            // On every core (when there are more than the performance cores): level 6 and the decoder only.
            for level in [1, 6] where level == 6 || lanes <= performanceCores {
                let fixture = Lazy {
                    let encoder = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: chunkSize, lanes: lanes)
                    let outputCount = encoder.maximumCompressedSize(forByteCount: sample.byteCount)
                    let fixture = ParallelEncodeFixture(input: sample.bytes, encoder: encoder, outputCount: outputCount)
                    let count = parallelEncodeAll(&fixture.encoder, fixture.input, into: &fixture.output)
                    precondition(Fixtures.inflates(fixture.output[..<count], to: fixture.input), "Parallel deflate: wrong result")
                    return fixture
                }
                let name = "Parallel deflate \(level) \(sample.label): Bytes, \(lanes) lanes"
                Benchmark("\(name), sync", configuration: configuration) { benchmark in
                    let f = fixture.value
                    for _ in benchmark.scaledIterations {
                        blackHole(parallelEncodeAll(&f.encoder, f.input, into: &f.output))
                    }
                } setup: { _ = fixture.value }
                guard async && level == 1 else { continue }
                Benchmark("\(name), async Dispatch", configuration: configuration) { (benchmark: Benchmark) async in
                    let f = fixture.value
                    let input = f.input, buffer = f.buffer
                    for _ in benchmark.scaledIterations {
                        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                        try! await f.encoder.compressAll(input.span.bytes, into: &span, on: queue)
                        blackHole(span.finalize(for: buffer))
                    }
                } setup: { _ = fixture.value }
                Benchmark("\(name), async task group", configuration: configuration) { (benchmark: Benchmark) async in
                    let f = fixture.value
                    let input = f.input, buffer = f.buffer
                    for _ in benchmark.scaledIterations {
                        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                        try! await f.encoder.compressAllConcurrently(input.span.bytes, into: &span)
                        blackHole(span.finalize(for: buffer))
                    }
                } setup: { _ = fixture.value }
            }

            let fixture = Lazy { ParallelDecodeFixture(sample, chunkSize: chunkSize, lanes: lanes) }
            let name = "Parallel inflate \(sample.label): Bytes, \(lanes) lanes"
            Benchmark("\(name), sync", configuration: configuration) { benchmark in
                let f = fixture.value
                for _ in benchmark.scaledIterations {
                    blackHole(parallelDecodeAll(&f.decoder, f.compressed, into: &f.output))
                }
            } setup: { _ = fixture.value }
            if async {
                Benchmark("\(name), async Dispatch", configuration: configuration) { (benchmark: Benchmark) async in
                    let f = fixture.value
                    let compressed = f.compressed, buffer = f.buffer
                    for _ in benchmark.scaledIterations {
                        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                        _ = try! await f.decoder.decompressAll(compressed.span.bytes, into: &span, on: queue)
                        blackHole(span.finalize(for: buffer))
                    }
                } setup: { _ = fixture.value }
            }
            if lanes == performanceCores {
                Benchmark("Parallel inflate \(sample.label): Bytes, sequential", configuration: configuration) { benchmark in
                    let f = fixture.value
                    for _ in benchmark.scaledIterations {
                        blackHole(decodeAll(&f.sequential, f.compressed, into: &f.output))
                    }
                } setup: { _ = fixture.value }
            }
        }

        // Brotli on the performance cores, sync and Dispatch; compare with "Brotli encode qN sample: Bytes".
        for quality in [1, 5] {
            let fixture = Lazy {
                let encoder = ParallelBrotliEncoder(quality: quality, chunkSize: chunkSize, lanes: performanceCores)
                let outputCount = encoder.maximumCompressedSize(forByteCount: sample.byteCount)
                let fixture = ParallelEncodeFixture(input: sample.bytes, encoder: encoder, outputCount: outputCount)
                let count = parallelBrotliEncodeAll(&fixture.encoder, fixture.input, into: &fixture.output)
                precondition(Fixtures.brotliDecodes(fixture.output[..<count], to: fixture.input), "Parallel Brotli: wrong result")
                return fixture
            }
            let name = "Parallel Brotli q\(quality) \(sample.label): Bytes, \(performanceCores) lanes"
            Benchmark("\(name), sync", configuration: configuration) { benchmark in
                let f = fixture.value
                for _ in benchmark.scaledIterations {
                    blackHole(parallelBrotliEncodeAll(&f.encoder, f.input, into: &f.output))
                }
            } setup: { _ = fixture.value }
            guard quality == 1 && sample.name == "samba" else { continue }
            Benchmark("\(name), async Dispatch", configuration: configuration) { (benchmark: Benchmark) async in
                let f = fixture.value
                let input = f.input, buffer = f.buffer
                for _ in benchmark.scaledIterations {
                    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                    try! await f.encoder.compressAll(input.span.bytes, into: &span, on: queue)
                    blackHole(span.finalize(for: buffer))
                }
            } setup: { _ = fixture.value }
        }
    }
}

@inline(__always)
func parallelEncodeAll(_ encoder: inout ParallelDeflateEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

@inline(__always)
func parallelDecodeAll(_ decoder: inout ParallelDeflateDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

@inline(__always)
func parallelBrotliEncodeAll(_ encoder: inout ParallelBrotliEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}
