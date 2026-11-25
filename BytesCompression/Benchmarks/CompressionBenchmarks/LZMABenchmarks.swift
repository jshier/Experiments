import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CLZMA
import Compression
import Foundation

// .xz decoding: Bytes' `LZMA2Decoder` against liblzma 5.8 (Homebrew's XZ Utils) and Apple's Compression
// (`COMPRESSION_LZMA`), single-threaded, one call each, whole file into a whole buffer.
//
// Inputs: Silesia files compressed as `xz -6` would (liblzma's preset encoder, CRC-64 checks, which
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

    /// The names of the `.aea` segments in the corpus directory.
    static func appleSegmentNames() -> [String] {
        let directory = Fixtures.corpusRoot.appending(path: "aea")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".xz") }.sorted().map { String($0.dropLast(3)) }
    }

    /// The `.aea` segment `name`.
    static func appleSegment(_ name: String) -> [UInt8] {
        [UInt8](FileManager.default.contents(atPath: Fixtures.corpusRoot.appending(path: "aea/\(name).xz").path)!)
    }
}

/// Decodes a whole `.xz` file into `output` with `decompressAll(_:into:)`.
@inline(__always)
func lzmaDecodeXZ(_ decoder: inout LZMA2Decoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Registers the three decoders on each input; each benchmark's setup checks that its decoder decodes the input
/// exactly (liblzma's output being the reference for Apple's segments).
func registerLZMABenchmarks() {
    var inputs: [(label: String, fixture: Lazy<DecodeFixture<LZMA2Decoder>>)] = []
    for name in LZMAFixtures.files {
        guard let sample = Fixtures.silesia(name) else { continue }
        // (`-9e` decoded at `-6`'s rate, RESULTS.md's LZMA table: its rows were retired on 2026-11-19, with the Apple
        // segments seg130 and seg200.)
        for (label, key, preset) in [("-6", "6", UInt32(6))] {
            let fixture = Lazy {
                let compressed = Fixtures.cached("\(name)-\(sample.byteCount).xz-5.8-\(key)") {
                    LZMAFixtures.compress(sample.bytes, preset: preset)
                }
                return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: sample.byteCount, decoder: LZMA2Decoder())
            }
            inputs.append(("\(label) \(sample.label)", fixture))
        }
    }
    for name in LZMAFixtures.appleSegmentNames() where !["seg130", "seg200"].contains(name) {
        let fixture = Lazy {
            let compressed = LZMAFixtures.appleSegment(name)
            var reference = [UInt8](repeating: 0, count: 64 << 20)
            reference.removeLast(reference.count - liblzmaDecode(compressed, into: &reference))
            return DecodeFixture(original: reference, compressed: compressed, outputCount: reference.count, decoder: LZMA2Decoder())
        }
        inputs.append(("Apple \(name) (16.0 MB)", fixture))
    }
    let apple = Lazy { AppleLZMA() }
    for (label, fixture) in inputs {
        let configuration = Fixtures.largeConfiguration
        register("LZMA decode \(label): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            lzmaDecodeXZ(&f.decoder, f.compressed, into: &f.output)
        }
        register("LZMA decode \(label): liblzma", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            liblzmaDecode(f.compressed, into: &f.output)
        }
        register("LZMA decode \(label): Compression", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            apple.value.decode(f.compressed, into: &f.output)
        }
    }
}

/// Allocation checks: decoding allocates nothing once a decoder exists, `.xz` (CRC-64 checks) or raw LZMA2.
/// Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:LZMA.*'
func registerLZMAAllocationBenchmarks() {
    for preset: UInt32 in [0, 6] {
        let fixture = Lazy {
            let content = Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16))
            return DecodeFixture(
                original: content, compressed: LZMAFixtures.compress(content, preset: preset), outputCount: content.count, decoder: LZMA2Decoder()
            )
        }
        register("Allocations:LZMA_decode_xz_\(preset)", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decodedAll($1) }) { f in
            lzmaDecodeXZ(&f.decoder, f.compressed, into: &f.output)
        }
    }
}
