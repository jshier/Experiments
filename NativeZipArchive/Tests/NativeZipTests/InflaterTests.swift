import BytesReferenceCodecs
import BytesTesting
import BytesTestSupport
@_spi(Benchmarking) import NativeZip
import Testing
import zlib

// NativeZip's DEFLATE decoding against zlib, a reference on the test side: streams zlib compresses (raw DEFLATE, as
// zip stores it: BytesReferenceCodecs' `Zlib.compress`) must decode to the original, and corrupted streams must be
// rejected (never trap) exactly when zlib's `inflate` rejects them.

enum Outcome: Equatable {
    case decoded([UInt8])
    case failed
}

/// NativeZip's decoding of a raw DEFLATE stream.
func inflate(_ payload: [UInt8]) -> Outcome {
    var decoder = ZipDecoder()
    do throws(ZipError) {
        return try .decoded(DeflateBackends.inflate(payload.span.bytes, using: &decoder))
    } catch {
        return .failed
    }
}

/// zlib's decoding of a raw DEFLATE stream, as zip readers use it: decoded until the stream's end, ignoring any bytes
/// after it (BytesReferenceCodecs' `Zlib.decompress` rejects those); invalid or truncated streams fail.
func zlibInflate(_ payload: [UInt8]) -> Outcome {
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return .failed }
    defer { inflateEnd(&stream) }
    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    var input = payload
    return input.withUnsafeMutableBufferPointer { input in
        stream.next_in = input.baseAddress
        stream.avail_in = uInt(input.count)
        while true {
            let (status, produced) = chunk.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                let status = zlib.inflate(&stream, Z_NO_FLUSH)
                return (status, buffer.count - Int(stream.avail_out))
            }
            output += chunk[..<produced]
            switch status {
            case Z_STREAM_END: return .decoded(output)
            case Z_OK: continue
            default: return .failed // Errors, and Z_BUF_ERROR: no progress possible (truncated).
            }
        }
    }
}

/// Inputs that exercise every block type and match shape, "large" last (made once: several megabytes take a while in
/// debug).
func samples() -> [(name: String, bytes: [UInt8])] { SampleBytes.deflateSamples }

/// What zlib makes of `bytes` at `level` with `strategy`, decoded by NativeZip.
func checkDecodesWhatZlibEncodes(_ name: String, _ bytes: [UInt8], level: Int32, strategy: Int32) {
    let compressed = Zlib.compress(bytes, level: level, strategy: strategy)
    #expect(inflate(compressed) == .decoded(bytes), "\(name), level \(level), strategy \(strategy)")
}

/// Mutated streams: NativeZip must accept exactly what zlib accepts, with the same output. The first
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
        let native = inflate(bytes)
        let reference = zlibInflate(bytes)
        #expect(native == reference, "\(bytes.prefix(32))…")
        if case .decoded = native { accepted += 1 } else { rejected += 1 }
    }
    #expect(accepted > 0 && rejected > 0)
}

@Suite struct InflaterTests {
    /// Every sample but the multi-megabyte one at every level and strategy; that one (back-references across
    /// chunks) at the default level and strategy. Its other levels and strategies are in
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
    }

    /// The first 2,000 of `InflaterBulkTests`' 20,000 mutations.
    @Test func corruptStreamsMatchZlib() {
        checkCorruptStreamsMatchZlib(iterations: 2_000)
    }

    @Test func rejectsMalformedStreams() {
        #expect(inflate([0x07]) == .failed) // Block type 3.
        #expect(inflate([0x01, 0x05, 0x00, 0x00, 0x00]) == .failed) // Stored: NLEN isn't ~LEN.
        #expect(inflate([]) == .failed) // No block at all.
        // A fixed block whose first symbol is a match reaching before the start: final bit 1, type 01,
        // length code 257 (0000001), distance code 0 (00000), packed least significant bit first.
        #expect(inflate([0x03, 0x02]) == .failed)
        #expect(zlibInflate([0x03, 0x02]) == .failed)
        #expect(inflate([0x03, 0x00]) == .decoded([])) // An empty fixed block.
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
    }

    /// All 20,000 mutations.
    @Test func corruptStreamsMatchZlib() {
        checkCorruptStreamsMatchZlib(iterations: 20_000)
    }
}
