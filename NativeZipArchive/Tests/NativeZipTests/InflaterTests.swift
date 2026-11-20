import BytesReferenceCodecs
import BytesTestSupport
import BytesTesting
@_spi(Benchmarking) import NativeZip
import Testing
import zlib

// The `Bytes` DEFLATE decoder against zlib: streams zlib compresses (raw DEFLATE, as zip stores it: Bytes'
// `Zlib.compress`) must decode to the original, and corrupted streams must be rejected (never trap) exactly when
// zlib rejects them.

enum Outcome: Equatable {
    case decoded([UInt8])
    case failed
}

func inflate(_ payload: [UInt8], backend: ZipDecoder.Backend) -> Outcome {
    var decoder = ZipDecoder(backend: backend)
    do {
        return try .decoded(DeflateBackends.inflate(payload.span.bytes, using: &decoder))
    } catch {
        return .failed
    }
}

/// Inputs that exercise every block type and match shape (made once: several megabytes take a while in debug).
func samples() -> [(name: String, bytes: [UInt8])] { sampleInputs }

private let sampleInputs: [(name: String, bytes: [UInt8])] = {
    var rng = SplitMix64(seed: 7)
    let words = ["swift", "byte", "span", "inflate", "huffman", "window", " ", "\n", "the", "a"]
    var text: [UInt8] = []
    while text.count < 200_000 {
        text += Array(words.randomElement(using: &rng)!.utf8)
    }
    let random = (0..<100_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
    let runs = (0..<100_000).map { UInt8(($0 / 1000) % 3) } // Long runs: distance-1 matches.
    let periodic = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 % 7) } // Short distances.
    // Several megabytes, so output spans chunks and back-references reach across them.
    var large: [UInt8] = []
    while large.count < 3 << 20 {
        large += text.prefix(Int.random(in: 1_000...50_000, using: &rng)); large += random.prefix(500)
    }
    return [
        ("empty", []), ("one byte", [0x41]), ("text", text), ("random", random), ("runs", runs),
        ("periodic", periodic), ("large", large),
    ]
}()

/// What zlib makes of `bytes` at `level` with `strategy`, decoded by the `Bytes` backend.
func checkDecodesWhatZlibEncodes(_ name: String, _ bytes: [UInt8], level: Int32, strategy: Int32) {
    let compressed = Zlib.compress(bytes, level: level, strategy: strategy)
    #expect(inflate(compressed, backend: .bytes) == .decoded(bytes), "\(name), level \(level), strategy \(strategy)")
}

/// Mutated streams: the `Bytes` decoder must accept exactly what zlib accepts, with the same output. The first
/// `iterations` mutations of one seeded sequence.
func checkCorruptStreamsMatchZlib(iterations: Int) {
    var rng = SplitMix64(seed: 42)
    let seeds = samples().filter { $0.bytes.count <= 200_000 }.flatMap { sample in
        [
            Zlib.compress(sample.bytes), Zlib.compress(sample.bytes, strategy: Zlib.fixedStrategy),
            Zlib.compress(sample.bytes, level: 0),
        ]
    }.map { Array($0.prefix(2_000)) + [] } // Short streams keep the test fast; truncation is a mutation too.
    var accepted = 0
    var rejected = 0
    for _ in 0..<iterations {
        var bytes = seeds.randomElement(using: &rng)!
        guard !bytes.isEmpty else { continue }
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
            case 1: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            default: bytes.removeLast(Int.random(in: 0...min(16, bytes.count - 1), using: &rng))
            }
        }
        let native = inflate(bytes, backend: .bytes)
        let reference = inflate(bytes, backend: .zlib)
        #expect(native == reference, "\(bytes.prefix(32))…")
        if case .decoded = native { accepted += 1 } else { rejected += 1 }
    }
    #expect(accepted > 0 && rejected > 0)
}

@Suite struct InflaterTests {
    /// Every sample but the multi-megabyte one at every level and strategy; that one (back-references across
    /// chunks) at the default level and strategy, with both backends. Its other levels and strategies are in
    /// `InflaterBulkTests`.
    @Test(arguments: [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED])
    func decodesWhatZlibEncodes(strategy: Int32) {
        for (name, bytes) in samples() where name != "large" {
            for level: Int32 in [0, 1, 6, 9] {
                checkDecodesWhatZlibEncodes(name, bytes, level: level, strategy: strategy)
            }
        }
    }

    @Test func decodesWhatZlibEncodesLarge() {
        let large = samples().last!
        checkDecodesWhatZlibEncodes(large.name, large.bytes, level: 6, strategy: Z_DEFAULT_STRATEGY)
        // Both backends agree, chunking included.
        #expect(inflate(Zlib.compress(large.bytes), backend: .zlib) == .decoded(large.bytes))
    }

    /// The first 2,000 of `InflaterBulkTests`' 20,000 mutations.
    @Test func corruptStreamsMatchZlib() {
        checkCorruptStreamsMatchZlib(iterations: 2_000)
    }

    @Test func rejectsMalformedStreams() {
        #expect(inflate([0x07], backend: .bytes) == .failed) // Block type 3.
        #expect(inflate([0x01, 0x05, 0x00, 0x00, 0x00], backend: .bytes) == .failed) // Stored: NLEN isn't ~LEN.
        #expect(inflate([], backend: .bytes) == .failed) // No block at all.
        // A fixed block whose first symbol is a match reaching before the start: final bit 1, type 01,
        // length code 257 (0000001), distance code 0 (00000), packed least significant bit first.
        #expect(inflate([0x03, 0x02], backend: .bytes) == .failed)
        #expect(inflate([0x03, 0x02], backend: .zlib) == .failed)
        #expect(inflate([0x03, 0x00], backend: .bytes) == .decoded([])) // An empty fixed block.
    }
}

@Suite(.bulk) struct InflaterBulkTests {
    /// The multi-megabyte sample at the levels and strategies `InflaterTests` leaves out.
    @Test(arguments: [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED])
    func decodesWhatZlibEncodes(strategy: Int32) {
        let large = samples().last!
        for level: Int32 in [0, 1, 6, 9] where !(level == 6 && strategy == Z_DEFAULT_STRATEGY) {
            checkDecodesWhatZlibEncodes(large.name, large.bytes, level: level, strategy: strategy)
        }
        // The original test checked both backends once per strategy.
        #expect(inflate(Zlib.compress(large.bytes), backend: .zlib) == .decoded(large.bytes))
    }

    /// All 20,000 mutations.
    @Test func corruptStreamsMatchZlib() {
        checkCorruptStreamsMatchZlib(iterations: 20_000)
    }
}
