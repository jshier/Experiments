import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Foundation

// LZRAVEN decoding (`COMPRESSION_LZRAVEN`, macOS 27): Bytes' `LZRAVENDecoder` against Apple's Compression, one
// call each, whole buffer into a whole buffer. Inputs are the corpus samples encoded by Compression (slow,
// about 3 MB/s, so cached in the corpus directory as `NAME-SIZE.lzraven-macos27`), whole, and Silesia's mozilla
// as Apple Encrypted Archive segments would be (16 MiB).

/// Apple's Compression, one call, with a scratch buffer allocated once.
final class AppleLZRAVEN {
    private let scratch = UnsafeMutableRawPointer.allocate(
        byteCount: compression_decode_scratch_buffer_size(COMPRESSION_LZRAVEN), alignment: 64
    )

    deinit { scratch.deallocate() }

    func decode(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, scratch, COMPRESSION_LZRAVEN)
            }
        }
    }

    static func encode(_ data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + data.count / 8 + 4096)
        let size = data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                compression_encode_buffer(out.baseAddress!, out.count, input.baseAddress!, input.count, nil, COMPRESSION_LZRAVEN)
            }
        }
        precondition(size > 0)
        return Array(output[..<size])
    }
}

/// Decodes a whole LZRAVEN buffer into `output`, which is exactly its size.
@inline(__always)
func lzravenDecode(_ decoder: inout LZRAVENDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    let count = output.count
    return output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, decodedSize: count, into: &span)
        return span.byteCount
    }
}

enum LZRAVENFixtures {
    /// The inputs: each sample, and mozilla's first 16 MiB.
    static func inputs() -> [(label: String, sample: Fixtures.Sample)] {
        var inputs = Fixtures.samples.map { ($0.label, $0) }
        if let segment = Fixtures.silesia("mozilla", limit: 16 << 20) {
            inputs.append(("mozilla segment (16.0 MB)", segment))
        }
        return inputs
    }
}

/// Registers both decoders on each input; each benchmark's setup checks that its decoder decodes it exactly.
func registerLZRAVENBenchmarks() {
    let apple = Lazy { AppleLZRAVEN() }
    for (label, sample) in LZRAVENFixtures.inputs() {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy {
            let compressed = Fixtures.cached("\(sample.name)-\(sample.byteCount).lzraven-macos27") { AppleLZRAVEN.encode(sample.bytes) }
            return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: sample.byteCount, decoder: LZRAVENDecoder())
        }
        register("LZRAVEN decode \(label): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            lzravenDecode(&f.decoder, f.compressed, into: &f.output)
        }
        register("LZRAVEN decode \(label): Compression", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            apple.value.decode(f.compressed, into: &f.output)
        }
    }
}

/// Allocation check: decoding allocates nothing once a decoder exists (coded and stored blocks, both
/// filters' flags). Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:LZRAVEN.*'
func registerLZRAVENAllocationBenchmarks() {
    let fixture = Lazy {
        var generator = SplitMix64(seed: 3)
        let random = (0..<600_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        let content = Array(Fixtures.json(count: 1_200)) + random + Array(Fixtures.json(count: 16))
        return DecodeFixture(original: content, compressed: AppleLZRAVEN.encode(content), outputCount: content.count, decoder: LZRAVENDecoder())
    }
    register("Allocations:LZRAVEN_decode", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decodedAll($1) }) { f in
        lzravenDecode(&f.decoder, f.compressed, into: &f.output)
    }
}
