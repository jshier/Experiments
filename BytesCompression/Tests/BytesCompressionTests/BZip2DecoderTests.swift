import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CBZip2
import Testing

// MARK: - The reference library

/// libbzip2's encoding of `data` at `level` (1–9): what `bzip2 -LEVEL` writes.
func bzip2Compress(_ data: [UInt8], level: Int32) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: data.count + data.count / 100 + 600)
    var length = UInt32(output.count)
    // A pointer even for no data: libbzip2 rejects a null source.
    var input = data.isEmpty ? [0] : data
    let status = input.withUnsafeMutableBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            BZ2_bzBuffToBuffCompress(
                UnsafeMutableRawPointer(output.baseAddress!).assumingMemoryBound(to: CChar.self), &length,
                UnsafeMutableRawPointer(input.baseAddress!).assumingMemoryBound(to: CChar.self), UInt32(data.count), level, 0, 0
            )
        }
    }
    precondition(status == BZ_OK, "BZ2_bzBuffToBuffCompress: \(status)")
    return Array(output.prefix(Int(length)))
}

/// libbzip2's decoding of one stream, or nil if it fails.
func bzip2ReferenceDecompress(_ data: [UInt8], capacity: Int) -> [UInt8]? {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    var length = UInt32(output.count)
    var input = data
    let status = input.withUnsafeMutableBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            BZ2_bzBuffToBuffDecompress(
                UnsafeMutableRawPointer(output.baseAddress!).assumingMemoryBound(to: CChar.self), &length,
                UnsafeMutableRawPointer(input.baseAddress!).assumingMemoryBound(to: CChar.self), UInt32(input.count), 0, 0
            )
        }
    }
    return status == BZ_OK ? Array(output.prefix(Int(length))) : nil
}

/// bzip2's CRC, a bit at a time: the reference for the decoder's tables and folding.
func bzip2ReferenceCRC(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 {
            crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1
        }
    }
    return ~crc
}

struct BZip2Decoded: Equatable {
    var output: [UInt8]
    var consumed: Int
}

/// Decodes with `decompressAll` into `capacity` bytes.
func bzip2Decode(
    _ data: [UInt8], capacity: Int, decodedSize: Int? = nil, decoder: inout BZip2Decoder
) -> Result<BZip2Decoded, BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    var consumed = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            consumed = try decoder.decompressAll(data.span.bytes, into: &span, decodedSize: decodedSize)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success(BZip2Decoded(output: Array(output[..<produced]), consumed: consumed))
}

func bzip2Decode(_ data: [UInt8], capacity: Int, decodedSize: Int? = nil) -> Result<BZip2Decoded, BytesError> {
    var decoder = BZip2Decoder()
    return bzip2Decode(data, capacity: capacity, decodedSize: decodedSize, decoder: &decoder)
}

/// Inputs for bzip2: the shared samples, plus ones aimed at its stages: runs of every length around the run-length
/// coding's 4 and 255 (and its 251 count), bytes from a skewed distribution (Huffman codes longer than the lookup
/// table's 10 bits), and every byte value.
func bzip2Samples() -> [(name: String, bytes: [UInt8])] {
    var rng = SplitMix64(seed: 2027)
    var runs: [UInt8] = []
    for length in [1, 2, 3, 4, 5, 6, 7, 8, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 300, 1000, 5000] {
        runs += [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next()), count: length)
        runs += [UInt8(truncatingIfNeeded: rng.next() | 1), UInt8(truncatingIfNeeded: rng.next() & ~1)]
    }
    for _ in 0..<2_000 {
        runs += [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next() % 6), count: Int(rng.next() % 12) + 1)
    }
    let skewed = (0..<150_000).map { _ in UInt8(min(255, (rng.next() % 1_000_000).leadingZeroBitCount * 9 % 256)) }
    let geometric = (0..<150_000).map { _ -> UInt8 in
        var value = 0
        while rng.next() % 3 != 0 && value < 255 {
            value += 1
        }
        return UInt8(value)
    }
    let allBytes = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7 ^ $0 >> 8) }
    let zeros = [UInt8](repeating: 0, count: 1_000_000)
    return samples() + [
        ("runs", runs), ("skewed", skewed), ("geometric", geometric), ("all bytes", allBytes), ("zeros", zeros),
    ]
}

// MARK: - Tests

@Suite("bzip2 decoding")
struct BZip2DecoderTests {
    /// Every level for the samples of one block at any level (100 KB or less); levels 1, 2 and 9 (the block sizes
    /// that split them, and the largest) for the others but the large one. Every level of those, and the large one at
    /// levels 1 and 9, in BZip2BulkTests.
    @Test func roundTripsEveryLevel() {
        Self.checkRoundTripsEveryLevel(bzip2Samples().filter { $0.name != "large" }) { data in
            data.count <= 100_000 ? Array(1...9) : [1, 2, 9]
        }
    }

    static func checkRoundTripsEveryLevel(_ samples: [(name: String, bytes: [UInt8])], levels: ([UInt8]) -> [Int32]) {
        var decoder = BZip2Decoder()
        for (name, data) in samples {
            for level in levels(data) {
                let compressed = bzip2Compress(data, level: level)
                #expect(
                    bzip2Decode(compressed, capacity: data.count, decoder: &decoder)
                        == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                    "\(name), level \(level)"
                )
            }
        }
    }

    /// Every length to 600 (the CRC's folding path from 64 bytes, its 16-byte steps, and the tails), and small
    /// sizes of text.
    @Test func roundTripsEverySmallSize() {
        var decoder = BZip2Decoder()
        var rng = SplitMix64(seed: 9)
        let random = (0..<600).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let text = samples().first { $0.name == "text" }!.bytes
        for size in 0...600 {
            for data in [Array(random.prefix(size)), Array(text.prefix(size))] {
                let compressed = bzip2Compress(data, level: 9)
                #expect(
                    bzip2Decode(compressed, capacity: data.count, decoder: &decoder)
                        == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                    "\(size) bytes"
                )
            }
        }
    }

    /// bzip2 fills a block with up to 100,000 × level − 19 bytes after its run-length coding: sizes on either
    /// side of one and two blocks, at levels 1 and 2. And blocks on either side of 32,768 bytes, where the decoder
    /// changes how it walks the inverse BWT (from both ends, or in segments).
    @Test func roundTripsBlockBoundaries() {
        var decoder = BZip2Decoder()
        var rng = SplitMix64(seed: 11)
        let random = (0..<400_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let text = samples().first { $0.name == "text" }!.bytes
        for size in [32_767, 32_768, 32_769, 33_791, 33_792, 33_793] {
            for data in [Array(random.prefix(size)), Array(text.prefix(size))] {
                let compressed = bzip2Compress(data, level: 9)
                #expect(
                    bzip2Decode(compressed, capacity: data.count, decoder: &decoder)
                        == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                    "\(size) bytes"
                )
            }
        }
        for level in [1, 2] {
            let block = 100_000 * level - 19
            for size in [block - 1, block, block + 1, 2 * block - 1, 2 * block, 2 * block + 1] {
                let data = Array(random.prefix(size))
                let compressed = bzip2Compress(data, level: Int32(level))
                #expect(
                    bzip2Decode(compressed, capacity: data.count, decoder: &decoder)
                        == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                    "\(size) bytes, level \(level)"
                )
            }
        }
    }

    /// Blocks that are a power of a shorter string (`abcabc…`) have a cycle of BWT links per copy, not one: the walk
    /// repeats the origin's.
    @Test func decodesPeriodicBlocks() {
        var decoder = BZip2Decoder()
        var rng = SplitMix64(seed: 13)
        for period in [1, 2, 3, 8, 99, 1_000, 4_000, 33_000, 49_500] {
            // Random bytes with no run of 4 (`bzip2`'s run-length coding would change the period), repeated to
            // 99,000 bytes: one block at level 9 (and two at level 1, the first not a power).
            var unit: [UInt8] = []
            while unit.count < period {
                let byte = UInt8.random(in: 0...255, using: &rng)
                if unit.count >= 3 && unit.suffix(3).allSatisfy({ $0 == byte }) { continue }
                unit.append(byte)
            }
            let data = Array([[UInt8]](repeating: unit, count: 99_000 / period).joined())
            for level: Int32 in [9, 1] {
                let compressed = bzip2Compress(data, level: level)
                #expect(
                    bzip2Decode(compressed, capacity: data.count, decoder: &decoder)
                        == .success(BZip2Decoded(output: data, consumed: compressed.count)),
                    "period \(period), level \(level)"
                )
            }
        }
    }

    @Test func checksCRCs() {
        // Every length's CRC against a bit-at-a-time reference, through decoding: each stream stores libbzip2's.
        for size in [0, 1, 15, 16, 17, 63, 64, 65, 127, 128, 129, 1000, 4097] {
            let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let compressed = bzip2Compress(data, level: 1)
            if size > 0 {
                // The block CRC follows the "BZh1" header and the block magic.
                let stored = compressed[10..<14].reduce(0) { $0 << 8 | UInt32($1) }
                #expect(stored == bzip2ReferenceCRC(data))
            }
            #expect(bzip2Decode(compressed, capacity: size) == .success(BZip2Decoded(output: data, consumed: compressed.count)))
        }
    }

    /// The CRC's tables (a literal) against their definition: table 0 each byte's CRC bit by bit, table `k` table
    /// `k - 1`'s entry followed by a zero byte.
    @Test func crcTables() {
        var expected = [UInt32](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var crc = UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1
            }
            expected[byte] = crc
        }
        for table in 1..<8 {
            for byte in 0..<256 {
                let previous = expected[(table - 1) * 256 + byte]
                expected[table * 256 + byte] = previous << 8 ^ expected[Int(previous >> 24)]
            }
        }
        #expect(BZip2CRC.tables == expected)
    }

    @Test func decodesConcatenatedStreams() {
        let text = samples().first { $0.name == "text" }!.bytes
        let first = Array(text.prefix(150_000))
        let second = Array(text.suffix(30_000)) + [7, 7, 7, 7, 7, 7]
        let streams = bzip2Compress(first, level: 1) + bzip2Compress([], level: 5) + bzip2Compress(second, level: 9)
        #expect(
            bzip2Decode(streams, capacity: first.count + second.count)
                == .success(BZip2Decoded(output: first + second, consumed: streams.count))
        )
        // Bytes after the last stream that don't start another are left alone.
        let trailing = bzip2Compress(first, level: 2)
        for extra: [UInt8] in [[0], [0x42, 0x5A], [0x42, 0x5A, 0x68, 0x30], Array("garbage".utf8)] {
            #expect(
                bzip2Decode(trailing + extra, capacity: first.count)
                    == .success(BZip2Decoded(output: first, consumed: trailing.count)),
                "\(extra)"
            )
        }
    }

    @Test func fillsExactAndShortOutputs() {
        let data = bzip2Samples().first { $0.name == "runs" }!.bytes
        let compressed = bzip2Compress(data, level: 1)
        let decoded = BZip2Decoded(output: data, consumed: compressed.count)
        #expect(bzip2Decode(compressed, capacity: data.count) == .success(decoded))
        #expect(bzip2Decode(compressed, capacity: data.count + 100) == .success(decoded))
        for short in [data.count - 1, data.count - 2, data.count - 300, data.count / 2, 1, 0] {
            #expect(bzip2Decode(compressed, capacity: short) == .failure(.insufficientCapacity), "\(short) bytes")
        }
        #expect(bzip2Decode(compressed, capacity: data.count + 100, decodedSize: data.count) == .success(decoded))
        #expect(bzip2Decode(compressed, capacity: data.count + 100, decodedSize: data.count - 1) == .failure(.mismatch))
        #expect(bzip2Decode(compressed, capacity: data.count + 100, decodedSize: data.count + 1) == .failure(.mismatch))
        #expect(bzip2Decode(compressed, capacity: data.count, decodedSize: data.count + 1) == .failure(.insufficientCapacity))
        #expect(bzip2Decode(compressed, capacity: data.count, decodedSize: -1) == .failure(.invalidValue))
        // A run's count that needs exactly the room left, and one more than it.
        let run = [UInt8](repeating: 9, count: 200)
        let runCompressed = bzip2Compress(run, level: 9)
        #expect(bzip2Decode(runCompressed, capacity: 200) == .success(BZip2Decoded(output: run, consumed: runCompressed.count)))
        #expect(bzip2Decode(runCompressed, capacity: 199) == .failure(.insufficientCapacity))
        #expect(bzip2Decode(runCompressed, capacity: 4) == .failure(.insufficientCapacity))
    }

    @Test func rejectsTruncatedStreams() {
        let text = samples().first { $0.name == "text" }!.bytes
        for (name, data) in [("empty", [UInt8]()), ("one byte", [0x41]), ("text", Array(text.prefix(3_000)))] {
            let compressed = bzip2Compress(data, level: 9)
            var decoder = BZip2Decoder()
            for length in 0..<compressed.count {
                let result = bzip2Decode(Array(compressed.prefix(length)), capacity: data.count + 64, decoder: &decoder)
                #expect(result == .failure(.insufficientData), "\(name), \(length) of \(compressed.count) bytes")
            }
        }
        // Two blocks, cut every 97 bytes.
        let twoBlocks = Array(text.prefix(150_000))
        let compressed = bzip2Compress(twoBlocks, level: 1)
        var decoder = BZip2Decoder()
        for length in stride(from: 0, to: compressed.count, by: 97) {
            let result = bzip2Decode(Array(compressed.prefix(length)), capacity: twoBlocks.count, decoder: &decoder)
            #expect(result == .failure(.insufficientData), "two blocks, \(length) bytes")
        }
    }

    @Test func rejectsBadHeaders() {
        let valid = bzip2Compress([1, 2, 3], level: 9)
        for header in ["BZh0", "BZx9", "BZ\u{0}9", "PK\u{3}\u{4}", "bZh9"] {
            let corrupt = Array(header.utf8) + valid.dropFirst(4)
            #expect(bzip2Decode(corrupt, capacity: 16) == .failure(.invalidValue), "\(header)")
        }
        for prefix in [[], [0x42], [0x42, 0x5A], [0x42, 0x5A, 0x68]] as [[UInt8]] {
            #expect(bzip2Decode(prefix, capacity: 16) == .failure(.insufficientData))
        }
        #expect(bzip2Decode([0x58], capacity: 16) == .failure(.invalidValue))
    }

    /// Flipped bits and bytes never crash the decoder, and every change to the data is caught (by a CRC, if
    /// nothing else): decoding either throws or gives the original (a flip in the end's padding bits).
    @Test func survivesCorruption() {
        // A tenth of the trials (more of the two-block stream's); all of them in BZip2BulkTests.
        Self.checkSurvivesCorruption(trials: [300, 100, 50, 20])
    }

    static func checkSurvivesCorruption(trials counts: [Int]) {
        var rng = SplitMix64(seed: 2028)
        var decoder = BZip2Decoder()
        let text = samples().first { $0.name == "text" }!.bytes
        let inputs: [(String, [UInt8], Int)] = [
            ("text", Array(text.prefix(5_000)), counts[0]),
            ("runs", Array(bzip2Samples().first { $0.name == "runs" }!.bytes.prefix(20_000)), counts[1]),
            ("skewed", Array(bzip2Samples().first { $0.name == "skewed" }!.bytes.prefix(30_000)), counts[2]),
            ("two blocks", Array(text.prefix(120_000)), counts[3]),
        ]
        for (name, data, trials) in inputs {
            let compressed = bzip2Compress(data, level: name == "two blocks" ? 1 : 9)
            var caught = 0
            for trial in 0..<trials {
                var corrupt = compressed
                let flips = trial % 3 + 1
                for _ in 0..<flips {
                    // Past the 4-byte header, which `rejectsBadHeaders` covers.
                    let index = 4 + Int(rng.next() % UInt64(corrupt.count - 4))
                    if trial % 2 == 0 {
                        corrupt[index] ^= 1 << (rng.next() % 8)
                    } else {
                        corrupt[index] = UInt8(truncatingIfNeeded: rng.next())
                    }
                }
                // Some room past the original size: a corrupt stream may decode longer.
                switch bzip2Decode(corrupt, capacity: data.count + 1_000, decoder: &decoder) {
                case let .success(decoded):
                    #expect(decoded.output == data, "\(name), trial \(trial)")
                case .failure:
                    caught += 1
                }
            }
            #expect(caught > trials * 9 / 10, "\(name): \(caught) of \(trials) caught")
        }
    }

    /// A randomized block, as bzip2 0.9.x wrote for repetitive data: a 1.0 stream with the flag set, whose bytes
    /// (none in runs of 4) are then those at bzip2's table's positions with their low bit flipped. Its CRCs are
    /// set to that output's, and libbzip2 agrees.
    @Test func decodesRandomizedBlocks() {
        var rng = SplitMix64(seed: 31)
        var data: [UInt8] = []
        var flipped: [UInt8] = []
        // Random bytes with no run of 4, before or after the flips.
        func hasRunOfFour(_ bytes: [UInt8]) -> Bool {
            bytes.count >= 4 && (3..<bytes.count).contains { bytes[$0] == bytes[$0 - 1] && bytes[$0] == bytes[$0 - 2] && bytes[$0] == bytes[$0 - 3] }
        }
        repeat {
            data = (0..<3_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
            flipped = data
            // bzip2's first table entries: a flip after 618 bytes, then every entry − 1 more.
            var toGo = 0
            var entry = 0
            for index in flipped.indices {
                if toGo == 0 {
                    toGo = [619, 720, 127, 481, 931, 816][entry]
                    entry += 1
                }
                toGo -= 1
                if toGo == 1 { flipped[index] ^= 1 }
            }
        } while hasRunOfFour(data) || hasRunOfFour(flipped)
        #expect(zip(data, flipped).filter { $0 != $1 }.count == 5)

        var stream = bzip2Compress(data, level: 9)
        let oldCRC = bzip2ReferenceCRC(data)
        let newCRC = bzip2ReferenceCRC(flipped)
        // The randomized flag, the first bit after the block CRC (bytes 10–13).
        stream[14] |= 0x80
        for index in 0..<4 {
            stream[10 + index] = UInt8(truncatingIfNeeded: newCRC >> (24 - 8 * index))
        }
        // The stream's CRC, after the end magic in the last 10 or 11 bytes, at a bit offset.
        func bits(_ start: Int, _ count: Int) -> UInt64 {
            (start..<(start + count)).reduce(0) { $0 << 1 | UInt64(stream[$1 >> 3] >> (7 - $1 & 7) & 1) }
        }
        let end = (0..<8).map { stream.count * 8 - 80 - $0 }.first {
            bits($0, 48) == 0x1772_4538_5090 && bits($0 + 48, 32) == UInt64(oldCRC)
        }
        guard let end else {
            Issue.record("No end marker")
            return
        }
        for bit in 0..<32 {
            let position = end + 48 + bit
            let mask = UInt8(0x80) >> (position & 7)
            if newCRC >> (31 - bit) & 1 != 0 { stream[position >> 3] |= mask } else { stream[position >> 3] &= ~mask }
        }
        #expect(bzip2ReferenceDecompress(stream, capacity: data.count) == flipped)
        #expect(bzip2Decode(stream, capacity: data.count) == .success(BZip2Decoded(output: flipped, consumed: stream.count)))
    }

    @Test func agreesWithLibbzip2OnCorpusLikeData() {
        var decoder = BZip2Decoder()
        let large = samples().first { $0.name == "large" }!.bytes
        let compressed = bzip2Compress(large, level: 9)
        #expect(bzip2ReferenceDecompress(compressed, capacity: large.count) == large)
        #expect(bzip2Decode(compressed, capacity: large.count, decoder: &decoder) == .success(BZip2Decoded(output: large, consumed: compressed.count)))
        // Reusing the decoder after an error.
        #expect(bzip2Decode(Array(compressed.prefix(1_000)), capacity: large.count, decoder: &decoder) == .failure(.insufficientData))
        #expect(bzip2Decode(compressed, capacity: large.count, decoder: &decoder) == .success(BZip2Decoded(output: large, consumed: compressed.count)))
    }
}

/// The large sample at levels 1 and 9, and every corruption trial.
@Suite(.bulk) struct BZip2BulkTests {
    @Test func roundTripsEveryLevel() {
        BZip2DecoderTests.checkRoundTripsEveryLevel(bzip2Samples().filter { $0.name == "large" || $0.bytes.count > 100_000 }) { data in
            data.count > 1_000_000 ? [1, 9] : [3, 4, 5, 6, 7, 8]
        }
    }

    @Test func survivesCorruption() { BZip2DecoderTests.checkSurvivesCorruption(trials: [3_000, 1_000, 500, 100]) }
}
