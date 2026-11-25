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
        streams.append((.lzma(try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23), maximumSize: original.count), lzma1Encode(original)))
        var lzfse = LZFSEEncoder()
        var lzvn = LZVNEncoder()
        var lzbitmap = LZBitmapEncoder()
        streams.append((.lzfse, Self.encode(original, LZFSEEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            try lzfse.compressAll(input, into: &output)
        }))
        streams.append((.lzvn, Self.encode(original, LZVNEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            try lzvn.compressAll(input, into: &output)
        }))
        streams.append((.lzbitmap, Self.encode(original, LZBitmapEncoder.maximumCompressedSize(forByteCount: original.count)) { input, output throws(BytesError) in
            try lzbitmap.compressAll(input, into: &output)
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
    // Many short LZMA and xz streams (ZIP's small entries): each starts by resetting the probability model (about
    // 8,000 probabilities for lc 3), whole through `decompressAll` (as `ChunkedDecompressor`'s whole mode) or streamed.
    if let sample = Fixtures.silesia("dickens", limit: SmallStreamsFixture.count * SmallStreamsFixture.size) {
        let fixture = Lazy { SmallStreamsFixture(sample.bytes) }
        let label = "\(SmallStreamsFixture.count) × \(SmallStreamsFixture.size / 1024) KB dickens"
        for (kind, xz) in [("raw -6", false), ("xz -6", true)] {
            register("LZMA small streams \(kind) \(label): whole", fixture, check: { f, count in
                count == f.original.count && f.output == f.original
            }) { f in f.decodeWhole(xz: xz) }
            register("LZMA small streams \(kind) \(label): streamed", fixture, check: { f, count in
                count == f.original.count
            }) { f in f.decodeStreamed(xz: xz) }
        }
    }
    // Zero mallocs once each format's state exists (made by setup's checked run).
    let gate = Lazy { DecompressorFixture(Fixtures.gateContent()) }
    register("Allocations:Decompressor_every_format", configuration: Fixtures.allocationConfiguration, gate, check: { f, count in
        count == f.original.count * (f.streams.count + f.streams.count { $0.format.isStreamable })
    }) { f in f.decodeAll() }
}

/// ``count`` pieces of ``size`` bytes of a text, each compressed on its own as raw LZMA (an end marker, as ZIP's
/// method 14 stores it) and as xz, at liblzma's preset 6; cached in the corpus directory, each stream after its
/// 4-byte little-endian length.
final class SmallStreamsFixture {
    static var count: Int { 1_000 }
    static var size: Int { 4 << 10 }

    let original: [UInt8]
    let raw: [[UInt8]]
    let xz: [[UInt8]]
    let properties = try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23)
    var decompressor = Decompressor()
    var output: [UInt8]
    var chunk = [UInt8](repeating: 0, count: 1 << 16)

    init(_ original: [UInt8]) {
        self.original = original
        output = [UInt8](repeating: 0, count: original.count)
        let pieces = stride(from: 0, to: original.count, by: Self.size).map { Array(original[$0..<min($0 + Self.size, original.count)]) }
        raw = Self.split(Fixtures.cached("dickens-\(original.count)-pieces\(Self.size).lzma1-5.8-6") { Self.join(pieces.map(lzma1Encode)) })
        xz = Self.split(Fixtures.cached("dickens-\(original.count)-pieces\(Self.size).xz-5.8-6") {
            Self.join(pieces.map { LZMAFixtures.compress($0, preset: 6) })
        })
        precondition(raw.count == pieces.count && xz.count == pieces.count)
    }

    static func join(_ streams: [[UInt8]]) -> [UInt8] {
        var joined: [UInt8] = []
        for stream in streams {
            joined += (0..<4).map { UInt8(truncatingIfNeeded: stream.count >> (8 * $0)) } + stream
        }
        return joined
    }

    static func split(_ joined: [UInt8]) -> [[UInt8]] {
        var streams: [[UInt8]] = []
        var offset = 0
        while offset < joined.count {
            let count = (0..<4).reduce(0) { $0 | Int(joined[offset + $1]) << (8 * $1) }
            streams.append(Array(joined[(offset + 4)..<(offset + 4 + count)]))
            offset += 4 + count
        }
        return streams
    }

    func format(xz: Bool, size: Int) -> DecompressionFormat {
        xz ? .xz(sizeHint: size) : .lzma(properties, maximumSize: size)
    }

    /// Every stream decoded whole into its place in ``output``: the bytes decoded.
    func decodeWhole(xz: Bool) -> Int {
        let streams = xz ? self.xz : raw
        var total = 0
        for (index, stream) in streams.enumerated() {
            let size = min(Self.size, original.count - index * Self.size)
            try! decompressor.reset(for: format(xz: xz, size: size))
            total += output.withOutputRawSpan(overwritingFrom: index * Self.size) { span in
                _ = try! decompressor.decompressAll(stream.span.bytes, into: &span, decodedSize: size)
                return span.byteCount
            }
        }
        return total
    }

    /// Every stream through the streaming decoder, 64 KB of output at a time: the bytes decoded.
    func decodeStreamed(xz: Bool) -> Int {
        let streams = xz ? self.xz : raw
        var total = 0
        for (index, stream) in streams.enumerated() {
            try! decompressor.reset(for: format(xz: xz, size: min(Self.size, original.count - index * Self.size)))
            var consumed = 0
            while true {
                let progress = chunk.withOutputRawSpan { span in
                    try! decompressor.decompress(stream.span.bytes.extracting(consumed...), into: &span)
                }
                consumed += progress.consumed
                total += progress.produced
                if progress.status == .finished { break }
            }
        }
        return total
    }
}

/// A `Decompressor` the benchmark closure can reach (it's `~Copyable`).
final class DecompressorBox {
    var decompressor = Decompressor()
}
