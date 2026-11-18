import Benchmark
import Bytes
import BytesCompression
import CLZMA
import Compression
import Foundation

// .xz decoding: Bytes' `LZMA2Decoder` against liblzma 5.8 (Homebrew's XZ Utils) and Apple's Compression
// (`COMPRESSION_LZMA`), single-threaded, one call each, whole file into a whole buffer.
//
// Inputs: Silesia files compressed as `xz -6` and `xz -9e` would (liblzma's preset encoder, CRC-64 checks, which
// all three decoders verify; cached in the corpus directory as `NAME-SIZE.xz-5.8-PRESET`), and segments of
// Apple's `.aea` archives (Xcode's payload: 16 MB xz streams, LZMA2 with an 8 MB dictionary, no check), which
// are local only: copy them to `CORPUS/aea/seg*.xz` and they're registered.

/// liblzma's one-call decoder: `lzma_stream_buffer_decode`.
func liblzmaDecode(_ input: [UInt8], into output: inout [UInt8]) -> Int {
    var memoryLimit: UInt64 = .max
    var inputPosition = 0
    var outputPosition = 0
    let status = input.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            lzma_stream_buffer_decode(&memoryLimit, 0, nil, input.baseAddress, &inputPosition, input.count, output.baseAddress, &outputPosition, output.count)
        }
    }
    precondition(status == LZMA_OK)
    return outputPosition
}

/// Apple's Compression, one call, with a scratch buffer allocated once.
final class AppleLZMA {
    private let scratch = UnsafeMutableRawPointer.allocate(byteCount: compression_decode_scratch_buffer_size(COMPRESSION_LZMA), alignment: 64)

    deinit { scratch.deallocate() }

    func decode(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, scratch, COMPRESSION_LZMA)
            }
        }
    }
}

enum LZMAFixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// liblzma's `.xz` encoding at `preset` (with 0x8000_0000 for `-e`), CRC-64 checks: what `xz -PRESET` writes.
    static func compress(_ data: [UInt8], preset: UInt32) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: lzma_stream_buffer_bound(data.count))
        var size = 0
        let status = data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                lzma_easy_buffer_encode(preset, LZMA_CHECK_CRC64, nil, input.baseAddress, input.count, output.baseAddress, &size, output.count)
            }
        }
        precondition(status == LZMA_OK)
        return Array(output[..<size])
    }

    /// The `.aea` segments in the corpus directory, by name.
    static func appleSegments() -> [(name: String, bytes: [UInt8])] {
        let directory = Fixtures.corpusRoot.appending(path: "aea")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".xz") }.sorted().compactMap { name in
            FileManager.default.contents(atPath: directory.appending(path: name).path).map { (String(name.dropLast(3)), [UInt8]($0)) }
        }
    }
}

/// Decodes a whole `.xz` file into `output` with `decompressXZ`.
@inline(__always)
func lzmaDecodeXZ(_ decoder: inout LZMA2Decoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressXZ(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Registers the three decoders on each input, after checking that each decodes it exactly.
func registerLZMABenchmarks() {
    var decoder = LZMA2Decoder()
    let apple = AppleLZMA()
    var inputs: [(label: String, compressed: [UInt8], size: Int)] = []
    for name in LZMAFixtures.files {
        guard let sample = ZstdFixtures.silesia(name) else { continue }
        for (label, key, preset) in [("-6", "6", UInt32(6)), ("-9e", "9e", 9 | 0x8000_0000)] {
            let compressed = Fixtures.cached("\(name)-\(sample.bytes.count).xz-5.8-\(key)") {
                LZMAFixtures.compress(sample.bytes, preset: preset)
            }
            inputs.append(("\(label) \(sample.label)", compressed, sample.bytes.count))
        }
    }
    for (name, compressed) in LZMAFixtures.appleSegments() {
        var output = [UInt8](repeating: 0, count: 64 << 20)
        let size = liblzmaDecode(compressed, into: &output)
        inputs.append(("Apple \(name) (16.0 MB)", compressed, size))
    }
    for (label, compressed, size) in inputs {
        var output = [UInt8](repeating: 0, count: size)
        var reference = [UInt8](repeating: 0, count: size)
        precondition(liblzmaDecode(compressed, into: &reference) == size)
        precondition(lzmaDecodeXZ(&decoder, compressed, into: &output) == size && output == reference, "Bytes: \(label)")
        precondition(apple.decode(compressed, into: &output) == size && output == reference, "Compression: \(label)")
        Benchmark("LZMA decode \(label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(lzmaDecodeXZ(&decoder, compressed, into: &output))
            }
        }
        Benchmark("LZMA decode \(label): liblzma") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(liblzmaDecode(compressed, into: &output))
            }
        }
        Benchmark("LZMA decode \(label): Compression") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(apple.decode(compressed, into: &output))
            }
        }
    }
}

/// Allocation checks: decoding allocates nothing once a decoder exists, `.xz` (CRC-64 checks) or raw LZMA2.
/// Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:LZMA.*'
func registerLZMAAllocationBenchmarks() {
    let configuration = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    let content = Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16))
    var output = [UInt8](repeating: 0, count: content.count)
    var decoder = LZMA2Decoder()
    for preset: UInt32 in [0, 6] {
        let compressed = LZMAFixtures.compress(content, preset: preset)
        precondition(lzmaDecodeXZ(&decoder, compressed, into: &output) == content.count && output == content)
        Benchmark("Allocations:LZMA_decode_xz_\(preset)", configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(lzmaDecodeXZ(&decoder, compressed, into: &output))
            }
        }
    }
}
