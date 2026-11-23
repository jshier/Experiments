import Bytes
import BytesCompression
import Testing

// Every codec's whole-buffer call starts a new stream, whatever the value did before: a value used by a one-shot
// call, a failed one, or a stream left unfinished writes exactly what a fresh value writes.

@Suite struct OneShotReuseTests {
    /// What a fresh value's call writes: the reference.
    typealias Call = (RawSpan, inout OutputRawSpan) throws(BytesError) -> Void

    /// `call` on `input` into `capacity` bytes of room: what it appended, or `nil` if it threw.
    static func run(_ input: [UInt8], capacity: Int, _ call: Call) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: capacity)
        do throws(BytesError) {
            let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
                try call(input.span.bytes, &span)
                return span.byteCount
            }
            return Array(output.prefix(count))
        } catch {
            return nil
        }
    }

    /// Runs `used` on `before` (a stream of other data, or a cut-short one: its result doesn't matter), then on
    /// `input` twice, and expects both to write what `fresh` writes for `input` (and that to be `expected`, if given).
    static func check(
        _ name: String, before: [UInt8], input: [UInt8], capacity: Int, expected: [UInt8]? = nil, used: Call, fresh: Call
    ) {
        _ = run(before, capacity: capacity, used)
        let reference = run(input, capacity: capacity, fresh)
        #expect(reference != nil, "\(name): the fresh value failed")
        if let expected { #expect(reference == expected, "\(name): the fresh value's output") }
        for round in 1...2 {
            #expect(run(input, capacity: capacity, used) == reference, "\(name), round \(round)")
        }
    }

    /// Starts a stream with a streaming call on part of `input` and leaves it unfinished.
    static func leaveUnfinished(_ input: [UInt8], _ call: (RawSpan, inout OutputRawSpan) throws(BytesError) -> TransformProgress) {
        var output = [UInt8](repeating: 0, count: 1 << 12)
        _ = try? output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
            try call(input.span.bytes.extracting(0..<(input.count / 2)), &span)
        }
    }

    static let data = DecompressorTests.data
    /// Other data, for the first call.
    static let other = Array(DecompressorTests.data.prefix(70_000).reversed()) + [UInt8](repeating: 7, count: 9_000)

    @Test func encoders() {
        let (data, other) = (Self.data, Self.other)
        let room = data.count + data.count / 4 + (64 << 10)
        for format in [DeflateFormat.raw, .zlib, .gzip] {
            for level in [1, 6] {
                var used = DeflateEncoder(format: format, level: level)
                var fresh = DeflateEncoder(format: format, level: level)
                Self.leaveUnfinished(other) { (input, output) throws(BytesError) in try used.compress(input, into: &output, flush: .none) }
                Self.check("Deflate \(format) \(level), after streaming", before: [], input: data, capacity: room,
                           used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                           fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
                Self.check("Deflate \(format) \(level)", before: other, input: data, capacity: room,
                           used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                           fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
            }
        }
        do {
            var used = BrotliEncoder(quality: 5)
            var fresh = BrotliEncoder(quality: 5)
            Self.leaveUnfinished(other) { (input, output) throws(BytesError) in try used.compress(input, into: &output, flush: .none) }
            Self.check("Brotli", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
        }
        do {
            var used = ZstdEncoder(level: 3, checksum: true)
            var fresh = ZstdEncoder(level: 3, checksum: true)
            Self.leaveUnfinished(other) { (input, output) throws(BytesError) in try used.compress(input, into: &output, flush: .none) }
            Self.check("Zstd", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
        }
        do {
            var used = LZFSEEncoder()
            var fresh = LZFSEEncoder()
            Self.check("LZFSE", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in _ = try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.compressAll(input, into: &output) })
        }
        do {
            var used = LZVNEncoder()
            var fresh = LZVNEncoder()
            Self.check("LZVN", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in _ = try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.compressAll(input, into: &output) })
        }
        do {
            var used = LZBitmapEncoder()
            var fresh = LZBitmapEncoder()
            Self.check("LZBITMAP", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in try used.compress(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try fresh.compress(input, into: &output) })
        }
        do {
            var used = ParallelDeflateEncoder(format: .gzip, level: 6, chunkSize: 64 << 10, lanes: 4)
            var fresh = ParallelDeflateEncoder(format: .gzip, level: 6, chunkSize: 64 << 10, lanes: 4)
            Self.leaveUnfinished(other) { (input, output) throws(BytesError) in try used.compress(input, into: &output, flush: .none) }
            Self.check("parallel Deflate", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
        }
        do {
            var used = ParallelBrotliEncoder(quality: 5, chunkSize: 64 << 10, lanes: 4)
            var fresh = ParallelBrotliEncoder(quality: 5, chunkSize: 64 << 10, lanes: 4)
            Self.check("parallel Brotli", before: other, input: data, capacity: room,
                       used: { (input, output) throws(BytesError) in try used.compressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try fresh.compressAll(input, into: &output) })
        }
    }

    /// Each decoder first fails on a cut-short stream (or is left in the middle of one by a streaming call), then
    /// decodes the whole stream twice.
    @Test func decoders() {
        let encodings = DecompressorTests.encodings
        func fixture(_ format: DecompressionFormat) -> (stream: [UInt8], data: [UInt8], cut: [UInt8]) {
            let (_, stream, data) = encodings.first { $0.format == format }!
            return (stream, data, Array(stream.prefix(stream.count * 2 / 3)))
        }
        for container in [DeflateFormat.raw, .zlib, .gzip] {
            let (stream, data, cut) = fixture(.deflate(container))
            var used = DeflateDecoder(format: container)
            var fresh = DeflateDecoder(format: container)
            Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try used.decompress(input, into: &output) }
            Self.check("Deflate \(container), after streaming", before: [], input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
            Self.check("Deflate \(container)", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
            var parallel = ParallelDeflateDecoder(format: container, lanes: 4)
            var freshParallel = ParallelDeflateDecoder(format: container, lanes: 4)
            Self.check("parallel Deflate \(container)", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try parallel.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try freshParallel.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.deflate64)
            var used = DeflateDecoder(variant: .deflate64)
            var fresh = DeflateDecoder(variant: .deflate64)
            Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try used.decompress(input, into: &output) }
            Self.check("Deflate64", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.brotli)
            var used = BrotliDecoder()
            var fresh = BrotliDecoder()
            Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try used.decompress(input, into: &output) }
            Self.check("Brotli", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.zstd)
            var used = ZstdDecoder()
            var fresh = ZstdDecoder()
            Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try used.decompress(input, into: &output) }
            Self.check("Zstd", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.bzip2)
            var used = BZip2Decoder()
            var fresh = BZip2Decoder()
            Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try used.decompress(input, into: &output) }
            Self.check("bzip2", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.lzma(DecompressorTests.lzmaProperties))
            let properties = DecompressorTests.lzmaProperties
            var used = LZMA2Decoder()
            var fresh = LZMA2Decoder()
            Self.check("LZMA", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressLZMA(input, properties: properties, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressLZMA(input, properties: properties, into: &output) })
            // The same stream as a `.lzma` file: the properties, the dictionary size, and no stated size.
            let file = [properties.byte] + littleEndian(UInt32(properties.dictionarySize), count: 4) + [UInt8](repeating: 0xFF, count: 8) + stream
            Self.check("LZMA file", before: Array(file.prefix(file.count / 2)), input: file, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressLZMAFile(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressLZMAFile(input, into: &output) })
            let (xz, xzData, xzCut) = fixture(.xz())
            Self.check("xz", before: xzCut, input: xz, capacity: xzData.count, expected: xzData,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressXZ(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressXZ(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.lzfse)
            var used = LZFSEDecoder()
            var fresh = LZFSEDecoder()
            Self.check("LZFSE", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.lzvn)
            let decoder = LZVNDecoder()
            Self.check("LZVN", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try decoder.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try LZVNDecoder().decompressAll(input, into: &output) })
        }
        do {
            let (raw, data, rawCut) = fixture(.lz4(framed: false))
            let (framed, _, framedCut) = fixture(.lz4(framed: true))
            let decoder = LZ4Decoder()
            Self.check("LZ4 raw", before: rawCut, input: raw, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in try decoder.decompressRaw(input, decodedSize: data.count, into: &output) },
                       fresh: { (input, output) throws(BytesError) in try LZ4Decoder().decompressRaw(input, decodedSize: data.count, into: &output) })
            Self.check("LZ4 framed", before: framedCut, input: framed, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try decoder.decompressFramed(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try LZ4Decoder().decompressFramed(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.lzbitmap)
            var used = LZBitmapDecoder()
            var fresh = LZBitmapDecoder()
            Self.check("LZBITMAP", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        do {
            let (stream, data, cut) = fixture(.lzraven)
            var used = LZRAVENDecoder()
            var fresh = LZRAVENDecoder()
            Self.check("LZRAVEN", before: cut, input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try used.decompressAll(input, into: &output) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output) })
        }
        // `Decompressor`, format by format, on one value: a cut-short stream, a stream left unfinished, then whole.
        var decompressor = Decompressor()
        for (format, stream, data) in encodings {
            let size: Int? = format == .lz4(framed: false) ? data.count : nil
            var fresh = Decompressor()
            do throws(BytesError) {
                try decompressor.reset(for: format)
                try fresh.reset(for: format)
            } catch {
                Issue.record("\(format): \(error)")
                continue
            }
            if format.isStreamable {
                Self.leaveUnfinished(stream) { (input, output) throws(BytesError) in try decompressor.decompress(input, into: &output) }
            }
            Self.check("Decompressor \(format)", before: Array(stream.prefix(stream.count / 2)), input: stream, capacity: data.count, expected: data,
                       used: { (input, output) throws(BytesError) in _ = try decompressor.decompressAll(input, into: &output, decodedSize: size) },
                       fresh: { (input, output) throws(BytesError) in _ = try fresh.decompressAll(input, into: &output, decodedSize: size) })
        }
    }
}
