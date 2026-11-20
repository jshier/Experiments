import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Testing

// LZFSEDecoder against Apple's Compression (`COMPRESSION_LZFSE`) and the lzfse reference encoder's streams, and
// LZVNDecoder against the reference's LZVN streams and results, the `bvxn` blocks Compression writes for small
// inputs, and hand-made opcodes. The reference's streams come from Bytes' encoders, which write its bytes (checked by
// digest in LZFSEEncoderTests); its decoder's results are recorded digests.

/// Decodes an LZFSE stream into exactly `capacity` bytes, checking that the stream was consumed whole.
func lzfseDecode(_ stream: [UInt8], capacity: Int, decoder: inout LZFSEDecoder) -> Result<[UInt8], BytesError> {
    let (result, output) = withExactBuffers(stream, capacity: capacity) { input, output throws(BytesError) in
        try decoder.decompressAll(input, into: &output)
    }
    // A stream not consumed whole reports `trailingData`.
    return result.flatMap { consumed in consumed == stream.count ? .success(output) : .failure(.trailingData) }
}

/// Decodes a raw LZVN stream into exactly `capacity` bytes, checking that the stream was consumed whole.
func lzvnDecode(_ stream: [UInt8], capacity: Int) -> Result<[UInt8], BytesError> {
    let (result, output) = withExactBuffers(stream, capacity: capacity) { input, output throws(BytesError) in
        try LZVNDecoder().decompressAll(input, into: &output)
    }
    // A stream not consumed whole reports `trailingData`.
    return result.flatMap { consumed in consumed == stream.count ? .success(output) : .failure(.trailingData) }
}

/// The blocks of an LZFSE stream: each one's magic and its bytes.
func lzfseBlocks(_ stream: [UInt8]) -> [(magic: String, bytes: ArraySlice<UInt8>)] {
    func load32(_ offset: Int) -> Int {
        Int(stream[offset]) | Int(stream[offset + 1]) << 8 | Int(stream[offset + 2]) << 16 | Int(stream[offset + 3]) << 24
    }
    var blocks: [(String, ArraySlice<UInt8>)] = []
    var position = 0
    while position < stream.count {
        let magic = String(decoding: stream[position..<position + 4], as: UTF8.self)
        let size: Int
        switch magic {
        case "bvx$": size = 4
        case "bvx-": size = 8 + load32(position + 4)
        case "bvxn": size = 12 + load32(position + 8)
        case "bvx2":
            let v0 = UInt64(load32(position + 8)) | UInt64(load32(position + 12)) << 32
            let v1 = UInt64(load32(position + 16)) | UInt64(load32(position + 20)) << 32
            let headerSize = load32(position + 24)
            size = headerSize + Int(v0 >> 20 & 0xFFFFF) + Int(v1 >> 40 & 0xFFFFF)
        default: preconditionFailure("unexpected block \(magic)")
        }
        blocks.append((magic, stream[position..<position + size]))
        position += size
    }
    return blocks
}

/// A `bvx2` block rewritten as `bvx1`: the same fields and frequencies, in the 772-byte plain header.
func lzfseBlockAsV1(_ block: ArraySlice<UInt8>) -> [UInt8] {
    let bytes = Array(block)
    func load64(_ offset: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) } }
    let v0 = load64(8), v1 = load64(16), v2 = load64(24)
    func field(_ value: UInt64, _ offset: UInt64, _ width: UInt64) -> Int { Int(value >> offset & (1 << width - 1)) }
    let headerSize = field(v2, 0, 32)
    // The frequencies: the same prefix code the decoder reads, low bits first.
    var frequencies: [Int] = []
    var accumulator: UInt64 = 0
    var accumulated = 0
    var position = 32
    while frequencies.count < 360 {
        while position < headerSize && accumulated <= 56 {
            accumulator |= UInt64(bytes[position]) << UInt64(accumulated)
            accumulated += 8
            position += 1
        }
        let (length, value): (Int, Int)
        if accumulator & 1 == 0 { (length, value) = (2, Int(accumulator >> 1 & 1)) }
        else if accumulator & 2 == 0 { (length, value) = (3, 2 + Int(accumulator >> 2 & 1)) }
        else if accumulator & 4 == 0 { (length, value) = (5, 4 + Int(accumulator >> 3 & 3)) }
        else if accumulator & 8 == 0 { (length, value) = (8, 8 + Int(accumulator >> 4 & 0xF)) }
        else { (length, value) = (14, 24 + Int(accumulator >> 4 & 0x3FF)) }
        frequencies.append(value)
        accumulator >>= UInt64(length)
        accumulated -= length
    }
    var header: [UInt8] = []
    func append32(_ value: Int) { header += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    func append16(_ value: Int) { header += (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    let literalPayload = field(v0, 20, 20), lmdPayload = field(v1, 40, 20)
    header += Array("bvx1".utf8)
    append32(Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24)
    append32(literalPayload + lmdPayload)
    append32(field(v0, 0, 20))
    append32(field(v0, 40, 20))
    append32(literalPayload)
    append32(lmdPayload)
    append32(field(v0, 60, 3) - 7)
    for shift: UInt64 in [0, 10, 20, 30] { append16(field(v1, shift, 10)) }
    append32(field(v1, 60, 3) - 7)
    append16(field(v2, 32, 10))
    append16(field(v2, 42, 10))
    append16(field(v2, 52, 10))
    for frequency in frequencies { append16(frequency) }
    header += [0, 0] // Padding to the C struct's 772 bytes.
    precondition(header.count == 772)
    return header + bytes[headerSize...]
}

// MARK: - LZVN opcodes

enum LZVNOp {
    /// A literal of 0 to 3 bytes and a match with a new distance: small (11 bits, distance below 1536), medium
    /// (14 bits), or large (16).
    static func small(_ literal: [UInt8], match: Int, distance: Int) -> [UInt8] {
        [UInt8(literal.count << 6 | (match - 3) << 3 | distance >> 8), UInt8(distance & 0xFF)] + literal
    }
    static func medium(_ literal: [UInt8], match: Int, distance: Int) -> [UInt8] {
        let operand = distance << 2 | (match - 3) & 3
        return [UInt8(0xA0 | literal.count << 3 | (match - 3) >> 2), UInt8(operand & 0xFF), UInt8(operand >> 8)] + literal
    }
    static func large(_ literal: [UInt8], match: Int, distance: Int) -> [UInt8] {
        [UInt8(literal.count << 6 | (match - 3) << 3 | 7), UInt8(distance & 0xFF), UInt8(distance >> 8)] + literal
    }
    /// A literal of 1 to 3 bytes and a match at the previous distance.
    static func previous(_ literal: [UInt8], match: Int) -> [UInt8] {
        [UInt8(literal.count << 6 | (match - 3) << 3 | 6)] + literal
    }
    static func literal(_ bytes: [UInt8]) -> [UInt8] {
        bytes.count < 16 ? [0xE0 | UInt8(bytes.count)] + bytes : [0xE0, UInt8(bytes.count - 16)] + bytes
    }
    static func match(_ length: Int) -> [UInt8] {
        length < 16 ? [0xF0 | UInt8(length)] : [0xF0, UInt8(length - 16)]
    }
    static let nop: [UInt8] = [0x0E]
    static let end: [UInt8] = [6, 0, 0, 0, 0, 0, 0, 0]
}

@Suite struct LZFSEDecoderTests {
    @Test func appleRoundTrips() {
        var decoder = LZFSEDecoder()
        var magics: Set<String> = []
        for (name, sample) in LZSamples.all where !sample.isEmpty {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            magics.formUnion(lzfseBlocks(stream).map(\.magic))
            #expect(lzfseDecode(stream, capacity: sample.count, decoder: &decoder) == .success(sample), "\(name)")
        }
        // Compression wrote every block type but the plain-header one.
        #expect(magics == ["bvx2", "bvxn", "bvx-", "bvx$"])
    }

    @Test func referenceRoundTrips() throws {
        var decoder = LZFSEDecoder()
        for (name, sample) in LZSamples.all {
            let stream = try lzfseReferenceEncode(sample)
            #expect(lzfseDecode(stream, capacity: sample.count, decoder: &decoder) == .success(sample), "\(name)")
        }
    }

    @Test func largeRoundTrips() {
        var decoder = LZFSEDecoder()
        for (name, sample) in LZSamples.large {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            #expect(lzfseBlocks(stream).count > 2, "\(name)")
            #expect(lzfseDecode(stream, capacity: sample.count, decoder: &decoder) == .success(sample), "\(name)")
            #expect(lzfseDecode(stream, capacity: sample.count + 77, decoder: &decoder) == .success(sample), "\(name)")
        }
    }

    /// `bvx1` blocks: Compression's `bvx2` blocks with their headers rewritten in the plain form.
    @Test func plainHeaders() {
        var decoder = LZFSEDecoder()
        for sample in [LZSamples.text(100_000, seed: 1), LZSamples.mixed(300_000, seed: 2)] {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            let rewritten = lzfseBlocks(stream).flatMap { $0.magic == "bvx2" ? lzfseBlockAsV1($0.bytes) : Array($0.bytes) }
            #expect(lzfseBlocks(stream).contains { $0.magic == "bvx2" })
            #expect(lzfseDecode(rewritten, capacity: sample.count, decoder: &decoder) == .success(sample))
        }
    }

    @Test func emptyAndStopsAtTheEnd() {
        var decoder = LZFSEDecoder()
        #expect(lzfseDecode(Array("bvx$".utf8), capacity: 0, decoder: &decoder) == .success([]))
        #expect(lzfseDecode([], capacity: 0, decoder: &decoder) == .failure(.insufficientData))
        let sample = LZSamples.text(10_000, seed: 3)
        let stream = appleEncode(sample, COMPRESSION_LZFSE)
        let (result, output) = withExactBuffers(stream + [0x62, 0x76], capacity: sample.count) { input, output throws(BytesError) in
            try decoder.decompressAll(input, into: &output)
        }
        #expect(result == .success(stream.count))
        #expect(output == sample)
    }

    @Test func sizeMismatches() {
        var decoder = LZFSEDecoder()
        for sample in [LZSamples.text(10_000, seed: 4), LZSamples.text(1000, seed: 5), LZSamples.random(500, seed: 6)] {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            #expect(lzfseDecode(stream, capacity: sample.count - 1, decoder: &decoder) == .failure(.insufficientCapacity))
            #expect(lzfseDecode(stream, capacity: sample.count + 1, decoder: &decoder) == .success(sample))
            // A block whose decoded size disagrees with its data (a stored block's then runs into the end marker).
            var larger = stream
            larger[4] &+= 1
            let expected: BytesError = lzfseBlocks(stream)[0].magic == "bvx-" ? .insufficientData : .invalidValue
            #expect(lzfseDecode(larger, capacity: sample.count + 1, decoder: &decoder) == .failure(expected))
        }
    }

    @Test func truncationThrows() {
        var decoder = LZFSEDecoder()
        for sample in [LZSamples.text(6000, seed: 1), LZSamples.text(800, seed: 2), LZSamples.random(60, seed: 3)] {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            for length in 0..<stream.count {
                #expect(throws: BytesError.self) {
                    _ = try lzfseDecode(Array(stream.prefix(length)), capacity: sample.count, decoder: &decoder).get()
                }
            }
        }
    }

    /// Random corruption of every block type: decoding may succeed or throw, but stays within the buffers
    /// (checked by the address sanitizer, with exact allocations).
    @Test func corruptionNeverCrashes() {
        var decoder = LZFSEDecoder()
        var generator = SplitMix64(seed: 7)
        let samples = [LZSamples.text(30_000, seed: 1), LZSamples.text(2000, seed: 2), LZSamples.mixed(50_000, seed: 3)]
        for sample in samples {
            let stream = appleEncode(sample, COMPRESSION_LZFSE)
            let v1 = lzfseBlocks(stream).flatMap { $0.magic == "bvx2" ? lzfseBlockAsV1($0.bytes) : Array($0.bytes) }
            for encoded in [stream, v1] {
                for _ in 0..<300 {
                    var corrupt = encoded
                    for _ in 0..<Int(generator.next() % 3 + 1) {
                        corrupt[Int(generator.next() % UInt64(corrupt.count))] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                    }
                    _ = lzfseDecode(corrupt, capacity: sample.count, decoder: &decoder)
                }
            }
        }
        // The decoder still works.
        #expect(lzfseDecode(appleEncode(samples[0], COMPRESSION_LZFSE), capacity: samples[0].count, decoder: &decoder) == .success(samples[0]))
    }
}

@Suite struct LZVNDecoderTests {
    @Test func referenceRoundTrips() throws {
        for (name, sample) in LZSamples.all + LZSamples.large.prefix(2) {
            let stream = try lzvnReferenceEncode(sample)
            #expect(lzvnDecode(stream, capacity: sample.count) == .success(sample), "\(name)")
            #expect(lzvnDecode(stream, capacity: sample.count + 40) == .success(sample), "\(name)")
        }
    }

    /// The `bvxn` blocks Compression writes for small inputs, decoded as raw LZVN.
    @Test func appleBlocks() {
        var count = 0
        for (name, sample) in LZSamples.all where !sample.isEmpty {
            for block in lzfseBlocks(appleEncode(sample, COMPRESSION_LZFSE)) where block.magic == "bvxn" {
                count += 1
                #expect(lzvnDecode(Array(block.bytes.dropFirst(12)), capacity: sample.count) == .success(sample), "\(name)")
            }
        }
        #expect(count > 50)
    }

    @Test func everyOpcode() {
        let a: [UInt8] = Array("abc".utf8)
        var stream = LZVNOp.literal(Array("0123456789ABCDEFGHIJ".utf8)) // A large literal (20 bytes).
        stream += LZVNOp.small(a, match: 4, distance: 3) // Overlapping.
        stream += LZVNOp.small([0x2D], match: 8, distance: 7)
        stream += LZVNOp.small([], match: 10, distance: 1)
        stream += LZVNOp.nop
        stream += LZVNOp.medium([], match: 34, distance: 20)
        stream += LZVNOp.previous([0x7A], match: 3)
        stream += LZVNOp.match(15)
        stream += LZVNOp.match(271)
        stream += LZVNOp.large(a, match: 4, distance: 300)
        stream += LZVNOp.literal(Array(repeating: 0x41, count: 271))
        stream += LZVNOp.small([], match: 9, distance: 1)
        stream += [0x16] // The other nop.
        stream += LZVNOp.end
        // The lzfse reference decoder's result for this stream: 657 bytes, by digest (recorded 2026-11-19).
        let decoded = lzvnDecode(stream, capacity: 657)
        #expect(goldenDigest([(try? decoded.get()) ?? []]) == "03b78bf1b39fbbf3e7662b6e10c24d9a4a7f00eb299e8df1d043a93ec8d3eff2")
    }

    /// Distances 1 through 20 with match lengths around the copy widths, alone in an exact buffer (the careful
    /// path) and with room after (the fast path).
    @Test func shortDistances() {
        for distance in 1...20 {
            let history = LZSamples.random(distance, seed: UInt64(distance))
            for length in [3, 4, 7, 8, 9, 10, 15, 16, 17, 31, 32, 33, 100, 271] {
                var stream = LZVNOp.literal(history) + LZVNOp.small([], match: 3, distance: distance)
                if length > 3 { stream += LZVNOp.match(length - 3) }
                stream += LZVNOp.end
                var expected = history
                for _ in 0..<length { expected.append(expected[expected.count - distance]) }
                #expect(lzvnDecode(stream, capacity: expected.count) == .success(expected), "\(distance), \(length)")
                #expect(lzvnDecode(stream, capacity: expected.count + 50) == .success(expected), "\(distance), \(length)")
            }
        }
    }

    @Test func invalidStreams() {
        // Undefined opcodes.
        for opcode: UInt8 in [0x1E, 0x26, 0x2E, 0x36, 0x3E, 0x70, 0x77, 0x7F, 0xD0, 0xD6, 0xDF] {
            #expect(lzvnDecode(LZVNOp.literal([1, 2, 3]) + [opcode, 1, 1] + LZVNOp.end, capacity: 100) == .failure(.invalidValue), "\(opcode)")
        }
        // A match with no distance yet, distance 0, and one before the start.
        #expect(lzvnDecode(LZVNOp.match(4) + LZVNOp.end, capacity: 100) == .failure(.invalidValue))
        #expect(lzvnDecode(LZVNOp.literal([1, 2, 3]) + LZVNOp.match(4) + LZVNOp.end, capacity: 100) == .failure(.invalidValue))
        #expect(lzvnDecode(LZVNOp.small([1, 2], match: 3, distance: 0) + LZVNOp.end, capacity: 100) == .failure(.invalidValue))
        #expect(lzvnDecode(LZVNOp.small([1, 2], match: 3, distance: 3) + LZVNOp.end, capacity: 100) == .failure(.invalidValue))
        #expect(lzvnDecode(LZVNOp.previous([1, 2], match: 3) + LZVNOp.end, capacity: 100) == .failure(.invalidValue))
        // No end-of-stream opcode, or a short one.
        #expect(lzvnDecode(LZVNOp.literal([1, 2, 3]), capacity: 100) == .failure(.insufficientData))
        #expect(lzvnDecode(LZVNOp.literal([1, 2, 3]) + [6, 0, 0], capacity: 100) == .failure(.insufficientData))
        #expect(lzvnDecode([], capacity: 0) == .failure(.insufficientData))
        #expect(lzvnDecode(LZVNOp.end, capacity: 0) == .success([]))
    }

    @Test func sizeMismatches() throws {
        let sample = LZSamples.text(5000, seed: 8)
        let stream = try lzvnReferenceEncode(sample)
        #expect(lzvnDecode(stream, capacity: sample.count - 1) == .failure(.insufficientCapacity))
        #expect(lzvnDecode(stream, capacity: sample.count + 1) == .success(sample))
    }

    @Test func truncationThrows() throws {
        for sample in [LZSamples.text(900, seed: 1), LZSamples.mixed(1200, seed: 2), LZSamples.random(30, seed: 3)] {
            let stream = try lzvnReferenceEncode(sample)
            for length in 0..<stream.count {
                #expect(throws: BytesError.self) { _ = try lzvnDecode(Array(stream.prefix(length)), capacity: sample.count).get() }
            }
        }
    }

    /// Random corruption, checked against the reference decoder's results (recorded 2026-11-19, by digest): the 853
    /// corrupt streams we decode, the reference decoded to the same bytes (it also accepts some we reject: a match at
    /// distance 0, which copies nothing over itself). Nothing reads or writes outside the buffers.
    @Test func corruptionMatchesReference() throws {
        var generator = SplitMix64(seed: 11)
        var decoded: [[UInt8]] = []
        for sample in [LZSamples.text(4000, seed: 1), LZSamples.mixed(20_000, seed: 2)] {
            let stream = try lzvnReferenceEncode(sample)
            for index in 0..<500 {
                var corrupt = stream
                corrupt[Int(generator.next() % UInt64(stream.count - 8))] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                if case .success(let bytes) = lzvnDecode(corrupt, capacity: sample.count + 300) {
                    decoded.append(withUnsafeBytes(of: UInt64(index).littleEndian, Array.init) + bytes)
                }
            }
        }
        #expect(decoded.count == 853)
        #expect(goldenDigest(decoded) == "59d76f00abb0aa1d7b356af1232c93b0488a0bc0e136602033466c6dce574187")
    }
}
