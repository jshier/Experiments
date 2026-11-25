import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Foundation

// LZFSE and LZVN encoding: Bytes' `LZFSEEncoder` and `LZVNEncoder` against Apple's Compression (`COMPRESSION_LZFSE`,
// and raw LZVN: the undocumented algorithm 0x900), which write the same streams (checked in the tests). Bytes' LZVN
// also with the lzfse reference's parse ("Bytes, reference parse"), the default until 2026-11-19, to compare code
// with the earlier baselines (on the JSON and dickens' 64 KB pieces since 2026-11-19). Single-threaded, one call per stream, each encoder's scratch state made once, into a
// buffer with room for any stream. (The lzfse reference's encoders were compared here until 2026-11-19, then removed:
// RESULTS-lz4-lzfse.md has the last comparison and how to build it again; the tests check that Bytes writes its
// streams, by digest.)
//
// Two shapes, from where the formats are used:
// - "16 MB": the first 16 MiB of a Silesia file (or all of it) as one stream, as an Apple Encrypted Archive segment
//   holds;
// - "64 KB × 16": the first 1 MiB as 16 independent 64 KiB streams, as an APFS-compressed file's resource fork
//   (decmpfs types 11 and 12) holds; each iteration encodes all 16.
// And the 1.6 KB JSON response, which LZFSE writes as an LZVN block. Throughput: iterations per second times the
// bytes per iteration.

enum LZEncodeFixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// The inputs: each shape of each Silesia file present (its pieces made on first use), and the small JSON.
    static func shapes() -> [(label: String, byteCount: Int, pieces: Lazy<[[UInt8]]>)] {
        var shapes: [(String, Int, Lazy<[[UInt8]]>)] = []
        for name in files {
            guard let large = Fixtures.silesia(name, limit: 16 << 20), let small = Fixtures.silesia(name, limit: 1 << 20) else { continue }
            shapes.append((large.label, large.byteCount, Lazy { [large.bytes] }))
            shapes.append(("\(name) (64 KB × 16)", small.byteCount, Lazy { lzbitmapPieces(small.bytes, piece: 1 << 16).map(Array.init) }))
        }
        let json = Fixtures.Sample(name: "JSON", bytes: Fixtures.json(count: 16))
        shapes.append((json.label, json.byteCount, Lazy { [json.bytes] }))
        // Already-compressed data, as APFS meets it: chunks that don't compress.
        shapes.append(("random (64 KB × 16)", 1 << 20, Lazy { lzbitmapPieces(Fixtures.random.bytes, piece: 1 << 16).map(Array.init) }))
        return shapes
    }
}

/// Apple's Compression, one call per stream, its scratch buffer allocated once.
final class ReferenceLZEncoders {
    /// Raw LZVN (`compression_encode_buffer`'s algorithm 0x900, APFS `decmpfs` type 8).
    static let lzvn = compression_algorithm(rawValue: 0x900)

    private let appleScratch = UnsafeMutableRawPointer.allocate(
        byteCount: max(compression_encode_scratch_buffer_size(COMPRESSION_LZFSE), compression_encode_scratch_buffer_size(lzvn), 1),
        alignment: 64
    )

    deinit {
        appleScratch.deallocate()
    }

    /// Encodes each piece into `output` (each over the last) with `algorithm`, returning the bytes written in all.
    func apple(_ pieces: [[UInt8]], into output: inout [UInt8], algorithm: compression_algorithm = COMPRESSION_LZFSE) -> Int {
        output.withUnsafeMutableBufferPointer { output in
            var total = 0
            for piece in pieces {
                total += piece.withUnsafeBufferPointer { input in
                    compression_encode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, appleScratch, algorithm)
                }
            }
            return total
        }
    }
}

/// Bytes' LZFSE encoding of each piece into `output` (each over the last): the bytes written in all.
@inline(__always)
func lzfseEncodeAll(_ encoder: inout LZFSEEncoder, _ pieces: [[UInt8]], into output: inout [UInt8]) -> Int {
    var total = 0
    for piece in pieces {
        total += output.withOutputRawSpan { span in
            try! encoder.compressAll(piece.span.bytes, into: &span)
            return span.byteCount
        }
    }
    return total
}

/// Bytes' LZVN encoding of each piece into `output` (each over the last): the bytes written in all.
@inline(__always)
func lzvnEncodeAll(_ encoder: inout LZVNEncoder, _ pieces: [[UInt8]], into output: inout [UInt8]) -> Int {
    var total = 0
    for piece in pieces {
        total += output.withOutputRawSpan { span in
            try! encoder.compressAll(piece.span.bytes, into: &span)
            return span.byteCount
        }
    }
    return total
}

/// The streams `body` writes for each piece, kept.
func lzStreams(_ pieces: [[UInt8]], capacity: Int, _ body: ([UInt8], inout [UInt8]) -> Int) -> [[UInt8]] {
    pieces.map { piece in
        var output = [UInt8](repeating: 0, count: capacity)
        let size = body(piece, &output)
        return Array(output[..<size])
    }
}

/// A shape's pieces, an output buffer with room for any piece's stream, and each encoder.
final class LZEncodeFixture {
    let pieces: [[UInt8]]
    var output: [UInt8]
    var lzfseEncoder = LZFSEEncoder()
    var lzvnEncoder = LZVNEncoder()
    var lzvnReferenceEncoder = LZVNEncoder(parse: .reference)
    let references = ReferenceLZEncoders()

    init(pieces: [[UInt8]]) {
        self.pieces = pieces
        let largest = pieces.map(\.count).max()!
        output = [UInt8](repeating: 0, count: max(LZFSEEncoder.maximumCompressedSize(forByteCount: largest), LZVNEncoder.maximumCompressedSize(forByteCount: largest)))
    }

    /// Whether `encode`'s stream for each piece decodes back with `decode`, and (for a shape of pieces of 64 KiB or less)
    /// whether the first piece's stream is Compression's with `algorithm` (if one is given). Compression's streams are
    /// Bytes' for the whole corpus: the tests check that.
    func roundTrips(
        _ encode: (LZEncodeFixture, [UInt8], inout [UInt8]) -> Int, decode: ([UInt8], inout [UInt8]) -> Int, algorithm: compression_algorithm?
    ) -> Bool {
        let streams = lzStreams(pieces, capacity: output.count) { piece, output in encode(self, piece, &output) }
        for (piece, stream) in zip(pieces, streams) {
            var decoded = [UInt8](repeating: 0, count: piece.count)
            guard decode(stream, &decoded) == piece.count && decoded == piece else { return false }
        }
        guard let algorithm, pieces.map(\.count).max()! <= 1 << 16 else { return true }
        let apple = lzStreams([pieces[0]], capacity: output.count) { piece, output in references.apple([piece], into: &output, algorithm: algorithm) }
        return apple[0] == streams[0]
    }

    /// For Compression's rows: whether its stream for each piece (made again, kept) decodes with Bytes' `decode`, and
    /// the streams add up to the measured run's `total`.
    func referenceRoundTrips(_ total: Int, algorithm: compression_algorithm, decode: ([UInt8], inout [UInt8]) -> Int) -> Bool {
        let streams = lzStreams(pieces, capacity: output.count) { piece, output in references.apple([piece], into: &output, algorithm: algorithm) }
        guard streams.map(\.count).reduce(0, +) == total else { return false }
        return zip(pieces, streams).allSatisfy { piece, stream in
            var decoded = [UInt8](repeating: 0, count: piece.count)
            return decode(stream, &decoded) == piece.count && decoded == piece
        }
    }
}

/// Registers each encoder on each input. The Bytes benchmarks' setup checks that their streams decode back.
func registerLZEncodeBenchmarks() {
    for (label, byteCount, pieces) in LZEncodeFixtures.shapes() {
        let configuration = Fixtures.configuration(forByteCount: byteCount)
        let fixture = Lazy { LZEncodeFixture(pieces: pieces.value) }
        register("LZFSE encode \(label): Bytes", configuration: configuration, fixture, check: { f, _ in
            var decoder = LZFSEDecoder()
            return f.roundTrips(
                { f, piece, output in lzfseEncodeAll(&f.lzfseEncoder, [piece], into: &output) },
                decode: { lzfseDecode(&decoder, $0, into: &$1) }, algorithm: COMPRESSION_LZFSE
            )
        }) { f in
            lzfseEncodeAll(&f.lzfseEncoder, f.pieces, into: &f.output)
        }
        register("LZFSE encode \(label): Compression", configuration: configuration, fixture, check: { f, total in
            var decoder = LZFSEDecoder()
            return f.referenceRoundTrips(total, algorithm: COMPRESSION_LZFSE, decode: { lzfseDecode(&decoder, $0, into: &$1) })
        }) { f in
            f.references.apple(f.pieces, into: &f.output)
        }
        register("LZVN encode \(label): Bytes", configuration: configuration, fixture, check: { f, _ in
            f.roundTrips(
                { f, piece, output in lzvnEncodeAll(&f.lzvnEncoder, [piece], into: &output) },
                decode: { lzvnDecode($0, into: &$1) }, algorithm: ReferenceLZEncoders.lzvn
            )
        }) { f in
            lzvnEncodeAll(&f.lzvnEncoder, f.pieces, into: &f.output)
        }
        register("LZVN encode \(label): Compression", configuration: configuration, fixture, check: { f, total in
            f.referenceRoundTrips(total, algorithm: ReferenceLZEncoders.lzvn, decode: { lzvnDecode($0, into: &$1) })
        }) { f in
            f.references.apple(f.pieces, into: &f.output, algorithm: ReferenceLZEncoders.lzvn)
        }
        // The lzfse reference's parse on two shapes: the earlier baselines' code, and its distance from Compression's.
        guard label.hasPrefix("JSON") || label == "dickens (64 KB × 16)" else { continue }
        register("LZVN encode \(label): Bytes, reference parse", configuration: configuration, fixture, check: { f, _ in
            f.roundTrips(
                { f, piece, output in lzvnEncodeAll(&f.lzvnReferenceEncoder, [piece], into: &output) },
                decode: { lzvnDecode($0, into: &$1) }, algorithm: nil
            )
        }) { f in
            lzvnEncodeAll(&f.lzvnReferenceEncoder, f.pieces, into: &f.output)
        }
    }
}

/// Allocation checks: encoding allocates nothing once an encoder exists: several LZFSE blocks, 64 KiB streams, the
/// small input's LZVN block, and raw LZVN. Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:(LZFSE|LZVN)_encode.*'
func registerLZEncodeAllocationBenchmarks() {
    // Several LZFSE blocks (40,000 literals or 10,000 matches each); the 1.6 KB JSON is an LZVN block.
    let content = Lazy { Array(Fixtures.json(count: 3_000)) + LZEncodeFixtures.noise(100_000) }
    let shapes: [(String, Lazy<[[UInt8]]>)] = [
        ("LZFSE_encode", Lazy { [content.value] }),
        ("LZFSE_encode_64KB", Lazy { lzbitmapPieces(content.value, piece: 1 << 16).map(Array.init) }),
        ("LZFSE_encode_small", Lazy { [Fixtures.json(count: 16)] }),
    ]
    for (label, pieces) in shapes {
        let fixture = Lazy { LZEncodeFixture(pieces: pieces.value) }
        register("Allocations:\(label)", configuration: Fixtures.allocationConfiguration, fixture, check: { $1 > 0 }) { f in
            lzfseEncodeAll(&f.lzfseEncoder, f.pieces, into: &f.output)
        }
    }
    let fixture = Lazy { LZEncodeFixture(pieces: [content.value]) }
    register("Allocations:LZVN_encode", configuration: Fixtures.allocationConfiguration, fixture, check: { $1 > 0 }) { f in
        lzvnEncodeAll(&f.lzvnEncoder, f.pieces, into: &f.output)
    }
}

extension LZEncodeFixtures {
    /// Bytes that don't compress, for literal-heavy blocks.
    static func noise(_ count: Int) -> [UInt8] {
        var generator = SplitMix64(seed: 42)
        return (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    }
}
