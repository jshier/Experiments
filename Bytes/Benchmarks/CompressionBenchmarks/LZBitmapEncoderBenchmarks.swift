import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Foundation

// LZBITMAP encoding: Bytes' `LZBitmapEncoder` against Apple's Compression (`COMPRESSION_LZBITMAP`, whose bytes it
// reproduces). (libzbitmap's encoder, 0.5–4 MB/s, was compared here until 2026-11-19: RESULTS-lzbitmap.md.)
// Single-threaded, one call per stream, the same two shapes as the decoder benchmarks:
// - "16 MB": the first 16 MiB of a Silesia file (or all of it) as one stream, with room for any stream;
// - "64 KB × 16": the first 1 MiB as 16 independent 64 KiB streams, each with 64 KiB of room, as APFS
//   compression (decmpfs type 14) encodes a file's chunks; each iteration encodes all 16.
// Throughput: iterations per second times the input bytes per iteration (16 MiB, or 1 MiB).

/// Apple's Compression, one call, with a scratch buffer allocated once.
final class AppleLZBitmapEncoder {
    private let scratch = UnsafeMutableRawPointer.allocate(
        byteCount: max(compression_encode_scratch_buffer_size(COMPRESSION_LZBITMAP), 1), alignment: 64
    )

    deinit { scratch.deallocate() }

    func encode(_ input: ArraySlice<UInt8>, into output: UnsafeMutableRawBufferPointer) -> Int {
        input.withUnsafeBufferPointer { input in
            compression_encode_buffer(
                output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count, input.baseAddress!, input.count, scratch,
                COMPRESSION_LZBITMAP
            )
        }
    }
}

/// Encodes each piece into `output` with room of `capacity(piece)` each, returning the total size (0 if one
/// doesn't fit).
@inline(__always)
func lzbitmapEncodeAll(
    _ encoder: inout LZBitmapEncoder, _ pieces: [ArraySlice<UInt8>], capacities: [Int], into output: inout [UInt8]
) -> Int {
    output.withUnsafeMutableBytes { buffer in
        var total = 0
        for (piece, capacity) in zip(pieces, capacities) {
            let room = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<capacity])
            var span = OutputRawSpan(buffer: room, initializedCount: 0)
            let fits = piece.withUnsafeBytes { bytes in
                (try? encoder.compress(RawSpan(_unsafeBytes: bytes), into: &span)) != nil
            }
            total += fits ? span.finalize(for: room) : 0
        }
        return total
    }
}

func appleLZBitmapEncodeAll(
    _ apple: AppleLZBitmapEncoder, _ pieces: [ArraySlice<UInt8>], capacities: [Int], into output: inout [UInt8]
) -> Int {
    output.withUnsafeMutableBytes { buffer in
        var total = 0
        for (piece, capacity) in zip(pieces, capacities) {
            total += apple.encode(piece, into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<capacity]))
        }
        return total
    }
}

/// A shape's pieces, the room each is given, and an output buffer with room for any stream.
final class LZBitmapEncodeFixture {
    let pieces: [ArraySlice<UInt8>]
    let capacities: [Int]
    var output: [UInt8]
    var encoder = LZBitmapEncoder()

    init(pieces: [ArraySlice<UInt8>], capacities: [Int], outputCount: Int) {
        self.pieces = pieces
        self.capacities = capacities
        output = [UInt8](repeating: 0, count: outputCount)
    }

    /// Whether Bytes' stream for each piece is Compression's, byte for byte.
    func matchesCompression() -> Bool {
        let apple = AppleLZBitmapEncoder()
        var ours = output
        var theirs = output
        return zip(pieces, capacities).allSatisfy { piece, capacity in
            let size = lzbitmapEncodeAll(&encoder, [piece], capacities: [capacity], into: &ours)
            let appleSize = appleLZBitmapEncodeAll(apple, [piece], capacities: [capacity], into: &theirs)
            return size == appleSize && ours[..<size] == theirs[..<appleSize]
        }
    }
}

/// Registers both encoders on each input. The Bytes benchmarks' setup checks that its streams are Compression's,
/// byte for byte.
func registerLZBitmapEncodeBenchmarks() {
    let apple = Lazy { AppleLZBitmapEncoder() }
    // Each shape: its label, input, piece size, and the output buffer's room (the file's large shape's, as before).
    var shapes: [(label: String, sample: Fixtures.Sample, piece: Int?, room: Int)] = []
    for name in LZBitmapFixtures.files {
        guard let large = Fixtures.silesia(name, limit: 16 << 20), let small = Fixtures.silesia(name, limit: 1 << 20) else { continue }
        shapes += [(large.label, large, nil, large.byteCount), ("\(name) (64 KB × 16)", small, 1 << 16, large.byteCount)]
    }
    // Already-compressed data: a chunk that doesn't fit in its own size is given up on (APFS then stores it as is), and
    // this measures how soon; setup checks Bytes gives up where Compression does.
    shapes.append(("random (64 KB × 16)", Fixtures.random, 1 << 16, Fixtures.random.byteCount))
    for (label, sample, piece, room) in shapes {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy {
            let pieces = lzbitmapPieces(sample.bytes, piece: piece)
            // One stream with room for any, or 64 KiB pieces with room of their own size, as APFS gives them.
            let capacities = piece == nil ? [LZBitmapEncoder.maximumCompressedSize(forByteCount: sample.byteCount)] : pieces.map(\.count)
            return LZBitmapEncodeFixture(pieces: pieces, capacities: capacities, outputCount: LZBitmapEncoder.maximumCompressedSize(forByteCount: room))
        }
        register("LZBITMAP encode \(label): Bytes", configuration: configuration, fixture, check: { f, _ in f.matchesCompression() }) { f in
            lzbitmapEncodeAll(&f.encoder, f.pieces, capacities: f.capacities, into: &f.output)
        }
        // Compression's streams are Bytes' (checked in the Bytes row's setup): the same total.
        register("LZBITMAP encode \(label): Compression", configuration: configuration, fixture, check: { f, total in
            total == lzbitmapEncodeAll(&f.encoder, f.pieces, capacities: f.capacities, into: &f.output)
        }) { f in
            appleLZBitmapEncodeAll(apple.value, f.pieces, capacities: f.capacities, into: &f.output)
        }
    }
}

/// Allocation checks: encoding allocates nothing once an encoder exists, one large stream or many 64 KiB ones.
/// Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:LZBITMAP_encode.*'
func registerLZBitmapEncodeAllocationBenchmarks() {
    for (label, piece) in [("one", nil), ("64KB", 1 << 16)] as [(String, Int?)] {
        let fixture = Lazy {
            let content = Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16))
            let outputCount = LZBitmapEncoder.maximumCompressedSize(forByteCount: content.count)
            let pieces = lzbitmapPieces(content, piece: piece)
            return LZBitmapEncodeFixture(pieces: pieces, capacities: piece == nil ? [outputCount] : pieces.map(\.count), outputCount: outputCount)
        }
        register("Allocations:LZBITMAP_encode_\(label)", configuration: Fixtures.allocationConfiguration, fixture, check: { $1 > 0 }) { f in
            lzbitmapEncodeAll(&f.encoder, f.pieces, capacities: f.capacities, into: &f.output)
        }
    }
}
