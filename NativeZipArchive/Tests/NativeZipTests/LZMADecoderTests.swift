import BytesReferenceCodecs
import BytesTestSupport
import BytesTesting
import Compression
import Foundation
@_spi(Testing) import NativeZip
import Testing

// LZMA (zip method 14) decoding against liblzma's encoder, through `ZipDecoder.decodePayload` (whatever decodes
// method 14 there): vectors made by `Fixtures/lzma/make-lzma-vectors.sh` (into TestData/nativezip-lzma, through
// `Tools/test-data fetch`) must decode to the inputs their generators rebuild here; truncated and corrupted payloads
// must throw, never trap, and never decode to the wrong size. A small encoder below covers what liblzma won't encode
// (lc + lp above 4). Errors are checked as the zip reader reports them: `unsupportedMethod` for a header it can't
// read, `decoding` (the decoder's error), `truncated`, or `sizeMismatch` for everything else (`LZMAOutcome.corrupt`).
//
// The output arrives in the decoder's 1 MiB chunks: resuming in steps of other sizes (1 byte to 64 KiB) was tested on
// the decoder's own type, and is now its codec's own tests' business.

/// One vector from `vectors.tsv`: a payload file, and how to rebuild what it decodes to.
struct LZMAVector: CustomTestStringConvertible, Sendable {
    var name: String
    var generator: String
    var size: Int
    var seed: UInt64
    var hasEndMarker: Bool

    var testDescription: String { name }

    static let directory = TestData.directory(set: "nativezip-lzma")

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

    var expected: [UInt8] { Self.expectedByName[name]! }

    /// Every vector's decoded bytes, generated once: several tests decode the same megabytes.
    private static let expectedByName: [String: [UInt8]] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, LZMAInputs.generate($0.generator, size: $0.size, seed: $0.seed)) }
    )
}

/// The generators in `make-lzma-vectors.py`, repeated: the same random numbers (its SplitMix64 is Bytes') make the
/// same bytes.
enum LZMAInputs {
    static let words: [[UInt8]] = [
        "swift", "byte", "span", "lzma", "range", "coder", " ", "\n", "the", "a", "dictionary", "match", "literal",
        "probability", ", ", ".",
    ].map { Array($0.utf8) }

    static func generate(_ generator: String, size: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(seed: seed)
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
        rng.bytes(size)
    }
}

/// Decodes a whole zip LZMA payload with `decoder`, as an entry of `size` bytes whose flag bit 1 is `hasEndMarker`.
func lzmaDecode(_ payload: [UInt8], size: Int, hasEndMarker: Bool, decoder: inout ZipDecoder) throws(ZipError) -> [UInt8] {
    var output: [UInt8] = []
    try decoder.decodePayload(
        payload.span.bytes, method: ZipArchive.Method.lzma, uncompressedSize: UInt64(size), hasEndMarker: hasEndMarker
    ) { chunk in
        #expect(chunk.byteCount <= 1 << 20, "A chunk larger than the decoder's buffer")
        chunk.withUnsafeBytes { output.append(contentsOf: $0) }
    }
    return output
}

func lzmaDecode(_ payload: [UInt8], size: Int, hasEndMarker: Bool) throws(ZipError) -> [UInt8] {
    var decoder = ZipDecoder()
    return try lzmaDecode(payload, size: size, hasEndMarker: hasEndMarker, decoder: &decoder)
}

/// What decoding did: the output, or the zip reader's error.
enum LZMAOutcome: Equatable {
    case decoded([UInt8])
    /// `ZipError.unsupportedMethod`: a zip LZMA header it can't read.
    case unsupported
    /// An invalid or truncated stream (`ZipError.decoding`, or `.truncated` for a cut header), or one that doesn't
    /// decode to the recorded size (`ZipError.sizeMismatch`).
    case corrupt
    /// Any other error (none is expected).
    case other(String)

    init(_ body: () throws(ZipError) -> [UInt8]) {
        do throws(ZipError) {
            self = try .decoded(body())
        } catch {
            switch error {
            case .unsupportedMethod: self = .unsupported
            case .decoding, .truncated, .sizeMismatch: self = .corrupt
            default: self = .other("\(error)")
            }
        }
    }

    var failed: Bool {
        if case .decoded = self { false } else { true }
    }
}

@Suite struct LZMADecoderTests {
    @Test func vectorsArePresent() throws {
        // `TestData.Missing` names the command that makes a missing file.
        _ = try TestData.file(set: "nativezip-lzma", name: "vectors.tsv")
        #expect(LZMAVector.all.count >= 18)
        for vector in LZMAVector.all {
            _ = try TestData.file(set: "nativezip-lzma", name: vector.name + ".lzma")
            #expect(!vector.payload.isEmpty, "\(vector.name)")
        }
    }

    /// Every vector, several of them over 1 MiB (matches and the window across the decoder's chunks).
    @Test(arguments: LZMAVector.all)
    func decodesVector(_ vector: LZMAVector) throws {
        let expected = vector.expected
        #expect(expected.count == vector.size)
        let decoded = try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker)
        #expect(decoded == expected)
    }

    /// One decoder for every entry, in an order where storage shrinks and grows: probabilities and the window
    /// are reused, and nothing from one entry leaks into the next.
    @Test func reusesOneDecoder() throws {
        var decoder = ZipDecoder()
        for vector in LZMAVector.all + LZMAVector.all.reversed() {
            let decoded = try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: vector.hasEndMarker, decoder: &decoder)
            #expect(decoded == vector.expected, "\(vector.name)")
        }
    }

    @Test func emptyEntries() throws {
        for name in ["empty-marker", "empty-nomarker"] {
            let vector = LZMAVector.named(name)
            #expect(try lzmaDecode(vector.payload, size: 0, hasEndMarker: vector.hasEndMarker) == [], "\(name)")
        }
    }

    /// Zip flag bit 1 clear, but an end marker right at the uncompressed size: accepted. Set, but no marker:
    /// rejected.
    @Test func endMarkerFlag() throws {
        for name in ["text-marker", "one-marker", "empty-marker", "random"] {
            let vector = LZMAVector.named(name)
            #expect(try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: false) == vector.expected, "\(name)")
        }
        for name in ["text-nomarker", "one-nomarker", "empty-nomarker", "runs"] {
            let vector = LZMAVector.named(name)
            let outcome = LZMAOutcome { () throws(ZipError) in try lzmaDecode(vector.payload, size: vector.size, hasEndMarker: true) }
            #expect(outcome == .corrupt, "\(name)")
        }
    }

    /// Sizes that don't match the stream: a marker before the size, output past it, or a stream that
    /// continues past it.
    @Test func wrongSizes() {
        for name in ["text-marker", "text-nomarker", "records-lc0-lp4-pb0", "sentences-1m-dict4k"] {
            let vector = LZMAVector.named(name)
            for size in [vector.size - 1, vector.size + 1, vector.size / 2] {
                let outcome = LZMAOutcome { () throws(ZipError) in try lzmaDecode(vector.payload, size: size, hasEndMarker: vector.hasEndMarker) }
                #expect(outcome == .corrupt, "\(name), size \(size)")
            }
        }
    }

    /// Small unencrypted LZMA and xz entries (at most the decoder's 1 MiB chunk) decode in one call straight into the
    /// output buffer, with no window: at their recorded size they decode, at any other (one short, one over, half,
    /// over 1 MiB as recorded for a stream that isn't) they're corrupt.
    @Test func smallEntriesDecodeWhole() throws {
        let text = LZMAVector.named("text-marker").expected
        let xz = AppleCompression.encode(text, COMPRESSION_LZMA)
        var decoder = ZipDecoder()
        func decode(_ payload: [UInt8], method: UInt16, size: Int, hasEndMarker: Bool) -> LZMAOutcome {
            LZMAOutcome { () throws(ZipError) in
                var output: [UInt8] = []
                try decoder.decodePayload(payload.span.bytes, method: method, uncompressedSize: UInt64(size), hasEndMarker: hasEndMarker) { chunk in
                    chunk.withUnsafeBytes { output.append(contentsOf: $0) }
                }
                return output
            }
        }
        let entries: [(name: String, payload: [UInt8], method: UInt16, expected: [UInt8], hasEndMarker: Bool)] = [
            ("LZMA, end marker", LZMAVector.named("text-marker").payload, ZipArchive.Method.lzma, text, true),
            ("LZMA, end marker, flag clear", LZMAVector.named("text-marker").payload, ZipArchive.Method.lzma, text, false),
            ("LZMA, no marker", LZMAVector.named("text-nomarker").payload, ZipArchive.Method.lzma, LZMAVector.named("text-nomarker").expected, false),
            ("LZMA, one byte", LZMAVector.named("one-nomarker").payload, ZipArchive.Method.lzma, LZMAVector.named("one-nomarker").expected, false),
            ("xz", xz, ZipArchive.Method.xz, text, false),
        ]
        // Twice, so the second round reuses each method's state.
        for _ in 0..<2 {
            for entry in entries {
                let size = entry.expected.count
                #expect(decode(entry.payload, method: entry.method, size: size, hasEndMarker: entry.hasEndMarker) == .decoded(entry.expected), "\(entry.name)")
                for wrong in Set([size - 1, size + 1, size / 2, (1 << 20) + 1]) where wrong >= 0 && wrong != size {
                    let outcome = decode(entry.payload, method: entry.method, size: wrong, hasEndMarker: entry.hasEndMarker)
                    #expect(outcome == .corrupt, "\(entry.name), size \(wrong)")
                }
            }
        }
    }

    @Test func rejectsBadHeaders() throws {
        let vector = LZMAVector.named("text-marker")
        let payload = vector.payload
        func outcome(_ payload: [UInt8]) -> LZMAOutcome {
            LZMAOutcome { () throws(ZipError) in try lzmaDecode(payload, size: vector.size, hasEndMarker: true) }
        }
        var badSize = payload
        badSize[2] = 4
        #expect(outcome(badSize) == .unsupported)
        var badProperties = payload
        badProperties[4] = 225 // pb 5
        #expect(outcome(badProperties) == .unsupported)
        var badFirstByte = payload
        badFirstByte[9] = 1
        #expect(outcome(badFirstByte) == .corrupt)
        var impossibleCode = payload
        impossibleCode.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(outcome(impossibleCode) == .corrupt)
        for count in 0..<14 {
            #expect(outcome(Array(payload.prefix(count))) == .corrupt, "\(count) bytes")
        }
        // After a failed entry, the same decoder decodes the next one.
        var decoder = ZipDecoder()
        for bad in [badSize, badFirstByte, Array(payload.prefix(20))] {
            #expect(LZMAOutcome { () throws(ZipError) in try lzmaDecode(bad, size: vector.size, hasEndMarker: true, decoder: &decoder) }.failed)
            #expect(try lzmaDecode(payload, size: vector.size, hasEndMarker: true, decoder: &decoder) == vector.expected)
        }
    }

    /// The cuts every payload gets in the default run: the header (13 bytes) and the range coder's first bytes
    /// after it, the last 16 (the coder's 5-byte flush and the end marker), and every 997th of payloads up to
    /// 20 KB (every 9,973rd of larger ones). `LZMADecoderBulkTests` makes the rest of the full sweep's cuts.
    static func fastCuts(_ count: Int) -> Set<Int> {
        let header = (0...19).filter { $0 < count }
        let end = Array(max(0, count - 16)..<count)
        return Set(header + end + stride(from: 0, to: count, by: count <= 20_000 ? 997 : 9_973))
    }

    /// The full sweep's cuts: the last 64 bytes, and every 997th elsewhere.
    static func allCuts(_ count: Int) -> Set<Int> {
        Set(Array(max(0, count - 64)..<count) + stride(from: 0, to: count, by: 997))
    }

    static let truncatedNames = [
        "text-marker", "text-nomarker", "one-nomarker", "empty-marker", "empty-nomarker", "runs", "records-lc1-lp3-pb1",
        "sentences-1m-dict4k",
    ]

    static func checkTruncated(_ name: String, cuts: (Int) -> Set<Int>) {
        let vector = LZMAVector.named(name)
        let payload = vector.payload
        var decoder = ZipDecoder()
        for cut in cuts(payload.count).sorted() {
            let outcome = LZMAOutcome { () throws(ZipError) in
                try lzmaDecode(Array(payload.prefix(cut)), size: vector.size, hasEndMarker: vector.hasEndMarker, decoder: &decoder)
            }
            #expect(outcome == .corrupt, "\(name) cut to \(cut) of \(payload.count) bytes")
        }
    }

    /// Cuts in the header, near the end, and a sample elsewhere: always `.corrupt`, never a trap or a short
    /// success.
    @Test(arguments: Self.truncatedNames)
    func rejectsTruncatedPayloads(_ name: String) {
        Self.checkTruncated(name, cuts: Self.fastCuts)
    }

    /// Changed bytes: decoding is `.corrupt` or produces output of the right size, never traps. With an end
    /// marker, most changes are caught. 25 changes per vector (`LZMADecoderBulkTests` makes 200).
    @Test func survivesCorruptPayloads() {
        Self.checkCorruptPayloads(perVector: 25)
    }

    static func checkCorruptPayloads(perVector: Int) {
        var rng = SplitMix64(seed: 99)
        var rejected = 0
        var total = 0
        var decoder = ZipDecoder()
        for name in ["text-marker", "text-nomarker", "random", "runs", "records-lc0-lp0-pb0", "sentences-1m-lc1-lp1-pb1"] {
            let vector = LZMAVector.named(name)
            let payload = vector.payload
            for _ in 0..<perVector {
                var corrupt = payload
                for _ in 0..<(1 + rng.next() % 3) {
                    let index = 14 + Int(rng.next() % UInt64(payload.count - 14))
                    corrupt[index] ^= UInt8(truncatingIfNeeded: 1 + rng.next() % 255)
                }
                let outcome = LZMAOutcome { () throws(ZipError) in
                    try lzmaDecode(corrupt, size: vector.size, hasEndMarker: vector.hasEndMarker, decoder: &decoder)
                }
                total += 1
                switch outcome {
                case let .decoded(bytes): #expect(bytes.count == vector.size)
                case .corrupt: rejected += 1
                default: Issue.record("\(name): \(outcome)")
                }
            }
        }
        #expect(rejected > total / 2)
    }

    /// Random bytes after valid headers, with every lc/lp/pb byte: no traps, and `.corrupt` or the right size.
    @Test func survivesRandomStreams() {
        var rng = SplitMix64(seed: 5)
        for properties in 0..<225 {
            var payload: [UInt8] = [9, 20, 5, 0, UInt8(properties), 0x00, 0x10, 0x00, 0x00, 0x00]
            payload += (0..<(64 + Int(rng.next() % 2_000))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            for hasEndMarker in [false, true] {
                // A decoder each: resetting a reused one's probabilities (up to 3 million with lc 8 and lp 4) one by
                // one is slow in debug builds.
                let outcome = LZMAOutcome { () throws(ZipError) in try lzmaDecode(payload, size: 100_000, hasEndMarker: hasEndMarker) }
                switch outcome {
                case let .decoded(bytes): #expect(bytes.count == 100_000)
                case .corrupt: break
                default: Issue.record("properties \(properties): \(outcome)")
                }
            }
        }
    }

    /// Streams liblzma won't make: lc + lp above 4, up to lc 8, lp 4, pb 4.
    @Test(arguments: [(8, 4, 4), (8, 0, 0), (4, 4, 2), (5, 3, 0), (0, 0, 4), (3, 0, 2)])
    func decodesTestEncoderStreams(lc: Int, lp: Int, pb: Int) throws {
        var rng = SplitMix64(seed: UInt64(lc * 25 + lp * 5 + pb))
        let input = LZMAInputs.text(30_000, &rng) + LZMAInputs.random(2_000, &rng)
            + LZMAInputs.generate("records", size: 20_000, seed: 3) + LZMAInputs.text(30_000, &rng)
        for hasEndMarker in [false, true] {
            for dictionarySize in [4_096, 1 << 20] {
                let payload = TestLZMAEncoder.encode(
                    input, lc: lc, lp: lp, pb: pb, dictionarySize: dictionarySize, endMarker: hasEndMarker
                )
                let decoded = try lzmaDecode(payload, size: input.count, hasEndMarker: hasEndMarker)
                #expect(decoded == input, "dictionary \(dictionarySize), end marker \(hasEndMarker)")
            }
        }
    }

    /// Not a test: decoding throughput, in release builds (`swift test -c release --filter measureLZMAThroughput`).
    /// Set `LZMA_PERF_PAYLOAD` and `LZMA_PERF_ORIGINAL` to time a payload of your own too (made from the
    /// original with `make-lzma-vectors.sh --payload ORIGINAL PAYLOAD`).
    @Test(.optimizedOnly) func measureLZMAThroughput() throws {
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
        var decoder = ZipDecoder()
        for (name, payload, size, hasEndMarker) in cases {
            var best = Duration.seconds(100)
            let repeats = max(3, 20_000_000 / max(size, 1))
            for _ in 0..<repeats {
                let start = ContinuousClock.now
                try decoder.decodePayload(
                    payload.span.bytes, method: ZipArchive.Method.lzma, uncompressedSize: UInt64(size), hasEndMarker: hasEndMarker
                ) { _ in }
                best = min(best, ContinuousClock.now - start)
            }
            let seconds = Double(best.components.attoseconds) / 1e18 + Double(best.components.seconds)
            print("LZMA \(name): \(size) bytes in \(best), \(Int(Double(size) / seconds / 1e6)) MB/s")
        }
    }
}

@Suite(.bulk) struct LZMADecoderBulkTests {
    /// The full sweep's cuts that `LZMADecoderTests` doesn't make.
    @Test(arguments: LZMADecoderTests.truncatedNames)
    func rejectsTruncatedPayloads(_ name: String) {
        LZMADecoderTests.checkTruncated(name) { LZMADecoderTests.allCuts($0).subtracting(LZMADecoderTests.fastCuts($0)) }
    }

    /// 200 changes per vector.
    @Test func survivesCorruptPayloads() {
        LZMADecoderTests.checkCorruptPayloads(perVector: 200)
    }
}

/// A small LZMA encoder for tests: greedy matches from a hash of 3-byte sequences, repeat distances when
/// they match as well, short repeats, matched literals, and the end marker. Writes a zip method-14 payload.
/// Its streams are valid but not small; it exists for properties liblzma won't encode.
struct TestLZMAEncoder {
    /// Where each probability lives in the one array of them (the LZMA SDK's `LzmaDec.c` layout, in its order).
    /// Each is an 11-bit probability that the next bit is 0, starting at one half.
    enum Layout {
        static let states = 12
        /// `isMatch[state << 4 + posState]`: a literal (0) or a match (1).
        static let isMatch = 0
        /// `isRep[state]`: a new distance (0) or a repeated one (1).
        static let isRep = 192
        /// `isRepG0[state]`: rep0 (0), or rep1 through rep3 (1).
        static let isRepG0 = isRep + states
        /// `isRepG1[state]`: rep1 (0), or rep2 or rep3 (1).
        static let isRepG1 = isRepG0 + states
        /// `isRepG2[state]`: rep2 (0) or rep3 (1).
        static let isRepG2 = isRepG1 + states
        /// `isRep0Long[state << 4 + posState]`: a one-byte rep0 match (0) or a rep0 match with a length (1).
        static let isRep0Long = isRepG2 + states
        /// Four 6-bit trees of distance slots, by length (2, 3, 4, 5 or more).
        static let distanceSlots = isRep0Long + 192
        /// Reverse trees for the low bits of distances in slots 4 through 13.
        static let specialDistances = distanceSlots + 4 << 6
        /// A 4-bit reverse tree for the low bits of distances in slots 14 and up.
        static let align = specialDistances + 128
        /// The two length coders: `choice`, `choice2`, 16 low and 16 middle 3-bit trees (by posState), and an
        /// 8-bit high tree.
        static let lengthCoderSize = 2 + 16 << 3 + 16 << 3 + 256
        static let matchLengths = align + 16
        static let repeatLengths = matchLengths + lengthCoderSize
        /// `0x300` probabilities per literal context: a plain 8-bit tree, then two more used with a match byte.
        static let literals = repeatLengths + lengthCoderSize
    }

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
            probabilities: [UInt16](repeating: 1024, count: Layout.literals + 0x300 << (lc + lp))
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
                encoder.bit(Layout.isMatch + state << 4 + positionState, 1)
                encoder.bit(Layout.isRep + state, 1)
                if bestRep.index == 0 {
                    encoder.bit(Layout.isRepG0 + state, 0)
                    encoder.bit(Layout.isRep0Long + state << 4 + positionState, 1)
                } else {
                    encoder.bit(Layout.isRepG0 + state, 1)
                    if bestRep.index == 1 {
                        encoder.bit(Layout.isRepG1 + state, 0)
                    } else {
                        encoder.bit(Layout.isRepG1 + state, 1)
                        encoder.bit(Layout.isRepG2 + state, bestRep.index - 2)
                    }
                    let distance = reps.remove(at: bestRep.index)
                    reps.insert(distance, at: 0)
                }
                encoder.length(Layout.repeatLengths, length - 2, positionState)
                state = state < 7 ? 8 : 11
                position += length
            } else if best.length >= 3 {
                encoder.bit(Layout.isMatch + state << 4 + positionState, 1)
                encoder.bit(Layout.isRep + state, 0)
                encoder.length(Layout.matchLengths, best.length - 2, positionState)
                encoder.distance(best.distance, length: best.length - 2)
                reps = [best.distance] + reps.prefix(3)
                state = state < 7 ? 7 : 10
                position += best.length
            } else if position > reps[0], input[position] == input[position - reps[0] - 1], position % 5 == 0 {
                // A short repeat, now and then.
                encoder.bit(Layout.isMatch + state << 4 + positionState, 1)
                encoder.bit(Layout.isRep + state, 1)
                encoder.bit(Layout.isRepG0 + state, 0)
                encoder.bit(Layout.isRep0Long + state << 4 + positionState, 0)
                state = state < 7 ? 9 : 11
                position += 1
            } else {
                encoder.bit(Layout.isMatch + state << 4 + positionState, 0)
                let previous = position > 0 ? Int(input[position - 1]) : 0
                let base = Layout.literals + 0x300 * ((position & (1 << lp - 1)) << lc + previous >> (8 - lc))
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
            encoder.bit(Layout.isMatch + state << 4 + positionState, 1)
            encoder.bit(Layout.isRep + state, 0)
            encoder.length(Layout.matchLengths, 0, positionState)
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
        tree(Layout.distanceSlots + min(length, 3) << 6, bitCount: 6, slot)
        guard slot >= 4 else { return }
        let bitCount = slot >> 1 - 1
        let base = (2 | slot & 1) << bitCount
        let rest = distance - base
        if slot < 14 {
            reverseTree(Layout.specialDistances + base - slot, bitCount: bitCount, rest)
        } else {
            for bit in (4..<bitCount).reversed() {
                range >>= 1
                if rest >> bit & 1 == 1 { low += UInt64(range) }
                while range < 1 << 24 {
                    range <<= 8
                    shiftLow()
                }
            }
            reverseTree(Layout.align, bitCount: 4, rest & 15)
        }
    }
}
