import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Compression
import Foundation
import Testing

/// Compression's LZBITMAP encoding of `data` into a destination of `capacity` bytes, or nil where it fails.
func appleLZBitmapEncode(_ data: [UInt8], capacity: Int) -> [UInt8]? {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    let count = data.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { output in
            compression_encode_buffer(
                output.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                (input.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_LZBITMAP
            )
        }
    }
    return count == 0 ? nil : Array(output[..<count])
}

/// Bytes' encoding of `data` between exactly sized buffers of `capacity` bytes.
func lzbitmapEncode(_ data: [UInt8], capacity: Int, encoder: inout LZBitmapEncoder) -> Result<[UInt8], BytesError> {
    let (result, output) = withExactBuffers(data, capacity: capacity) { input, output throws(BytesError) in
        try encoder.compressAll(input, into: &output)
    }
    return result.map { output }
}

@Suite("LZBITMAP encoder")
struct LZBitmapEncoderTests {
    static let sizes = [0, 1, 7, 8, 9, 63, 64, 100, 144, 145, 146, 159, 160, 161, 272, 273, 1000, 4095, 4096, 4097,
                        32767, 32768, 32769, 32775, 32912, 32913, 40000, 65535, 65536, 65537, 98_304, 100_003]

    /// Every kind of the decoder tests' content and LZSamples' mixes.
    static func content(_ kind: Int, size: Int) -> [UInt8] {
        kind < 5 ? LZBitmapDecoderTests.content(kind, size: size) : LZSamples.mixed(size, seed: UInt64(size))
    }

    @Test("Compression's bytes, across sizes and kinds of data", arguments: 0..<6)
    func matchesCompression(kind: Int) throws {
        var encoder = LZBitmapEncoder()
        for size in Self.sizes {
            let data = Self.content(kind, size: size)
            let capacity = LZBitmapEncoder.maximumCompressedSize(forByteCount: size)
            let expected = appleLZBitmapEncode(data, capacity: capacity)
            #expect(expected != nil)
            #expect(try lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get() == expected, "kind \(kind), size \(size)")
        }
    }

    @Test("Periods: repeats from every distance, past 65,535 (the table's positions wrap), and runs")
    func periods() throws {
        var encoder = LZBitmapEncoder()
        for distance in [1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 255, 256, 257, 4095, 65535, 65536, 65537, 70000, 131_072] {
            let pattern = LZSamples.random(distance, seed: UInt64(distance))
            var data: [UInt8] = []
            while data.count < max(4 * distance, 50_000) {
                data += pattern
            }
            // Sparse changes, so groups mix literals and copies.
            for index in stride(from: 13, to: data.count, by: 997) {
                data[index] ^= 0x5A
            }
            let capacity = LZBitmapEncoder.maximumCompressedSize(forByteCount: data.count)
            #expect(try lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get() == appleLZBitmapEncode(data, capacity: capacity), "distance \(distance)")
        }
    }

    /// The sweep every 1,477 bytes of room here, every 211 in LZBitmapEncoderBulkTests.
    @Test("64 KiB chunks at Compression's capacity: the same bytes, or the same failure")
    func capacities() {
        Self.checkCapacities(sweepStep: 1477)
    }

    static func checkCapacities(sweepStep: Int) {
        var encoder = LZBitmapEncoder()
        // Inputs whose streams land near 64 KiB: random bytes in compressible text, in varying proportions.
        for share in [0, 50, 90, 95, 97, 98, 99, 100] {
            var rng = SplitMix64(seed: UInt64(share))
            let text = LZBitmapDecoderTests.content(0, size: 65536)
            let data = (0..<65536).map { Int(rng.next() % 100) < share ? UInt8(truncatingIfNeeded: rng.next()) : text[$0] }
            let size = appleLZBitmapEncode(data, capacity: 1 << 20)!.count
            for capacity in [0, 34, 35, 36, 65536, size - 32, size + 29, size + 30, size + 31, size + 32] where capacity >= 0 {
                let expected = appleLZBitmapEncode(data, capacity: capacity)
                let actual = lzbitmapEncode(data, capacity: capacity, encoder: &encoder)
                switch actual {
                case let .success(bytes): #expect(bytes == expected, "share \(share), capacity \(capacity)")
                case let .failure(error):
                    #expect(error == .insufficientCapacity)
                    #expect(expected == nil, "share \(share), capacity \(capacity): Compression fits")
                }
            }
        }
        // A sweep of capacities over a compressible input: every capacity fails or succeeds as Compression does.
        let data = Self.content(4, size: 70000)
        for capacity in stride(from: 0, to: 72000, by: sweepStep) {
            let expected = appleLZBitmapEncode(data, capacity: capacity)
            let actual = try? lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get()
            #expect(actual == expected, "capacity \(capacity)")
        }
    }

    @Test("Round trips through Bytes' and Compression's decoders", arguments: 0..<6)
    func roundTrips(kind: Int) throws {
        var encoder = LZBitmapEncoder()
        var decoder = LZBitmapDecoder()
        for size in Self.sizes {
            let data = Self.content(kind, size: size)
            let stream = try lzbitmapEncode(data, capacity: LZBitmapEncoder.maximumCompressedSize(forByteCount: size), encoder: &encoder).get()
            #expect(appleLZBitmapDecode(stream, capacity: size + 64) == data)
            #expect(try lzbitmapDecode(stream, capacity: size, expectedSize: size, decoder: &decoder).get().output == data)
        }
    }

    /// 400 KB here (positions past 65,535, so the table's wrap); 6 MB in LZBitmapEncoderBulkTests.
    @Test("Hundreds of kilobytes, reusing the encoder")
    func large() throws {
        try Self.checkLarge(samples()[2].bytes + Self.content(4, size: 200_000))
    }

    static func checkLarge(_ data: [UInt8]) throws {
        var encoder = LZBitmapEncoder()
        let capacity = LZBitmapEncoder.maximumCompressedSize(forByteCount: data.count)
        let expected = appleLZBitmapEncode(data, capacity: capacity)
        #expect(try lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get() == expected)
        #expect(try lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get() == expected)
    }

    @Test("Appends after bytes already in the output; nothing on failure")
    func appends() throws {
        let data = Self.content(0, size: 5000)
        var encoder = LZBitmapEncoder()
        let expected = appleLZBitmapEncode(data, capacity: 10_000)!
        var output = [UInt8](repeating: 0xEE, count: 10_100)
        let appended = output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 100)
            let result = Result { () throws(BytesError) in try encoder.compressAll(data.span.bytes, into: &span) }
            return (result, span.finalize(for: buffer))
        }
        #expect(throws: Never.self) { _ = try appended.0.get() }
        #expect(appended.1 == 100 + expected.count)
        #expect(Array(output[100..<appended.1]) == expected)

        // Too small: nothing appended.
        var small = [UInt8](repeating: 0, count: 200)
        let failed = small.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 10)
            let result = Result { () throws(BytesError) in try encoder.compressAll(data.span.bytes, into: &span) }
            return (result, span.finalize(for: buffer))
        }
        #expect(throws: BytesError.insufficientCapacity) { _ = try failed.0.get() }
        #expect(failed.1 == 10)
    }

    /// The compression corpus (`Tools/corpus fetch`), if present: each file's first 2 MiB as 64 KiB chunks at
    /// 64 KiB of capacity, as APFS compression encodes them, and as one stream.
    static func checkCorpus() throws {
        let directory = Corpus.root.path(percentEncoded: false)
        var encoder = LZBitmapEncoder()
        var files = 0
        for set in ["silesia", "web"] {
            let path = directory + "/" + set
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for name in names.sorted() {
                guard let contents = FileManager.default.contents(atPath: path + "/" + name) else { continue }
                let data = [UInt8](contents.prefix(2 << 20))
                files += 1
                for offset in stride(from: 0, to: data.count, by: 65536) {
                    let chunk = Array(data[offset..<min(offset + 65536, data.count)])
                    let actual = try? lzbitmapEncode(chunk, capacity: chunk.count, encoder: &encoder).get()
                    #expect(actual == appleLZBitmapEncode(chunk, capacity: chunk.count), "\(name) at \(offset)")
                }
                let capacity = LZBitmapEncoder.maximumCompressedSize(forByteCount: data.count)
                #expect(try lzbitmapEncode(data, capacity: capacity, encoder: &encoder).get() == appleLZBitmapEncode(data, capacity: capacity), "\(name)")
            }
        }
        if files == 0 { print("LZBITMAP encoder corpus test: no corpus at \(directory) (Tools/corpus fetch)") }
    }
}

/// The full capacity sweep, 6 MB through one encoder, and the corpus (if present).
@Suite(.bulk) struct LZBitmapEncoderBulkTests {
    @Test func capacities() { LZBitmapEncoderTests.checkCapacities(sweepStep: 211) }

    @Test("Several megabytes, reusing the encoder")
    func large() throws {
        try LZBitmapEncoderTests.checkLarge(largeSample() + LZBitmapEncoderTests.content(4, size: 3 << 20))
    }

    @Test("The corpus, as 64 KiB chunks and whole")
    func corpus() throws { try LZBitmapEncoderTests.checkCorpus() }
}
