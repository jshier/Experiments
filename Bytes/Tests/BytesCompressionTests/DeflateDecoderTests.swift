import Bytes
import BytesCompression
import Testing
import zlib

// The DEFLATE decoder against zlib: what zlib encodes must decode to the original, one-shot and in pieces,
// and corrupted streams must be rejected (never trap) exactly when zlib rejects them.

@Suite struct DeflateDecoderTests {
    static let formats: [DeflateFormat] = [.raw, .zlib, .gzip]

    @Test(arguments: [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED])
    func decodesWhatZlibEncodes(strategy: Int32) {
        for (name, bytes) in samples() {
            for level: Int32 in [0, 1, 6, 9] {
                for format in Self.formats {
                    let compressed = zlibCompress(bytes, format: format, level: level, strategy: strategy)
                    #expect(decodeAll(compressed, format: format) == .decoded(bytes), "\(name), level \(level), \(format)")
                }
            }
        }
    }

    /// Input split anywhere and small output buffers: every resumption point.
    @Test(arguments: [(1, 1), (1, 7), (3, 300), (17, 1), (500, 64), (4096, 100_000), (65_536, 4096)])
    func decodesInPieces(chunk: Int, outputChunk: Int) {
        for (name, bytes) in samples() where bytes.count <= (chunk < 16 ? 100_000 : 4 << 20) {
            for format in Self.formats {
                for strategy in [Z_DEFAULT_STRATEGY, Z_FIXED] {
                    let compressed = zlibCompress(bytes, format: format, strategy: strategy)
                    let outcome = decodeStreaming(compressed, format: format, chunk: chunk, outputChunk: outputChunk)
                    #expect(outcome == .decoded(bytes), "\(name), \(format), chunks \(chunk)/\(outputChunk)")
                }
            }
        }
    }

    @Test func storedBlocksInPieces() {
        let bytes = samples()[3].bytes // random: stored at level 0
        for format in Self.formats {
            let compressed = zlibCompress(bytes, format: format, level: 0)
            #expect(decodeStreaming(compressed, format: format, chunk: 1000, outputChunk: 333) == .decoded(bytes))
        }
    }

    @Test func outputExactlyFullAndTooSmall() {
        let bytes = samples()[2].bytes
        for format in Self.formats {
            let compressed = zlibCompress(bytes, format: format)
            #expect(decodeAll(compressed, format: format, capacity: bytes.count) == .decoded(bytes))
            #expect(decodeAll(compressed, format: format, capacity: bytes.count - 1) == .failed)
        }
    }

    @Test func gzipOptionalHeaderFields() {
        // FTEXT | FHCRC | FEXTRA | FNAME | FCOMMENT, then the stream zlib makes for the payload.
        let payload = Array("hello, gzip header fields".utf8)
        let deflated = zlibCompress(payload, format: .raw)
        var header: [UInt8] = [0x1F, 0x8B, 0x08, 0x1F, 0, 0, 0, 0, 0, 3]
        header += [4, 0, 0xAA, 0xBB, 0xCC, 0xDD] // XLEN 4, extra bytes
        header += Array("name.txt".utf8) + [0]
        header += Array("a comment".utf8) + [0]
        let crc = header.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        header += [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF)]
        let payloadCRC = payload.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        var trailer: [UInt8] = []
        for value in [payloadCRC, UInt32(payload.count)] {
            for shift in stride(from: 0, to: 32, by: 8) {
                trailer.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        let stream = header + deflated + trailer
        #expect(zlibDecompress(stream, format: .gzip) == .decoded(payload))
        #expect(decodeAll(stream, format: .gzip) == .decoded(payload))
        for chunk in [1, 2, 5, 13] {
            #expect(decodeStreaming(stream, format: .gzip, chunk: chunk, outputChunk: 3) == .decoded(payload))
        }
        var badHeaderCRC = stream
        badHeaderCRC[header.count - 1] ^= 1
        #expect(decodeAll(badHeaderCRC, format: .gzip) == .failed)
    }

    @Test func checksumsAreVerified() {
        let bytes = samples()[2].bytes
        for format in [DeflateFormat.zlib, .gzip] {
            var compressed = zlibCompress(bytes, format: format)
            compressed[compressed.count - 1] ^= 0x10
            #expect(decodeAll(compressed, format: format) == .failed)
            #expect(decodeStreaming(compressed, format: format, chunk: 4096, outputChunk: 4096) == .failed)
        }
    }

    @Test func dataAfterTheStreamIsNotConsumed() throws {
        let bytes = Array("trailing data".utf8)
        for format in Self.formats {
            let compressed = zlibCompress(bytes, format: format)
            var decoder = DeflateDecoder(format: format)
            var output = [UInt8](repeating: 0, count: 100)
            let input = compressed + [1, 2, 3]
            // The span's closure keeps the error type. Swift 6.4.2 miscompiles a typed-throws closure passed to the
            // array's (which rethrows `any Error`): an error thrown through it arrives as garbage.
            var outputSpan = output.mutableSpan
            let consumed = try outputSpan.withUnsafeMutableBytes { buffer throws(BytesError) in
                var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                return try decoder.decompressAll(input.span.bytes, into: &span)
            }
            #expect(consumed == compressed.count)
        }
    }

    /// Mutated streams: the decoder must accept exactly what zlib accepts, with the same output.
    @Test(arguments: Self.formats)
    func corruptStreamsMatchZlib(format: DeflateFormat) {
        var rng = SplitMix64(state: 42)
        let seeds = samples().filter { $0.bytes.count <= 200_000 }.flatMap { sample in
            [zlibCompress(sample.bytes, format: format), zlibCompress(sample.bytes, format: format, strategy: Z_FIXED),
             zlibCompress(sample.bytes, format: format, level: 0)]
        }.map { Array($0.prefix(2_000)) + [] } // Short streams keep the test fast; truncation is a mutation too.
        var accepted = 0
        var rejected = 0
        for iteration in 0..<10_000 {
            var bytes = seeds.randomElement(using: &rng)!
            guard !bytes.isEmpty else { continue }
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
                case 1: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                default: bytes.removeLast(Int.random(in: 0...min(16, bytes.count - 1), using: &rng))
                }
            }
            let reference = zlibDecompress(bytes, format: format)
            #expect(decodeAll(bytes, format: format) == reference, "\(format) \(bytes.prefix(32))…")
            if iteration % 10 == 0 {
                #expect(decodeStreaming(bytes, format: format, chunk: 37, outputChunk: 1000) == reference)
            }
            if case .decoded = reference { accepted += 1 } else { rejected += 1 }
        }
        #expect(accepted > 0 && rejected > 0)
    }

    @Test func rejectsMalformedStreams() {
        #expect(decodeAll([0x07], format: .raw) == .failed) // Block type 3.
        #expect(decodeAll([0x01, 0x05, 0x00, 0x00, 0x00], format: .raw) == .failed) // Stored: NLEN isn't ~LEN.
        #expect(decodeAll([], format: .raw) == .failed) // No block at all.
        // A fixed block whose first symbol is a match reaching before the start: final bit 1, type 01,
        // length code 257 (0000001), distance code 0 (00000), packed least significant bit first.
        #expect(decodeAll([0x03, 0x02], format: .raw) == .failed)
        #expect(decodeAll([0x03, 0x00], format: .raw) == .decoded([])) // An empty fixed block.
        #expect(decodeAll([0x78, 0x9C], format: .zlib) == .failed) // Header only.
        #expect(decodeAll([0x78, 0x9D, 0x03, 0x00], format: .zlib) == .failed) // Bad header check.
        #expect(decodeAll([0x1F, 0x8C, 0x08, 0, 0, 0, 0, 0, 0, 3, 0x03, 0x00], format: .gzip) == .failed) // Bad magic.
    }
}

extension DeflateDecoderTests {
    /// A dynamic block's header cut after 8 bytes, from a 16-lane parallel stream: the zeros read past the end
    /// decode as code 16 (repeat the previous length) with no previous length. That's a truncated header, so
    /// more input is needed; it threw `invalidValue` (a socket stream's receiver failed whenever a read ended
    /// there). Block headers don't depend on history, so the block alone is a stream from its start.
    @Test func headerCutWhereZerosReadAsARepeatNeedsInput() throws {
        let header: [UInt8] = [0xA4, 0x7D, 0x39, 0xD2, 0x35, 0x3B, 0x6C, 0xDD]
        var decoder = DeflateDecoder(format: .raw)
        var output = [UInt8](repeating: 0, count: 1024)
        let progress: TransformProgress? = output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
            let progress = try? decoder.decompress(header.span.bytes, into: &span)
            _ = span.finalize(for: buffer)
            return progress
        }
        let unwrapped = try #require(progress, "a truncated header threw")
        #expect(unwrapped.status == .needsInput && unwrapped.consumed == 0 && unwrapped.produced == 0)
    }
}
