import Benchmark
import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import Compression

// Small inputs, where a coder's per-stream setup is most of the work (Phase C of the 2026-11-23 fix plan):
// - DEFLATE levels 1 and 6 on pieces of dickens of 64 B, 1 KB, and 4 KB, one reused encoder, against libdeflate;
// - LZBITMAP encoding of 1, 4, and 16 KB pieces, each with 64 KiB of room (as `aa` gives every APFS chunk), against
//   Compression, whose bytes it reproduces (checked in setup);
// - every codec's coder made for a 64-byte stream ("new") against one coder reused for it ("reused"): the difference
//   is what a client that makes a coder per stream pays.
// Per iteration: every piece of the shape (the count is in the name), or one 64-byte stream.

/// `count` pieces of `size` bytes of `data`, spread through it (the review's probe's pieces).
func smallPieces(_ data: [UInt8], size: Int, count: Int) -> [[UInt8]] {
    (0..<count).map { index in
        let start = (index &* 7919 &* 64) % (data.count - size)
        return Array(data[start..<start + size])
    }
}

/// The shapes: piece size and count, so that each iteration is a few million instructions.
enum SmallInputs {
    static let deflateShapes: [(size: Int, count: Int)] = [(64, 1_000), (1 << 10, 200), (4 << 10, 50)]
    static let lzbitmapShapes: [(size: Int, count: Int)] = [(1 << 10, 100), (4 << 10, 50), (16 << 10, 16)]

    static func sizeLabel(_ size: Int) -> String {
        size < 1024 ? "\(size) B" : "\(size >> 10) KB"
    }
}

/// Pieces, an output buffer with room for any piece's stream, and each encoder.
final class SmallDeflateFixture {
    let pieces: [[UInt8]]
    var output: [UInt8]
    var encoder: DeflateEncoder
    let libdeflate: LibDeflate

    init(pieces: [[UInt8]], level: Int) {
        self.pieces = pieces
        output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: pieces.map(\.count).max()!, format: .raw))
        encoder = DeflateEncoder(format: .raw, level: level)
        libdeflate = LibDeflate(format: .raw, level: Int32(level))
    }

    /// Every piece through the reused encoder: the total size.
    func encodeBytes() -> Int {
        var total = 0
        for piece in pieces {
            total &+= encodeAll(&encoder, piece, into: &output)
        }
        return total
    }

    func encodeLibdeflate() -> Int {
        var total = 0
        for piece in pieces {
            total &+= libdeflate.compress(piece, into: &output)
        }
        return total
    }

    /// Whether zlib decodes every piece's stream back, each from the reused encoder.
    func roundTrips() -> Bool {
        pieces.allSatisfy { piece in
            let count = encodeAll(&encoder, piece, into: &output)
            return Fixtures.inflates(output[..<count], to: piece)
        }
    }
}

func registerSmallInputBenchmarks() {
    guard let dickens = Fixtures.silesia("dickens") else { return }
    let data = Lazy { dickens.bytes }
    for level in [1, 6] {
        for (size, count) in SmallInputs.deflateShapes {
            let fixture = Lazy { SmallDeflateFixture(pieces: smallPieces(data.value, size: size, count: count), level: level) }
            let label = "\(count) × \(SmallInputs.sizeLabel(size)) dickens"
            register("Deflate \(level) small streams \(label): Bytes", fixture, check: { f, _ in f.roundTrips() }) { f in
                f.encodeBytes()
            }
            register("Deflate \(level) small streams \(label): libdeflate", fixture) { f in
                f.encodeLibdeflate()
            }
        }
    }
    for (size, count) in SmallInputs.lzbitmapShapes {
        let fixture = Lazy {
            let pieces = smallPieces(data.value, size: size, count: count).map { $0[...] }
            return LZBitmapEncodeFixture(pieces: pieces, capacities: pieces.map { _ in 1 << 16 }, outputCount: 1 << 16)
        }
        let apple = Lazy { AppleLZBitmapEncoder() }
        let label = "\(count) × \(SmallInputs.sizeLabel(size)) dickens"
        register("LZBITMAP encode small streams \(label): Bytes", fixture, check: { f, _ in f.matchesCompression() }) { f in
            lzbitmapEncodeAll(&f.encoder, f.pieces, capacities: f.capacities, into: &f.output)
        }
        register("LZBITMAP encode small streams \(label): Compression", fixture, check: { f, total in
            total == lzbitmapEncodeAll(&f.encoder, f.pieces, capacities: f.capacities, into: &f.output)
        }) { f in
            appleLZBitmapEncodeAll(apple.value, f.pieces, capacities: f.capacities, into: &f.output)
        }
    }
    registerConstructionBenchmarks(data)
}

// MARK: - Construction

/// One coder kept for every stream (the "reused" rows), a 64-byte input or its encoding, and an output buffer.
final class ConstructionFixture<Coder: ~Copyable> {
    let original: [UInt8]
    let input: [UInt8]
    var output: [UInt8]
    var coder: Coder

    init(original: [UInt8], input: [UInt8], coder: consuming Coder) {
        self.original = original
        self.input = input
        output = [UInt8](repeating: 0, count: 64 << 10)
        self.coder = coder
    }
}

/// Registers "New coder per 64 B stream: NAME" (a coder made, used for one stream, and destroyed per iteration) and
/// "Reused coder, 64 B stream: NAME" (the fixture's coder for every stream). `input` makes the stream's input from the
/// 64 bytes (an encoding, for decoders); `check` judges a run's output (the bytes `run` reports, at the output's start).
func registerConstruction<Coder: ~Copyable>(
    _ name: String, _ original: Lazy<[UInt8]>, input: @escaping ([UInt8]) -> [UInt8] = { $0 },
    check: @escaping (_ original: [UInt8], _ output: ArraySlice<UInt8>) -> Bool,
    make: @escaping () -> Coder, run: @escaping (inout Coder, [UInt8], inout [UInt8]) -> Int
) {
    let fixture = Lazy { ConstructionFixture(original: original.value, input: input(original.value), coder: make()) }
    register("New coder per 64 B stream: \(name)", fixture, check: { f, count in check(f.original, f.output[..<count]) }) { f in
        var coder = make()
        return run(&coder, f.input, &f.output)
    }
    register("Reused coder, 64 B stream: \(name)", fixture, check: { f, count in check(f.original, f.output[..<count]) }) { f in
        run(&f.coder, f.input, &f.output)
    }
}

/// Every codec's coder, made per 64-byte stream and reused, encoders then decoders.
func registerConstructionBenchmarks(_ data: Lazy<[UInt8]>) {
    let piece = Lazy { Array(data.value[(1 << 16)..<(1 << 16) + 64]) }
    // Encoders: their streams decode back with the reference decoders (or Bytes' own, for Apple's formats).
    let inflates = { (original: [UInt8], output: ArraySlice<UInt8>) in Fixtures.inflates(output, to: original) }
    for level in [1, 6] {
        registerConstruction("DeflateEncoder level \(level)", piece, check: inflates, make: { DeflateEncoder(format: .raw, level: level) }) {
            encodeAll(&$0, $1, into: &$2)
        }
    }
    let brotliDecodes = { (original: [UInt8], output: ArraySlice<UInt8>) in Fixtures.brotliDecodes(output, to: original) }
    for quality in [1, 5] {
        registerConstruction("BrotliEncoder quality \(quality)", piece, check: brotliDecodes, make: { BrotliEncoder(quality: quality) }) {
            brotliEncodeAll(&$0, $1, into: &$2)
        }
    }
    registerConstruction("ZstdEncoder level 3", piece, check: { original, output in
        var decoder = ZstdDecoder()
        var decoded = [UInt8](repeating: 0, count: 1024)
        return zstdDecodeAll(&decoder, Array(output), into: &decoded) == original.count && decoded.prefix(original.count).elementsEqual(original)
    }, make: { ZstdEncoder(level: 3) }) {
        zstdEncodeAll(&$0, $1, into: &$2)
    }
    let appleDecodes = { (algorithm: compression_algorithm) in
        { (original: [UInt8], output: ArraySlice<UInt8>) in
            BytesReferenceCodecs.AppleCompression.decode(Array(output), capacity: original.count, algorithm) == original
        }
    }
    registerConstruction("LZFSEEncoder", piece, check: appleDecodes(COMPRESSION_LZFSE), make: { LZFSEEncoder() }) {
        lzfseEncodeAll(&$0, [$1], into: &$2)
    }
    registerConstruction("LZVNEncoder", piece, check: appleDecodes(ReferenceLZEncoders.lzvn), make: { LZVNEncoder() }) {
        lzvnEncodeAll(&$0, [$1], into: &$2)
    }
    registerConstruction("LZBitmapEncoder", piece, check: appleDecodes(COMPRESSION_LZBITMAP), make: { LZBitmapEncoder() }) {
        lzbitmapEncodeAll(&$0, [$1[...]], capacities: [1 << 16], into: &$2)
    }

    // Decoders: each decodes its format's encoding of the 64 bytes back to them.
    let decodes = { (original: [UInt8], output: ArraySlice<UInt8>) in output.elementsEqual(original) }
    registerConstruction("DeflateDecoder", piece, input: { Fixtures.zlibCompress($0) }, check: decodes, make: { DeflateDecoder(format: .raw) }) {
        decodeAll(&$0, $1, into: &$2)
    }
    registerConstruction("BrotliDecoder", piece, input: { original in
        var output = [UInt8](repeating: 0, count: 1024)
        let count = GoogleBrotli.compress(original, quality: 5, into: &output) // Before reading `output`.
        return Array(output.prefix(count))
    }, check: decodes, make: { BrotliDecoder() }) {
        brotliDecodeAll(&$0, $1, into: &$2)
    }
    registerConstruction("ZstdDecoder", piece, input: { ZstdFixtures.compress($0, level: 3) }, check: decodes, make: { ZstdDecoder() }) {
        zstdDecodeAll(&$0, $1, into: &$2)
    }
    registerConstruction("LZMA2Decoder (.xz whole)", piece, input: { LZMAFixtures.compress($0, preset: 6) }, check: decodes, make: { LZMA2Decoder() }) {
        lzmaDecodeXZ(&$0, $1, into: &$2)
    }
    registerConstruction("XZDecoder (streamed)", piece, input: { LZMAFixtures.compress($0, preset: 6) }, check: decodes, make: { XZDecoder() }) { decoder, input, output in
        output.withOutputRawSpan { span in
            _ = try! decoder.decompress(input.span.bytes, into: &span)
            return span.byteCount
        }
    }
    let properties = try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23)
    registerConstruction("LZMADecoder (raw, streamed)", piece, input: lzma1Encode, check: decodes, make: { LZMADecoder() }) { decoder, input, output in
        try! decoder.reset(properties: properties)
        return output.withOutputRawSpan { span in
            _ = try! decoder.decompress(input.span.bytes, into: &span)
            return span.byteCount
        }
    }
    registerConstruction("BZip2Decoder", piece, input: { BZip2Fixtures.compress($0, level: 9) }, check: decodes, make: { BZip2Decoder() }) {
        bzip2Decode(&$0, $1, into: &$2)
    }
    registerConstruction("LZFSEDecoder", piece, input: { LZFixtures.appleEncode($0, COMPRESSION_LZFSE) }, check: decodes, make: { LZFSEDecoder() }) {
        lzfseDecode(&$0, $1, into: &$2)
    }
    let lzbitmapInput = { (original: [UInt8]) in LZFixtures.appleEncode(original, COMPRESSION_LZBITMAP) }
    registerConstruction("LZBitmapDecoder", piece, input: lzbitmapInput, check: decodes, make: { LZBitmapDecoder() }) { decoder, input, output in
        output.withOutputRawSpan { span in
            _ = try! decoder.decompressAll(input.span.bytes, into: &span)
            return span.byteCount
        }
    }
    registerConstruction("LZRAVENDecoder", piece, input: AppleLZRAVEN.encode, check: decodes, make: { LZRAVENDecoder() }) { decoder, input, output in
        output.withOutputRawSpan { span in
            _ = try! decoder.decompressAll(input.span.bytes, into: &span)
            return span.byteCount
        }
    }
}
