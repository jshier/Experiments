import Foundation
@testable import NativeZip
import Testing

// The LZMA (zip method 14) decoder against liblzma's encoder: vectors made by
// `Fixtures/lzma/make-lzma-vectors.sh` (into TestData/nativezip-lzma, through `Tools/test-data fetch`) must decode to the inputs their generators rebuild here, in output
// steps of any size; truncated and corrupted payloads must throw, never trap. A small encoder below covers
// what liblzma won't encode (lc + lp above 4).

/// One vector from `vectors.tsv`: a payload file, and how to rebuild what it decodes to.
struct LZMAVector: CustomTestStringConvertible, Sendable {
    var name: String
    var generator: String
    var size: Int
    var seed: UInt64
    var hasEndMarker: Bool

    var testDescription: String { name }

    static let directory = testDataDirectory("nativezip-lzma")

    static let all: [LZMAVector] = {
        let manifest = (try? String(contentsOf: directory.appending(path: "vectors.tsv"), encoding: .utf8)) ?? ""
        return manifest.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t").map(String.init)
            return LZMAVector(
                name: fields[0], generator: fields[1], size: Int(fields[2])!, seed: UInt64(fields[3])!,
                hasEndMarker: fields[8] == "1"
            )
        }
    }()

    static func named(_ name: String) -> LZMAVector { all.first { $0.name == name }! }

    var payload: [UInt8] { [UInt8]((try? Data(contentsOf: Self.directory.appending(path: name + ".lzma"))) ?? Data()) }

    var expected: [UInt8] { LZMAInputs.generate(generator, size: size, seed: seed) }
}

/// The generators in `make-lzma-vectors.py`, repeated: the same random numbers make the same bytes.
enum LZMAInputs {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let words: [[UInt8]] = [
        "swift", "byte", "span", "lzma", "range", "coder", " ", "\n", "the", "a", "dictionary", "match", "literal",
        "probability", ", ", ".",
    ].map { Array($0.utf8) }

    static func generate(_ generator: String, size: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(state: seed)
        switch generator {
        case "text": return text(size, &rng)
        case "random": return random(size, &rng)
        case "runs": return (0..<size).map { UInt8(($0 / 1000) % 3) }
        case "records":
            var out: [UInt8] = []
            var index: UInt64 = 0
            while out.count < size {
                let value = UInt32(truncatingIfNeeded: index &* 7 &+ (rng.next() & 3))
                out += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                        UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
                index += 1
            }
            return Array(out.prefix(size))
        case "sentences":
            var table: [[UInt8]] = []
            for _ in 0..<32 {
                var sentence: [UInt8] = []
                for _ in 0..<(5 + rng.next() % 11) {
                    sentence += words[Int(rng.next() % UInt64(words.count))]
                }
                table.append(sentence)
            }
            var out: [UInt8] = []
            while out.count < size {
                if rng.next() % 512 == 0 {
                    out += random(Int(1 + rng.next() % 64), &rng)
                } else {
                    out += table[Int(rng.next() % UInt64(table.count))]
                }
            }
            return Array(out.prefix(size))
        default: fatalError("unknown generator \(generator)")
        }
    }

    static func text(_ size: Int, _ rng: inout SplitMix64) -> [UInt8] {
        var out: [UInt8] = []
        while out.count < size {
            out += words[Int(rng.next() % UInt64(words.count))]
        }
        return Array(out.prefix(size))
    }

    static func random(_ size: Int, _ rng: inout SplitMix64) -> [UInt8] {
        (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
    }
}

/// Decodes a whole payload in steps of `bufferSize`, checking that each step but the last fills its buffer.
func lzmaDecode(
    _ payload: [UInt8], size: Int, hasEndMarker: Bool, bufferSize: Int = 65_536,
    decoder: inout LZMADecoder
) throws(LZMAError) -> [UInt8] {
    try decoder.reset(payload: payload.span.bytes, uncompressedSize: UInt64(size), hasEndMarker: hasEndMarker)
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while true {
        var span = buffer.mutableSpan
        var bytes = span.mutableBytes
        let (produced, finished) = try decoder.decode(payload.span.bytes, into: &bytes)
        output += buffer.prefix(produced)
        if finished { return output }
        #expect(produced == bufferSize, "A step that didn't finish didn't fill its buffer")
        if produced == 0 { return output } // Never loop forever on a broken decoder.
    }
}

func lzmaDecode(
    _ payload: [UInt8], size: Int, hasEndMarker: Bool, bufferSize: Int = 65_536
) throws(LZMAError) -> [UInt8] {
    var decoder = LZMADecoder()
    return try lzmaDecode(payload, size: size, hasEndMarker: hasEndMarker, bufferSize: bufferSize, decoder: &decoder)
}

/// What decoding did: the output, or the error.
enum LZMAOutcome: Equatable {
    case decoded([UInt8])
    case failed(LZMAError)

    init(_ body: () throws(LZMAError) -> [UInt8]) {
        do {
            self = try .decoded(body())
        } catch {
            self = .failed(error)
        }
    }
}

@Suite struct LZMADecoderTests {
    @Test func vectorsArePresent() {
        #expect(LZMAVector.all.count >= 18, "\(MissingTestData(set: "nativezip-lzma", name: "vectors.tsv"))")
        for vector in LZMAVector.all {
            #expect(!vector.payload.isEmpty, "\(MissingTestData(set: "nativezip-lzma", name: vector.name + ".lzma"))")
        }
    }

    @Test(arguments: LZMAVector.all)
    func decodesVector(_ vector: LZMAVector) throws {
        let expected = vector.expected
        #expect(expected.count == vector.size)
        let decoded = try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker)
        #expect(decoded == expected)
    }

    /// Steps of every size: matches split across steps, and the window's growth and wrap at any point.
    @Test(arguments: [1_000, 1_024, 4_096, 4_099, 65_537])
    func resumesInSmallSteps(bufferSize: Int) throws {
        for name in ["sentences-3m-dict64k", "sentences-1m-dict4k", "text-nomarker", "runs"] {
            let vector = LZMAVector.named(name)
            let decoded = try lzmaDecode(
                vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker, bufferSize: bufferSize
            )
            #expect(decoded == vector.expected, "\(name), \(bufferSize)-byte steps")
        }
    }

    @Test func resumesOneByteAtATime() throws {
        for name in ["text-marker", "runs", "records-lc2-lp2-pb3"] {
            let vector = LZMAVector.named(name)
            let decoded = try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker, bufferSize: 1)
            #expect(decoded == vector.expected, "\(name)")
        }
    }

    /// One decoder for every entry, in an order where storage shrinks and grows: probabilities and the window
    /// are reused, and nothing from one entry leaks into the next.
    @Test func reusesOneDecoder() throws {
        var decoder = LZMADecoder()
        for vector in LZMAVector.all + LZMAVector.all.reversed() {
            let decoded = try lzmaDecode(
                vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker, bufferSize: 10_000,
                decoder: &decoder
            )
            #expect(decoded == vector.expected, "\(vector.name)")
        }
    }

    @Test func emptyEntries() throws {
        for name in ["empty-marker", "empty-nomarker"] {
            let vector = LZMAVector.named(name)
            var decoder = LZMADecoder()
            try decoder.reset(payload: vector.payload.span.bytes, uncompressedSize: 0, hasEndMarker: vector.hasEndMarker)
            // An empty buffer is enough to finish.
            var buffer: [UInt8] = []
            var span = buffer.mutableSpan
            var bytes = span.mutableBytes
            let result = try decoder.decode(vector.payload.span.bytes, into: &bytes)
            #expect(result.produced == 0 && result.finished)
            // And it stays finished.
            #expect(try decoder.decode(vector.payload.span.bytes, into: &bytes).finished)
        }
    }

    /// Zip flag bit 1 clear, but an end marker right at the uncompressed size: accepted. Set, but no marker:
    /// rejected.
    @Test func endMarkerFlag() throws {
        for name in ["text-marker", "one-marker", "empty-marker", "random"] {
            let vector = LZMAVector.named(name)
            #expect(try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: false) == vector.expected)
        }
        for name in ["text-nomarker", "one-nomarker", "empty-nomarker", "runs"] {
            let vector = LZMAVector.named(name)
            #expect(throws: LZMAError.self) { _ = try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: true) }
        }
    }

    /// Sizes that don't match the stream: a marker before the size, output past it, or a stream that
    /// continues past it.
    @Test func wrongSizes() {
        for name in ["text-marker", "text-nomarker", "records-lc0-lp4-pb0", "sentences-1m-dict4k"] {
            let vector = LZMAVector.named(name)
            for size in [vector.size - 1, vector.size + 1, vector.size / 2] {
                let outcome = LZMAOutcome { () throws(LZMAError) in
                    try lzmaDecode(vector.payload, size: size, hasEndMarker: vector.hasEndMarker)
                }
                #expect(outcome == .failed(.corruptData) || outcome == .failed(.truncated), "\(name), size \(size)")
            }
        }
    }

    @Test func rejectsBadHeaders() {
        let payload = LZMAVector.named("text-marker").payload
        func outcome(_ payload: [UInt8]) -> LZMAOutcome {
            LZMAOutcome { () throws(LZMAError) in try lzmaDecode(payload, size: 200_000, hasEndMarker: true) }
        }
        var badSize = payload
        badSize[2] = 4
        #expect(outcome(badSize) == .failed(.unsupportedHeader))
        var badProperties = payload
        badProperties[4] = 225 // pb 5
        #expect(outcome(badProperties) == .failed(.unsupportedHeader))
        var badFirstByte = payload
        badFirstByte[9] = 1
        #expect(outcome(badFirstByte) == .failed(.corruptData))
        var impossibleCode = payload
        impossibleCode.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(outcome(impossibleCode) == .failed(.corruptData))
        for count in 0..<14 {
            #expect(outcome(Array(payload.prefix(count))) == .failed(.truncated), "\(count) bytes")
        }
        // After a failed reset, decoding throws the same error rather than reporting an empty entry.
        var decoder = LZMADecoder()
        #expect(throws: LZMAError.unsupportedHeader) {
            try decoder.reset(payload: badSize.span.bytes, uncompressedSize: 200_000, hasEndMarker: true)
        }
        var buffer = [UInt8](repeating: 0, count: 16)
        var span = buffer.mutableSpan
        var bytes = span.mutableBytes
        #expect(throws: LZMAError.unsupportedHeader) { _ = try decoder.decode(badSize.span.bytes, into: &bytes) }
    }

    /// Every cut, near the end, and a sample elsewhere: always `truncated`, never a trap or a short success.
    @Test func rejectsTruncatedPayloads() {
        for name in ["text-marker", "text-nomarker", "one-nomarker", "empty-marker", "empty-nomarker", "runs",
                     "records-lc1-lp3-pb1", "sentences-1m-dict4k"] {
            let vector = LZMAVector.named(name)
            let payload = vector.payload
            let cuts = Set(Array(max(0, payload.count - 64)..<payload.count) + stride(from: 0, to: payload.count, by: 997))
            for cut in cuts.sorted() {
                let outcome = LZMAOutcome { () throws(LZMAError) in
                    try lzmaDecode(Array(payload.prefix(cut)), size: vector.size, hasEndMarker: vector.hasEndMarker, bufferSize: 4_096)
                }
                #expect(outcome == .failed(.truncated), "\(name) cut to \(cut) of \(payload.count) bytes")
            }
        }
    }

    /// Changed bytes: decoding throws or produces some output of the right size, never traps. With an end
    /// marker, most changes are caught.
    @Test func survivesCorruptPayloads() {
        var rng = LZMAInputs.SplitMix64(state: 99)
        var rejected = 0
        var total = 0
        for name in ["text-marker", "text-nomarker", "random", "runs", "records-lc0-lp0-pb0", "sentences-1m-lc1-lp1-pb1"] {
            let vector = LZMAVector.named(name)
            let payload = vector.payload
            for _ in 0..<200 {
                var corrupt = payload
                for _ in 0..<(1 + rng.next() % 3) {
                    let index = 14 + Int(rng.next() % UInt64(payload.count - 14))
                    corrupt[index] ^= UInt8(truncatingIfNeeded: 1 + rng.next() % 255)
                }
                let outcome = LZMAOutcome { () throws(LZMAError) in
                    try lzmaDecode(corrupt, size: vector.size, hasEndMarker: vector.hasEndMarker, bufferSize: 3_000)
                }
                total += 1
                switch outcome {
                case let .decoded(bytes): #expect(bytes.count == vector.size)
                case .failed: rejected += 1
                }
            }
        }
        #expect(rejected > total / 2)
    }

    /// Random bytes after valid headers, with every lc/lp/pb byte: no traps.
    @Test func survivesRandomStreams() {
        var rng = LZMAInputs.SplitMix64(state: 5)
        for properties in 0..<225 {
            var payload: [UInt8] = [9, 20, 5, 0, UInt8(properties), 0x00, 0x10, 0x00, 0x00, 0x00]
            payload += (0..<(64 + Int(rng.next() % 2_000))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            for hasEndMarker in [false, true] {
                let outcome = LZMAOutcome { () throws(LZMAError) in
                    try lzmaDecode(payload, size: 100_000, hasEndMarker: hasEndMarker, bufferSize: 7_000)
                }
                if case let .decoded(bytes) = outcome { #expect(bytes.count == 100_000) }
            }
        }
    }

    /// Streams liblzma won't make: lc + lp above 4, up to lc 8, lp 4, pb 4.
    @Test(arguments: [(8, 4, 4), (8, 0, 0), (4, 4, 2), (5, 3, 0), (0, 0, 4), (3, 0, 2)])
    func decodesTestEncoderStreams(lc: Int, lp: Int, pb: Int) throws {
        var rng = LZMAInputs.SplitMix64(state: UInt64(lc * 25 + lp * 5 + pb))
        let input = LZMAInputs.text(30_000, &rng) + LZMAInputs.random(2_000, &rng)
            + LZMAInputs.generate("records", size: 20_000, seed: 3) + LZMAInputs.text(30_000, &rng)
        for hasEndMarker in [false, true] {
            for dictionarySize in [4_096, 1 << 20] {
                let payload = TestLZMAEncoder.encode(
                    input, lc: lc, lp: lp, pb: pb, dictionarySize: dictionarySize, endMarker: hasEndMarker
                )
                for bufferSize in [999, 65_536] {
                    let decoded = try lzmaDecode(payload, size: input.count, hasEndMarker: hasEndMarker, bufferSize: bufferSize)
                    #expect(decoded == input, "dictionary \(dictionarySize), \(bufferSize)-byte steps")
                }
            }
        }
    }

    /// Not a test: decoding throughput, in release builds (`swift test -c release --filter measureLZMAThroughput`).
    /// Set `LZMA_PERF_PAYLOAD` and `LZMA_PERF_ORIGINAL` to time a payload of your own too (made from the
    /// original with `make-lzma-vectors.sh --payload ORIGINAL PAYLOAD`).
    @Test(.disabled(if: lzmaIsDebugBuild)) func measureLZMAThroughput() throws {
        var cases = ["text-marker", "sentences-3m-dict64k", "records-lc2-lp2-pb3", "random"].map { name in
            let vector = LZMAVector.named(name)
            return (name, vector.payload, vector.size, vector.hasEndMarker)
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["LZMA_PERF_PAYLOAD"], let original = environment["LZMA_PERF_ORIGINAL"] {
            let payload = [UInt8](try Data(contentsOf: URL(filePath: path)))
            let expected = [UInt8](try Data(contentsOf: URL(filePath: original)))
            #expect(try lzmaDecode(payload, size: expected.count, hasEndMarker: false) == expected)
            cases.append((path, payload, expected.count, false))
        }
        var decoder = LZMADecoder()
        for (name, payload, size, hasEndMarker) in cases {
            var best = Duration.seconds(100)
            let repeats = max(3, 20_000_000 / max(size, 1))
            for _ in 0..<repeats {
                let start = ContinuousClock.now
                _ = try lzmaDecode(payload, size: size, hasEndMarker: hasEndMarker, bufferSize: 1 << 20, decoder: &decoder)
                best = min(best, ContinuousClock.now - start)
            }
            let seconds = Double(best.components.attoseconds) / 1e18 + Double(best.components.seconds)
            print("LZMA \(name): \(size) bytes in \(best), \(Int(Double(size) / seconds / 1e6)) MB/s")
        }
    }
}

let lzmaIsDebugBuild: Bool = {
    #if DEBUG
    true
    #else
    false
    #endif
}()

/// A small LZMA encoder for tests: greedy matches from a hash of 3-byte sequences, repeat distances when
/// they match as well, short repeats, matched literals, and the end marker. Writes a zip method-14 payload.
/// Its streams are valid but not small; it exists for properties liblzma won't encode.
struct TestLZMAEncoder {
    var probabilities: [UInt16]
    var low: UInt64 = 0
    var range: UInt32 = 0xFFFF_FFFF
    var cache: UInt8 = 0
    var cacheSize = 1
    var bytes: [UInt8] = []

    static func encode(
        _ input: [UInt8], lc: Int, lp: Int, pb: Int, dictionarySize: Int, endMarker: Bool
    ) -> [UInt8] {
        var encoder = TestLZMAEncoder(
            probabilities: [UInt16](repeating: 1024, count: LZMADecoder.literals + 0x300 << (lc + lp))
        )
        var state = 0
        var reps = [0, 0, 0, 0]
        var last: [Int: Int] = [:]
        var position = 0
        let positionMask = 1 << pb - 1

        func matchLength(_ distance: Int) -> Int {
            guard distance < position, distance < dictionarySize else { return 0 }
            var length = 0
            while length < 273, position + length < input.count, input[position + length] == input[position - distance - 1 + length] {
                length += 1
            }
            return length
        }

        while position < input.count {
            let positionState = position & positionMask
            // Candidates: the last occurrence of these 3 bytes, and the repeat distances.
            var best = (length: 0, distance: 0)
            if position + 3 <= input.count {
                let key = Int(input[position]) | Int(input[position + 1]) << 8 | Int(input[position + 2]) << 16
                if let previous = last[key] {
                    let distance = position - previous - 1
                    let length = matchLength(distance)
                    if length >= 3 { best = (length, distance) }
                }
                last[key] = position
            }
            var bestRep = (length: 0, index: 0)
            for index in 0..<4 {
                let length = matchLength(reps[index])
                if length > bestRep.length { bestRep = (length, index) }
            }

            if position > 0 && bestRep.length >= 2 && bestRep.length + 1 >= best.length {
                let length = bestRep.length
                encoder.bit(LZMADecoder.isMatch + state << 4 + positionState, 1)
                encoder.bit(LZMADecoder.isRep + state, 1)
                if bestRep.index == 0 {
                    encoder.bit(LZMADecoder.isRepG0 + state, 0)
                    encoder.bit(LZMADecoder.isRep0Long + state << 4 + positionState, 1)
                } else {
                    encoder.bit(LZMADecoder.isRepG0 + state, 1)
                    if bestRep.index == 1 {
                        encoder.bit(LZMADecoder.isRepG1 + state, 0)
                    } else {
                        encoder.bit(LZMADecoder.isRepG1 + state, 1)
                        encoder.bit(LZMADecoder.isRepG2 + state, bestRep.index - 2)
                    }
                    let distance = reps.remove(at: bestRep.index)
                    reps.insert(distance, at: 0)
                }
                encoder.length(LZMADecoder.repeatLengths, length - 2, positionState)
                state = state < 7 ? 8 : 11
                position += length
            } else if best.length >= 3 {
                encoder.bit(LZMADecoder.isMatch + state << 4 + positionState, 1)
                encoder.bit(LZMADecoder.isRep + state, 0)
                encoder.length(LZMADecoder.matchLengths, best.length - 2, positionState)
                encoder.distance(best.distance, length: best.length - 2)
                reps = [best.distance] + reps.prefix(3)
                state = state < 7 ? 7 : 10
                position += best.length
            } else if position > reps[0], input[position] == input[position - reps[0] - 1], position % 5 == 0 {
                // A short repeat, now and then.
                encoder.bit(LZMADecoder.isMatch + state << 4 + positionState, 1)
                encoder.bit(LZMADecoder.isRep + state, 1)
                encoder.bit(LZMADecoder.isRepG0 + state, 0)
                encoder.bit(LZMADecoder.isRep0Long + state << 4 + positionState, 0)
                state = state < 7 ? 9 : 11
                position += 1
            } else {
                encoder.bit(LZMADecoder.isMatch + state << 4 + positionState, 0)
                let previous = position > 0 ? Int(input[position - 1]) : 0
                let base = LZMADecoder.literals + 0x300 * ((position & (1 << lp - 1)) << lc + previous >> (8 - lc))
                let byte = Int(input[position])
                var symbol = 1
                var bit = 7
                if state >= 7 {
                    let matchByte = Int(input[position - reps[0] - 1])
                    while bit >= 0 {
                        let value = byte >> bit & 1
                        let matchBit = matchByte >> bit & 1
                        encoder.bit(base + (1 + matchBit) << 8 + symbol, value)
                        symbol = symbol << 1 | value
                        bit -= 1
                        if matchBit != value { break }
                    }
                }
                while bit >= 0 {
                    let value = byte >> bit & 1
                    encoder.bit(base + symbol, value)
                    symbol = symbol << 1 | value
                    bit -= 1
                }
                state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6
                position += 1
            }
        }
        if endMarker {
            let positionState = position & positionMask
            encoder.bit(LZMADecoder.isMatch + state << 4 + positionState, 1)
            encoder.bit(LZMADecoder.isRep + state, 0)
            encoder.length(LZMADecoder.matchLengths, 0, positionState)
            encoder.distance(0xFFFF_FFFF, length: 0)
        }
        for _ in 0..<5 {
            encoder.shiftLow()
        }
        let properties = UInt8((pb * 5 + lp) * 9 + lc)
        let size = UInt32(dictionarySize)
        return [9, 20, 5, 0, properties, UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size >> 8),
                UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 24)] + encoder.bytes
    }

    mutating func shiftLow() {
        if low < 0xFF00_0000 || low > 0xFFFF_FFFF {
            let carry = UInt8(truncatingIfNeeded: low >> 32)
            var byte = cache
            repeat {
                bytes.append(byte &+ carry)
                byte = 0xFF
                cacheSize -= 1
            } while cacheSize != 0
            cache = UInt8(truncatingIfNeeded: low >> 24)
        }
        cacheSize += 1
        low = (low & 0x00FF_FFFF) << 8
    }

    mutating func bit(_ index: Int, _ value: Int) {
        let probability = UInt32(probabilities[index])
        let bound = (range >> 11) * probability
        if value == 0 {
            range = bound
            probabilities[index] = UInt16(probability + (2048 - probability) >> 5)
        } else {
            low += UInt64(bound)
            range -= bound
            probabilities[index] = UInt16(probability - probability >> 5)
        }
        while range < 1 << 24 {
            range <<= 8
            shiftLow()
        }
    }

    mutating func tree(_ base: Int, bitCount: Int, _ value: Int) {
        var node = 1
        for bit in (0..<bitCount).reversed() {
            let value = value >> bit & 1
            self.bit(base + node, value)
            node = node << 1 | value
        }
    }

    mutating func reverseTree(_ base: Int, bitCount: Int, _ value: Int) {
        var node = 1
        for bit in 0..<bitCount {
            let value = value >> bit & 1
            self.bit(base + node, value)
            node = node << 1 | value
        }
    }

    mutating func length(_ base: Int, _ length: Int, _ positionState: Int) {
        if length < 8 {
            bit(base, 0)
            tree(base + 2 + positionState << 3, bitCount: 3, length)
        } else if length < 16 {
            bit(base, 1)
            bit(base + 1, 0)
            tree(base + 2 + 16 << 3 + positionState << 3, bitCount: 3, length - 8)
        } else {
            bit(base, 1)
            bit(base + 1, 1)
            tree(base + 2 + 32 << 3, bitCount: 8, length - 16)
        }
    }

    mutating func distance(_ distance: Int, length: Int) {
        let slot: Int
        if distance < 4 {
            slot = distance
        } else {
            let top = Int.bitWidth - 1 - distance.leadingZeroBitCount
            slot = top << 1 | distance >> (top - 1) & 1
        }
        tree(LZMADecoder.distanceSlots + min(length, 3) << 6, bitCount: 6, slot)
        guard slot >= 4 else { return }
        let bitCount = slot >> 1 - 1
        let base = (2 | slot & 1) << bitCount
        let rest = distance - base
        if slot < 14 {
            reverseTree(LZMADecoder.specialDistances + base - slot, bitCount: bitCount, rest)
        } else {
            for bit in (4..<bitCount).reversed() {
                range >>= 1
                if rest >> bit & 1 == 1 { low += UInt64(range) }
                while range < 1 << 24 {
                    range <<= 8
                    shiftLow()
                }
            }
            reverseTree(LZMADecoder.align, bitCount: 4, rest & 15)
        }
    }
}
