import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Compression
import Foundation
import Testing

// LZRAVEN decoding against Apple's Compression, which writes the streams (COMPRESSION_LZRAVEN, macOS 27).

/// Compression's LZRAVEN encoding of `data`.
func lzravenCompress(_ data: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: data.count + data.count / 8 + 4096)
    let size = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            compression_encode_buffer(
                out.baseAddress!, out.count, input.baseAddress ?? UnsafePointer(bitPattern: 1)!, input.count, nil, COMPRESSION_LZRAVEN
            )
        }
    }
    precondition(size > 0)
    return Array(output[..<size])
}

/// Compression's decoding of an LZRAVEN buffer into at most `capacity` bytes (0 when it fails).
func lzravenReferenceDecompress(_ data: [UInt8], capacity: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    let size = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            compression_decode_buffer(out.baseAddress!, out.count, input.baseAddress!, input.count, nil, COMPRESSION_LZRAVEN)
        }
    }
    return Array(output[..<size])
}

/// Decodes with ``LZRAVENDecoder/decompressAll(_:decodedSize:into:)``, into exactly `count` bytes.
func lzravenDecode(_ data: [UInt8], count: Int, decoder: inout LZRAVENDecoder) -> Result<[UInt8], BytesError> {
    var output = [UInt8](repeating: 0, count: count)
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            #expect(try decoder.decompressAll(data.span.bytes, decodedSize: count, into: &span) == data.count)
        }
    } catch {
        return .failure(error)
    }
    return .success(output)
}

/// Decodes with ``LZRAVENDecoder/decompressAll(_:decodedSize:into:)``, no size stated, into `capacity` bytes,
/// returning what it made.
func lzravenDecodeOpen(_ data: [UInt8], capacity: Int, decoder: inout LZRAVENDecoder) -> Result<[UInt8], BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            let consumed = try decoder.decompressAll(data.span.bytes, into: &span)
            precondition(consumed == data.count)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success(Array(output[..<produced]))
}

enum LZRAVENSamples {
    /// The corpus directory (`Tools/corpus fetch`); tests that need it skip files that are missing.
    static var corpusRoot: URL { Corpus.root }

    static func corpus(_ path: String, prefix: Int = .max) -> [UInt8]? {
        FileManager.default.contents(atPath: corpusRoot.appending(path: path).path).map { Array($0.prefix(prefix)) }
    }

    /// Text built from a few words, random bytes, runs, and short periods.
    static let generated: [(name: String, bytes: [UInt8])] = samples()

    /// This Mac's `zsh`: ARM64 (and x86-64) code, which Compression marks for the ARM64 branch filter.
    static var machineCode: [UInt8]? {
        FileManager.default.contents(atPath: "/bin/zsh").map { Array($0) }
    }

    /// x86 code, which Compression marks for the x86 filter: a DLL inside Silesia's `ooffice`.
    static var x86Code: [UInt8]? { corpus("silesia/ooffice", prefix: 3 << 20) }
}

@Suite struct LZRAVENDecoderTests {
    static func checkRoundTrip(_ data: [UInt8], _ label: String, decoder: inout LZRAVENDecoder) {
        let compressed = lzravenCompress(data)
        let decoded = lzravenDecode(compressed, count: data.count, decoder: &decoder)
        #expect(decoded == .success(data), "\(label): \(data.count) bytes")
    }

    @Test func emptyAndTiny() {
        var decoder = LZRAVENDecoder()
        for count in 0...70 {
            Self.checkRoundTrip((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) }, "ramp", decoder: &decoder)
            Self.checkRoundTrip([UInt8](repeating: 0x61, count: count), "run", decoder: &decoder)
        }
    }

    /// Powers of two to 512 KiB, and the block boundaries; 1 to 4 MiB in LZRAVENBulkTests.
    @Test func sizesAcrossPowersOfTwo() {
        Self.checkSizesAcrossPowersOfTwo(5...19)
        var decoder = LZRAVENDecoder()
        let text = LZRAVENSamples.generated.first { $0.name == "large" }!.bytes
        // Blocks are 512 KiB: last blocks under 64 bytes are stored.
        for count in [524_288 - 1, 524_288, 524_288 + 1, 524_288 + 63, 524_288 + 64, 2 * 524_288 + 32] {
            Self.checkRoundTrip(Array(text.prefix(count)), "text around blocks", decoder: &decoder)
        }
    }

    static func checkSizesAcrossPowersOfTwo(_ shifts: ClosedRange<Int>) {
        var decoder = LZRAVENDecoder()
        let text = LZRAVENSamples.generated.first { $0.name == "large" }!.bytes
        for shift in shifts {
            for delta in [-33, -1, 0, 1, 31, 63, 64, 65] {
                let count = (1 << shift) + delta
                guard count >= 0, count <= text.count else { continue }
                checkRoundTrip(Array(text.prefix(count)), "text", decoder: &decoder)
            }
        }
    }

    @Test func generatedKinds() {
        var decoder = LZRAVENDecoder()
        for (name, bytes) in LZRAVENSamples.generated {
            Self.checkRoundTrip(bytes, name, decoder: &decoder)
        }
        var rng = SplitMix64(seed: 99)
        // Incompressible data is stored, in whole blocks.
        let random = (0..<1_300_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        Self.checkRoundTrip(random, "random", decoder: &decoder)
        // Coded blocks between stored ones: matches reach back across them.
        var mixed: [UInt8] = []
        let text = LZRAVENSamples.generated.first { $0.name == "text" }!.bytes
        mixed += random.prefix(600_000)
        mixed += text
        mixed += random.prefix(600_000)
        mixed += text
        Self.checkRoundTrip(mixed, "mixed", decoder: &decoder)
        // Long matches and every short distance.
        for distance in 1...40 {
            var periodic = (0..<distance).map { _ in UInt8.random(in: 0...255, using: &rng) }
            while periodic.count < 70_000 { periodic.append(periodic[periodic.count - distance]) }
            Self.checkRoundTrip(periodic, "period \(distance)", decoder: &decoder)
        }
    }

    /// ARM64 code (this Mac's `zsh`); x86 code (from the corpus) in LZRAVENBulkTests.
    @Test func branchFilters() throws {
        var decoder = LZRAVENDecoder()
        let arm = try #require(LZRAVENSamples.machineCode)
        Self.checkRoundTrip(arm, "/bin/zsh", decoder: &decoder)
    }

    static let corpusFiles = [
        "silesia/dickens", "silesia/mozilla", "silesia/mr", "silesia/nci", "silesia/ooffice", "silesia/osdb",
        "silesia/reymont", "silesia/samba", "silesia/sao", "silesia/webster", "silesia/x-ray", "silesia/xml",
        "web/Main.js", "web/Main.css", "web/CodeMirror.js", "web/Three.js", "web/Main.html",
    ]

    @Test func appleArchiveBlock() throws {
        // `aa archive -a lzraven` writes `pbzm` blocks whose header's top bits aren't 0.
        let text = LZRAVENSamples.generated.first { $0.name == "text" }!.bytes
        var compressed = lzravenCompress(text)
        compressed[7] = 0x44
        #expect(lzravenReferenceDecompress(compressed, capacity: text.count) == text)
        var decoder = LZRAVENDecoder()
        #expect(lzravenDecode(compressed, count: text.count, decoder: &decoder) == .success(text))
    }

    @Test func openEndedAndSizes() {
        var decoder = LZRAVENDecoder()
        let text = Array(LZRAVENSamples.generated.first { $0.name == "large" }!.bytes.prefix(1_200_000))
        let compressed = lzravenCompress(text)
        #expect(lzravenDecodeOpen(compressed, capacity: text.count + 100, decoder: &decoder) == .success(text))
        #expect(lzravenDecodeOpen(compressed, capacity: text.count, decoder: &decoder) == .success(text))
        #expect(lzravenDecodeOpen(compressed, capacity: text.count - 1, decoder: &decoder) == .failure(.insufficientCapacity))
        #expect(lzravenDecodeOpen(compressed, capacity: 0, decoder: &decoder) == .failure(.insufficientCapacity))
        // The exact-size form: any other size is a mismatch.
        #expect(lzravenDecode(compressed, count: text.count - 1, decoder: &decoder) == .failure(.mismatch))
        #expect(lzravenDecode(compressed, count: text.count + 1, decoder: &decoder) == .failure(.mismatch))
        #expect(lzravenDecode(compressed, count: 0, decoder: &decoder) == .failure(.mismatch))
        // Trailing bytes, a bad magic, and the reserved header bits.
        #expect(lzravenDecode(compressed + [0], count: text.count, decoder: &decoder) == .failure(.invalidValue))
        var bad = compressed
        bad[0] ^= 1
        #expect(lzravenDecode(bad, count: text.count, decoder: &decoder) == .failure(.invalidValue))
        bad = compressed
        bad[4] = 1
        #expect(lzravenDecode(bad, count: text.count, decoder: &decoder) == .failure(.invalidValue))
        // And the decoder still works.
        #expect(lzravenDecode(compressed, count: text.count, decoder: &decoder) == .success(text))
    }

    @Test func truncation() {
        var decoder = LZRAVENDecoder()
        for (name, bytes) in LZRAVENSamples.generated where bytes.count <= 300_000 {
            let compressed = lzravenCompress(bytes)
            // Every cut of small streams, a spread of cuts of larger ones.
            let step = max(1, compressed.count / 400)
            for cut in stride(from: 0, to: compressed.count, by: step) {
                let result = lzravenDecode(Array(compressed.prefix(cut)), count: bytes.count, decoder: &decoder)
                guard case .failure = result else {
                    Issue.record("\(name): a cut at \(cut) of \(compressed.count) decoded")
                    continue
                }
            }
        }
    }


    /// 40 trials on the text sample and 5 on 1.1 MB (several blocks) here; 300 on each in LZRAVENBulkTests.
    @Test func corruption() {
        Self.checkCorruption(trials: [40, 5])
    }

    static func checkCorruption(trials perSource: [Int]) {
        var decoder = LZRAVENDecoder()
        var rng = SplitMix64(seed: 5)
        let text = LZRAVENSamples.generated.first { $0.name == "text" }!.bytes
        let sources: [[UInt8]] = [text, Array(LZRAVENSamples.generated.first { $0.name == "large" }!.bytes.prefix(1_100_000))]
        var detected = 0
        var trials = 0
        for (source, count) in zip(sources, perSource) {
            let compressed = lzravenCompress(source)
            for _ in 0..<count {
                var damaged = compressed
                let index = Int.random(in: 8..<damaged.count, using: &rng)
                damaged[index] ^= UInt8.random(in: 1...255, using: &rng)
                trials += 1
                // Must throw or decode to the right size; never crash.
                switch lzravenDecode(damaged, count: source.count, decoder: &decoder) {
                case .failure: detected += 1
                case let .success(output): if output == source { Issue.record("damage at \(index) changed nothing") }
                }
                // Lengths wrong both ways.
                _ = lzravenDecodeOpen(damaged, capacity: source.count + 4096, decoder: &decoder)
            }
        }
        // The format has no checksum (containers have their own): damage is caught when a coded block doesn't
        // read exactly its words, makes another size, or reaches before the output. That's most of it (509 of
        // 600 in the bulk run, as Compression, which `matchesCompressionOnDamage` compares).
        #expect(detected > trials * 3 / 4, "\(detected) of \(trials) detected")
    }

    /// 50 damaged streams here, 200 in LZRAVENBulkTests.
    @Test func matchesCompressionOnDamage() {
        Self.checkMatchesCompressionOnDamage(trials: 50)
    }

    static func checkMatchesCompressionOnDamage(trials: Int) {
        // Where Compression decodes damaged data, the result is the same.
        var decoder = LZRAVENDecoder()
        var rng = SplitMix64(seed: 11)
        let text = LZRAVENSamples.generated.first { $0.name == "text" }!.bytes
        let compressed = lzravenCompress(text)
        for _ in 0..<trials {
            var damaged = compressed
            // Not the end marker, which Compression accepts with any flags and this decoder only as 0.
            let index = Int.random(in: 8..<damaged.count - 4, using: &rng)
            damaged[index] ^= UInt8.random(in: 1...255, using: &rng)
            let reference = lzravenReferenceDecompress(damaged, capacity: text.count)
            let ours = lzravenDecode(damaged, count: text.count, decoder: &decoder)
            if reference.count == text.count {
                #expect(ours == .success(reference), "damage at \(index)")
            } else {
                #expect(throws: (any Error).self, "damage at \(index)") { _ = try ours.get() }
            }
        }
    }
}

/// Sizes to 4 MiB, x86 code, the corpus (if present), and the full damage trials.
@Suite(.bulk) struct LZRAVENBulkTests {
    @Test func sizesAcrossPowersOfTwo() { LZRAVENDecoderTests.checkSizesAcrossPowersOfTwo(20...22) }

    @Test func x86BranchFilter() {
        guard let x86 = LZRAVENSamples.x86Code else { return }
        var decoder = LZRAVENDecoder()
        LZRAVENDecoderTests.checkRoundTrip(x86, "ooffice", decoder: &decoder)
    }

    @Test(arguments: LZRAVENDecoderTests.corpusFiles)
    func corpus(_ path: String) throws {
        guard let data = LZRAVENSamples.corpus(path) else { return }
        var decoder = LZRAVENDecoder()
        // As Apple Encrypted Archive segments: at most 16 MiB each.
        let segment = 16 << 20
        for start in stride(from: 0, to: max(data.count, 1), by: segment) {
            LZRAVENDecoderTests.checkRoundTrip(Array(data[start..<min(data.count, start + segment)]), path, decoder: &decoder)
        }
    }

    @Test func corruption() { LZRAVENDecoderTests.checkCorruption(trials: [300, 300]) }

    @Test func matchesCompressionOnDamage() { LZRAVENDecoderTests.checkMatchesCompressionOnDamage(trials: 200) }
}
