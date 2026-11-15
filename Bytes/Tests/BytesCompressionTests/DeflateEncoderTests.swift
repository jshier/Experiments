import Bytes
import BytesCompression
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
func encodeStreaming(_ data: [UInt8], format: DeflateFormat, level: Int, chunk: Int, outputChunk: Int, flush: TransformFlush = .none) -> [UInt8] {
    var encoder = DeflateEncoder(format: format, level: level)
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    var offset = 0
    repeat {
        let end = min(offset + chunk, data.count)
        var piece = Array(data[offset..<end])
        let mode: TransformFlush = end == data.count ? .finish : flush
        while true {
            let progress: TransformProgress = buffer.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: raw, initializedCount: 0)
                let progress = try! encoder.compress(piece.span.bytes, into: &span, flush: mode)
                result += raw[..<span.finalize(for: raw)]
                return progress
            }
            piece.removeFirst(progress.consumed)
            if progress.status == .finished || (progress.status == .needsInput && piece.isEmpty) { break }
        }
        offset = end
    } while offset < data.count
    return result
}

@Suite struct DeflateEncoderTests {
    static let formats: [DeflateFormat] = [.raw, .zlib, .gzip]

    @Test(arguments: 0...9)
    func roundTripsEveryLevel(level: Int) {
        for (name, bytes) in samples() {
            for format in Self.formats {
                let compressed = encodeAll(bytes, format: format, level: level)
                #expect(zlibDecompress(compressed, format: format) == .decoded(bytes), "zlib: \(name), level \(level), \(format)")
                #expect(decodeAll(compressed, format: format) == .decoded(bytes), "Bytes: \(name), level \(level), \(format)")
            }
        }
    }

    @Test(arguments: [1, 6, 9])
    func streamingRoundTrips(level: Int) {
        for (name, bytes) in samples() where bytes.count <= 1 << 20 {
            for (chunk, outputChunk) in [(1, 7), (1000, 1), (4096, 333), (100_000, 65_536), (300_000, 1 << 20)] where chunk > 1 || bytes.count <= 20_000 {
                let compressed = encodeStreaming(bytes, format: .gzip, level: level, chunk: chunk, outputChunk: outputChunk)
                #expect(zlibDecompress(compressed, format: .gzip) == .decoded(bytes), "\(name), level \(level), chunks \(chunk)/\(outputChunk)")
            }
        }
        // Several windows' worth.
        let large = samples().last!.bytes
        let compressed = encodeStreaming(large, format: .zlib, level: level, chunk: 70_000, outputChunk: 50_000)
        #expect(zlibDecompress(compressed, format: .zlib) == .decoded(large))
    }

    /// After each sync flush, everything so far decodes: messages over one compressed stream.
    @Test(arguments: [1, 6])
    func syncFlushMakesEachMessageDecodable(level: Int) {
        var rng = SplitMix64(state: 3)
        let text = samples()[2].bytes
        var encoder = DeflateEncoder(format: .raw, level: level)
        var decoder = DeflateDecoder(format: .raw)
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        var decoded = [UInt8](repeating: 0, count: 1 << 18)
        for _ in 0..<200 {
            let start = Int.random(in: 0..<(text.count - 3000), using: &rng)
            let message = Array(text[start..<(start + Int.random(in: 1...3000, using: &rng))])
            let compressed: [UInt8] = buffer.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: raw, initializedCount: 0)
                let progress = try! encoder.compress(message.span.bytes, into: &span, flush: .flush)
                #expect(progress.status == .needsInput && progress.consumed == message.count)
                return Array(raw[..<span.finalize(for: raw)])
            }
            // A flushed message ends with the empty stored block's 00 00 FF FF.
            #expect(compressed.suffix(4) == [0, 0, 0xFF, 0xFF])
            let output: [UInt8] = decoded.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: raw, initializedCount: 0)
                let progress = try! decoder.decompress(compressed.span.bytes, into: &span)
                #expect(progress.status == .needsInput && progress.consumed == compressed.count)
                return Array(raw[..<span.finalize(for: raw)])
            }
            #expect(output == message)
        }
    }

    /// A flush whose last bytes (too few to hash, so never inserted) span the 32 KB rebase point: positions
    /// then pass it without landing on it. The tables must still rebase, or every match after is lost (the
    /// output stays correct, only bigger: 14% became 62% after 26 MB of a socket stream).
    @Test(arguments: [1, 6])
    func flushAcrossTheRebasePointKeepsMatching(level: Int) {
        var text: [UInt8] = []
        while text.count < 600_000 { text += samples()[2].bytes }
        var encoder = DeflateEncoder(format: .raw, level: level)
        var output = [UInt8](repeating: 0, count: text.count * 2)
        var produced = 0
        var offset = 0
        // The first flush ends 2 bytes past 32 KB; the rest every 64 KB.
        for end in [32_770] + Array(stride(from: 32_770 + 65_536, to: text.count, by: 65_536)) + [text.count] {
            output.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: UnsafeMutableRawBufferPointer(rebasing: raw[produced...]), initializedCount: 0)
                let progress = try! encoder.compress(text.span.bytes.extracting(offset..<end), into: &span, flush: end == text.count ? .finish : .flush)
                #expect(progress.consumed == end - offset)
                produced += span.finalize(for: UnsafeMutableRawBufferPointer(rebasing: raw[produced...]))
            }
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
