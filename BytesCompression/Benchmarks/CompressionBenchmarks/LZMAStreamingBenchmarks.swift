import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CLZMA

// Streaming LZMA and xz against the whole-buffer decoders, on the inputs of LZMABenchmarks.swift: Silesia files as
// `xz -6` writes them, and as raw LZMA1 (liblzma's preset 6, 8 MiB dictionary, with an end marker; what ZIP's
// method 14 stores after its header), cached in the corpus directory as `NAME-SIZE.lzma1-5.8-6`.
//
// Streaming rows decode into a 1 MiB output buffer, emptied after every call (what NativeZip does with each
// entry), passing the whole rest of the input each time, or ("64 KiB in") input that grows by 64 KiB whenever the
// decoder asks for more, the unconsumed rest passed again.

final class LZMAStreamFixture {
    let original: [UInt8]
    let xz: [UInt8]
    let raw: [UInt8]
    let properties: LZMAProperties
    var output = [UInt8](repeating: 0, count: 1 << 20)
    var whole: [UInt8]
    var wholeDecoder = LZMA2Decoder()
    var xzDecoder = XZDecoder()
    var lzmaDecoder = LZMADecoder()

    init(_ sample: Fixtures.Sample) {
        original = sample.bytes
        xz = Fixtures.cached("\(sample.name)-\(sample.byteCount).xz-5.8-6") { LZMAFixtures.compress(sample.bytes, preset: 6) }
        raw = Fixtures.cached("\(sample.name)-\(sample.byteCount).lzma1-5.8-6") { lzma1Encode(sample.bytes) }
        properties = try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23)
        whole = [UInt8](repeating: 0, count: sample.byteCount)
    }

    /// Streams with `step` (a decoder's `decompress`), handing each output chunk to `chunk`.
    @inline(__always)
    func stream(
        _ input: [UInt8], inputPiece: Int?, _ step: (RawSpan, inout OutputRawSpan) -> TransformProgress, chunk: ([UInt8], Int) -> Void = { _, _ in }
    ) -> Int {
        var consumed = 0
        var available = inputPiece.map { min($0, input.count) } ?? input.count
        var produced = 0
        while true {
            let progress = output.withOutputRawSpan { span in step(input.span.bytes.extracting(consumed..<available), &span) }
            chunk(output, progress.produced)
            consumed += progress.consumed
            produced += progress.produced
            switch progress.status {
            case .needsOutput: continue
            case .finished where consumed == input.count || inputPiece == nil: return produced
            case .finished, .needsInput:
                guard let inputPiece, available < input.count else { return produced }
                available = min(input.count, available + inputPiece)
            }
        }
    }

    func streamXZ(inputPiece: Int?, chunk: ([UInt8], Int) -> Void = { _, _ in }) -> Int {
        xzDecoder.reset()
        let input = xz
        return stream(input, inputPiece: inputPiece, { input, output in try! xzDecoder.decompress(input, into: &output) }, chunk: chunk)
    }

    func streamLZMA(inputPiece: Int?, chunk: ([UInt8], Int) -> Void = { _, _ in }) -> Int {
        try! lzmaDecoder.reset(properties: properties, uncompressedSize: original.count)
        let input = raw
        return stream(input, inputPiece: inputPiece, { input, output in try! lzmaDecoder.decompress(input, into: &output) }, chunk: chunk)
    }

    func wholeLZMA() -> Int {
        let input = raw
        return whole.withOutputRawSpan { span in
            _ = try! wholeDecoder.decompressAll(input.span.bytes, properties: properties, into: &span, decodedSize: original.count)
            return span.byteCount
        }
    }

    /// Whether streaming decodes the original exactly, chunk by chunk.
    func streams(_ run: (([UInt8], Int) -> Void) -> Int) -> Bool {
        var offset = 0
        var matches = true
        let original = original
        let count = run { chunk, produced in
            matches = matches && offset + produced <= original.count && chunk.prefix(produced).elementsEqual(original[offset..<(offset + produced)])
            offset += produced
        }
        return matches && count == original.count
    }
}

/// liblzma's raw LZMA1 at preset 6 (8 MiB dictionary), with an end marker.
func lzma1Encode(_ data: [UInt8]) -> [UInt8] {
    var options = lzma_options_lzma()
    precondition(lzma_lzma_preset(&options, 6) == 0)
    var output = [UInt8](repeating: 0, count: data.count + data.count / 2 + 1024)
    var size = 0
    let status = withUnsafeMutablePointer(to: &options) { lzma in
        var filters = [lzma_filter(id: 0x4000_0000_0000_0001, options: UnsafeMutableRawPointer(lzma)), lzma_filter(id: .max, options: nil)]
        return data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                lzma_raw_buffer_encode(&filters, nil, input.baseAddress, input.count, out.baseAddress, &size, out.count)
            }
        }
    }
    precondition(status == LZMA_OK)
    return Array(output[..<size])
}

func registerLZMAStreamingBenchmarks() {
    for name in LZMAFixtures.files {
        guard let sample = Fixtures.silesia(name) else { continue }
        let fixture = Lazy { LZMAStreamFixture(sample) }
        let configuration = Fixtures.largeConfiguration
        let label = sample.label
        register("LZMA stream xz -6 \(label): 1 MiB out", configuration: configuration, fixture, check: { f, _ in
            f.streams { f.streamXZ(inputPiece: nil, chunk: $0) }
        }) { f in f.streamXZ(inputPiece: nil) }
        register("LZMA stream raw -6 \(label): whole", configuration: configuration, fixture, check: { f, count in
            count == f.original.count && f.whole == f.original
        }) { f in f.wholeLZMA() }
        register("LZMA stream raw -6 \(label): 1 MiB out", configuration: configuration, fixture, check: { f, _ in
            f.streams { f.streamLZMA(inputPiece: nil, chunk: $0) }
        }) { f in f.streamLZMA(inputPiece: nil) }
        guard name == "dickens" || name == "x-ray" else { continue }
        register("LZMA stream xz -6 \(label): 1 MiB out, 64 KiB in", configuration: configuration, fixture, check: { f, _ in
            f.streams { f.streamXZ(inputPiece: 1 << 16, chunk: $0) }
        }) { f in f.streamXZ(inputPiece: 1 << 16) }
        register("LZMA stream raw -6 \(label): 1 MiB out, 64 KiB in", configuration: configuration, fixture, check: { f, _ in
            f.streams { f.streamLZMA(inputPiece: 1 << 16, chunk: $0) }
        }) { f in f.streamLZMA(inputPiece: 1 << 16) }
    }
    // Zero mallocs once the decoders exist (the windows are made by setup's checked run).
    let gate = Lazy {
        LZMAStreamFixture(Fixtures.Sample(name: "gate", bytes: Fixtures.gateContent()))
    }
    register("Allocations:LZMA_stream_xz", configuration: Fixtures.allocationConfiguration, gate, check: { f, _ in
        f.streams { f.streamXZ(inputPiece: 1 << 12, chunk: $0) }
    }) { f in f.streamXZ(inputPiece: 1 << 12) }
    register("Allocations:LZMA_stream_raw", configuration: Fixtures.allocationConfiguration, gate, check: { f, _ in
        f.streams { f.streamLZMA(inputPiece: 1 << 12, chunk: $0) }
    }) { f in f.streamLZMA(inputPiece: 1 << 12) }
}
