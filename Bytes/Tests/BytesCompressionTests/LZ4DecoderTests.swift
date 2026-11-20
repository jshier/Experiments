import Bytes
import BytesCompression
import BytesTestSupport
import Compression
import Testing

// LZ4Decoder against Apple's Compression (`COMPRESSION_LZ4_RAW` and `COMPRESSION_LZ4`), and hand-made blocks
// for the edges: every short offset, lengths around the copy widths, and malformed sequences.

/// Decodes a raw block into exactly `capacity` bytes, `decodedSize` of them expected.
func lz4DecodeRaw(_ block: [UInt8], decodedSize: Int, capacity: Int? = nil) -> Result<[UInt8], BytesError> {
    let (result, output) = withExactBuffers(block, capacity: capacity ?? decodedSize) { input, output throws(BytesError) in
        try LZ4Decoder().decompressRaw(input, decodedSize: decodedSize, into: &output)
    }
    return result.map { output }
}

/// Decodes a framed stream into exactly `capacity` bytes, checking that the stream was consumed whole.
func lz4DecodeFramed(_ stream: [UInt8], capacity: Int) -> Result<[UInt8], BytesError> {
    let (result, output) = withExactBuffers(stream, capacity: capacity) { input, output throws(BytesError) in
        try LZ4Decoder().decompressFramed(input, into: &output)
    }
    // A stream not consumed whole reports `trailingData`.
    return result.flatMap { consumed in consumed == stream.count ? .success(output) : .failure(.trailingData) }
}

/// An LZ4 sequence: a token, `literals`, then (unless `offset` is nil) a match of `matchLength` at `offset`.
func lz4Sequence(_ literals: [UInt8], offset: Int?, matchLength: Int = 4) -> [UInt8] {
    func extra(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value - 15
        while rest >= 255 {
            bytes.append(255)
            rest -= 255
        }
        return bytes + [UInt8(rest)]
    }
    let literalCode = min(literals.count, 15)
    let matchCode = offset == nil ? 0 : min(matchLength - 4, 15)
    var bytes = [UInt8(literalCode << 4 | matchCode)]
    if literals.count >= 15 { bytes += extra(literals.count) }
    bytes += literals
    if let offset {
        bytes += [UInt8(offset & 0xFF), UInt8(offset >> 8)]
        if matchLength - 4 >= 15 { bytes += extra(matchLength - 4) }
    }
    return bytes
}

/// What decoding the sequence `lz4Sequence(literals, offset:, matchLength:)` appends after `history`.
func lz4Expected(history: [UInt8], _ literals: [UInt8], offset: Int, matchLength: Int) -> [UInt8] {
    var bytes = history + literals
    for _ in 0..<matchLength { bytes.append(bytes[bytes.count - offset]) }
    return bytes
}

@Suite struct LZ4DecoderTests {
    @Test func rawRoundTrips() {
        for (name, sample) in LZSamples.all {
            let block = appleEncode(sample, COMPRESSION_LZ4_RAW)
            if sample.isEmpty { continue } // Compression encodes nothing.
            #expect(lz4DecodeRaw(block, decodedSize: sample.count) == .success(sample), "\(name)")
            // With room to spare: the fast path runs to the end.
            #expect(lz4DecodeRaw(block, decodedSize: sample.count, capacity: sample.count + 64) == .success(sample), "\(name)")
        }
    }

    @Test func framedRoundTrips() {
        for (name, sample) in LZSamples.all {
            let stream = appleEncode(sample, COMPRESSION_LZ4)
            if sample.isEmpty { continue }
            #expect(lz4DecodeFramed(stream, capacity: sample.count) == .success(sample), "\(name)")
        }
    }

    @Test func largeRoundTrips() {
        for (name, sample) in LZSamples.large {
            let block = appleEncode(sample, COMPRESSION_LZ4_RAW)
            #expect(lz4DecodeRaw(block, decodedSize: sample.count) == .success(sample), "raw \(name)")
            let stream = appleEncode(sample, COMPRESSION_LZ4)
            #expect(lz4DecodeFramed(stream, capacity: sample.count) == .success(sample), "framed \(name)")
        }
    }

    @Test func emptyInputs() {
        #expect(lz4DecodeRaw([], decodedSize: 0) == .success([]))
        #expect(lz4DecodeRaw([], decodedSize: 1) == .failure(.insufficientData))
        #expect(lz4DecodeFramed(Array("bv4$".utf8), capacity: 0) == .success([]))
        #expect(lz4DecodeFramed([], capacity: 10) == .failure(.insufficientData))
    }

    /// Every offset 1 through 20, with match lengths around the copy widths, alone in an exact buffer (the
    /// careful path) and with room after (the fast path).
    @Test func shortOffsets() {
        for offset in 1...20 {
            let history = LZSamples.random(offset, seed: UInt64(offset))
            for matchLength in [4, 5, 7, 8, 9, 15, 16, 17, 18, 19, 31, 32, 33, 48, 270, 271, 300] {
                let tail: [UInt8] = Array("12345".utf8)
                let block = lz4Sequence(history, offset: offset, matchLength: matchLength) + lz4Sequence(tail, offset: nil)
                let expected = lz4Expected(history: [], history, offset: offset, matchLength: matchLength) + tail
                #expect(lz4DecodeRaw(block, decodedSize: expected.count) == .success(expected), "offset \(offset), \(matchLength)")
                let padded = lz4DecodeRaw(block, decodedSize: expected.count, capacity: expected.count + 100)
                #expect(padded == .success(expected), "offset \(offset), \(matchLength), padded")
            }
        }
    }

    /// Long literal runs and matches: their 255-continued lengths.
    @Test func longLengths() {
        for literalCount in [14, 15, 16, 269, 270, 271, 525, 1000] {
            let literals = LZSamples.random(literalCount, seed: UInt64(literalCount))
            let block = lz4Sequence(literals, offset: 3, matchLength: 1000) + lz4Sequence(literals, offset: nil)
            let expected = lz4Expected(history: [], literals, offset: 3, matchLength: 1000) + literals
            #expect(lz4DecodeRaw(block, decodedSize: expected.count) == .success(expected))
        }
    }

    @Test func blockMayEndWithAMatch() {
        let block = lz4Sequence(Array("abc".utf8), offset: 3, matchLength: 6)
        #expect(lz4DecodeRaw(block, decodedSize: 9) == .success(Array("abcabcabc".utf8)))
    }

    @Test func invalidOffsets() {
        // Offset 0, and one reaching before the output's start.
        #expect(lz4DecodeRaw(lz4Sequence([1, 2], offset: 0) + lz4Sequence([1], offset: nil), decodedSize: 7) == .failure(.invalidValue))
        #expect(lz4DecodeRaw(lz4Sequence([1, 2], offset: 3) + lz4Sequence([1], offset: nil), decodedSize: 7) == .failure(.invalidValue))
        #expect(lz4DecodeRaw(lz4Sequence([1, 2], offset: 2) + lz4Sequence([1], offset: nil), decodedSize: 7) == .success([1, 2, 1, 2, 1, 2, 1]))
    }

    @Test func sizeMismatches() {
        let sample = LZSamples.text(5000, seed: 9)
        let block = appleEncode(sample, COMPRESSION_LZ4_RAW)
        #expect(lz4DecodeRaw(block, decodedSize: sample.count - 1) == .failure(.insufficientCapacity))
        #expect(lz4DecodeRaw(block, decodedSize: sample.count + 1) == .failure(.insufficientData))
        #expect(lz4DecodeRaw(block, decodedSize: sample.count, capacity: sample.count - 1) == .failure(.insufficientCapacity))
        #expect(lz4DecodeRaw(block, decodedSize: -1, capacity: 0) == .failure(.invalidValue))
        let stream = appleEncode(sample, COMPRESSION_LZ4)
        #expect(lz4DecodeFramed(stream, capacity: sample.count - 1) == .failure(.insufficientCapacity))
        #expect(lz4DecodeFramed(stream, capacity: sample.count + 100).map { Array($0) } == .success(sample))
    }

    @Test func framedStopsAtTheEndMarker() {
        let sample = LZSamples.text(3000, seed: 5)
        let stream = appleEncode(sample, COMPRESSION_LZ4)
        let (result, output) = withExactBuffers(stream + [1, 2, 3], capacity: sample.count) { input, output throws(BytesError) in
            try LZ4Decoder().decompressFramed(input, into: &output)
        }
        #expect(result == .success(stream.count))
        #expect(output == sample)
    }

    /// Framed blocks whose sizes disagree with their data, and unknown magics.
    @Test func corruptFrames() {
        let sample = LZSamples.text(3000, seed: 6)
        let stream = appleEncode(sample, COMPRESSION_LZ4)
        #expect(Array(stream.prefix(4)) == Array("bv41".utf8))
        var larger = stream
        larger[4] &+= 1 // The decoded size, one more.
        #expect(lz4DecodeFramed(larger, capacity: sample.count + 1) == .failure(.invalidValue))
        var smaller = stream
        smaller[4] &-= 1
        #expect(lz4DecodeFramed(smaller, capacity: sample.count) == .failure(.invalidValue))
        var magic = stream
        magic[3] = UInt8(ascii: "2")
        #expect(lz4DecodeFramed(magic, capacity: sample.count) == .failure(.invalidValue))
    }

    @Test func truncationThrows() {
        for sample in [LZSamples.text(700, seed: 1), LZSamples.mixed(900, seed: 2), LZSamples.random(40, seed: 3)] {
            let block = appleEncode(sample, COMPRESSION_LZ4_RAW)
            let stream = appleEncode(sample, COMPRESSION_LZ4)
            for length in 0..<block.count {
                #expect(throws: BytesError.self) { _ = try lz4DecodeRaw(Array(block.prefix(length)), decodedSize: sample.count).get() }
            }
            for length in 0..<stream.count {
                #expect(throws: BytesError.self) { _ = try lz4DecodeFramed(Array(stream.prefix(length)), capacity: sample.count).get() }
            }
        }
    }

    /// Random corruption: decoding may succeed or throw, but stays within the buffers (checked by the address
    /// sanitizer, with exact allocations).
    @Test func corruptionNeverCrashes() {
        var generator = SplitMix64(seed: 42)
        for sample in [LZSamples.text(5000, seed: 1), LZSamples.mixed(20_000, seed: 2), LZSamples.periodic(3000, period: 5, seed: 3)] {
            let block = appleEncode(sample, COMPRESSION_LZ4_RAW)
            let stream = appleEncode(sample, COMPRESSION_LZ4)
            for _ in 0..<300 {
                var corrupt = block
                for _ in 0..<Int(generator.next() % 4 + 1) {
                    corrupt[Int(generator.next() % UInt64(corrupt.count))] = UInt8(truncatingIfNeeded: generator.next())
                }
                _ = lz4DecodeRaw(corrupt, decodedSize: sample.count)
                var corruptStream = stream
                corruptStream[Int(generator.next() % UInt64(stream.count))] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                _ = lz4DecodeFramed(corruptStream, capacity: sample.count)
            }
        }
    }
}
