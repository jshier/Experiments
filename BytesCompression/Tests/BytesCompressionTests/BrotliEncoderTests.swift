import Bytes
import BytesCompression
import BytesTestSupport
import CBrotli
import Testing

func brotliEncodeAll(_ data: [UInt8], quality: Int, windowBits: Int = 22) -> [UInt8] {
    var encoder = BrotliEncoder(quality: quality, windowBits: windowBits)
    var output = [UInt8](repeating: 0, count: BrotliEncoder.maximumCompressedSize(forByteCount: data.count))
    let produced: Int? = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        guard (try? encoder.compressAll(data.span.bytes, into: &span)) != nil else { return nil }
        return span.finalize(for: buffer)
    }
    return Array(output[..<produced!])
}

func brotliEncodeStreaming(
    _ data: [UInt8], quality: Int, windowBits: Int = 18, chunk: Int, outputChunk: Int, flush: TransformFlush = .none
) throws(BytesError) -> [UInt8] {
    var encoder = BrotliEncoder(quality: quality, windowBits: windowBits)
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

@Suite struct BrotliEncoderTests {
    @Test(arguments: 1...9)
    func roundTripsEveryQuality(quality: Int) {
        for (name, bytes) in samples() {
            let compressed = brotliEncodeAll(bytes, quality: quality)
            #expect(googleBrotliDecompress(compressed) == .decoded(bytes), "Google: \(name), quality \(quality)")
            #expect(brotliDecodeAll(compressed) == .decoded(bytes), "Bytes: \(name), quality \(quality)")
        }
    }

    @Test(arguments: [10, 16, 18, 24])
    func windowSizes(windowBits: Int) {
        let large = samples().last!.bytes
        let compressed = brotliEncodeAll(large, quality: 5, windowBits: windowBits)
        #expect(googleBrotliDecompress(compressed) == .decoded(large))
    }

    @Test(arguments: [1, 5, 9])
    func streamingRoundTrips(quality: Int) throws {
        for (name, bytes) in samples() where bytes.count <= 1 << 20 {
            for (chunk, outputChunk) in [(1000, 7), (4096, 333), (100_000, 65_536), (300_000, 1 << 20)] {
                let compressed = try brotliEncodeStreaming(bytes, quality: quality, chunk: chunk, outputChunk: outputChunk)
                #expect(googleBrotliDecompress(compressed) == .decoded(bytes), "\(name), quality \(quality), chunks \(chunk)/\(outputChunk)")
            }
        }
        let large = samples().last!.bytes
        let compressed = try brotliEncodeStreaming(large, quality: quality, windowBits: 16, chunk: 70_000, outputChunk: 50_000)
        #expect(googleBrotliDecompress(compressed) == .decoded(large))
    }

    /// After each flush, everything so far decodes: messages over one compressed stream.
    @Test(arguments: [1, 5])
    func flushMakesEachMessageDecodable(quality: Int) throws {
        var rng = SplitMix64(seed: 5)
        let text = samples()[2].bytes
        var encoder = BrotliEncoder(quality: quality, windowBits: 18)
        var decoder = BrotliDecoder()
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
            let outputCount = try decoded.withOutputRawSpan { span throws(BytesError) in
                let progress = try decoder.decompress(compressed.span.bytes, into: &span)
                #expect(progress.status == .needsInput && progress.consumed == compressed.count)
                return span.byteCount
            }
            let output = Array(decoded[..<outputCount])
            #expect(output == message)
        }
    }

    @Test func incompressibleDataIsStored() {
        let random = samples()[3].bytes
        let compressed = brotliEncodeAll(random, quality: 5)
        #expect(compressed.count <= random.count + random.count / 1000 + 32)
    }

    @Test func ratioIsCloseToGooglesAtLowQualities() {
        let text = samples()[2].bytes
        for quality in [1, 5] {
            let ours = brotliEncodeAll(text, quality: quality).count
            let googles = googleBrotliCompress(text, quality: Int32(quality)).count
            #expect(Double(ours) <= Double(googles) * 1.25, "quality \(quality): \(ours) vs Google \(googles)")
        }
    }

    @Test func emptyInput() {
        let compressed = brotliEncodeAll([], quality: 5)
        #expect(googleBrotliDecompress(compressed) == .decoded([]))
    }

    /// A stream whose table positions pass 2^32 (started 100,000 bytes below it, which a stream reaches after 4 GiB):
    /// every distance is a wrapping difference, so it decodes, and compresses as a fresh encoder's does (within 1%:
    /// empty slots read as near positions for a window's worth after the wrap, and are compared like any candidate).
    @Test(arguments: [1, 5, 9])
    func positionsWrapWithinAStream(quality: Int) throws {
        let text = samples()[2].bytes
        let base = UInt32.max - 100_000
        #expect(Int(base) + text.count > Int(UInt32.max), "the stream wraps")
        let fresh = brotliEncodeAll(text, quality: quality)

        var encoder = BrotliEncoder(quality: quality)
        encoder.setStreamBase(base)
        var output = [UInt8](repeating: 0, count: BrotliEncoder.maximumCompressedSize(forByteCount: text.count))
        let count = try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(text.span.bytes, into: &span)
            return span.byteCount
        }
        let wrapped = Array(output[..<count])
        #expect(googleBrotliDecompress(wrapped) == .decoded(text), "Google, one call")
        #expect(brotliDecodeAll(wrapped) == .decoded(text), "Bytes, one call")
        #expect(Double(wrapped.count) <= Double(fresh.count) * 1.01, "\(wrapped.count) against \(fresh.count) fresh")

        // Streamed, in 7,000-byte pieces through a window of 2^16: its buffer (2^16 + 256 KiB) fills and slides after
        // 327,680 bytes, and the positions wrap 400,000 bytes in, after that slide.
        let large = Array(samples().last!.bytes.prefix(500_000))
        let freshStreamed = try brotliEncodeStreaming(large, quality: quality, windowBits: 16, chunk: 7000, outputChunk: 4096)
        encoder = BrotliEncoder(quality: quality, windowBits: 16)
        encoder.setStreamBase(UInt32.max - 400_000)
        var streamed: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var offset = 0
        while offset < large.count {
            let end = min(offset + 7000, large.count)
            var piece = Array(large[offset..<end])
            while true {
                let (progress, produced) = try buffer.withOutputRawSpan { span throws(BytesError) in
                    try (encoder.compress(piece.span.bytes, into: &span, flush: end == large.count ? .finish : .none), span.byteCount)
                }
                streamed += buffer[..<produced]
                piece.removeFirst(progress.consumed)
                if progress.status == .finished || (progress.status == .needsInput && piece.isEmpty) { break }
            }
            offset = end
        }
        #expect(googleBrotliDecompress(streamed) == .decoded(large), "Google, streamed")
        #expect(Double(streamed.count) <= Double(freshStreamed.count) * 1.01, "\(streamed.count) against \(freshStreamed.count) fresh")
    }
}
