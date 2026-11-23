import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport

// `Decompressor`, the one decoder for every format, against the formats' own decoders: the same stream through
// each (the dispatch is one `switch` per call), and a zero-malloc gate for a decoder reset between formats, as an
// archive's entries or segments reset it.

/// One `Decompressor` and the gate's streams: the same content in several formats.
final class DecompressorFixture {
    let original: [UInt8]
    let streams: [(format: DecompressionFormat, stream: [UInt8])]
    var decompressor = Decompressor()
    var output: [UInt8]
    var chunk = [UInt8](repeating: 0, count: 1 << 16)

    init(_ original: [UInt8]) {
        self.original = original
        output = [UInt8](repeating: 0, count: original.count)
        var streams: [(DecompressionFormat, [UInt8])] = []
        for format in [DeflateFormat.raw, .zlib, .gzip] {
            var encoder = DeflateEncoder(format: format, level: 6)
            var encoded = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: original.count, format: format))
            let count = encodeAll(&encoder, original, into: &encoded)
            streams.append((.deflate(format), Array(encoded.prefix(count))))
        }
        streams.append((.xz(sizeHint: original.count), LZMAFixtures.compress(original, preset: 6)))
        streams.append((.lzma(try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23), sizeHint: original.count), lzma1Encode(original)))
        var lzfse = LZFSEEncoder()
        var lzvn = LZVNEncoder()
        var lzbitmap = LZBitmapEncoder()
        streams.append((.lzfse, Self.encode(original, LZFSEEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            _ = try lzfse.compressAll(input, into: &output)
        }))
        streams.append((.lzvn, Self.encode(original, LZVNEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            _ = try lzvn.compressAll(input, into: &output)
        }))
        streams.append((.lzbitmap, Self.encode(original, LZBitmapEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            try lzbitmap.compress(input, into: &output)
        }))
        self.streams = streams
    }

    static func encode(_ data: [UInt8], _ capacity: Int, _ body: (RawSpan, inout OutputRawSpan) throws(BytesError) -> Void) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: capacity)
        let count = output.withOutputRawSpan { span in
            try! body(data.span.bytes, &span)
            return span.byteCount
        }
        return Array(output.prefix(count))
    }

    /// Every stream whole, then the streaming ones a 64 KB chunk at a time: the bytes decoded.
    func decodeAll() -> Int {
        var total = 0
        for (format, encoded) in streams {
            try! decompressor.reset(for: format)
            total += output.withOutputRawSpan { span in
                _ = try! decompressor.decompressAll(encoded.span.bytes, into: &span, decodedSize: original.count)
                return span.byteCount
            }
            guard format.isStreamable else { continue }
            try! decompressor.reset(for: format)
            total += stream(encoded)
        }
        return total
    }

    /// `stream` through ``decompressor``'s streaming form, output 64 KB at a time.
    func stream(_ stream: [UInt8]) -> Int {
        var consumed = 0
        var produced = 0
        while true {
            let progress = chunk.withOutputRawSpan { span in
                try! decompressor.decompress(stream.span.bytes.extracting(consumed...), into: &span)
            }
            consumed += progress.consumed
            produced += progress.produced
            if progress.status == .finished { return produced }
        }
    }
}

func registerDecompressorBenchmarks() {
    // The same stream as "LZMA stream xz -6 dickens (9.7 MB): 1 MiB out", through `Decompressor`.
    if let sample = Fixtures.silesia("dickens") {
        let fixture = Lazy { LZMAStreamFixture(sample) }
        let decompressor = Lazy { () -> DecompressorBox in DecompressorBox() }
        register("Decompressor xz -6 \(sample.label): 1 MiB out", configuration: Fixtures.largeConfiguration, fixture, check: { f, count in
            count == f.original.count
        }) { f in
            let box = decompressor.value
            try! box.decompressor.reset(for: .xz(sizeHint: f.original.count))
            let input = f.xz
            return f.stream(input, inputPiece: nil) { input, output in try! box.decompressor.decompress(input, into: &output) }
        }
    }
    // Zero mallocs once each format's state exists (made by setup's checked run).
    let gate = Lazy { DecompressorFixture(Fixtures.gateContent()) }
    register("Allocations:Decompressor_every_format", configuration: Fixtures.allocationConfiguration, gate, check: { f, count in
        count == f.original.count * (f.streams.count + f.streams.count { $0.format.isStreamable })
    }) { f in f.decodeAll() }
}

/// A `Decompressor` the benchmark closure can reach (it's `~Copyable`).
final class DecompressorBox {
    var decompressor = Decompressor()
}
