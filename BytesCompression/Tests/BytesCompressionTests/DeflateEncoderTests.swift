import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing
import zlib

/// Encodes with `compressAll`.
func encodeAll(_ data: [UInt8], format: DeflateFormat, level: Int) -> [UInt8] {
    var encoder = DeflateEncoder(format: format, level: level)
    var output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: data.count, format: format))
    let produced: Int? = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        guard (try? encoder.compressAll(data.span.bytes, into: &span)) != nil else { return nil }
        return span.finalize(for: buffer)
    }
    return Array(output[..<produced!])
}

/// Encodes in pieces of up to `chunk` bytes into an output buffer of `outputChunk` bytes, with `flush`
/// after every piece and `.finish` at the end.
func encodeStreaming(_ data: [UInt8], format: DeflateFormat, level: Int, chunk: Int, outputChunk: Int, flush: TransformFlush = .none) throws(BytesError) -> [UInt8] {
    var encoder = DeflateEncoder(format: format, level: level)
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    var offset = 0
    repeat {
        let end = min(offset + chunk, data.count)
        var piece = Array(data[offset..<end])
        let mode: TransformFlush = end == data.count ? .finish : flush
        while true {
            let (progress, produced) = try buffer.withOutputRawSpan { span throws(BytesError) in
                try (encoder.compress(piece.span.bytes, into: &span, flush: mode), span.byteCount)
            }
            result += buffer[..<produced]
            piece.removeFirst(progress.consumed)
            if progress.status == .finished || (progress.status == .needsInput && piece.isEmpty) { break }
        }
        offset = end
    } while offset < data.count
    return result
}

@Suite struct DeflateEncoderTests {
    static let formats: [DeflateFormat] = [.raw, .zlib, .gzip]

    static func checkRoundTrips(_ samples: [(name: String, bytes: [UInt8])], level: Int, formats: [DeflateFormat] = formats) {
        for (name, bytes) in samples {
            for format in formats {
                let compressed = encodeAll(bytes, format: format, level: level)
                #expect(zlibDecompress(compressed, format: format) == .decoded(bytes), "zlib: \(name), level \(level), \(format)")
                #expect(decodeAll(compressed, format: format) == .decoded(bytes), "Bytes: \(name), level \(level), \(format)")
            }
        }
    }

    /// Every level on the samples under 1 MB, raw, and zlib and gzip (which wrap the same blocks) at levels 0, 1, and
    /// 6. The large sample (every level and format) in DeflateEncoderBulkTests; ParallelDeflateTests encodes it here.
    @Test(arguments: 0...9)
    func roundTripsEveryLevel(level: Int) {
        Self.checkRoundTrips(smallSamples(), level: level, formats: [0, 1, 6].contains(level) ? Self.formats : [.raw])
    }

    static func checkStreamingRoundTrips(level: Int, windows: [UInt8]) throws {
        for (name, bytes) in samples() where bytes.count <= 1 << 20 {
            for (chunk, outputChunk) in [(1, 7), (1000, 1), (4096, 333), (100_000, 65_536), (300_000, 1 << 20)] where chunk > 1 || bytes.count <= 20_000 {
                let compressed = try encodeStreaming(bytes, format: .gzip, level: level, chunk: chunk, outputChunk: outputChunk)
                #expect(zlibDecompress(compressed, format: .gzip) == .decoded(bytes), "\(name), level \(level), chunks \(chunk)/\(outputChunk)")
            }
        }
        // Several windows' worth.
        let compressed = try encodeStreaming(windows, format: .zlib, level: level, chunk: 70_000, outputChunk: 50_000)
        #expect(zlibDecompress(compressed, format: .zlib) == .decoded(windows))
    }

    /// Several windows' worth: the 200 KB text sample (six windows) here, the 3 MB one in DeflateEncoderBulkTests.
    @Test(arguments: [1, 6, 9])
    func streamingRoundTrips(level: Int) throws {
        try Self.checkStreamingRoundTrips(level: level, windows: samples()[2].bytes)
    }

    /// After each sync flush, everything so far decodes: messages over one compressed stream.
    @Test(arguments: [1, 6])
    func syncFlushMakesEachMessageDecodable(level: Int) throws {
        var rng = SplitMix64(seed: 3)
        let text = samples()[2].bytes
        var encoder = DeflateEncoder(format: .raw, level: level)
        var decoder = DeflateDecoder(format: .raw)
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        var decoded = [UInt8](repeating: 0, count: 1 << 18)
        for _ in 0..<200 {
            let start = Int.random(in: 0..<(text.count - 3000), using: &rng)
            let message = Array(text[start..<(start + Int.random(in: 1...3000, using: &rng))])
            let compressedCount = try buffer.withOutputRawSpan { span throws(BytesError) in
                let progress = try encoder.compress(message.span.bytes, into: &span, flush: .flush)
                #expect(progress.status == .needsInput && progress.consumed == message.count)
                return span.byteCount
            }
            let compressed = Array(buffer[..<compressedCount])
            // A flushed message ends with the empty stored block's 00 00 FF FF.
            #expect(compressed.suffix(4) == [0, 0, 0xFF, 0xFF])
            let outputCount = try decoded.withOutputRawSpan { span throws(BytesError) in
                let progress = try decoder.decompress(compressed.span.bytes, into: &span)
                #expect(progress.status == .needsInput && progress.consumed == compressed.count)
                return span.byteCount
            }
            let output = Array(decoded[..<outputCount])
            #expect(output == message)
        }
    }

    /// A flush whose last bytes (too few to hash, so never inserted) span the 32 KB rebase point: positions
    /// then pass it without landing on it. The tables must still rebase, or every match after is lost (the
    /// output stays correct, only bigger: 14% became 62% after 26 MB of a socket stream).
    @Test(arguments: [1, 6])
    func flushAcrossTheRebasePointKeepsMatching(level: Int) throws {
        var text: [UInt8] = []
        while text.count < 600_000 {
            text += samples()[2].bytes
        }
        var encoder = DeflateEncoder(format: .raw, level: level)
        var output = [UInt8](repeating: 0, count: text.count * 2)
        var produced = 0
        var offset = 0
        // The first flush ends 2 bytes past 32 KB; the rest every 64 KB.
        for end in [32_770] + Array(stride(from: 32_770 + 65_536, to: text.count, by: 65_536)) + [text.count] {
            let written = try output.withOutputRawSpan(overwritingFrom: produced) { span throws(BytesError) in
                let progress = try encoder.compress(text.span.bytes.extracting(offset..<end), into: &span, flush: end == text.count ? .finish : .flush)
                #expect(progress.consumed == end - offset)
                return span.byteCount
            }
            produced += written
            offset = end
        }
        let streamed = Array(output[..<produced])
        #expect(zlibDecompress(streamed, format: .raw) == .decoded(text))
        let whole = encodeAll(text, format: .raw, level: level).count
        #expect(Double(streamed.count) <= Double(whole) * 1.1, "level \(level): streamed \(streamed.count), whole \(whole)")
    }

    @Test func ratiosAreCloseToZlib() {
        let text = samples()[2].bytes
        for (level, zlibLevel) in [(1, Int32(1)), (6, 6), (9, 9)] {
            let ours = encodeAll(text, format: .raw, level: level).count
            let zlibs = zlibCompress(text, format: .raw, level: zlibLevel).count
            #expect(Double(ours) <= Double(zlibs) * 1.08, "level \(level): \(ours) vs zlib \(zlibs)")
        }
    }

    @Test func incompressibleDataIsStored() {
        let random = samples()[3].bytes
        let compressed = encodeAll(random, format: .raw, level: 6)
        #expect(compressed.count <= random.count + random.count / 1000 + 16)
    }

    @Test func outputTooSmallThrows() {
        let text = samples()[2].bytes
        var encoder = DeflateEncoder(format: .gzip, level: 6)
        var output = [UInt8](repeating: 0, count: 100)
        output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
            #expect(throws: BytesError.insufficientCapacity) { try encoder.compressAll(text.span.bytes, into: &span) }
            _ = span.finalize(for: buffer)
        }
    }
}

/// A `Compressor` moved from one DEFLATE level to another keeps its encoder (`DeflateEncoder.reset(level:)`, which
/// allocates the tables a level reads that the earlier didn't, and clears only those the level reads): each stream
/// after the move is a fresh encoder's, byte for byte.
@Suite struct DeflateLevelChangeTests {
    static func encode(_ compressor: inout Compressor, _ format: CompressionFormat, _ data: [UInt8]) throws -> [UInt8] {
        try compressor.reset(for: format)
        var output = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: data.count, format: .gzip))
        let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try compressor.compressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        return Array(output.prefix(count))
    }

    /// Streams at `from`, then one at `to`, through one compressor, against a fresh compressor at `to`. The second
    /// streams include one under 512 bytes, which parses with 3-byte matches: the only streams that read the 3-byte
    /// heads, so the only ones a head left from the earlier stream would change.
    static func checkLevelChanges(from levels: [Int], to targets: [Int], size: Int) throws {
        let first = SampleBytes.text(size, seed: 5)
        for second in [SampleBytes.text(size, seed: 6), Array(first.prefix(400))] {
            for to in targets {
                var fresh = Compressor()
                let expected = try encode(&fresh, .deflate(.gzip, level: to), second)
                for from in levels {
                    var compressor = Compressor()
                    _ = try encode(&compressor, .deflate(.gzip, level: from), first)
                    #expect(try encode(&compressor, .deflate(.gzip, level: to), second) == expected, "level \(from) → \(to), \(second.count) bytes")
                }
            }
        }
    }

    @Test func levelChangesEncodeAsAFreshEncoder() throws {
        try Self.checkLevelChanges(from: [0, 1, 2, 6, 9], to: [0, 1, 2, 6, 9], size: 4_096)
    }
}

/// The large sample at every level and format, and streamed whole at every level.
@Suite(.bulk) struct DeflateEncoderBulkTests {
    @Test(arguments: 0...9)
    func roundTripsEveryLevel(level: Int) {
        DeflateEncoderTests.checkRoundTrips(samples(), level: level)
    }

    /// Every level to every level, on 64 KB streams.
    @Test func levelChangesEncodeAsAFreshEncoder() throws {
        try DeflateLevelChangeTests.checkLevelChanges(from: Array(0...9), to: Array(0...9), size: 64 << 10)
    }

    @Test(arguments: [1, 6, 9])
    func streamingRoundTrips(level: Int) throws {
        try DeflateEncoderTests.checkStreamingRoundTrips(level: level, windows: largeSample())
    }
}
