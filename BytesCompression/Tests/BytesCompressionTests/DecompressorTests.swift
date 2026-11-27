import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import CLZMA
import Compression
import Darwin
import Testing

// `Decompressor`: every format through one decoder, reset between them (the codecs' own tests cover their streams'
// edges). Whole buffers with and without a stated size, streams in pieces, DEFLATE after history, the errors of the
// wrong mode, raw LZMA and xz taking turns with one window, and memory given back.

/// The process's physical footprint in bytes (what Activity Monitor's Memory column shows).
func physicalFootprint() -> Int {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        // Unsafe: `proc_pid_rusage` writes a `rusage_info_v4` into `info`, which is one.
        unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { unsafe proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    precondition(result == 0, "proc_pid_rusage")
    return Int(info.ri_phys_footprint)
}

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
            (.zstd(), zstdCompress(data), data),
            (.bzip2, bzip2Compress(data, level: 9), data),
            (.lzma(lzmaProperties), lzma, data),
            (.lzma(lzmaProperties, uncompressedSize: data.count), lzma, data),
            (.lzma(lzmaProperties, maximumSize: data.count), lzma, data),
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

    /// Every format whole into a new array (`decompressAll(_:maximumSize:decodedSize:)`): with its size stated, and
    /// without (but raw LZ4) up to a maximum with room to spare or exactly enough; a maximum a byte short, or a stated
    /// size above the maximum, throws.
    @Test func wholeIntoNewArrays() {
        var decompressor = Decompressor()
        let failure = { (result: Result<[UInt8], BytesError>) -> BytesError? in
            if case let .failure(error) = result { return error }
            return nil
        }
        for (format, stream, data) in Self.encodings {
            let stated = format == .lz4(framed: false)
            #expect(throws: Never.self, "\(format)") { try decompressor.reset(for: format) }
            for (maximumSize, decodedSize) in [(data.count, data.count), (data.count + 1000, data.count)] + (stated ? [] : [(data.count + 1000, nil), (data.count, nil)]) {
                let decoded = Result { () throws(BytesError) in
                    try decompressor.decompressAll(stream.span.bytes, maximumSize: maximumSize, decodedSize: decodedSize)
                }
                #expect((try? decoded.get()) == data, "\(format), at most \(maximumSize), size \(String(describing: decodedSize))")
            }
            // (Results first: spans can't be captured by `#expect`'s closures.)
            if !stated {
                let short = Result { () throws(BytesError) in try decompressor.decompressAll(stream.span.bytes, maximumSize: data.count - 1) }
                #expect(failure(short) == .limitExceeded, "\(format)")
            }
            let above = Result { () throws(BytesError) in
                try decompressor.decompressAll(stream.span.bytes, maximumSize: data.count - 1, decodedSize: data.count)
            }
            #expect(failure(above) == .limitExceeded, "\(format)")
        }
        let first = Self.encodings[0].stream
        let negative = Result { () throws(BytesError) in try decompressor.decompressAll(first.span.bytes, maximumSize: -1) }
        #expect(failure(negative) == .invalidValue)
    }

    /// Raw LZMA with its end marker and a maximum size (zip's flag bit 1): a stream decoding past the maximum throws
    /// `limitExceeded` at the symbol that would write the first byte past it, streamed (no byte past the maximum
    /// delivered: what was decoded since the last delivery isn't, the call throwing) and whole (nothing written past
    /// the maximum in a buffer with room for more; all but at most the crossing match, 273 bytes, before it); at its
    /// own size, it decodes.
    @Test func lzmaMaximumSizeStopsAtTheFirstBytePast() throws {
        let stream = Self.encodings.first { $0.format == .lzma(Self.lzmaProperties) }!.stream
        let data = Self.data
        var decompressor = Decompressor()
        for maximum in [data.count - 1, data.count / 2, 70_000, 1, 0, data.count] {
            let format = DecompressionFormat.lzma(Self.lzmaProperties, maximumSize: maximum)
            try decompressor.reset(for: format)
            var streamed: [UInt8] = []
            var consumed = 0
            var failure: BytesError?
            var chunk = [UInt8](repeating: 0, count: 4096)
            while failure == nil {
                let rest = Array(stream[consumed...])
                do throws(BytesError) {
                    let progress = try chunk.withOutputRawSpan { span throws(BytesError) in
                        try decompressor.decompress(rest.span.bytes, into: &span)
                    }
                    streamed += chunk.prefix(progress.produced)
                    consumed += progress.consumed
                    if progress.status == .finished { break }
                } catch {
                    failure = error
                }
            }
            if maximum == data.count {
                #expect(failure == nil && streamed == data)
            } else {
                #expect(failure == .limitExceeded, "at most \(maximum)")
                #expect(streamed.count <= maximum, "at most \(maximum): \(streamed.count) bytes")
                #expect(streamed == Array(data.prefix(streamed.count)), "at most \(maximum)")
            }

            // Whole, into room for all of it and 64 bytes more, filled with a pattern first.
            try decompressor.reset(for: format)
            var whole = [UInt8](repeating: 0xA5, count: data.count + 64)
            let result = Result { () throws(BytesError) in
                try whole.withOutputRawSpan { span throws(BytesError) in
                    _ = try decompressor.decompressAll(stream.span.bytes, into: &span)
                    return span.byteCount
                }
            }
            if maximum == data.count {
                #expect((try? result.get()) == data.count && whole.prefix(data.count).elementsEqual(data))
            } else {
                #expect(result.map { _ in 0 } == .failure(.limitExceeded), "whole, at most \(maximum)")
                #expect(whole.prefix(max(maximum - 273, 0)).elementsEqual(data.prefix(max(maximum - 273, 0))), "whole, at most \(maximum)")
                #expect(whole[maximum...].allSatisfy { $0 == 0xA5 }, "whole, at most \(maximum): written past it")
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
                let concatenated = if case .xz = format { true } else { format == .zstd() }
                let result = streamDecode(stream, outputChunk: 4096, split: split, concatenated: concatenated) { input, output throws(BytesError) in
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

    /// Zstandard's window limit is the format's: a frame asking for 16 MB is refused under HTTP's 8 MB limit (RFC 9659)
    /// before anything is allocated, and decodes with the default (128 MB); the decoder is made anew when the limit
    /// changes, and the limit can't be negative.
    @Test func zstdWindowLimit() throws {
        // An empty frame: no content size, window log 24 (16 MB), then a last raw block of no bytes.
        let frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x70, 0x01, 0x00, 0x00]
        var decompressor = Decompressor()
        var output = [UInt8](repeating: 0, count: 16)
        func stream() throws(BytesError) -> TransformProgress {
            try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompress(frame.span.bytes, into: &span) }
        }
        try decompressor.reset(for: .zstd(maximumWindowSize: 8 << 20))
        #expect(throws: BytesError.limitExceeded) { _ = try stream() }
        try decompressor.reset(for: .zstd())
        #expect(try stream() == TransformProgress(consumed: frame.count, produced: 0, status: .finished))
        try decompressor.reset(for: .zstd(maximumWindowSize: 8 << 20))
        #expect(throws: BytesError.limitExceeded) { _ = try stream() }
        #expect(throws: BytesError.invalidValue) { try decompressor.reset(for: .zstd(maximumWindowSize: -1)) }
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
            // Streaming a format that decodes only whole buffers; history for one that keeps its own window: things the
            // format doesn't do.
            try decompressor.reset(for: format)
            var output = [UInt8](repeating: 0, count: 64)
            if !format.isStreamable {
                #expect(throws: BytesError.unsupported, "\(format)") {
                    _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompress(stream.span.bytes, into: &span) }
                }
            }
            if format.historySize == nil {
                #expect(throws: BytesError.unsupported, "\(format)") {
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
        #expect(throws: BytesError.invalidValue) { try decompressor.reset(for: .lzma(Self.lzmaProperties, maximumSize: -1)) }
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
                let result = streamDecode(stream, outputChunk: 1 << 20, split: [100_000], concatenated: true) { input, output throws(BytesError) in
                    try decompressor.decompress(input, into: &output)
                }
                #expect((try? result.get())?.output == data, "\(format)")
            }
        }
    }

    /// DEFLATE's containers through the one DEFLATE decoder `Decompressor` keeps (fix plan D5), switched mid-stream: a
    /// gzip stream left half decoded, then zlib whole, raw in pieces, gzip in pieces, and two gzip members, each
    /// decoding as a fresh decoder would (no state of the stream before: its stage, checksum, length, or header).
    @Test func oneDeflateDecoderTakesEveryContainer() throws {
        var decompressor = Decompressor()
        let raw = encodeAll(Self.data, format: .raw, level: 6)
        let zlib = encodeAll(Self.data, format: .zlib, level: 6)
        let gzip = encodeAll(Self.data, format: .gzip, level: 6)
        let half = Self.data.count / 2
        let members = encodeAll(Array(Self.data[..<half]), format: .gzip, level: 1) + encodeAll(Array(Self.data[half...]), format: .gzip, level: 9)
        for _ in 0..<2 {
            // A gzip stream started and left: its header read, its checksum and length under way.
            try decompressor.reset(for: .deflate(.gzip))
            var output = [UInt8](repeating: 0, count: 4096)
            _ = try output.withOutputRawSpan { span throws(BytesError) in
                try decompressor.decompress(gzip.span.bytes.extracting(0..<(gzip.count / 3)), into: &span)
            }
            let whole = Self.decodeAll(zlib, format: .deflate(.zlib), decodedSize: Self.data.count, capacity: Self.data.count, with: &decompressor)
            #expect(whole.map(\.output) == .success(Self.data))
            for (container, stream) in [(DeflateFormat.raw, raw), (.gzip, gzip), (.gzip, members), (.zlib, zlib)] {
                try decompressor.reset(for: .deflate(container))
                let finished = decompressor.isFinished // `#expect` doesn't take a `~Copyable` value's property.
                #expect(!finished, "\(container)")
                let result = streamDecode(stream, outputChunk: 4096, split: [7, 19, 1000], concatenated: container == .gzip) { input, output throws(BytesError) in
                    try decompressor.decompress(input, into: &output)
                }
                #expect((try? result.get())?.output == Self.data, "\(container)")
            }
        }
        // The decoder itself: a DEFLATE decoder takes every container; a Deflate64 one only raw, and refusing the others
        // leaves it decoding Deflate64.
        var deflate = DeflateDecoder(format: .raw)
        for (container, stream) in [(DeflateFormat.gzip, gzip), (.zlib, zlib), (.raw, raw)] {
            try deflate.reset(format: container)
            let format = deflate.format, hasHeader = deflate.gzipHeader != nil
            #expect(format == container && hasHeader == false)
            var output = [UInt8](repeating: 0, count: Self.data.count)
            let consumed = try output.withOutputRawSpan { span throws(BytesError) in try deflate.decompressAll(stream.span.bytes, into: &span) }
            let headerAfter = deflate.gzipHeader != nil
            #expect(consumed == stream.count && output == Self.data, "\(container)")
            #expect(headerAfter == (container == .gzip), "\(container)")
        }
        var deflate64 = DeflateDecoder(variant: .deflate64)
        #expect(throws: BytesError.unsupported) { try deflate64.reset(format: .zlib) }
        #expect(throws: BytesError.unsupported) { try deflate64.reset(format: .gzip) }
        try deflate64.reset(format: .raw)
        let variant = deflate64.variant, format = deflate64.format
        #expect(variant == .deflate64 && format == .raw)
        var output = [UInt8](repeating: 0, count: Deflate64Tests.longReach.count)
        let dynamic = Deflate64Tests.dynamic // A span of the static's value would be a temporary's.
        _ = try output.withOutputRawSpan { span throws(BytesError) in try deflate64.decompressAll(dynamic.span.bytes, into: &span) }
        #expect(output == Deflate64Tests.longReach)
    }

    /// HTTP's `deflate` coding, zlib or raw by its first two bytes: zlib's headers at every level and window, our
    /// encoder's raw streams at every level never (their first block's bits can't make method 8), and the edges of
    /// the header's rules.
    @Test func zlibOrRawDecidesByTheHeader() {
        #expect(DeflateFormat(zlibOrRaw: [UInt8]().span.bytes) == nil)
        #expect(DeflateFormat(zlibOrRaw: [UInt8(0x78)].span.bytes) == nil)
        for level in 0...9 {
            for (name, sample) in smallSamples() {
                #expect(DeflateFormat(zlibOrRaw: encodeAll(sample, format: .zlib, level: level).span.bytes) == .zlib, "\(name), level \(level)")
                #expect(DeflateFormat(zlibOrRaw: encodeAll(sample, format: .raw, level: level).span.bytes) == .raw, "\(name), level \(level)")
            }
        }
        for windowBits: Int32 in 9...15 {
            let stream = Zlib.compress(Self.data, windowBits: windowBits, level: 6)
            #expect(DeflateFormat(zlibOrRaw: stream.span.bytes) == .zlib, "window bits \(windowBits)")
        }
        // Check bits that don't make a multiple of 31, a 64 KiB window (CINFO 8), another method (9): raw.
        for header: [UInt8] in [[0x78, 0x9D], [0x88, 0x1C], [0x79, 0x18]] {
            #expect(DeflateFormat(zlibOrRaw: header.span.bytes) == .raw, "\(header)")
        }
        // A preset dictionary is still zlib's header (the decoder refuses it).
        #expect(DeflateFormat(zlibOrRaw: [UInt8]([0x78, 0xBB]).span.bytes) == .zlib)
    }

    /// `releaseMemory()` frees every format's state and keeps the format: decoding throws until a reset, and then
    /// every format decodes again, whole and streamed (`reset()` remaking the kept format, as a pipeline's next message
    /// does). A stream in progress is discarded.
    @Test func releaseMemoryForgetsEveryFormat() throws {
        var decompressor = Decompressor()
        for (format, stream, data) in Self.encodings {
            // Its state made and used, then a stream left half decoded where it can be.
            let first = Self.decodeAll(stream, format: format, decodedSize: data.count, capacity: data.count, with: &decompressor)
            #expect(first.map(\.output) == .success(data), "\(format)")
            var output = [UInt8](repeating: 0, count: 4096)
            if format.isStreamable {
                try decompressor.reset(for: format)
                _ = try output.withOutputRawSpan { span throws(BytesError) in
                    try decompressor.decompress(stream.span.bytes.extracting(0..<(stream.count / 2)), into: &span)
                }
            }
            decompressor.releaseMemory()
            let kept = decompressor.format, finished = decompressor.isFinished
            #expect(kept == format && !finished, "\(format)")
            #expect(throws: BytesError.invalidValue, "\(format)") {
                _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompressAll(stream.span.bytes, into: &span) }
            }
            if format.isStreamable {
                #expect(throws: BytesError.invalidValue, "\(format)") {
                    _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompress(stream.span.bytes, into: &span) }
                }
                decompressor.reset()
                let concatenated = if case .xz = format { true } else { format == .zstd() }
                let split = if case .xz = format { [70_000, 3] } else { [7, 19, 1000] } // xz: at least a unit's worth
                let streamed = streamDecode(stream, outputChunk: 4096, split: split, concatenated: concatenated) { input, output throws(BytesError) in
                    try decompressor.decompress(input, into: &output)
                }
                #expect((try? streamed.get())?.output == data, "\(format), streamed after reset()")
            }
            let again = Self.decodeAll(stream, format: format, decodedSize: data.count, capacity: data.count, with: &decompressor)
            #expect(again.map(\.output) == .success(data), "\(format), whole after reset(for:)")
        }
    }

    /// A Zstandard frame that makes a streaming decoder reserve and touch a 32 MiB window: no content size, window log
    /// 25, and 300 RLE blocks of 128 KiB of `0xAB` (37.5 MiB; tiny to decode, even in a debug build).
    static func largeWindowFrame() -> (frame: [UInt8], decodedCount: Int) {
        // Magic; frame header descriptor 0 (no content size, not single-segment); window descriptor exponent 15.
        var frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 15 << 3]
        let blocks = 300
        for index in 0..<blocks {
            let header = UInt32(index == blocks - 1 ? 1 : 0) | 1 << 1 | UInt32(128 << 10) << 3 // last, RLE, size
            frame += [UInt8(truncatingIfNeeded: header), UInt8(truncatingIfNeeded: header >> 8), UInt8(truncatingIfNeeded: header >> 16), 0xAB]
        }
        return (frame, blocks * (128 << 10))
    }

    /// Streams `frame` through `decompressor` in 1 MiB pieces of output, checking every byte is `0xAB`.
    static func streamLargeWindowFrame(_ frame: [UInt8], decodedCount: Int, with decompressor: inout Decompressor) throws(BytesError) {
        try decompressor.reset(for: .zstd())
        var output = [UInt8](repeating: 0, count: 1 << 20)
        var consumed = 0
        var produced = 0
        while true {
            let progress = try output.withOutputRawSpan { span throws(BytesError) in
                try decompressor.decompress(frame.span.bytes.extracting(consumed...), into: &span)
            }
            consumed += progress.consumed
            precondition(output[..<progress.produced].allSatisfy { $0 == 0xAB }, "the frame's bytes")
            produced += progress.produced
            if progress.status == .finished { break }
        }
        precondition(produced == decodedCount && consumed == frame.count, "the whole frame")
    }

    /// `releaseMemory()` gives a large window back to the system: the footprint falls by most of the 32 MiB zstd window
    /// the frame touched, and so it does when the decompressor is dropped; and by most of an xz stream's 12 MiB window.
    /// (malloc kept a freed window of any size in the footprint; windows of 9 MiB or more are mapped now.) In a
    /// process of its own, so other tests' memory doesn't move the measurement; the frame decodes the same after the
    /// release.
    @Test func releaseMemoryGivesALargeWindowBack() async {
        await #expect(processExitsWith: .success) {
            let (frame, decodedCount) = DecompressorTests.largeWindowFrame()
            var decompressor = Decompressor()
            try! DecompressorTests.streamLargeWindowFrame(frame, decodedCount: decodedCount, with: &decompressor)
            let held = physicalFootprint()
            decompressor.releaseMemory()
            let released = physicalFootprint()
            precondition(held - released >= 24 << 20, "releaseMemory gave back \(held - released) bytes")
            // Again after the release, then dropped.
            try! DecompressorTests.streamLargeWindowFrame(frame, decodedCount: decodedCount, with: &decompressor)
            let heldAgain = physicalFootprint()
            _ = consume decompressor
            let dropped = physicalFootprint()
            precondition(heldAgain - dropped >= 24 << 20, "dropping the decompressor gave back \(heldAgain - dropped) bytes")

            // xz with a 16 MiB dictionary over 12 MiB of zeros: the block headers state the size, so the window is
            // 12 MiB (mapped), all of it touched.
            let zeros = [UInt8](repeating: 0, count: 12 << 20)
            let xz = xzCompress(zeros, options: lzmaOptions(preset: 0, dictionary: 16 << 20))
            var decoder = Decompressor()
            try! decoder.reset(for: .xz())
            let streamed = try! streamDecode(xz, outputChunk: 1 << 20, split: nil, concatenated: true) { input, output throws(BytesError) in
                try decoder.decompress(input, into: &output)
            }.get()
            precondition(streamed.output == zeros, "the xz stream's bytes")
            let heldXZ = physicalFootprint()
            decoder.releaseMemory()
            let releasedXZ = physicalFootprint()
            precondition(heldXZ - releasedXZ >= 8 << 20, "releaseMemory gave back \(heldXZ - releasedXZ) bytes of xz's window")
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
