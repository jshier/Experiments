import Benchmark
import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import Compression
import Foundation

// LZ4, LZFSE, and LZVN decoding: Bytes' `LZ4Decoder`, `LZFSEDecoder`, and `LZVNDecoder` against Apple's
// Compression (`COMPRESSION_LZ4_RAW`, `COMPRESSION_LZ4`, `COMPRESSION_LZFSE`, and raw LZVN, the undocumented
// algorithm 0x900), single-threaded,
// one call each, whole stream into an exactly sized buffer. (The lzfse reference's decoders were compared here until
// 2026-11-19, then removed: RESULTS-lz4-lzfse.md has the last comparison and how to build it again.)
//
// Inputs: Silesia files and a small JSON response, encoded by Compression (LZ4 and LZFSE) and by the reference's
// LZVN parse (`LZVNEncoder` writes its bytes), cached in the corpus directory as `NAME-SIZE.apple-ALGORITHM` and
// `NAME-SIZE.lzvn-ref`.

enum LZFixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// Compression's encoding of `data` with `algorithm`.
    static func appleEncode(_ data: [UInt8], _ algorithm: compression_algorithm) -> [UInt8] {
        // Qualified: References.swift's `AppleCompression` is the benchmarked coder.
        BytesReferenceCodecs.AppleCompression.encode(data, algorithm)
    }

    /// The lzfse reference's raw LZVN encoding of `data`, as `LZVNEncoder` writes it with that parse.
    static func lzvnEncode(_ data: [UInt8]) -> [UInt8] {
        var encoder = LZVNEncoder(parse: .reference)
        var output = [UInt8](repeating: 0, count: LZVNEncoder.maximumCompressedSize(forByteCount: data.count))
        let size = output.withOutputRawSpan { span in
            try! encoder.compressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        return Array(output[..<size])
    }

    /// The inputs: Silesia files present in the corpus, and the 1.6 KB JSON response.
    static func samples() -> [Fixtures.Sample] {
        files.compactMap { Fixtures.silesia($0) } + [Fixtures.Sample(name: "JSON", bytes: Fixtures.json(count: 16))]
    }
}

@inline(__always)
func lz4DecodeRaw(_ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        try! LZ4Decoder().decompressRaw(input.span.bytes, into: &span, decodedSize: span.capacity)
        return span.byteCount
    }
}

@inline(__always)
func lz4DecodeFramed(_ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! LZ4Decoder().decompressFramed(input.span.bytes, into: &span)
        return span.byteCount
    }
}

@inline(__always)
func lzfseDecode(_ decoder: inout LZFSEDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

@inline(__always)
func lzvnDecode(_ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! LZVNDecoder().decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Each sample's encodings, and an output buffer of exactly its size.
final class LZDecodeFixture {
    let original: [UInt8]
    let lz4Raw: [UInt8]
    let lz4: [UInt8]
    let lzfse: [UInt8]
    let lzvn: [UInt8]
    var output: [UInt8]
    var decoder = LZFSEDecoder()

    init(_ sample: Fixtures.Sample) {
        let key = "\(sample.name)-\(sample.byteCount)"
        original = sample.bytes
        lz4Raw = Fixtures.cached("\(key).apple-lz4raw") { LZFixtures.appleEncode(sample.bytes, COMPRESSION_LZ4_RAW) }
        lz4 = Fixtures.cached("\(key).apple-lz4") { LZFixtures.appleEncode(sample.bytes, COMPRESSION_LZ4) }
        lzfse = Fixtures.cached("\(key).apple-lzfse") { LZFixtures.appleEncode(sample.bytes, COMPRESSION_LZFSE) }
        lzvn = Fixtures.cached("\(key).lzvn-ref") { LZFixtures.lzvnEncode(sample.bytes) }
        output = [UInt8](repeating: 0, count: sample.byteCount)
    }

    /// Whether `produced` is the original's size and the output is the original; clears the output for the next check.
    func decoded(_ produced: Int) -> Bool {
        defer { output.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        return produced == original.count && output == original
    }
}

/// Registers each decoder on each input; each benchmark's setup checks that its decoder decodes the input exactly.
func registerLZBenchmarks() {
    let appleLZ4Raw = Lazy { AppleCompression(algorithm: COMPRESSION_LZ4_RAW) }
    let appleLZ4 = Lazy { AppleCompression(algorithm: COMPRESSION_LZ4) }
    let appleLZFSE = Lazy { AppleCompression(algorithm: COMPRESSION_LZFSE) }
    let appleLZVN = Lazy { AppleCompression(algorithm: ReferenceLZEncoders.lzvn) }
    for sample in LZFixtures.samples() {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy { LZDecodeFixture(sample) }
        let check = { (f: LZDecodeFixture, produced: Int) in f.decoded(produced) }
        register("LZ4 raw decode \(sample.label): Bytes", configuration: configuration, fixture, check: check) { f in
            lz4DecodeRaw(f.lz4Raw, into: &f.output)
        }
        register("LZ4 raw decode \(sample.label): Compression", configuration: configuration, fixture, check: check) { f in
            appleLZ4Raw.value.decompress(f.lz4Raw, into: &f.output)
        }
        register("LZ4 framed decode \(sample.label): Bytes", configuration: configuration, fixture, check: check) { f in
            lz4DecodeFramed(f.lz4, into: &f.output)
        }
        register("LZ4 framed decode \(sample.label): Compression", configuration: configuration, fixture, check: check) { f in
            appleLZ4.value.decompress(f.lz4, into: &f.output)
        }
        register("LZFSE decode \(sample.label): Bytes", configuration: configuration, fixture, check: check) { f in
            lzfseDecode(&f.decoder, f.lzfse, into: &f.output)
        }
        register("LZFSE decode \(sample.label): Compression", configuration: configuration, fixture, check: check) { f in
            appleLZFSE.value.decompress(f.lzfse, into: &f.output)
        }
        register("LZVN decode \(sample.label): Bytes", configuration: configuration, fixture, check: check) { f in
            lzvnDecode(f.lzvn, into: &f.output)
        }
        // Compression's raw LZVN (APFS `decmpfs` type 8), undocumented: setup's check is the proof it decodes these streams.
        register("LZVN decode \(sample.label): Compression", configuration: configuration, fixture, check: check) { f in
            appleLZVN.value.decompress(f.lzvn, into: &f.output)
        }
    }
}

/// Allocation checks: decoding allocates nothing once a decoder exists. Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:(LZ4|LZFSE|LZVN).*'
func registerLZAllocationBenchmarks() {
    let configuration = Fixtures.allocationConfiguration
    // Large enough for several LZFSE and LZ4 blocks; the JSON's 1.6 KB is LZFSE's LZVN-block size.
    let content = Lazy { Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16)) }
    func fixture(_ encode: @escaping ([UInt8]) -> [UInt8], small: Bool = false) -> Lazy<DecodeFixture<LZFSEDecoder>> {
        Lazy {
            let original = small ? Fixtures.json(count: 16) : content.value
            return DecodeFixture(original: original, compressed: encode(original), outputCount: original.count, decoder: LZFSEDecoder())
        }
    }
    let check = { (f: DecodeFixture<LZFSEDecoder>, produced: Int) in f.decodedAll(produced) }
    register("Allocations:LZ4_decode_raw", configuration: configuration, fixture { LZFixtures.appleEncode($0, COMPRESSION_LZ4_RAW) }, check: check) { f in
        lz4DecodeRaw(f.compressed, into: &f.output)
    }
    register("Allocations:LZ4_decode_framed", configuration: configuration, fixture { LZFixtures.appleEncode($0, COMPRESSION_LZ4) }, check: check) { f in
        lz4DecodeFramed(f.compressed, into: &f.output)
    }
    register("Allocations:LZFSE_decode", configuration: configuration, fixture { LZFixtures.appleEncode($0, COMPRESSION_LZFSE) }, check: check) { f in
        lzfseDecode(&f.decoder, f.compressed, into: &f.output)
    }
    register(
        "Allocations:LZFSE_decode_small", configuration: configuration, fixture({ LZFixtures.appleEncode($0, COMPRESSION_LZFSE) }, small: true),
        check: check
    ) { f in
        lzfseDecode(&f.decoder, f.compressed, into: &f.output)
    }
    register("Allocations:LZVN_decode", configuration: configuration, fixture { LZFixtures.lzvnEncode($0) }, check: check) { f in
        lzvnDecode(f.compressed, into: &f.output)
    }
}
