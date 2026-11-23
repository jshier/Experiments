import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import CLZMA
import Compression
import Testing

// `Decompressor`: every format through one decoder, reset between them (the codecs' own tests cover their streams'
// edges). Whole buffers with and without a stated size, streams in pieces, DEFLATE after history, the errors of the
// wrong mode, and raw LZMA and xz taking turns with one window.

@Suite struct DecompressorTests {
    /// 200 KB of text: every encoder here takes it, and LZMA's and xz's windows matter at this size.
    static let data = Array(lzmaSamples().first { $0.name == "text" }!.bytes.prefix(200_000))

    static let lzmaProperties = try! LZMAProperties(byte: 0x5D, dictionarySize: 1 << 20)

    /// Every format's encoding of ``data`` (Deflate64's of its own data, which only Deflate64 can code).
    static let encodings: [(format: DecompressionFormat, stream: [UInt8], data: [UInt8])] = {
        let lzma = lzma1Compress(data, options: lzmaOptions(preset: 6, dictionary: 1 << 20), marker: true)
        return [
            (.deflate(.raw), encodeAll(data, format: .raw, level: 6), data),
            (.deflate(.zlib), encodeAll(data, format: .zlib, level: 6), data),
            (.deflate(.gzip), encodeAll(data, format: .gzip, level: 6), data),
            (.deflate64, Deflate64Tests.dynamic, Deflate64Tests.longReach),
            (.brotli, brotliEncodeAll(data, quality: 5), data),
            (.zstd, zstdCompress(data), data),
            (.bzip2, bzip2Compress(data, level: 9), data),
            (.lzma(lzmaProperties), lzma, data),
            (.lzma(lzmaProperties, uncompressedSize: data.count), lzma, data),
            (.lzma(lzmaProperties, sizeHint: data.count), lzma, data),
            (.xz(), xzCompress(data, preset: 6), data),
            (.xz(sizeHint: data.count), xzCompress(data, preset: 6), data),
            (.lzfse, AppleCompression.encode(data, COMPRESSION_LZFSE), data),
            (.lzvn, AppleCompression.encode(data, AppleCompression.lzvnRaw), data),
            (.lz4(framed: false), AppleCompression.encode(data, COMPRESSION_LZ4_RAW), data),
            (.lz4(framed: true), AppleCompression.encode(data, COMPRESSION_LZ4), data),
            (.lzbitmap, lzbitmapCompress(data), data),
            (.lzraven, lzravenCompress(data), data),
        ]
    }()

    /// Decodes `stream` whole with `decompressor`, into exactly `capacity` bytes of room.
    static func decodeAll(
        _ stream: [UInt8], format: DecompressionFormat, decodedSize: Int?, capacity: Int, with decompressor: inout Decompressor
    ) -> Result<(output: [UInt8], consumed: Int), BytesError> {
        var output = [UInt8](repeating: 0, count: capacity)
        do throws(BytesError) {
            try decompressor.reset(for: format)
            var consumed = 0
            let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
                consumed = try decompressor.decompressAll(stream.span.bytes, into: &span, decodedSize: decodedSize)
                return span.byteCount
            }
            return .success((Array(output.prefix(count)), consumed))
        } catch {
            return .failure(error)
        }
    }

    /// Every format whole, through one decoder, twice over (the second time on the state the first made), with the
    /// decoded size stated (and without, but for raw LZ4).
    @Test func wholeBuffers() {
        var decompressor = Decompressor()
        for _ in 0..<2 {
            for (format, stream, data) in Self.encodings {
                for decodedSize in format == .lz4(framed: false) ? [data.count] : [data.count, nil] {
                    let result = Self.decodeAll(stream, format: format, decodedSize: decodedSize, capacity: data.count, with: &decompressor)
                    #expect((try? result.get())?.output == data, "\(format), size \(String(describing: decodedSize))")
                    #expect((try? result.get())?.consumed == stream.count, "\(format)")
                }
            }
        }
    }

    /// The streaming formats in pieces: output 4 KB at a time, input fed as the decoder asks, in odd sizes (xz at
    /// least a unit's worth).
    @Test func streams() {
        var decompressor = Decompressor()
        for (format, stream, data) in Self.encodings where format.isStreamable {
            let splits: [[Int]?] = if case .xz = format { [nil, [70_000, 3]] } else { [nil, [7, 19, 1000]] }
            for split in splits {
                do throws(BytesError) {
                    try decompressor.reset(for: format)
                } catch {
                    Issue.record("\(format): \(error)")
                    continue
                }
                let concatenated = if case .xz = format { true } else { format == .zstd }
                let result = streamDecode(stream, outputChunk: 4096, split: split, concatenated: concatenated) { (input, output) throws(BytesError) in
                    try decompressor.decompress(input, into: &output)
                }
                #expect((try? result.get())?.output == data, "\(format), split \(String(describing: split))")
                let finished = decompressor.isFinished // `#expect` doesn't take a `~Copyable` value's property.
                #expect(finished, "\(format)")
            }
        }
    }

    /// DEFLATE and Deflate64 into 128 KB buffers, the history moved to each one's front, as NativeZip decodes.
    @Test func afterHistory() throws {
        var decompressor = Decompressor()
        for (format, stream, data) in Self.encodings {
            guard let historySize = format.historySize else { continue }
            try decompressor.reset(for: format)
            var buffer = [UInt8](repeating: 0, count: historySize + (128 << 10))
            var output: [UInt8] = []
            var consumed = 0
            var history = 0
            while true {
                var span = buffer.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                let progress = try decompressor.decompress(stream.span.bytes.extracting(consumed...), into: &raw, historyCount: history)
                consumed += progress.consumed
                output += buffer[history..<(history + progress.produced)]
                if progress.status == .finished { break }
                try #require(progress.status == .needsOutput, "\(format)")
                let end = history + progress.produced
                let kept = min(historySize, end)
                buffer.replaceSubrange(0..<kept, with: buffer[(end - kept)..<end])
                history = kept
            }
            #expect(output == data, "\(format)")
            #expect(consumed == stream.count, "\(format)")
        }
    }

    @Test func wrongModesAndSizes() throws {
        var decompressor = Decompressor()
        // Before any format.
        var fresh = Decompressor()
        #expect(throws: BytesError.invalidValue) {
            var output = [UInt8](repeating: 0, count: 16)
            _ = try output.withOutputRawSpan { span throws(BytesError) in try fresh.decompress([1, 2, 3].span.bytes, into: &span) }
        }
        let (format, finished) = (fresh.format, fresh.isFinished)
        #expect(format == nil && !finished)
        for (format, stream, data) in Self.encodings {
            // A size other than the stream's; room for fewer than the size.
            let wrong = Self.decodeAll(stream, format: format, decodedSize: data.count - 1, capacity: data.count, with: &decompressor)
            #expect(throws: (any Error).self, "\(format)") { _ = try wrong.get() }
            #expect(
                Self.decodeAll(stream, format: format, decodedSize: data.count, capacity: data.count - 1, with: &decompressor).map(\.consumed)
                    == .failure(.insufficientCapacity), "\(format)"
            )
            // Streaming a format that decodes only whole buffers; history for one that keeps its own window.
            try decompressor.reset(for: format)
            var output = [UInt8](repeating: 0, count: 64)
            if !format.isStreamable {
                #expect(throws: BytesError.invalidValue, "\(format)") {
                    _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompress(stream.span.bytes, into: &span) }
                }
            }
            if format.historySize == nil {
                #expect(throws: BytesError.invalidValue, "\(format)") {
                    var span = output.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    _ = try decompressor.decompress(stream.span.bytes, into: &raw, historyCount: 0)
                }
            }
        }
        // A raw LZ4 block without its size; negative sizes and hints.
        let lz4 = Self.encodings.first { $0.format == .lz4(framed: false) }!
        #expect(Self.decodeAll(lz4.stream, format: lz4.format, decodedSize: nil, capacity: lz4.data.count, with: &decompressor).map(\.consumed) == .failure(.invalidValue))
        #expect(Self.decodeAll(lz4.stream, format: lz4.format, decodedSize: -1, capacity: 16, with: &decompressor).map(\.consumed) == .failure(.invalidValue))
        #expect(throws: BytesError.invalidValue) { try decompressor.reset(for: .xz(sizeHint: -1)) }
        #expect(throws: BytesError.invalidValue) { try decompressor.reset(for: .lzma(Self.lzmaProperties, sizeHint: -1)) }
    }

    /// Raw LZMA and xz taking turns, streamed: each takes the one window (sized for the larger stream) and decodes.
    @Test func lzmaAndXZShareTheWindow() throws {
        var decompressor = Decompressor()
        let large = Array(largeSample().prefix(3 << 20))
        let streams: [(DecompressionFormat, [UInt8], [UInt8])] = [
            (.xz(), xzCompress(large, options: lzmaOptions(preset: 3, dictionary: 1 << 20)), large),
            (.lzma(Self.lzmaProperties), lzma1Compress(Self.data, options: lzmaOptions(preset: 6, dictionary: 1 << 20), marker: true), Self.data),
            (.xz(sizeHint: Self.data.count), xzCompress(Self.data, preset: 1), Self.data),
            (.lzma(Self.lzmaProperties, uncompressedSize: large.count), lzma1Compress(large, options: lzmaOptions(preset: 3, dictionary: 1 << 20), marker: false), large),
        ]
        for _ in 0..<2 {
            for (format, stream, data) in streams {
                try decompressor.reset(for: format)
                let result = streamDecode(stream, outputChunk: 1 << 20, split: [100_000], concatenated: true) { (input, output) throws(BytesError) in
                    try decompressor.decompress(input, into: &output)
                }
                #expect((try? result.get())?.output == data, "\(format)")
            }
        }
    }

    /// The decoder as a pipeline stage: `.finish` with the whole stream, and with it cut short (which never
    /// finishes: it throws, or for DEFLATE and Brotli asks for input, as their own decoders do).
    @Test func transform() throws {
        var decompressor = Decompressor()
        for (format, stream, data) in Self.encodings where format.isStreamable {
            try decompressor.reset(for: format)
            var output = [UInt8](repeating: 0, count: data.count)
            let progress = try output.withOutputRawSpan { span throws(BytesError) in
                try decompressor.transform(stream.span.bytes, into: &span, flush: .finish)
            }
            #expect(progress.produced == data.count && output == data, "\(format)")
            decompressor.reset()
            var cut: TransformStatus?
            do throws(BytesError) {
                cut = try output.withOutputRawSpan { span throws(BytesError) in
                    try decompressor.transform(stream.span.bytes.extracting(0..<(stream.count / 2)), into: &span, flush: .finish)
                }.status
            } catch {
                #expect(error == .insufficientData, "\(format)")
            }
            #expect(cut != .finished, "\(format)")
        }
    }
}
