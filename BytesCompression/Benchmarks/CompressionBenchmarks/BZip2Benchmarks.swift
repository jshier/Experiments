import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CBZip2
import Foundation

// bzip2 decoding: Bytes' `BZip2Decoder` against libbzip2 1.0.8 (macOS's, `BZ2_bzBuffToBuffDecompress`),
// single-threaded, one call each, whole stream into an exactly sized buffer.
//
// Inputs: Silesia files compressed as `bzip2 -9` writes them (libbzip2's `BZ2_bzBuffToBuffCompress` at level 9, cached
// in the corpus directory as `NAME-SIZE.bzip2-1.0.8-9`), and two JSON responses (1.6 KB and 119 KB), the small
// inputs where per-block setup counts.

enum BZip2Fixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// libbzip2's encoding of `data` at `level`.
    static func compress(_ data: [UInt8], level: Int32) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + data.count / 100 + 600)
        var length = UInt32(output.count)
        var input = data
        let status = input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                BZ2_bzBuffToBuffCompress(
                    UnsafeMutableRawPointer(output.baseAddress!).assumingMemoryBound(to: CChar.self), &length,
                    UnsafeMutableRawPointer(input.baseAddress!).assumingMemoryBound(to: CChar.self), UInt32(data.count), level, 0, 0
                )
            }
        }
        precondition(status == BZ_OK)
        return Array(output[..<Int(length)])
    }

    /// The inputs: Silesia files present in the corpus, and the JSON responses.
    static func samples() -> [Fixtures.Sample] {
        files.compactMap { Fixtures.silesia($0) } + Fixtures.samples.filter { $0.name == "JSON" }
    }
}

/// libbzip2's one-call decoder.
func libbz2Decode(_ input: [UInt8], into output: inout [UInt8]) -> Int {
    var length = UInt32(output.count)
    var input = input
    let status = input.withUnsafeMutableBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            BZ2_bzBuffToBuffDecompress(
                UnsafeMutableRawPointer(output.baseAddress!).assumingMemoryBound(to: CChar.self), &length,
                UnsafeMutableRawPointer(input.baseAddress!).assumingMemoryBound(to: CChar.self), UInt32(input.count), 0, 0
            )
        }
    }
    precondition(status == BZ_OK)
    return Int(length)
}

@inline(__always)
func bzip2Decode(_ decoder: inout BZip2Decoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Registers both decoders on each input; each benchmark's setup checks that its decoder decodes it exactly.
func registerBZip2Benchmarks() {
    for sample in BZip2Fixtures.samples() {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy {
            let compressed = Fixtures.cached("\(sample.name)-\(sample.byteCount).bzip2-1.0.8-9") {
                BZip2Fixtures.compress(sample.bytes, level: 9)
            }
            return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: sample.byteCount, decoder: BZip2Decoder())
        }
        register("BZip2 decode -9 \(sample.label): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            bzip2Decode(&f.decoder, f.compressed, into: &f.output)
        }
        register("BZip2 decode -9 \(sample.label): libbz2", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
            libbz2Decode(f.compressed, into: &f.output)
        }
    }
}

/// Allocation check: decoding allocates nothing once a decoder exists (two concatenated streams, the first of two
/// blocks). Zero threshold in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:BZip2.*'
func registerBZip2AllocationBenchmarks() {
    let fixture = Lazy {
        let content = Fixtures.json(count: 1_200) + [UInt8](repeating: 0x20, count: 5_000) + Fixtures.json(count: 16)
        let compressed = BZip2Fixtures.compress(content, level: 1) + BZip2Fixtures.compress(Array(content.prefix(70_000)), level: 9)
        let expected = content + content.prefix(70_000)
        return DecodeFixture(original: expected, compressed: compressed, outputCount: expected.count, decoder: BZip2Decoder())
    }
    register("Allocations:BZip2_decode", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decodedAll($1) }) { f in
        bzip2Decode(&f.decoder, f.compressed, into: &f.output)
    }
}
