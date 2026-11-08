@_spi(Benchmarking) import NativeZip
import Testing
import zlib

// The `Bytes` DEFLATE decoder against zlib: streams zlib compresses must decode to the original, and
// corrupted streams must be rejected (never trap) exactly when zlib rejects them.

/// Raw DEFLATE (no zlib header), as zip stores it.
func deflate(_ data: [UInt8], level: Int32 = Z_DEFAULT_COMPRESSION, strategy: Int32 = Z_DEFAULT_STRATEGY) -> [UInt8] {
    var stream = z_stream()
    precondition(deflateInit2_(&stream, level, Z_DEFLATED, -MAX_WBITS, 8, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 16)
    var input = data
    let status = input.withUnsafeMutableBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            stream.next_out = output.baseAddress
            stream.avail_out = uInt(output.count)
            return deflate(&stream, Z_FINISH)
        }
    }
    precondition(status == Z_STREAM_END)
    return Array(output[..<Int(stream.total_out)])
}

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

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Inputs that exercise every block type and match shape.
func samples() -> [(name: String, bytes: [UInt8])] {
    var rng = SplitMix64(state: 7)
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
}

@Suite struct InflaterTests {
    @Test(arguments: [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED])
    func decodesWhatZlibEncodes(strategy: Int32) {
        for (name, bytes) in samples() {
            for level: Int32 in [0, 1, 6, 9] {
                let compressed = deflate(bytes, level: level, strategy: strategy)
                #expect(inflate(compressed, backend: .bytes) == .decoded(bytes), "\(name), level \(level), strategy \(strategy)")
            }
        }
        // Both backends agree, chunking included.
        let large = samples().last!.bytes
        #expect(inflate(deflate(large), backend: .zlib) == .decoded(large))
    }

    /// Mutated streams: the `Bytes` decoder must accept exactly what zlib accepts, with the same output.
    @Test func corruptStreamsMatchZlib() {
        var rng = SplitMix64(state: 42)
        let seeds = samples().filter { $0.bytes.count <= 200_000 }.flatMap { sample in
            [deflate(sample.bytes), deflate(sample.bytes, strategy: Z_FIXED), deflate(sample.bytes, level: 0)]
        }.map { Array($0.prefix(2_000)) + [] } // Short streams keep the test fast; truncation is a mutation too.
        var accepted = 0
        var rejected = 0
        for _ in 0..<20_000 {
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
