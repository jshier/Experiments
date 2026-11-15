import Bytes
import BytesCompression
import CBrotli
import Testing

/// Google's encoding of `data`.
func googleBrotliCompress(_ data: [UInt8], quality: Int32 = 5, windowBits: Int32 = 22, mode: BrotliEncoderMode = BROTLI_MODE_GENERIC) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: BrotliEncoderMaxCompressedSize(data.count) + 64)
    var size = output.count
    let ok = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            BrotliEncoderCompress(quality, windowBits, mode, input.count, input.baseAddress, &size, output.baseAddress)
        }
    }
    precondition(ok == BROTLI_TRUE)
    return Array(output[..<size])
}

/// Google's decoding of `data`, which must be one whole stream.
func googleBrotliDecompress(_ data: [UInt8]) -> Outcome {
    guard let state = BrotliDecoderCreateInstance(nil, nil, nil) else { return .failed }
    defer { BrotliDecoderDestroyInstance(state) }
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    return data.withUnsafeBufferPointer { input in
        var availableIn = input.count
        var nextIn = input.baseAddress
        while true {
            var availableOut = chunk.count
            let status = chunk.withUnsafeMutableBufferPointer { output in
                var nextOut = output.baseAddress
                return BrotliDecoderDecompressStream(state, &availableIn, &nextIn, &availableOut, &nextOut, nil)
            }
            result += chunk[..<(chunk.count - availableOut)]
            switch status {
            case BROTLI_DECODER_RESULT_SUCCESS: return availableIn == 0 ? .decoded(result) : .failed
            case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT: continue
            default: return .failed
            }
        }
    }
}

func brotliDecodeAll(_ data: [UInt8], capacity: Int? = nil) -> Outcome {
    var decoder = BrotliDecoder()
    // Brotli's ratio has no useful bound (a long copy is a few bytes): by default, room for every sample.
    var output = [UInt8](repeating: 0, count: capacity ?? (4 << 20) + data.count * 1100)
    let produced: Int? = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        guard let consumed = try? decoder.decompressAll(data.span.bytes, into: &span), consumed == data.count else { return nil }
        return span.finalize(for: buffer)
    }
    guard let produced else { return .failed }
    return .decoded(Array(output[..<produced]))
}

func brotliDecodeStreaming(_ data: [UInt8], chunk: Int, outputChunk: Int, decoder: inout BrotliDecoder) -> Outcome {
    decoder.reset()
    var result: [UInt8] = []
    var pending: [UInt8] = []
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    while true {
        let take = min(chunk, data.count - offset)
        pending += data[offset..<(offset + take)]
        offset += take
        let progress: TransformProgress? = buffer.withUnsafeMutableBytes { raw in
            var span = OutputRawSpan(buffer: raw, initializedCount: 0)
            let progress = try? decoder.decompress(pending.span.bytes, into: &span)
            result += raw[..<span.finalize(for: raw)]
            return progress
        }
        guard let progress else { return .failed }
        pending.removeFirst(progress.consumed)
        switch progress.status {
        case .finished: return pending.isEmpty && offset == data.count ? .decoded(result) : .failed
        case .needsInput: if offset == data.count { return .failed }
        case .needsOutput: continue
        }
    }
}

func brotliDecodeStreaming(_ data: [UInt8], chunk: Int, outputChunk: Int) -> Outcome {
    var decoder = BrotliDecoder()
    return brotliDecodeStreaming(data, chunk: chunk, outputChunk: outputChunk, decoder: &decoder)
}

@Suite struct BrotliDecoderTests {
    @Test(arguments: 0...11)
    func decodesWhatGoogleEncodes(quality: Int32) {
        for (name, bytes) in samples() where quality < 10 || bytes.count <= 300_000 {
            let compressed = googleBrotliCompress(bytes, quality: quality)
            #expect(brotliDecodeAll(compressed) == .decoded(bytes), "\(name), quality \(quality)")
        }
    }

    @Test(arguments: [10, 16, 18, 22, 24] as [Int32])
    func windowSizes(windowBits: Int32) {
        let large = samples().last!.bytes
        for quality: Int32 in [1, 5, 9] {
            let compressed = googleBrotliCompress(large, quality: quality, windowBits: windowBits)
            #expect(brotliDecodeAll(compressed) == .decoded(large), "quality \(quality), window \(windowBits)")
            #expect(brotliDecodeStreaming(compressed, chunk: 65_536, outputChunk: 100_000) == .decoded(large))
        }
    }

    @Test func textModeUsesTheDictionary() {
        // Small web text compresses with dictionary references at the higher qualities.
        let html = Array(#"<!DOCTYPE html><html><head><title>The page of the information</title></head><body class="content"><p>This is the first paragraph, and it is not long.</p></body></html>"#.utf8)
        for quality: Int32 in [5, 9, 11] {
            let compressed = googleBrotliCompress(html, quality: quality, mode: BROTLI_MODE_TEXT)
            #expect(brotliDecodeAll(compressed) == .decoded(html), "quality \(quality)")
            #expect(brotliDecodeStreaming(compressed, chunk: 1, outputChunk: 1) == .decoded(html))
        }
    }

    @Test(arguments: [(1, 1), (1, 9), (7, 64), (100, 1), (4096, 777), (65_536, 1 << 20)])
    func decodesInPieces(chunk: Int, outputChunk: Int) {
        var decoder = BrotliDecoder()
        for (name, bytes) in samples() where bytes.count <= (chunk < 16 ? 100_000 : 4 << 20) {
            for quality: Int32 in [0, 1, 5, 11] where quality < 10 || bytes.count <= 300_000 {
                let compressed = googleBrotliCompress(bytes, quality: quality)
                let outcome = brotliDecodeStreaming(compressed, chunk: chunk, outputChunk: outputChunk, decoder: &decoder)
                #expect(outcome == .decoded(bytes), "\(name), quality \(quality), chunks \(chunk)/\(outputChunk)")
            }
        }
    }

    @Test func outputExactlyFullAndTooSmall() {
        let bytes = samples()[2].bytes
        let compressed = googleBrotliCompress(bytes)
        #expect(brotliDecodeAll(compressed, capacity: bytes.count) == .decoded(bytes))
        #expect(brotliDecodeAll(compressed, capacity: bytes.count - 1) == .failed)
    }

    /// Mutated streams: accepted exactly when Google's decoder accepts them, with the same output.
    @Test func corruptStreamsMatchGoogle() {
        var rng = SplitMix64(state: 99)
        let seeds = samples().filter { $0.bytes.count <= 200_000 }.flatMap { sample in
            [googleBrotliCompress(sample.bytes, quality: 1), googleBrotliCompress(sample.bytes, quality: 5),
             googleBrotliCompress(sample.bytes, quality: 11, windowBits: 16)]
        }.map { Array($0.prefix(3_000)) + [] }
        var accepted = 0
        var rejected = 0
        for iteration in 0..<10_000 {
            var bytes = seeds.randomElement(using: &rng)!
            guard !bytes.isEmpty else { continue }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
                case 1: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                default: bytes.removeLast(Int.random(in: 0...min(16, bytes.count - 1), using: &rng))
                }
            }
            let reference = googleBrotliDecompress(bytes)
            #expect(brotliDecodeAll(bytes) == reference, "\(bytes.prefix(24))…")
            if iteration % 10 == 0 {
                #expect(brotliDecodeStreaming(bytes, chunk: 29, outputChunk: 1000) == reference)
            }
            if case .decoded = reference { accepted += 1 } else { rejected += 1 }
        }
        #expect(accepted > 0 && rejected > 0)
    }

    @Test func emptyAndTinyStreams() {
        #expect(brotliDecodeAll([0x06]) == .decoded([])) // WBITS 16, ISLAST, ISLASTEMPTY.
        #expect(brotliDecodeAll(googleBrotliCompress([])) == .decoded([]))
        #expect(brotliDecodeAll(googleBrotliCompress([0x41])) == .decoded([0x41]))
        #expect(brotliDecodeAll([]) == .failed)
    }
}
