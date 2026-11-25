import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Foundation

// LZBITMAP decoding: Bytes' `LZBitmapDecoder` against Apple's Compression (`COMPRESSION_LZBITMAP`, which also
// made every stream). Single-threaded, one call per stream, into a buffer of exactly the decompressed size.
// (libzbitmap, an open-source decoder, was compared here until 2026-11-19, then removed: RESULTS-lzbitmap.md has the
// last comparison and how to build it again.)
//
// Two shapes, from where LZBITMAP is used:
// - "16 MB": the first 16 MiB of a Silesia file (or all of it) as one stream, as an Apple Encrypted Archive
//   segment holds;
// - "64 KB × 16": the first 1 MiB as 16 independent 64 KiB streams, as an APFS-compressed file's resource fork
//   (decmpfs type 14) holds; each iteration decodes all 16.
// Throughput: iterations per second times the bytes per iteration (16 MiB, or 1 MiB).

/// Apple's Compression, one call, with a scratch buffer allocated once.
final class AppleLZBitmap {
    private let scratch = UnsafeMutableRawPointer.allocate(
        byteCount: max(compression_decode_scratch_buffer_size(COMPRESSION_LZBITMAP), 1), alignment: 64
    )

    deinit { scratch.deallocate() }

    func decode(_ input: [UInt8], into output: UnsafeMutableRawBufferPointer) -> Int {
        input.withUnsafeBufferPointer { input in
            compression_decode_buffer(
                output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count, input.baseAddress!, input.count, scratch,
                COMPRESSION_LZBITMAP
            )
        }
    }
}

enum LZBitmapFixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// Compression's encoding of `data`.
    static func compress(_ data: some Collection<UInt8>) -> [UInt8] {
        let input = Array(data)
        var output = [UInt8](repeating: 0, count: input.count + input.count / 1024 + 64)
        let count = input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                compression_encode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, nil, COMPRESSION_LZBITMAP)
            }
        }
        precondition(count > 0)
        return Array(output[..<count])
    }
}

/// Decodes each stream into its slice of `output` (consecutive, each exactly its size) with Bytes.
@inline(__always)
func lzbitmapDecodeAll(_ decoder: inout LZBitmapDecoder, _ streams: [[UInt8]], sizes: [Int], into output: inout [UInt8]) -> Int {
    output.withUnsafeMutableBytes { buffer in
        var offset = 0
        for (stream, size) in zip(streams, sizes) {
            var span = OutputRawSpan(buffer: UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + size)]), initializedCount: 0)
            _ = try! decoder.decompressAll(stream.span.bytes, into: &span, decodedSize: size)
            offset += span.byteCount
        }
        return offset
    }
}

func appleLZBitmapDecodeAll(_ apple: AppleLZBitmap, _ streams: [[UInt8]], sizes: [Int], into output: inout [UInt8]) -> Int {
    output.withUnsafeMutableBytes { buffer in
        var offset = 0
        for (stream, size) in zip(streams, sizes) {
            offset += apple.decode(stream, into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + size)]))
        }
        return offset
    }
}

/// A shape's streams, their decoded sizes, and an output buffer of exactly the content's size.
final class LZBitmapDecodeFixture {
    let content: [UInt8]
    let streams: [[UInt8]]
    let sizes: [Int]
    var output: [UInt8]
    var decoder = LZBitmapDecoder()

    init(content: [UInt8], streams: [[UInt8]], sizes: [Int]) {
        self.content = content
        self.streams = streams
        self.sizes = sizes
        output = [UInt8](repeating: 0, count: content.count)
    }

    func decoded(_ produced: Int) -> Bool {
        produced == content.count && output == content
    }
}

/// `content` in pieces of `piece` bytes (one piece if `piece` is nil).
func lzbitmapPieces(_ content: [UInt8], piece: Int?) -> [ArraySlice<UInt8>] {
    guard let piece else { return [content[...]] }
    return stride(from: 0, to: content.count, by: piece).map { content[$0..<min($0 + piece, content.count)] }
}

/// Registers both decoders on each input; each benchmark's setup checks that its decoder decodes it exactly.
func registerLZBitmapBenchmarks() {
    let apple = Lazy { AppleLZBitmap() }
    for name in LZBitmapFixtures.files {
        guard let large = Fixtures.silesia(name, limit: 16 << 20), let small = Fixtures.silesia(name, limit: 1 << 20) else { continue }
        for (label, sample, piece) in [(large.label, large, nil), ("\(name) (64 KB × 16)", small, 1 << 16)] as [(String, Fixtures.Sample, Int?)] {
            let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
            let fixture = Lazy {
                let content = sample.bytes
                let pieces = lzbitmapPieces(content, piece: piece)
                let streams = pieces.map { piece in
                    Fixtures.cached("\(name)-\(piece.startIndex)-\(piece.count).lzbitmap-macos27") { LZBitmapFixtures.compress(piece) }
                }
                return LZBitmapDecodeFixture(content: content, streams: streams, sizes: pieces.map(\.count))
            }
            register("LZBITMAP decode \(label): Bytes", configuration: configuration, fixture, check: { $0.decoded($1) }) { f in
                lzbitmapDecodeAll(&f.decoder, f.streams, sizes: f.sizes, into: &f.output)
            }
            register("LZBITMAP decode \(label): Compression", configuration: configuration, fixture, check: { $0.decoded($1) }) { f in
                appleLZBitmapDecodeAll(apple.value, f.streams, sizes: f.sizes, into: &f.output)
            }
        }
    }
    registerLZBitmapEncodeBenchmarks()
}

/// Allocation checks: decoding allocates nothing once a decoder exists, one large stream or many small ones.
/// Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:LZBITMAP.*'
func registerLZBitmapAllocationBenchmarks() {
    for (label, piece) in [("one", nil), ("64KB", 1 << 16)] as [(String, Int?)] {
        let fixture = Lazy {
            let content = Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16))
            let pieces = lzbitmapPieces(content, piece: piece)
            return LZBitmapDecodeFixture(content: content, streams: pieces.map { LZBitmapFixtures.compress($0) }, sizes: pieces.map(\.count))
        }
        register("Allocations:LZBITMAP_decode_\(label)", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decoded($1) }) { f in
            lzbitmapDecodeAll(&f.decoder, f.streams, sizes: f.sizes, into: &f.output)
        }
    }
    registerLZBitmapEncodeAllocationBenchmarks()
}
