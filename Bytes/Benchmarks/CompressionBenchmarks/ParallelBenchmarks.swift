import Benchmark
import Bytes
import BytesAsync
import BytesCompression
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

/// The large samples, plus a 256 KB slice of dickens, where a round's fixed costs show.
private let parallelSamples: [Fixtures.Sample] = {
    var samples = Fixtures.samples.filter { $0.bytes.count >= 1 << 20 && $0.name != "x-ray" }
    if let dickens = Fixtures.samples.first(where: { $0.name == "dickens" }) {
        samples.append(Fixtures.Sample(name: "dickens", bytes: Array(dickens.bytes.prefix(256 << 10))))
    }
    return samples
}()

/// An output buffer for the async forms, which can't borrow an array across a suspension: allocated once,
/// never freed (the benchmark process registers it for its whole life).
private func outputBuffer(_ byteCount: Int) -> UnsafeMutableRawBufferPointer {
    UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 64)
}

/// Compresses each large sample with the parallel DEFLATE encoder on `performanceCores` and 8 lanes, at levels
/// 1 and 6, in each of its three forms: synchronous (`concurrentPerform` rounds), async on a Dispatch queue,
/// and async as task groups. Raw format, 256 KB chunks (64 KB for the 256 KB input, so it fills 4 lanes).
/// Compare with the sequential "Deflate N sample: Bytes" rows.
///
/// Then decodes an independent-chunk encoding of each (level 6) with the parallel decoder and, for
/// reference, the sequential one.
func registerParallelBenchmarks() {
    let queue = DispatchQueue(label: "compression")
    for sample in parallelSamples {
        let chunkSize = sample.bytes.count <= 256 << 10 ? 64 << 10 : 256 << 10
        for lanes in Set([performanceCores, 8]).sorted(by: >) {
            for level in [1, 6] {
                var encoder = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: chunkSize, lanes: lanes)
                var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: sample.bytes.count))
                let buffer = outputBuffer(output.count)
                precondition(parallelEncodeAll(&encoder, sample.bytes, into: &output) > 0)
                let name = "Parallel deflate \(level) \(sample.label): Bytes, \(lanes) lanes"
                Benchmark("\(name), sync") { benchmark in
                    for _ in benchmark.scaledIterations {
                        blackHole(parallelEncodeAll(&encoder, sample.bytes, into: &output))
                    }
                }
                Benchmark("\(name), async Dispatch") { (benchmark: Benchmark) async in
                    for _ in benchmark.scaledIterations {
                        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                        try! await encoder.compressAll(sample.bytes.span.bytes, into: &span, on: queue)
                        blackHole(span.finalize(for: buffer))
                    }
                }
                Benchmark("\(name), async task group") { (benchmark: Benchmark) async in
                    for _ in benchmark.scaledIterations {
                        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                        try! await encoder.compressAllConcurrently(sample.bytes.span.bytes, into: &span)
                        blackHole(span.finalize(for: buffer))
                    }
                }
            }

            // Independent chunks, so the decoder can split the stream.
            var independent = ParallelDeflateEncoder(format: .raw, level: 6, chunkSize: chunkSize, lanes: lanes, independentChunks: true)
            var scratch = [UInt8](repeating: 0, count: independent.maximumCompressedSize(forByteCount: sample.bytes.count))
            // (The size into a local first: `scratch.prefix(encode(into: &scratch))` reads `scratch` before
            // the encoder writes it.)
            let compressedSize = parallelEncodeAll(&independent, sample.bytes, into: &scratch)
            let compressed = Array(scratch.prefix(compressedSize))
            var output = [UInt8](repeating: 0, count: sample.bytes.count + 64)
            var decoder = ParallelDeflateDecoder(format: .raw, lanes: lanes)
            precondition(parallelDecodeAll(&decoder, compressed, into: &output) == sample.bytes.count
                && Array(output.prefix(sample.bytes.count)) == sample.bytes && decoder.lastSegmentCount > 1)
            let buffer = outputBuffer(output.count)
            let name = "Parallel inflate \(sample.label): Bytes, \(lanes) lanes"
            Benchmark("\(name), sync") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(parallelDecodeAll(&decoder, compressed, into: &output))
                }
            }
            Benchmark("\(name), async Dispatch") { (benchmark: Benchmark) async in
                for _ in benchmark.scaledIterations {
                    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                    _ = try! await decoder.decompressAll(compressed.span.bytes, into: &span, on: queue)
                    blackHole(span.finalize(for: buffer))
                }
            }
            if lanes == performanceCores {
                var sequential = DeflateDecoder(format: .raw)
                Benchmark("Parallel inflate \(sample.label): Bytes, sequential") { benchmark in
                    for _ in benchmark.scaledIterations {
                        blackHole(decodeAll(&sequential, compressed, into: &output))
                    }
                }
            }
        }

        // Brotli on the performance cores, sync and Dispatch; compare with "Brotli encode qN sample: Bytes".
        for quality in [1, 5] {
            var encoder = ParallelBrotliEncoder(quality: quality, chunkSize: chunkSize, lanes: performanceCores)
            var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: sample.bytes.count))
            let buffer = outputBuffer(output.count)
            precondition(parallelBrotliEncodeAll(&encoder, sample.bytes, into: &output) > 0)
            let name = "Parallel Brotli q\(quality) \(sample.label): Bytes, \(performanceCores) lanes"
            Benchmark("\(name), sync") { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(parallelBrotliEncodeAll(&encoder, sample.bytes, into: &output))
                }
            }
            Benchmark("\(name), async Dispatch") { (benchmark: Benchmark) async in
                for _ in benchmark.scaledIterations {
                    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                    try! await encoder.compressAll(sample.bytes.span.bytes, into: &span, on: queue)
                    blackHole(span.finalize(for: buffer))
                }
            }
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
