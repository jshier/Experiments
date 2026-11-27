import Bytes
import BytesAsync
import BytesCompression
import BytesCompressionAsync
import BytesTesting
import BytesTestSupport
import Dispatch
import Testing
import zlib

/// Encodes with the parallel encoder's synchronous `compressAll`.
func parallelEncodeAll(_ encoder: inout ParallelDeflateEncoder, _ data: [UInt8]) throws(BytesError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: data.count))
    let produced = try output.withOutputRawSpan { span throws(BytesError) in
        try encoder.compressAll(data.span.bytes, into: &span)
        return span.byteCount
    }
    return Array(output[..<produced])
}

/// Encodes with the parallel encoder's streaming form: pieces of up to `chunk` bytes into an output buffer of
/// `outputChunk` bytes, with `flush` after each piece and `.finish` at the end.
func parallelEncodeStreaming(
    _ encoder: inout ParallelDeflateEncoder, _ data: [UInt8], chunk: Int, outputChunk: Int, flush: TransformFlush = .none
) throws(BytesError) -> [UInt8] {
    encoder.reset()
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

/// The large sample's first megabyte: 8 chunks of 128 KiB, 16 of 64 KiB, for the fast forms of the tests that take
/// the whole 3 MB in the bulk suites.
func largePrefix() -> [UInt8] { Array(largeSample().prefix(1 << 20)) }

@Suite struct ParallelDeflateTests {
    static func checkRoundTrips(_ samples: [(name: String, bytes: [UInt8])], level: Int, formats: [DeflateFormat] = [.raw, .zlib, .gzip]) throws {
        for format in formats {
            var encoder = ParallelDeflateEncoder(format: format, level: level, chunkSize: 64 << 10, lanes: 4)
            for (name, bytes) in samples {
                let compressed = try parallelEncodeAll(&encoder, bytes)
                #expect(zlibDecompress(compressed, format: format) == .decoded(bytes), "zlib: \(name), level \(level), \(format)")
                #expect(decodeAll(compressed, format: format) == .decoded(bytes), "Bytes: \(name), level \(level), \(format)")
            }
        }
    }

    /// The samples under 1 MB in every format; the large one at level 1 in gzip (every way in
    /// ParallelDeflateBulkTests).
    @Test(arguments: [0, 1, 6, 9])
    func roundTripsInEveryFormat(level: Int) throws {
        try Self.checkRoundTrips(smallSamples(), level: level)
        if level == 1 { try Self.checkRoundTrips([("large", largeSample())], level: level, formats: [.gzip]) }
    }

    /// Primed chunks compress almost as well as one stream; independent ones lose a little. A megabyte at level 1
    /// here, 3 MB at levels 1 and 6 in ParallelDeflateBulkTests.
    @Test func compressesAlmostAsWellAsOneStream() throws {
        try Self.checkCompressesAlmostAsWellAsOneStream(largePrefix(), level: 1)
    }

    static func checkCompressesAlmostAsWellAsOneStream(_ large: [UInt8], level: Int) throws {
        let sequential = encodeAll(large, format: .raw, level: level).count
        var primed = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: 128 << 10, lanes: 8)
        var independent = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: 128 << 10, lanes: 8, independentChunks: true)
        let primedSize = try parallelEncodeAll(&primed, large).count
        let independentSize = try parallelEncodeAll(&independent, large).count
        #expect(Double(primedSize) <= Double(sequential) * 1.005, "primed \(primedSize) vs \(sequential)")
        #expect(independentSize > primedSize)
        #expect(try zlibDecompress(parallelEncodeAll(&independent, large)) == .decoded(large))
    }

    /// One lane, or more lanes than chunks, and inputs around chunk boundaries.
    @Test func laneAndChunkEdges() throws {
        var rng = SplitMix64(seed: 11)
        let text = samples()[2].bytes
        for lanes in [1, 3, 16] {
            var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: lanes)
            for count in [1, 4, 5, 32767, 32768, 32769, 65536 + 3, 150_001] {
                let start = Int.random(in: 0..<(text.count - count), using: &rng)
                let bytes = Array(text[start..<(start + count)])
                #expect(try zlibDecompress(parallelEncodeAll(&encoder, bytes), format: .gzip) == .decoded(bytes), "\(lanes) lanes, \(count) bytes")
            }
        }
    }

    /// Every piece pattern on 1.2 MB (past the largest piece); on the 3 MB sample in ParallelDeflateBulkTests.
    @Test(arguments: [1, 6])
    func streamingRoundTrips(level: Int) throws {
        try Self.checkStreamingRoundTrips(Array(largeSample().prefix(1_200_000)), level: level)
    }

    static func checkStreamingRoundTrips(_ large: [UInt8], level: Int) throws {
        var encoder = ParallelDeflateEncoder(format: .gzip, level: level, chunkSize: 32 << 10, lanes: 4)
        for (chunk, outputChunk, flush) in [(1000, 777, TransformFlush.none), (100_000, 65_536, .flush), (300_000, 1 << 20, .none), (1 << 20, 3000, .flush)] {
            let compressed = try parallelEncodeStreaming(&encoder, large, chunk: chunk, outputChunk: outputChunk, flush: flush)
            #expect(zlibDecompress(compressed, format: .gzip) == .decoded(large), "pieces \(chunk), output \(outputChunk), \(flush)")
        }
        for (name, bytes) in samples() where bytes.count < 1 << 20 {
            let compressed = try parallelEncodeStreaming(&encoder, bytes, chunk: 4096, outputChunk: 1000, flush: .flush)
            #expect(zlibDecompress(compressed, format: .gzip) == .decoded(bytes), "\(name)")
        }
    }

    /// After each flush, everything so far decodes: what a message stream needs.
    @Test func streamingFlushMakesEachMessageDecodable() throws {
        var encoder = ParallelDeflateEncoder(format: .raw, level: 1, chunkSize: 32 << 10, lanes: 4)
        let text = samples().last!.bytes
        var sent: [UInt8] = []
        var compressed: [UInt8] = []
        var output = [UInt8](repeating: 0, count: 1 << 20)
        for size in [100, 70_000, 5, 200_000] {
            let message = Array(text[sent.count..<(sent.count + size)])
            sent += message
            let produced = try output.withOutputRawSpan { span throws(BytesError) in
                let progress = try encoder.compress(message.span.bytes, into: &span, flush: .flush)
                #expect(progress.status == .needsInput && progress.consumed == message.count)
                return span.byteCount
            }
            compressed += output[..<produced]
            #expect(decodePrefix(compressed) == sent, "after \(sent.count) bytes")
        }
    }

    @Test func asyncFormsMatchTheSynchronousOne() async throws {
        let large = samples().last!.bytes
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 6, chunkSize: 128 << 10, lanes: 6)
        let expected = try parallelEncodeAll(&encoder, large)
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: large.count))
        let pointer = output.withUnsafeMutableBytes { $0 }
        var span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        try await encoder.compressAll(large.span.bytes, into: &span, on: DispatchQueue(label: "test"))
        #expect(Array(output[..<span.finalize(for: pointer)]) == expected)
        span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        try await encoder.compressAllConcurrently(large.span.bytes, into: &span)
        #expect(Array(output[..<span.finalize(for: pointer)]) == expected)
    }

    @Test func outputTooSmallThrows() {
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: 2)
        let text = samples()[2].bytes
        var output = [UInt8](repeating: 0, count: 100)
        output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
            #expect(throws: BytesError.insufficientCapacity) { try encoder.compressAll(text.span.bytes, into: &span) }
        }
    }

    @Test func checksumsCombine() {
        var rng = SplitMix64(seed: 5)
        let bytes = (0..<10_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        for split in [0, 1, 7, 4096, 9_999, 10_000] {
            let first = bytes.span.bytes.extracting(0..<split)
            let second = bytes.span.bytes.extracting(split..<bytes.count)
            #expect(CRC32.combine(CRC32.checksum(first), CRC32.checksum(second), secondLength: second.byteCount) == CRC32.checksum(bytes.span.bytes))
            #expect(Adler32.combine(Adler32.checksum(first), Adler32.checksum(second), secondLength: second.byteCount) == Adler32.checksum(bytes.span.bytes))
        }
    }
}

/// zlib's decoding of a stream that may not be finished (flushed, not ended): everything decodable so far.
func decodePrefix(_ data: [UInt8]) -> [UInt8] {
    var stream = z_stream()
    precondition(inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    var input = data
    input.withUnsafeMutableBufferPointer { input in
        stream.next_in = input.baseAddress
        stream.avail_in = uInt(input.count)
        while true {
            let (status, produced) = chunk.withUnsafeMutableBufferPointer { output in
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                let status = inflate(&stream, Z_SYNC_FLUSH)
                return (status, output.count - Int(stream.avail_out))
            }
            result += chunk[..<produced]
            if status != Z_OK || (produced == 0 && stream.avail_in == 0) { return }
        }
    }
    return result
}

/// Decodes with the parallel decoder: the result, and how many segments it used.
func parallelDecodeAll(_ decoder: inout ParallelDeflateDecoder, _ data: [UInt8], capacity: Int) -> (Outcome, segments: Int) {
    var output = [UInt8](repeating: 0, count: capacity)
    let produced: Int? = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        guard let consumed = try? decoder.decompressAll(data.span.bytes, into: &span), consumed == data.count else { return nil }
        return span.finalize(for: buffer)
    }
    guard let produced else { return (.failed, decoder.lastSegmentCount) }
    return (.decoded(Array(output[..<produced])), decoder.lastSegmentCount)
}

@Suite struct ParallelInflateTests {
    /// Independent chunks decode in parallel; primed chunks and other streams sequentially; all correctly. A megabyte
    /// and the samples under 1 MB here; the 3 MB sample in ParallelInflateBulkTests.
    @Test(arguments: [1, 6])
    func decodesEveryStreamCorrectly(level: Int) throws {
        try Self.checkDecodesEveryStream(largePrefix(), smallSamples(), level: level)
    }

    static func checkDecodesEveryStream(_ large: [UInt8], _ samples: [(name: String, bytes: [UInt8])], level: Int) throws {
        for format: DeflateFormat in [.raw, .zlib, .gzip] {
            var decoder = ParallelDeflateDecoder(format: format, lanes: 6)
            var independent = ParallelDeflateEncoder(format: format, level: level, chunkSize: 128 << 10, lanes: 8, independentChunks: true)
            var primed = ParallelDeflateEncoder(format: format, level: level, chunkSize: 128 << 10, lanes: 8)
            let fromIndependent = try parallelDecodeAll(&decoder, parallelEncodeAll(&independent, large), capacity: large.count + 100)
            #expect(fromIndependent.0 == .decoded(large), "independent, \(format)")
            #expect(fromIndependent.segments > 1, "independent chunks decode in parallel")
            let fromPrimed = try parallelDecodeAll(&decoder, parallelEncodeAll(&primed, large), capacity: large.count + 100)
            #expect(fromPrimed.0 == .decoded(large), "primed, \(format)")
            let fromZlib = parallelDecodeAll(&decoder, zlibCompress(large, format: format), capacity: large.count + 100)
            #expect(fromZlib.0 == .decoded(large), "zlib, \(format)")
            #expect(fromZlib.segments == 1)
            for (name, bytes) in samples {
                let compressed = try parallelEncodeAll(&independent, bytes)
                #expect(parallelDecodeAll(&decoder, compressed, capacity: bytes.count + 100).0 == .decoded(bytes), "\(name), \(format)")
            }
        }
    }

    /// Stored blocks full of `00 00 FF FF` (false sync markers) don't fool the proof. Half a megabyte (8 chunks) here,
    /// 2 MB in ParallelInflateBulkTests.
    @Test func falseMarkersAreRejected() throws {
        try Self.checkFalseMarkers(size: 512 << 10)
    }

    static func checkFalseMarkers(size: Int) throws {
        var rng = SplitMix64(seed: 9)
        var bytes: [UInt8] = []
        while bytes.count < size {
            bytes += [0, 0, 0xFF, 0xFF]
            bytes += (0..<Int.random(in: 0..<40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 8)
        for level in [0, 1, 6] {
            for independent in [false, true] {
                var encoder = ParallelDeflateEncoder(format: .gzip, level: level, chunkSize: 64 << 10, lanes: 8, independentChunks: independent)
                let compressed = try parallelEncodeAll(&encoder, bytes)
                #expect(parallelDecodeAll(&decoder, compressed, capacity: bytes.count + 100).0 == .decoded(bytes), "level \(level), independent \(independent)")
            }
            let compressed = zlibCompress(bytes, format: .gzip, level: Int32(level))
            #expect(parallelDecodeAll(&decoder, compressed, capacity: bytes.count + 100).0 == .decoded(bytes), "zlib level \(level)")
        }
    }

    /// A megabyte here, 3 MB in ParallelInflateBulkTests.
    @Test func corruptAndTruncatedStreamsThrow() throws {
        try Self.checkCorruptAndTruncated(largePrefix())
    }

    static func checkCorruptAndTruncated(_ large: [UInt8]) throws {
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 128 << 10, lanes: 8, independentChunks: true)
        let compressed = try parallelEncodeAll(&encoder, large)
        var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 8)
        var badCRC = compressed
        badCRC[badCRC.count - 6] ^= 1
        #expect(parallelDecodeAll(&decoder, badCRC, capacity: large.count + 100).0 == .failed)
        #expect(parallelDecodeAll(&decoder, Array(compressed.dropLast(3)), capacity: large.count + 100).0 == .failed)
        #expect(parallelDecodeAll(&decoder, compressed, capacity: large.count - 1).0 == .failed)
        #expect(parallelDecodeAll(&decoder, compressed, capacity: large.count).0 == .decoded(large))
    }

    /// A megabyte here, 3 MB in ParallelInflateBulkTests.
    @Test func asyncFormMatches() async throws {
        try await Self.checkAsyncFormMatches(largePrefix())
    }

    static func checkAsyncFormMatches(_ large: [UInt8]) async throws {
        var encoder = ParallelDeflateEncoder(format: .zlib, level: 6, chunkSize: 128 << 10, lanes: 8, independentChunks: true)
        let compressed = try parallelEncodeAll(&encoder, large)
        var decoder = ParallelDeflateDecoder(format: .zlib, lanes: 8)
        for concurrently in [false, true] {
            var output = [UInt8](repeating: 0, count: large.count)
            let pointer = output.withUnsafeMutableBytes { $0 }
            var span = OutputRawSpan(buffer: pointer, initializedCount: 0)
            let consumed = if concurrently {
                try await decoder.decompressAllConcurrently(compressed.span.bytes, into: &span)
            } else {
                try await decoder.decompressAll(compressed.span.bytes, into: &span, on: DispatchQueue(label: "test"))
            }
            let produced = span.finalize(for: pointer)
            #expect(consumed == compressed.count && produced == large.count && output == large, "concurrently: \(concurrently)")
            #expect(decoder.lastSegmentCount > 1, "concurrently: \(concurrently)")
        }
    }

    /// The task-group form (its segment workers child tasks, its sequential parts in a child task of its own) decodes
    /// as the synchronous call does, whichever way the stream goes: in parallel, sequentially (no split points), a
    /// gzip stream's later members after a parallel first one, a failed segment decoded again in place, and the
    /// synchronous call's errors (a bad checksum, an output a byte short).
    @Test func concurrentFormMatchesTheSynchronousOne() async throws {
        let large = largePrefix()
        var independent = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 64 << 10, lanes: 4, independentChunks: true)
        let parallel = try parallelEncodeAll(&independent, large)
        var sequentialEncoder = DeflateEncoder(format: .gzip, level: 1)
        var single = [UInt8](repeating: 0, count: DeflateEncoder.maximumCompressedSize(forByteCount: large.count, format: .gzip))
        let singleCount = try single.withOutputRawSpan { span throws(BytesError) in
            try sequentialEncoder.compressAll(large.span.bytes, into: &span)
            return span.byteCount
        }
        single.removeSubrange(singleCount...)
        // Full and sync flushes in turn: segments after a sync flush fail (matches reach back across it) and are
        // decoded again in place.
        let repaired = zlibCompressFlushing(large, format: .gzip, every: 32 << 10, flushes: [Z_FULL_FLUSH, Z_SYNC_FLUSH])
        var badCRC = parallel
        badCRC[badCRC.count - 6] ^= 1
        let cases: [(name: String, stream: [UInt8], expected: [UInt8], capacity: Int)] = [
            ("parallel", parallel, large, large.count),
            ("sequential", single, large, large.count),
            ("members", parallel + single, large + large, 2 * large.count),
            ("repaired", repaired, large, large.count),
            ("bad CRC", badCRC, large, large.count),
            ("a byte short", parallel, large, large.count - 1),
        ]
        var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 4)
        for (name, stream, expected, capacity) in cases {
            var outcomes: [Result<[UInt8], BytesError>] = []
            var segmentCounts: [Int] = []
            for concurrently in [false, true] {
                var output = [UInt8](repeating: 0, count: capacity)
                let pointer = output.withUnsafeMutableBytes { $0 }
                var span = OutputRawSpan(buffer: pointer, initializedCount: 0)
                do throws(CancellableError<BytesError>) {
                    let consumed: Int
                    if concurrently {
                        consumed = try await decoder.decompressAllConcurrently(stream.span.bytes, into: &span)
                    } else {
                        do throws(BytesError) {
                            consumed = try decoder.decompressAll(stream.span.bytes, into: &span)
                        } catch {
                            throw .failed(error)
                        }
                    }
                    let produced = span.finalize(for: pointer)
                    #expect(consumed == stream.count, "\(name)")
                    outcomes.append(.success(Array(output[..<produced])))
                } catch {
                    _ = span.finalize(for: pointer)
                    switch error {
                    case let .failed(error): outcomes.append(.failure(error))
                    case .cancelled: Issue.record("\(name): cancelled, uncancelled")
                    }
                }
                segmentCounts.append(decoder.lastSegmentCount)
            }
            #expect(outcomes[0] == outcomes[1], "\(name)")
            #expect(segmentCounts[0] == segmentCounts[1], "\(name)")
            switch name {
            case "bad CRC": #expect(outcomes[1] == .failure(.checksumMismatch), "\(name)")
            case "a byte short": #expect(outcomes[1] == .failure(.insufficientCapacity), "\(name)")
            default: #expect(outcomes[1] == .success(expected), "\(name)")
            }
            if name == "parallel" || name == "members" || name == "repaired" { #expect(segmentCounts[1] > 1, "\(name)") }
            if name == "repaired" { #expect(decoder.lastRepairCount > 0, "\(name)") }
            if name == "sequential" { #expect(segmentCounts[1] == 1, "\(name)") }
        }
    }
}

@Suite struct ParallelBrotliTests {
    /// Google's decoder and Bytes' both read the joined stream, at every quality, for inputs around chunk sizes.
    @Test(arguments: [1, 5, 9])
    func roundTrips(quality: Int) throws {
        var encoder = ParallelBrotliEncoder(quality: quality, chunkSize: 64 << 10, historySize: 32 << 10, lanes: 4)
        var inputs = samples()
        let text = inputs[2].bytes
        for count in [65536, 65537, 131_072 + 5] {
            inputs.append(("text prefix \(count)", Array(text.prefix(count))))
        }
        for (name, bytes) in inputs {
            var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: bytes.count))
            let produced = try output.withOutputRawSpan { span throws(BytesError) in
                try encoder.compressAll(bytes.span.bytes, into: &span)
                return span.byteCount
            }
            let compressed = Array(output[..<produced])
            #expect(googleBrotliDecompress(compressed) == .decoded(bytes), "Google: \(name), quality \(quality)")
            #expect(brotliDecodeAll(compressed) == .decoded(bytes), "Bytes: \(name), quality \(quality)")
        }
    }

    /// No copy runs past its chunk's end. Lazy matching's second delay once allowed a copy one byte past the
    /// end of the data: in a parallel chunk, into the next chunk, whose bytes often matched, and the stream
    /// decoded a byte long (Silesia's samba at quality 5). Built to delay twice just before chunk 0's end: a
    /// 4-byte match at `p`, 7 bytes at `p + 1`, and at `p + 2` a match running to the chunk's end and on into
    /// chunk 1.
    @Test(arguments: [5, 9])
    func copiesStopAtChunkEnds(quality: Int) throws {
        var rng = SplitMix64(seed: 3)
        // Repetitive filler (no long stretch without matches, which the parser would skip through), and
        // high random bytes, which match nothing in it.
        var bytes = (0..<65_536).map { UInt8(0x30 + $0 % 10) }
        let high = (0..<66).map { _ in UInt8.random(in: 0x80...0xFF, using: &rng) }
        let a = Array(high[2...]) // "A": 64 bytes.
        let end = 32_768 // Chunk 0's end: 2 chunks of 32 KB on 1 lane.
        let p = end - 22
        let tail = high // "x y A0 A1 …"
        bytes.replaceSubrange(1_000..<1_004, with: tail.prefix(4)) // x y A0 A1
        bytes.replaceSubrange(2_000..<2_007, with: tail[1..<8]) // y A0 … A5
        bytes.replaceSubrange(3_000..<3_064, with: a) // A
        bytes.replaceSubrange(p..<(p + 66), with: tail) // x y A0 … A19 | A20 … (chunk 1)
        var encoder = ParallelBrotliEncoder(quality: quality, chunkSize: 32 << 10, historySize: 0, lanes: 1)
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: bytes.count))
        let produced = try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(bytes.span.bytes, into: &span)
            return span.byteCount
        }
        #expect(googleBrotliDecompress(Array(output[..<produced])) == .decoded(bytes))
    }

    @Test func asyncFormsMatchTheSynchronousOne() async throws {
        let large = samples().last!.bytes
        var encoder = ParallelBrotliEncoder(quality: 5, chunkSize: 64 << 10, historySize: 32 << 10, lanes: 6)
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: large.count))
        let pointer = output.withUnsafeMutableBytes { $0 }
        var span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        try encoder.compressAll(large.span.bytes, into: &span)
        let expected = Array(output[..<span.finalize(for: pointer)])
        #expect(googleBrotliDecompress(expected) == .decoded(large))
        span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        try await encoder.compressAll(large.span.bytes, into: &span, on: DispatchQueue(label: "test"))
        #expect(Array(output[..<span.finalize(for: pointer)]) == expected)
        span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        try await encoder.compressAllConcurrently(large.span.bytes, into: &span)
        #expect(Array(output[..<span.finalize(for: pointer)]) == expected)
    }

    @Test func outputTooSmallThrows() {
        var encoder = ParallelBrotliEncoder(quality: 1, chunkSize: 32 << 10, lanes: 3)
        let text = samples()[2].bytes
        var output = [UInt8](repeating: 0, count: 100)
        output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
            #expect(throws: BytesError.insufficientCapacity) { try encoder.compressAll(text.span.bytes, into: &span) }
        }
    }
}

extension ParallelInflateTests {
    /// A stream with a sync flush every 32 KB, decoded in pieces of many sizes into output room of many
    /// sizes: every way a flush's empty stored block can be split. 256 KB (8 flushes) here, 1 MB in
    /// ParallelInflateBulkTests.
    @Test func streamingDecodeOfManyFlushes() throws {
        try Self.checkStreamingDecodeOfManyFlushes(size: 256 << 10)
    }

    static func checkStreamingDecodeOfManyFlushes(size: Int) throws {
        let text = samples().last!.bytes
        var encoder = ParallelDeflateEncoder(format: .raw, level: 1, chunkSize: 32 << 10, lanes: 16)
        let compressed = try parallelEncodeStreaming(&encoder, Array(text.prefix(size)), chunk: size, outputChunk: 1 << 20, flush: .flush)
        let expected = Array(text.prefix(size))
        for (chunk, outputChunk) in [(1, 1 << 20), (3, 1 << 20), (7, 777), (compressed.count, 1), (compressed.count, 2), (compressed.count, 5), (compressed.count, 31), (16_383, 65_536), (100, 3)] {
            #expect(decodeStreaming(compressed, format: .raw, chunk: chunk, outputChunk: outputChunk) == .decoded(expected) || decodePrefixStreaming(compressed, chunk: chunk, outputChunk: outputChunk) == expected, "pieces \(chunk), output \(outputChunk)")
        }
    }
}

/// Decodes an unfinished stream (flushed, not ended) in pieces with Bytes: everything decodable.
func decodePrefixStreaming(_ data: [UInt8], chunk: Int, outputChunk: Int) -> [UInt8]? {
    var decoder = DeflateDecoder(format: .raw)
    var result: [UInt8] = []
    var pending: [UInt8] = []
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    while offset < data.count || !pending.isEmpty {
        let end = min(offset + chunk, data.count)
        pending += data[offset..<end]
        offset = end
        while true {
            var progress = TransformProgress(consumed: 0, produced: 0, status: .needsInput)
            var failed = false
            buffer.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: raw, initializedCount: 0)
                do { progress = try decoder.decompress(pending.span.bytes, into: &span) } catch { failed = true }
                result += raw[..<span.finalize(for: raw)]
            }
            if failed { return nil }
            pending.removeFirst(progress.consumed)
            if progress.status != .needsOutput { break }
        }
        if offset == data.count { break }
    }
    return result
}

/// The parallel encoder on the large sample at every level and format, its ratio at levels 1 and 6, and every piece
/// pattern over it.
@Suite(.bulk) struct ParallelDeflateBulkTests {
    @Test(arguments: [0, 1, 6, 9])
    func roundTripsInEveryFormat(level: Int) throws {
        try ParallelDeflateTests.checkRoundTrips([("large", largeSample())], level: level)
    }

    @Test(arguments: [1, 6])
    func compressesAlmostAsWellAsOneStream(level: Int) throws {
        try ParallelDeflateTests.checkCompressesAlmostAsWellAsOneStream(largeSample(), level: level)
    }

    @Test(arguments: [1, 6])
    func streamingRoundTrips(level: Int) throws {
        try ParallelDeflateTests.checkStreamingRoundTrips(largeSample(), level: level)
    }
}

/// The parallel decoder on the large sample, 2 MB of false markers, and a megabyte of flushes.
@Suite(.bulk) struct ParallelInflateBulkTests {
    @Test(arguments: [1, 6])
    func decodesEveryStreamCorrectly(level: Int) throws {
        try ParallelInflateTests.checkDecodesEveryStream(largeSample(), [("large", largeSample())], level: level)
    }

    @Test func falseMarkersAreRejected() throws { try ParallelInflateTests.checkFalseMarkers(size: 2 << 20) }

    @Test func corruptAndTruncatedStreamsThrow() throws { try ParallelInflateTests.checkCorruptAndTruncated(largeSample()) }

    @Test func asyncFormMatches() async throws { try await ParallelInflateTests.checkAsyncFormMatches(largeSample()) }

    @Test func streamingDecodeOfManyFlushes() throws { try ParallelInflateTests.checkStreamingDecodeOfManyFlushes(size: 1 << 20) }
}
