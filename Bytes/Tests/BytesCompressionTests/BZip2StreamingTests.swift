import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing

// MARK: - Driving the streaming decoder

/// Decodes `data` with `decompress(_:into:)`, from a reset: `outputChunk` bytes of room per call, and input
/// `inputChunk` bytes more each time the decoder asks (`nil`: the whole rest on every call), as a caller holding
/// the unconsumed bytes does. A stream that ends with input left continues with more, as a pipeline would.
///
/// - Returns: The output and the input consumed, ``BytesError/insufficientData`` if the decoder asks for input
///   after all of `data`, or what it threw.
func bzip2DecodeStreaming(
    _ data: [UInt8], outputChunk: Int, inputChunk: Int? = nil, decoder: inout BZip2Decoder
) -> Result<BZip2Decoded, BytesError> {
    decoder.reset()
    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: outputChunk)
    var consumed = 0
    var available = min(inputChunk ?? data.count, data.count)
    var stalls = 0
    while true {
        let progress: TransformProgress
        var produced = 0
        do throws(BytesError) {
            progress = try chunk.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                let progress = try decoder.decompress(data.span.bytes.extracting(consumed..<available), into: &span)
                produced = span.byteCount
                return progress
            }
        } catch {
            return .failure(error)
        }
        guard progress.produced == produced, progress.consumed <= available - consumed else {
            Issue.record("Progress \(progress) doesn't match \(produced) bytes written of \(available - consumed) given")
            return .failure(.invalidValue)
        }
        output += chunk[..<produced]
        consumed += progress.consumed
        // Never a call with no progress twice over (the test would hang).
        stalls = produced == 0 && progress.consumed == 0 ? stalls + 1 : 0
        if stalls > 2 {
            Issue.record("No progress: \(progress.status), \(consumed) of \(data.count) consumed")
            return .failure(.invalidValue)
        }
        switch progress.status {
        case .needsOutput:
            if produced == 0 {
                Issue.record("Asked for output with \(outputChunk) bytes of room")
                return .failure(.invalidValue)
            }
        case .needsInput, .finished:
            if progress.status == .finished && !decoder.isFinished {
                Issue.record("Finished, but not isFinished")
            }
            if available == data.count {
                if progress.status == .finished { return .success(BZip2Decoded(output: output, consumed: consumed)) }
                return .failure(.insufficientData)
            }
            available = min(available + (inputChunk ?? data.count), data.count)
            stalls = 0
        }
    }
}

/// `decompressAll`'s result for `data`, with room for `size` bytes.
func bzip2DecodeWhole(_ data: [UInt8], capacity: Int) -> Result<BZip2Decoded, BytesError> {
    bzip2Decode(data, capacity: capacity)
}

// MARK: - Tests

@Suite("bzip2 streaming")
struct BZip2StreamingTests {
    /// Text of one and two blocks, runs, skewed bytes, and random bytes, with each output size: every call fills its
    /// output, so the run-length decoding stops at every kind of place (mid-run, mid-count, at a block's end).
    @Test(arguments: [1, 7, 4096, 65536, 1 << 20])
    func matchesWholeDecoding(outputChunk: Int) {
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let all = bzip2Samples()
        // One-byte and 7-byte outputs make a call per byte or seven: smaller inputs for them.
        let size = outputChunk < 4096 ? 30_000 : 1_000_000
        let inputs: [(String, [UInt8], Int32)] = [
            ("text", Array(text.prefix(size)), 9),
            ("text, blocks of 100 KB", Array(text.prefix(size)), 1),
            ("runs", Array(all.first { $0.name == "runs" }!.bytes.prefix(size)), 9),
            ("skewed", Array(all.first { $0.name == "skewed" }!.bytes.prefix(size)), 9),
            ("random", Array(samples().first { $0.name == "random" }!.bytes.prefix(size / 10)), 9),
        ]
        for (name, data, level) in inputs {
            let compressed = bzip2Compress(data, level: level)
            let expected = BZip2Decoded(output: data, consumed: compressed.count)
            #expect(bzip2DecodeWhole(compressed, capacity: data.count) == .success(expected), "\(name)")
            #expect(bzip2DecodeStreaming(compressed, outputChunk: outputChunk, decoder: &decoder) == .success(expected), "\(name)")
        }
    }

    /// A block's output isn't bounded by its 900 KB: runs of one byte (4 bytes and a count, 5 bytes for every 255)
    /// make a small block that decodes to tens of megabytes, delivered a piece at a time.
    @Test func expandsBlocksBeyondTheirSize() {
        // One block of 235 KB (47,059 runs of 255) decoding to 12 MB, in pieces that end anywhere in its runs (the largest block,
        // decoding to 45 MB, in the bulk tests).
        Self.checkExpandsBlock(runBytes: 12_000_000, outputChunks: [1_000_003])
        // Small outputs on a smaller one: every place in a run of 255.
        var decoder = BZip2Decoder()
        let small = [UInt8](repeating: 7, count: 30_000) + [1, 2, 3] + [UInt8](repeating: 7, count: 1_000)
        let smallCompressed = bzip2Compress(small, level: 9)
        for outputChunk in [1, 2, 3, 7, 254, 255, 256, 259] {
            #expect(
                bzip2DecodeStreaming(smallCompressed, outputChunk: outputChunk, decoder: &decoder)
                    == .success(BZip2Decoded(output: small, consumed: smallCompressed.count)),
                "\(outputChunk)"
            )
        }
    }

    /// `runBytes` of one byte and a short run after them, at level 9, streamed with each output size.
    static func checkExpandsBlock(runBytes: Int, outputChunks: [Int]) {
        var decoder = BZip2Decoder()
        var data = [UInt8](repeating: 0x61, count: runBytes)
        data += [0x62, 0x62, 0x62, 0x62, 0x62, 0x63]
        let compressed = bzip2Compress(data, level: 9)
        #expect(compressed.count < 2_000)
        let expected = BZip2Decoded(output: data, consumed: compressed.count)
        for outputChunk in outputChunks {
            #expect(bzip2DecodeStreaming(compressed, outputChunk: outputChunk, decoder: &decoder) == .success(expected), "\(outputChunk)")
        }
    }

    @Test func decodesConcatenatedAndEmptyStreams() {
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let first = Array(text.prefix(150_000))
        let second = Array(text.suffix(30_000)) + [7, 7, 7, 7, 7, 7]
        let streams = bzip2Compress(first, level: 1) + bzip2Compress([], level: 5) + bzip2Compress(second, level: 9)
        let expected = BZip2Decoded(output: first + second, consumed: streams.count)
        for (outputChunk, inputChunk) in [(65_536, nil), (4096, nil), (4096, 1000), (1 << 20, 7)] as [(Int, Int?)] {
            #expect(
                bzip2DecodeStreaming(streams, outputChunk: outputChunk, inputChunk: inputChunk, decoder: &decoder) == .success(expected),
                "\(outputChunk), \(String(describing: inputChunk))"
            )
        }
        // An empty stream alone.
        let empty = bzip2Compress([], level: 9)
        for inputChunk in [nil, 1, 3] as [Int?] {
            #expect(
                bzip2DecodeStreaming(empty, outputChunk: 16, inputChunk: inputChunk, decoder: &decoder)
                    == .success(BZip2Decoded(output: [], consumed: empty.count))
            )
        }
        let finished = decoder.isFinished
        #expect(finished)
        // Bytes after the last stream that don't start another are left alone, as `decompressAll` leaves them.
        let trailing = bzip2Compress(first, level: 2)
        for extra: [UInt8] in [[0], [0x42, 0x5A], [0x42, 0x5A, 0x68, 0x30], Array("garbage".utf8)] {
            let input = trailing + extra
            #expect(bzip2Decode(input, capacity: first.count) == .success(BZip2Decoded(output: first, consumed: trailing.count)))
            #expect(
                bzip2DecodeStreaming(input, outputChunk: 65_536, decoder: &decoder)
                    == .success(BZip2Decoded(output: first, consumed: trailing.count)),
                "\(extra)"
            )
        }
    }

    /// One decoder: a stream left halfway, reset, then others; and `decompressAll` between streamed ones.
    @Test func reusesAcrossResets() {
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let a = Array(text.prefix(120_000))
        let b = Array(text.suffix(50_000))
        let compressedA = bzip2Compress(a, level: 1)
        let compressedB = bzip2Compress(b, level: 9)
        // Half of A's first block's output.
        var chunk = [UInt8](repeating: 0, count: 50_000)
        let progress = chunk.withOutputRawSpan { span in try! decoder.decompress(compressedA.span.bytes, into: &span) }
        #expect(progress.status == .needsOutput && progress.produced == 50_000)
        #expect(Array(chunk) == Array(a.prefix(50_000)))
        let halfway = decoder.isFinished
        #expect(!halfway)
        // `bzip2DecodeStreaming` resets first.
        #expect(bzip2DecodeStreaming(compressedB, outputChunk: 4096, decoder: &decoder) == .success(BZip2Decoded(output: b, consumed: compressedB.count)))
        #expect(bzip2Decode(compressedA, capacity: a.count, decoder: &decoder) == .success(BZip2Decoded(output: a, consumed: compressedA.count)))
        #expect(bzip2DecodeStreaming(compressedA, outputChunk: 65_536, decoder: &decoder) == .success(BZip2Decoded(output: a, consumed: compressedA.count)))
        // After an error, nothing until a reset.
        var corrupt = compressedB
        corrupt[3] = 0x30 // "BZh0"
        decoder.reset()
        #expect(throws: BytesError.invalidValue) {
            _ = try chunk.withOutputRawSpan { span throws(BytesError) in try decoder.decompress(corrupt.span.bytes, into: &span) }
        }
        #expect(throws: BytesError.invalidValue) {
            _ = try chunk.withOutputRawSpan { span throws(BytesError) in try decoder.decompress(compressedB.span.bytes, into: &span) }
        }
        #expect(bzip2DecodeStreaming(compressedB, outputChunk: 4096, decoder: &decoder) == .success(BZip2Decoded(output: b, consumed: compressedB.count)))
    }

    /// Input in pieces, as a caller with a fixed buffer has it: a byte at a time (every split point), and larger
    /// pieces across blocks, with outputs of several sizes.
    @Test func acceptsInputInPieces() {
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let all = bzip2Samples()
        let small = Array(text.prefix(4_000))
        let smallCompressed = bzip2Compress(small, level: 9)
        for inputChunk in [1, 2, 3, 5, 8, 13] {
            #expect(
                bzip2DecodeStreaming(smallCompressed, outputChunk: 1000, inputChunk: inputChunk, decoder: &decoder)
                    == .success(BZip2Decoded(output: small, consumed: smallCompressed.count)),
                "\(inputChunk)"
            )
        }
        let inputs: [(String, [UInt8], Int32)] = [
            ("text, 3 blocks", Array(text.prefix(250_000)), 1),
            ("skewed", Array(all.first { $0.name == "skewed" }!.bytes), 9),
            ("runs", all.first { $0.name == "runs" }!.bytes, 2),
        ]
        for (name, data, level) in inputs {
            let compressed = bzip2Compress(data, level: level)
            let expected = BZip2Decoded(output: data, consumed: compressed.count)
            for (outputChunk, inputChunk) in [(65_536, 97), (4096, 1000), (1 << 20, 4096), (7_777, 65_536)] {
                #expect(
                    bzip2DecodeStreaming(compressed, outputChunk: outputChunk, inputChunk: inputChunk, decoder: &decoder) == .success(expected),
                    "\(name): \(outputChunk), \(inputChunk)"
                )
            }
        }
    }

    /// Input that ends early asks for more, and never decodes past the end: with no more, `insufficientData`
    /// (the driver's, and `transform`'s at `.finish`).
    @Test func rejectsTruncatedStreams() {
        Self.checkRejectsTruncatedStreams(step: 397)
    }

    static func checkRejectsTruncatedStreams(step: Int) {
        let text = samples().first { $0.name == "text" }!.bytes
        var decoder = BZip2Decoder()
        for (name, data) in [("empty", [UInt8]()), ("one byte", [0x41]), ("text", Array(text.prefix(3_000)))] {
            let compressed = bzip2Compress(data, level: 9)
            for length in 0..<compressed.count {
                let cut = Array(compressed.prefix(length))
                #expect(
                    bzip2DecodeStreaming(cut, outputChunk: 4096, decoder: &decoder) == .failure(.insufficientData),
                    "\(name), \(length) of \(compressed.count) bytes"
                )
            }
        }
        // Two blocks, cut every 397 bytes (every 97 in the bulk tests); in pieces too, and through `transform`.
        let twoBlocks = Array(text.prefix(150_000))
        let compressed = bzip2Compress(twoBlocks, level: 1)
        for length in stride(from: 0, to: compressed.count, by: step) {
            let cut = Array(compressed.prefix(length))
            #expect(bzip2DecodeStreaming(cut, outputChunk: 65_536, decoder: &decoder) == .failure(.insufficientData), "\(length)")
            if length % 3 == 0 {
                #expect(bzip2DecodeStreaming(cut, outputChunk: 65_536, inputChunk: 1000, decoder: &decoder) == .failure(.insufficientData), "\(length)")
            }
            decoder.reset()
            var output = [UInt8](repeating: 0, count: twoBlocks.count)
            #expect(throws: BytesError.insufficientData, "\(length)") {
                _ = try output.withOutputRawSpan { span throws(BytesError) in try decoder.transform(cut.span.bytes, into: &span, flush: .finish) }
            }
        }
    }

    /// Corrupt streams never trap or hang: decoding throws, or gives the original (a flip in the end's padding).
    @Test func survivesCorruption() {
        Self.checkSurvivesCorruption(trials: 40)
    }

    static func checkSurvivesCorruption(trials: Int) {
        var rng = SplitMix64(seed: 2029)
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let inputs: [(String, [UInt8], Int32)] = [
            ("text", Array(text.prefix(5_000)), 9),
            ("runs", Array(bzip2Samples().first { $0.name == "runs" }!.bytes.prefix(20_000)), 9),
            ("two blocks", Array(text.prefix(120_000)), 1),
        ]
        for (name, data, level) in inputs {
            let compressed = bzip2Compress(data, level: level)
            var caught = 0
            for trial in 0..<trials {
                var corrupt = compressed
                for _ in 0..<(trial % 3 + 1) {
                    let index = 4 + Int(rng.next() % UInt64(corrupt.count - 4))
                    if trial % 2 == 0 {
                        corrupt[index] ^= 1 << (rng.next() % 8)
                    } else {
                        corrupt[index] = UInt8(truncatingIfNeeded: rng.next())
                    }
                }
                let outputChunk = [4096, 1 << 20, 777][trial % 3]
                let inputChunk = [nil, 1000, 64][trial % 3]
                switch bzip2DecodeStreaming(corrupt, outputChunk: outputChunk, inputChunk: inputChunk, decoder: &decoder) {
                case .success(let decoded):
                    #expect(decoded.output == data, "\(name), trial \(trial)")
                case .failure:
                    caught += 1
                }
            }
            #expect(caught > trials * 9 / 10, "\(name): \(caught) of \(trials) caught")
        }
    }
}

/// Sweeps: every output size from 1 to 300 and input piece sizes on small streams; the large sample streamed;
/// input pieces of every 97th size for a two-block stream; more corruption.
@Suite(.bulk) struct BZip2StreamingBulkTests {
    @Test func everyOutputSize() {
        var decoder = BZip2Decoder()
        let data = Array(bzip2Samples().first { $0.name == "runs" }!.bytes.prefix(12_000))
        let compressed = bzip2Compress(data, level: 9)
        for outputChunk in 1...300 {
            #expect(
                bzip2DecodeStreaming(compressed, outputChunk: outputChunk, inputChunk: outputChunk, decoder: &decoder)
                    == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                "\(outputChunk)"
            )
        }
    }

    @Test func largeSample() {
        var decoder = BZip2Decoder()
        let large = samples().first { $0.name == "large" }!.bytes
        for level: Int32 in [1, 9] {
            let compressed = bzip2Compress(large, level: level)
            for (outputChunk, inputChunk) in [(1 << 20, nil), (65_536, 4096), (100_003, 256 << 10)] as [(Int, Int?)] {
                #expect(
                    bzip2DecodeStreaming(compressed, outputChunk: outputChunk, inputChunk: inputChunk, decoder: &decoder)
                        == .success(BZip2Decoded(output: large, consumed: compressed.count))
                )
            }
        }
    }

    @Test func everyPieceSize() {
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let data = Array(text.prefix(150_000))
        let compressed = bzip2Compress(data, level: 1)
        let expected = BZip2Decoded(output: data, consumed: compressed.count)
        for split in stride(from: 1, to: compressed.count, by: 97) {
            #expect(bzip2DecodeStreaming(compressed, outputChunk: 1 << 20, inputChunk: split, decoder: &decoder) == .success(expected), "\(split)")
        }
    }

    /// The largest block: 899,981 bytes after the run-length coding at level 9, up to 179,996 runs of 255, so 45 MB
    /// in one block.
    @Test func expandsTheLargestBlock() {
        BZip2StreamingTests.checkExpandsBlock(runBytes: 45_000_000, outputChunks: [1 << 20, 1_000_003, 65_536])
    }

    @Test func rejectsTruncatedStreams() { BZip2StreamingTests.checkRejectsTruncatedStreams(step: 97) }

    @Test func survivesCorruption() { BZip2StreamingTests.checkSurvivesCorruption(trials: 3_000) }
}
