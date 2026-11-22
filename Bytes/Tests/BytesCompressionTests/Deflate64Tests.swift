import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing
import zlib

// Deflate64 (zip method 9) and decoding into the caller's buffers with the history in front
// (`decompress(_:into:historyCount:)`). No library writes Deflate64, so the streams come from a small encoder here:
// fixed-Huffman blocks with chosen matches (as NativeZip's make-fixtures.py builds its fixture), and dynamic blocks
// from a greedy LZ77 parse. The three ways to decode must agree with each other and with the encoder's input.

@Suite struct Deflate64Tests {
    // MARK: Streams

    /// The operations of NativeZip's Deflate64 fixture: a 70,000-byte seed, then matches with distance codes 30 and
    /// 31 (the farthest, 65,536, with all 14 extra bits set), length symbol 285 with its 16 extra bits (the longest,
    /// 65,538), and enough long matches to cross several 1 MB chunks.
    static let fixedOperations: [Token] = {
        var tokens = text(70_000, seed: 2).map { Token.literal($0) }
        tokens += [
            .match(length: 30_000, distance: 40_000), .match(length: 1_000, distance: 65_536),
            .match(length: 65_538, distance: 1), .match(length: 65_538, distance: 100_000 - 64_000),
        ]
        tokens += Array(repeating: .match(length: 65_538, distance: 65_536), count: 40)
        return tokens
    }()

    /// The fixture's stream (one fixed-Huffman block) and what it decodes to: about 2.8 MB.
    static let fixed: (stream: [UInt8], data: [UInt8]) = {
        let encoder = TestDeflateEncoder(deflate64: true)
        return (encoder.stream(fixedOperations, blockTokens: .max, dynamic: false), expand(fixedOperations))
    }()

    /// Data with what only Deflate64 can code: a repeat 50,000 bytes back, runs longer than 258, matches 32,769 or
    /// more back.
    static let longReach: [UInt8] = {
        let a = text(40_000, seed: 3)
        let b = SampleBytes.random(12_000, seed: 4)
        return a + b + a + [UInt8](repeating: 0x2A, count: 70_000) + b + text(5_000, seed: 5) + a.prefix(30_000)
    }()

    /// ``longReach`` in dynamic blocks, small ones so the stream has several headers with up to 32 distance codes.
    static let dynamic: [UInt8] = TestDeflateEncoder(deflate64: true).compress(longReach, blockTokens: 4_000)

    /// A short stream: for input fed a byte at a time.
    static let shortData = text(20_000, seed: 6) + [UInt8](repeating: 7, count: 1_000) + text(3_000, seed: 6)
    static let short: [UInt8] = TestDeflateEncoder(deflate64: true).compress(shortData, blockTokens: 2_000)

    // MARK: Deflate64

    @Test func decoderProperties() {
        let plain = DeflateDecoder(format: .gzip)
        #expect(plain.variant == .deflate && plain.historySize == 32_768)
        let deflate64 = DeflateDecoder(variant: .deflate64)
        #expect(deflate64.variant == .deflate64 && deflate64.format == .raw && deflate64.historySize == 65_536)
        #expect(DeflateDecoder(variant: .deflate).format == .raw)
        #expect(DeflateVariant.deflate64.maximumMatchLength == 65_538 && DeflateVariant.deflate.maximumMatchLength == 258)
    }

    /// The fixture's long matches and far distances, decoded each way.
    @Test func fixedHuffmanLongMatches() {
        let (stream, data) = Self.fixed
        #expect(decode(stream, variant: .deflate64) == .decoded(data))
        #expect(decodeWithHistory(stream, variant: .deflate64, room: 1 << 20) == .decoded(data))
        #expect(decodeWithHistory(stream, variant: .deflate64, room: 65_539) == .decoded(data))
        #expect(decodeInWindow(stream, variant: .deflate64, chunk: 1 << 20, outputChunk: 1 << 20) == .decoded(data))
        // DEFLATE has no distance code 30.
        #expect(decode(stream, variant: .deflate) == .failed)
    }

    /// Dynamic blocks using distance codes 30 and 31 and length symbol 285, every way.
    @Test func dynamicBlocks() {
        let data = Self.longReach
        #expect(decode(Self.dynamic, variant: .deflate64) == .decoded(data))
        #expect(decodeInWindow(Self.dynamic, variant: .deflate64, chunk: 4096, outputChunk: 65_536) == .decoded(data))
        #expect(decodeInWindow(Self.dynamic, variant: .deflate64, chunk: 100_000, outputChunk: 1000) == .decoded(data))
        // The stream does use what's Deflate64's own.
        let tokens = TestDeflateEncoder(deflate64: true).tokens(data)
        #expect(tokens.contains { if case let .match(length, distance) = $0 { length > 258 && distance > 32_768 } else { false } })
        #expect(decode(Self.dynamic, variant: .deflate) == .failed)
    }

    /// A stream with no length-258 matches (symbol 285 is the only length that changes) and no distance codes 30 or
    /// 31 decodes the same either way.
    @Test func deflateWithoutLongestMatchesIsDeflate64() {
        for sample in smallSamples() where sample.name == "text" || sample.name == "random" {
            let data = Array(sample.bytes.prefix(100_000))
            for strategy in [Z_DEFAULT_STRATEGY, Z_FIXED] {
                let stream = zlibCompress(data, strategy: strategy)
                #expect(decode(stream, variant: .deflate64) == .decoded(data), "\(sample.name)")
            }
        }
        // And with length-258 matches it doesn't: the 16 extra bits make other lengths, or nonsense.
        for sample in smallSamples() where sample.name == "runs" || sample.name == "periodic" {
            #expect(decode(zlibCompress(sample.bytes), variant: .deflate64) != .decoded(sample.bytes))
        }
    }

    /// The encoder's DEFLATE (window 32 KB, matches up to 258) decodes as DEFLATE: checks the test encoder.
    @Test func testEncoderWritesDeflate() {
        let data = Self.longReach
        let stream = TestDeflateEncoder(deflate64: false).compress(data, blockTokens: 4_000)
        #expect(zlibDecompress(stream) == .decoded(data))
        #expect(decode(stream, variant: .deflate) == .decoded(data))
    }

    // MARK: Decoding into the caller's buffer

    static let rooms: [Int] = [0, 1 << 16, 1 << 20] // 0: the variant's longest match plus one

    /// The history API against `decompressAll`, for both variants, by room and by input pieces.
    @Test(arguments: Self.rooms)
    func historyMatchesDecompressAll(room: Int) {
        for (stream, variant, name) in Self.historyCases(full: false) {
            let reference = decode(stream, variant: variant)
            guard case .decoded = reference else {
                Issue.record("\(name) doesn't decode")
                continue
            }
            let room = room == 0 ? variant.maximumMatchLength + 1 : max(room, variant.maximumMatchLength + 1)
            for split in [nil, 4096, 65_543] as [Int?] {
                #expect(decodeWithHistory(stream, variant: variant, room: room, split: split) == reference, "\(name), room \(room), split \(split ?? 0)")
            }
        }
    }

    static func historyCases(full: Bool) -> [(stream: [UInt8], variant: DeflateVariant, name: String)] {
        let deflateSamples = full ? samples() : smallSamples()
        var cases = deflateSamples.flatMap { sample in
            [(zlibCompress(sample.bytes), DeflateVariant.deflate, "\(sample.name)"),
             (zlibCompress(sample.bytes, level: 0), .deflate, "\(sample.name), stored")]
        }
        cases += [(Self.dynamic, .deflate64, "Deflate64 dynamic"), (Self.short, .deflate64, "Deflate64 short")]
        if full { cases.append((Self.fixed.stream, .deflate64, "Deflate64 fixed")) }
        return cases
    }

    /// Input a byte at a time, and small room: every resumption point of a short stream, both variants.
    @Test func historyInputByteByByte() {
        let deflateData = Array(smallSamples()[2].bytes.prefix(20_000))
        let deflate = zlibCompress(deflateData)
        for split in [1, 7] {
            #expect(decodeWithHistory(deflate, variant: .deflate, room: 259, split: split) == .decoded(deflateData))
            #expect(decodeWithHistory(Self.short, variant: .deflate64, room: 65_539, split: split) == .decoded(Self.shortData))
        }
    }

    /// gzip through the history API: the checksum covers what it writes.
    @Test func historyWithContainer() {
        let data = smallSamples()[2].bytes
        var gzip = zlibCompress(data, format: .gzip)
        #expect(decodeWithHistory(gzip, format: .gzip, room: 1 << 16) == .decoded(data))
        gzip[gzip.count - 5] ^= 1 // The CRC-32.
        #expect(decodeWithHistory(gzip, format: .gzip, room: 1 << 16) == .failed)
    }

    /// A match reaching before the history given throws.
    @Test func tooLittleHistory() throws {
        // Literals "abc", then a fixed block's match of 3, 3 back: decodes with 0 history, but not when the "abc"
        // isn't there (a second stream starting with the match).
        var writer = LSBWriter()
        TestDeflateEncoder(deflate64: true).writeBlock(
            [.match(length: 3, distance: 3)][...], final: true, dynamic: false, into: &writer
        )
        let stream = writer.finish()
        var decoder = DeflateDecoder(variant: .deflate64)
        var buffer = [UInt8](repeating: 0x61, count: 300)
        var span = buffer.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        let progress = try decoder.decompress(stream.span.bytes, into: &raw, historyCount: 3)
        #expect(progress.status == .finished && progress.produced == 3)
        decoder.reset()
        do throws(BytesError) {
            _ = try decoder.decompress(stream.span.bytes, into: &raw, historyCount: 2)
            Issue.record("A match reaching before the history decoded")
        } catch {
            #expect(error == .invalidValue)
        }
    }

    // MARK: Malformed streams

    /// Truncated streams ask for more input (and fail in one call), never trap or loop.
    @Test(arguments: [DeflateVariant.deflate, .deflate64])
    func truncatedStreams(variant: DeflateVariant) {
        let stream = variant == .deflate64 ? Self.short : zlibCompress(Array(smallSamples()[2].bytes.prefix(20_000)))
        for count in Array(stride(from: 0, to: stream.count, by: 97)) + [stream.count - 1] {
            let cut = Array(stream.prefix(count))
            #expect(decode(cut, variant: variant) == .failed, "\(count)")
            #expect(decodeWithHistory(cut, variant: variant, room: 1 << 17) == .failed, "\(count)")
        }
    }

    /// Mutated Deflate64 streams: the three ways to decode agree, and none traps. The first 200 mutations; 5,000 in
    /// Deflate64BulkTests.
    @Test func corruptStreamsAgree() {
        Self.checkCorruptStreams(iterations: 200)
    }

    static func checkCorruptStreams(iterations: Int) {
        var rng = SplitMix64(seed: 64)
        let seeds = [Array(Self.dynamic.prefix(3_000)), Self.short, Array(Self.fixed.stream.prefix(3_000))]
        var rejected = 0
        for _ in 0..<iterations {
            var bytes = seeds.randomElement(using: &rng)!
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
                case 1: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                default: bytes.removeLast(Int.random(in: 0...min(16, bytes.count - 1), using: &rng))
                }
            }
            let reference = decode(bytes, variant: .deflate64)
            #expect(decodeWithHistory(bytes, variant: .deflate64, room: 65_539, split: 997) == reference)
            #expect(decodeInWindow(bytes, variant: .deflate64, chunk: 1000, outputChunk: 70_000) == reference)
            if case .failed = reference { rejected += 1 }
        }
        #expect(rejected > 0)
    }

    @Test func rejectsMalformedHeaders() {
        // A dynamic header with 31 distance codes (HDIST 30), Deflate64's alone: final, dynamic, HLIT 0 (257 codes),
        // HDIST 30, HCLEN 0, then nothing. DEFLATE rejects the count; Deflate64 reads on and runs out of input.
        let header: [UInt8] = [0x05, 0x1E, 0x00]
        for (variant, expected) in [(DeflateVariant.deflate, BytesError.invalidValue), (.deflate64, .insufficientData)] {
            var decoder = DeflateDecoder(variant: variant)
            var output = OutputRawSpan()
            do throws(BytesError) {
                _ = try decoder.decompressAll(header.span.bytes, into: &output)
                Issue.record("\(variant) decoded a header with no tables")
            } catch {
                #expect(error == expected, "\(variant)")
            }
        }
    }

    // MARK: A long literal code, then a long match

    /// A 15-bit literal code from a subtable, then a match whose length and distance codes and extra bits take 48
    /// bits, in DEFLATE's fast loop: 63 bits after a refill, which the loop's comments count as 56 or more. It works
    /// because a refill's 8-byte load leaves all 64 bits of the buffer valid. Several bit alignments and positions in
    /// a literal run.
    @Test func longLiteralThenLongMatch() {
        // Complete codes: lengths 1 through 14 and two of 15. Literal 'A' and length symbol 284 (5 extra bits) at 15
        // bits; distance symbol 29 (13 extra bits) at 15.
        var literalLengths = [Int](repeating: 0, count: 286)
        for byte in 0...12 { literalLengths[byte] = byte + 1 }
        literalLengths[256] = 14
        literalLengths[0x41] = 15
        literalLengths[284] = 15
        var distanceLengths = [Int](repeating: 0, count: 30)
        for code in 0...13 { distanceLengths[code] = code + 1 }
        distanceLengths[14] = 15
        distanceLengths[29] = 15
        var rng = SplitMix64(seed: 15)
        for prefix in 25_000..<25_010 {
            var tokens = (0..<prefix).map { _ in Token.literal(UInt8.random(in: 0...12, using: &rng)) }
            tokens += [.literal(0x41), .match(length: 257, distance: 24_577 + Int.random(in: 0..<400, using: &rng))]
            tokens += (0..<300).map { _ in Token.literal(UInt8.random(in: 0...12, using: &rng)) }
            var writer = LSBWriter()
            TestDeflateEncoder(deflate64: false).writeBlock(
                tokens[...], final: true, lengths: (literalLengths, distanceLengths), into: &writer
            )
            let stream = writer.finish()
            let data = expand(tokens)
            #expect(zlibDecompress(stream) == .decoded(data), "the test stream")
            #expect(decode(stream, variant: .deflate) == .decoded(data), "prefix \(prefix)")
        }
    }
}

/// The sweeps: the fixture stream and every sample through the history API at every room and split, and 5,000
/// mutations.
@Suite(.bulk) struct Deflate64BulkTests {
    @Test(arguments: Deflate64Tests.rooms)
    func historyMatchesDecompressAll(room: Int) {
        for (stream, variant, name) in Deflate64Tests.historyCases(full: true) {
            let reference = decode(stream, variant: variant)
            let room = room == 0 ? variant.maximumMatchLength + 1 : max(room, variant.maximumMatchLength + 1)
            for split in [nil, 1000, 4096, 65_543, 1 << 20] as [Int?] {
                #expect(decodeWithHistory(stream, variant: variant, room: room, split: split) == reference, "\(name), room \(room), split \(split ?? 0)")
            }
        }
    }

    @Test func truncatedEverywhere() {
        let stream = Deflate64Tests.dynamic
        for count in 0..<stream.count {
            let cut = Array(stream.prefix(count))
            #expect(decode(cut, variant: .deflate64) == .failed, "\(count)")
            if count % 16 == 0 {
                #expect(decodeWithHistory(cut, variant: .deflate64, room: 1 << 17, split: 1000) == .failed, "\(count)")
            }
        }
    }

    @Test func corruptStreamsAgree() {
        Deflate64Tests.checkCorruptStreams(iterations: 5_000)
    }

    @Test func windowedRoundTrips() {
        let encoder = TestDeflateEncoder(deflate64: true)
        for sample in samples() {
            let stream = encoder.compress(sample.bytes, chainDepth: 4)
            #expect(decode(stream, variant: .deflate64) == .decoded(sample.bytes), "\(sample.name)")
            for (chunk, outputChunk) in [(1, 7), (4096, 1000), (65_536, 100_000)] where chunk > 1 || sample.bytes.count <= 100_000 {
                #expect(decodeInWindow(stream, variant: .deflate64, chunk: chunk, outputChunk: outputChunk) == .decoded(sample.bytes))
            }
        }
    }
}

// MARK: - Drivers

/// `decompressAll` with a decoder of `variant`.
private func decode(_ data: [UInt8], variant: DeflateVariant) -> Outcome {
    var decoder = DeflateDecoder(variant: variant)
    // Uninitialized: room for the fixture's 2.8 MB, or DEFLATE's 1032:1 expansion; untouched pages are never mapped.
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(4 << 20, data.count * 1100), alignment: 1)
    defer { buffer.deallocate() }
    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
    guard let consumed = try? decoder.decompressAll(data.span.bytes, into: &span), consumed == data.count else {
        _ = span.finalize(for: buffer)
        return .failed
    }
    let produced = span.finalize(for: buffer)
    return .decoded(Array(UnsafeRawBufferPointer(rebasing: buffer[..<produced])))
}

/// `decompress(_:into:historyCount:)` into one buffer of history plus `room`, moving the last ``historySize`` bytes
/// to its front after each call; input given `split` more bytes at a time (all of it when `nil`).
private func decodeWithHistory(
    _ data: [UInt8], variant: DeflateVariant = .deflate, format: DeflateFormat = .raw, room: Int, split: Int? = nil
) -> Outcome {
    var decoder = variant == .deflate ? DeflateDecoder(format: format) : DeflateDecoder(variant: variant)
    let historySize = decoder.historySize
    var buffer = [UInt8](repeating: 0, count: historySize + room)
    var result: [UInt8] = []
    var history = 0
    var consumed = 0
    var available = min(split ?? data.count, data.count)
    while true {
        let progress: TransformProgress
        do {
            var span = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            progress = try decoder.decompress(data.span.bytes.extracting(consumed..<available), into: &raw, historyCount: history)
        } catch {
            return .failed
        }
        consumed += progress.consumed
        let end = history + progress.produced
        result += buffer[history..<end]
        let kept = min(historySize, end)
        buffer.replaceSubrange(0..<kept, with: buffer[(end - kept)..<end])
        history = kept
        switch progress.status {
        case .finished:
            return consumed == data.count ? .decoded(result) : .failed
        case .needsInput:
            if available == data.count { return .failed } // Truncated.
            available = min(available + (split ?? data.count), data.count)
        case .needsOutput:
            if progress.produced == 0 { return .failed } // Stalled: the room always fits a match.
        }
    }
}

/// `decompress(_:into:)` (the decoder's own window) with input in pieces of up to `chunk` bytes and an output buffer
/// of `outputChunk` bytes emptied after each call.
private func decodeInWindow(_ data: [UInt8], variant: DeflateVariant, chunk: Int, outputChunk: Int) -> Outcome {
    var decoder = DeflateDecoder(variant: variant)
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
            let produced = span.finalize(for: raw)
            result += raw[..<produced]
            return progress
        }
        guard let progress else { return .failed }
        pending.removeFirst(progress.consumed)
        switch progress.status {
        case .finished:
            return pending.isEmpty && offset == data.count ? .decoded(result) : .failed
        case .needsInput:
            if offset == data.count { return .failed } // Truncated.
        case .needsOutput:
            continue
        }
    }
}

// MARK: - A test encoder

private func text(_ count: Int, seed: UInt64) -> [UInt8] { SampleBytes.text(count, seed: seed) }

enum Token: Equatable {
    case literal(UInt8)
    case match(length: Int, distance: Int)
}

/// What `tokens` decode to.
private func expand(_ tokens: [Token]) -> [UInt8] {
    var output: [UInt8] = []
    for token in tokens {
        switch token {
        case let .literal(byte): output.append(byte)
        case let .match(length, distance):
            for _ in 0..<length { output.append(output[output.count - distance]) }
        }
    }
    return output
}

/// DEFLATE's bits: least significant first, Huffman codes most significant bit first.
struct LSBWriter {
    var bytes: [UInt8] = []
    var bits: UInt64 = 0
    var count = 0

    mutating func write(_ value: Int, _ bitCount: Int) {
        bits |= UInt64(value) << UInt64(count)
        count += bitCount
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
            count -= 8
        }
    }

    mutating func code(_ code: Int, _ length: Int) {
        var reversed = 0
        for index in 0..<length { reversed |= ((code >> index) & 1) << (length - 1 - index) }
        write(reversed, length)
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: bits)) }
        bits = 0
        count = 0
        return bytes
    }
}

/// A Deflate64 (or DEFLATE) encoder: greedy hash-chain LZ77, fixed or dynamic Huffman blocks. Slow and plain: a
/// source of streams that use what Deflate64 adds.
struct TestDeflateEncoder {
    var deflate64: Bool

    static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
    static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    var window: Int { deflate64 ? 65536 : 32768 }
    var maximumLength: Int { deflate64 ? 65538 : 258 }

    /// The symbol, extra bits, and extra bit count for a match length: Deflate64's 285 for anything over 258,
    /// DEFLATE's for exactly 258.
    func lengthCode(_ length: Int) -> (symbol: Int, extra: Int, bits: Int) {
        if deflate64, length > 258 { return (285, length - 3, 16) }
        if !deflate64, length == 258 { return (285, 0, 0) }
        let index = Self.lengthBases.lastIndex { $0 <= length }!
        return (257 + index, length - Self.lengthBases[index], Self.lengthExtra[index])
    }

    func distanceCode(_ distance: Int) -> (symbol: Int, extra: Int, bits: Int) {
        let index = Self.distanceBases.lastIndex { $0 <= distance }!
        return (index, distance - Self.distanceBases[index], Self.distanceExtra[index])
    }

    /// Greedy LZ77 with hash chains `chainDepth` long.
    func tokens(_ data: [UInt8], chainDepth: Int = 8) -> [Token] {
        let hashBits = 15
        let ringMask = (1 << 17) - 1
        var head = [Int](repeating: -1, count: 1 << hashBits)
        var previous = [Int](repeating: -1, count: ringMask + 1)
        func hash(_ position: Int) -> Int {
            let value = UInt32(data[position]) | UInt32(data[position + 1]) << 8 | UInt32(data[position + 2]) << 16
            return Int((value &* 2_654_435_761) >> UInt32(32 - hashBits))
        }
        func insert(_ position: Int) {
            guard position + 3 <= data.count else { return }
            let h = hash(position)
            previous[position & ringMask] = head[h]
            head[h] = position
        }
        var result: [Token] = []
        var position = 0
        while position < data.count {
            var bestLength = 0
            var bestDistance = 0
            if position + 3 <= data.count {
                var candidate = head[hash(position)]
                var depth = 0
                let limit = min(maximumLength, data.count - position)
                while candidate >= 0, position - candidate <= window, depth < chainDepth {
                    var length = 0
                    while length < limit, data[candidate + length] == data[position + length] { length += 1 }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = position - candidate
                        if length == limit { break }
                    }
                    let next = previous[candidate & ringMask]
                    if next >= candidate { break }
                    candidate = next
                    depth += 1
                }
            }
            if bestLength >= 3 {
                result.append(.match(length: bestLength, distance: bestDistance))
                for index in position..<(position + bestLength) { insert(index) }
                position += bestLength
            } else {
                result.append(.literal(data[position]))
                insert(position)
                position += 1
            }
        }
        return result
    }

    /// Code lengths for `frequencies`, at most `limit` bits (halving the counts until they fit).
    static func codeLengths(_ frequencies: [Int], limit: Int) -> [Int] {
        var frequencies = frequencies
        while true {
            let lengths = huffmanLengths(frequencies)
            if lengths.max()! <= limit { return lengths }
            frequencies = frequencies.map { $0 == 0 ? 0 : max(1, $0 >> 1) }
        }
    }

    /// Huffman's code lengths, by the two-queue method.
    static func huffmanLengths(_ frequencies: [Int]) -> [Int] {
        var lengths = [Int](repeating: 0, count: frequencies.count)
        let used = frequencies.indices.filter { frequencies[$0] > 0 }.sorted { (frequencies[$0], $0) < (frequencies[$1], $1) }
        if used.count == 1 { lengths[used[0]] = 1 }
        guard used.count > 1 else { return lengths }
        var weight = used.map { frequencies[$0] }
        var parent = [Int](repeating: -1, count: 2 * used.count)
        var nextLeaf = 0
        var nextInternal = used.count
        func smallest() -> Int {
            if nextLeaf < used.count, nextInternal >= weight.count || weight[nextLeaf] <= weight[nextInternal] {
                nextLeaf += 1
                return nextLeaf - 1
            }
            nextInternal += 1
            return nextInternal - 1
        }
        for _ in 0..<(used.count - 1) {
            let a = smallest()
            let b = smallest()
            weight.append(weight[a] + weight[b])
            parent[a] = weight.count - 1
            parent[b] = weight.count - 1
        }
        var depth = [Int](repeating: 0, count: weight.count)
        for node in stride(from: weight.count - 2, through: 0, by: -1) { depth[node] = depth[parent[node]] + 1 }
        for (index, symbol) in used.enumerated() { lengths[symbol] = depth[index] }
        return lengths
    }

    /// Canonical codes (RFC 1951, 3.2.2) for `lengths`.
    static func canonicalCodes(_ lengths: [Int]) -> [Int] {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 { counts[length] += 1 }
        var next = [Int](repeating: 0, count: 16)
        var code = 0
        for bits in 1...15 {
            code = (code + counts[bits - 1]) << 1
            next[bits] = code
        }
        return lengths.map { length in
            guard length > 0 else { return 0 }
            defer { next[length] += 1 }
            return next[length]
        }
    }

    static var fixedLiteralLengths: [Int] { (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 } }

    /// Writes one block of `tokens`: fixed Huffman, dynamic with codes from the tokens' frequencies, or dynamic with
    /// the code lengths given.
    func writeBlock(
        _ tokens: ArraySlice<Token>, final: Bool, dynamic: Bool = true, lengths given: (literal: [Int], distance: [Int])? = nil,
        into writer: inout LSBWriter
    ) {
        let dynamic = dynamic || given != nil
        writer.write(final ? 1 : 0, 1)
        writer.write(dynamic ? 2 : 1, 2)
        var literalLengths = Self.fixedLiteralLengths
        var distanceLengths = [Int](repeating: 5, count: 32)
        if let given {
            (literalLengths, distanceLengths) = given
        } else if dynamic {
            var literalCounts = [Int](repeating: 0, count: 286)
            var distanceCounts = [Int](repeating: 0, count: deflate64 ? 32 : 30)
            literalCounts[256] = 1
            for token in tokens {
                switch token {
                case let .literal(byte): literalCounts[Int(byte)] += 1
                case let .match(length, distance):
                    literalCounts[lengthCode(length).symbol] += 1
                    distanceCounts[distanceCode(distance).symbol] += 1
                }
            }
            if literalCounts.count(where: { $0 > 0 }) < 2 { literalCounts[0] += 1 }
            if distanceCounts.count(where: { $0 > 0 }) < 2 {
                distanceCounts[0] += 1
                distanceCounts[1] += 1
            }
            literalLengths = Self.codeLengths(literalCounts, limit: 15)
            distanceLengths = Self.codeLengths(distanceCounts, limit: 15)
        }
        if dynamic {
            let literalCount = max(257, literalLengths.lastIndex { $0 > 0 }! + 1)
            let distanceCount = distanceLengths.lastIndex { $0 > 0 }! + 1
            let sequence = Array(literalLengths[..<literalCount]) + Array(distanceLengths[..<distanceCount])
            var codeLengthCounts = [Int](repeating: 0, count: 19)
            for length in sequence { codeLengthCounts[length] += 1 }
            if codeLengthCounts.count(where: { $0 > 0 }) < 2 { codeLengthCounts[codeLengthCounts[0] > 0 ? 1 : 0] += 1 }
            let codeLengthLengths = Self.codeLengths(codeLengthCounts, limit: 7)
            let codeLengthCodes = Self.canonicalCodes(codeLengthLengths)
            var orderCount = 19
            while orderCount > 4, codeLengthLengths[Self.codeLengthOrder[orderCount - 1]] == 0 { orderCount -= 1 }
            writer.write(literalCount - 257, 5)
            writer.write(distanceCount - 1, 5)
            writer.write(orderCount - 4, 4)
            for index in 0..<orderCount { writer.write(codeLengthLengths[Self.codeLengthOrder[index]], 3) }
            for length in sequence { writer.code(codeLengthCodes[length], codeLengthLengths[length]) }
        }
        let literalCodes = Self.canonicalCodes(literalLengths)
        let distanceCodes = Self.canonicalCodes(distanceLengths)
        for token in tokens {
            switch token {
            case let .literal(byte):
                writer.code(literalCodes[Int(byte)], literalLengths[Int(byte)])
            case let .match(length, distance):
                let (symbol, extra, bits) = lengthCode(length)
                writer.code(literalCodes[symbol], literalLengths[symbol])
                writer.write(extra, bits)
                let (distanceSymbol, distanceExtra, distanceBits) = distanceCode(distance)
                writer.code(distanceCodes[distanceSymbol], distanceLengths[distanceSymbol])
                writer.write(distanceExtra, distanceBits)
            }
        }
        writer.code(literalCodes[256], literalLengths[256])
    }

    /// A whole raw stream of `tokens`, in blocks of `blockTokens`.
    func stream(_ tokens: [Token], blockTokens: Int = 1 << 15, dynamic: Bool = true) -> [UInt8] {
        var writer = LSBWriter()
        var start = 0
        repeat {
            let end = start + min(blockTokens, tokens.count - start)
            writeBlock(tokens[start..<end], final: end == tokens.count, dynamic: dynamic, into: &writer)
            start = end
        } while start < tokens.count
        return writer.finish()
    }

    func compress(_ data: [UInt8], blockTokens: Int = 1 << 15, chainDepth: Int = 8) -> [UInt8] {
        stream(tokens(data, chainDepth: chainDepth), blockTokens: blockTokens)
    }
}
