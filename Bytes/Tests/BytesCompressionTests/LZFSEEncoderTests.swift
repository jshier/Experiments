import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Compression
import Foundation
import Testing

// LZVNEncoder and LZFSEEncoder: their default streams against Compression's, byte for byte (raw LZVN is
// `compression_encode_buffer`'s algorithm 0x900), failures and room included; with `parse: .reference`, against the
// lzfse reference encoder's; decoded by Bytes' and Compression's decoders.
//
// The reference (github.com/lzfse/lzfse at e634ca5) isn't built any more: its streams are checked through SHA-256
// digests of them, recorded on 2026-11-19 from the reference itself (`Tools/test-data fetch c-references` has its
// source; Benchmarks/RESULTS-lz4-lzfse.md says how to build it again and compare).
enum LZReferenceDigests {
    /// Every sample of ``LZEncoderSamples/all`` then ``LZSamples/large``, in order: the reference's raw LZVN.
    static let lzvnSamples = "fae221d2a769a7be4212dd09e9e3471158d5f197d76851511347a2ddb1e4bb4b"
    /// The same, the reference's LZFSE.
    static let lzfseSamples = "827f97dbac18dbff81d416e8c2ac45be86a3628cc9881b13868ca3f4a82f2927"
    /// ``LZEncoderSamples/all`` alone (the fast tests' part of ``lzvnSamples``), recorded 2026-11-19 from the streams
    /// that ``lzvnSamples`` covers.
    static let lzvnEncoderSamples = "a8c3b378545c1e3301adc315b5b2663d99b9809abe327dd8514cf0aba5a4a6e2"
    /// The same, LZFSE (the fast part of ``lzfseSamples``).
    static let lzfseEncoderSamples = "91ecb58dc69c5d28ab40e381bc5efc6130bd1d3dafcc0dcde3024fcc0061b9cd"
    /// Corpus files' first 16 MiB, whole: LZVN, LZFSE, and LZFSE of their first 4 MiB in 64 KiB chunks.
    static let corpus: [String: (lzvn: String, lzfse: String, lzfseChunks: String)] = [
        "silesia/dickens": (
            "489f04986bc2b38287ab1e0fd3a4aa781f492462787905ec0677b3c7221173fd",
            "75fb8233c64adeb7923f82a93a8029d98e4ba5c38295b908f3628f901b1268bd",
            "d3cc81ae54e2f8c4a6cbaae128d3fe759a70d819e440a8c12e767a59aacfe2ac"
        ),
        "silesia/xml": (
            "80b875fe92bc23ec8589c553c0e5c4cad78cbb0bf564bf3f9310a6c3541d5d48",
            "dde0661b32bbe58d9f87b505e9105f2382c52e92722c327ae34d0ec82d3d15d3",
            "c0d7610886c10debd4f5459feaa2e65a6aacfec1c7c98acef3ee65abfcc1302f"
        ),
        "silesia/x-ray": (
            "b815bb5f314da5e338d8c50166aff140644bf3a738a34493a935f434bb0e68d8",
            "8703e30e4ee678deca7558b03007b8bffe9e68b237fd32d8376ab6d16287a20a",
            "ebae7e82ef0dd55d85fca44b9b08d55982621feaecb38d0f30be6100f8356045"
        ),
        "silesia/samba": (
            "0333de7a4b5288c300ec900bda0211e06e1db2b835333168cbd839c392beb018",
            "fce6ecae3fc63c8f1ea7918090ab4d27d538d36f33079a65ed1662d2729fb056",
            "82cbd6b78c49afd8977f23cd689c7efbb83f555fada8af7154da2959ba7dcd78"
        ),
        "silesia/mozilla": (
            "ec1200de73f3480f1a98169938befb8ada8a8367511d1d32ae77c51f360119ff",
            "e0a1c1647d7834e196c589d5293215fe09fd970b81c014841d2a44a97045e880",
            "e35d1b262f2afa8d26fb95139d618017d2776a4e4a95b435360a578bc68c57ad"
        ),
        "web/Main.js": (
            "65f203211b572238039ba618b0d874f4b08c1cc48284423f59ec446137134912",
            "417d12cd740ddc59249be88ee06a15e3dc6104d81827093a1841b718270967f5",
            "e24c70fc2fc16e5fa4f234de009260e6e7bbe46f1fd2b8d4ec1f793b09eebe5c"
        ),
    ]
}

/// Bytes' LZVN encoding of `data` into exactly `capacity` bytes (the maximum by default).
func lzvnEncode(_ data: [UInt8], encoder: inout LZVNEncoder, capacity: Int? = nil) -> Result<[UInt8], BytesError> {
    let capacity = capacity ?? LZVNEncoder.maximumCompressedSize(forByteCount: data.count)
    let (result, output) = withExactBuffers(data, capacity: capacity) { input, output throws(BytesError) in
        try encoder.compressAll(input, into: &output)
    }
    return result.map { written in
        precondition(written == output.count)
        return output
    }
}

/// Bytes' LZFSE encoding of `data` into exactly `capacity` bytes (the maximum by default).
func lzfseEncode(_ data: [UInt8], encoder: inout LZFSEEncoder, capacity: Int? = nil) -> Result<[UInt8], BytesError> {
    let capacity = capacity ?? LZFSEEncoder.maximumCompressedSize(forByteCount: data.count)
    let (result, output) = withExactBuffers(data, capacity: capacity) { input, output throws(BytesError) in
        try encoder.compressAll(input, into: &output)
    }
    return result.map { written in
        precondition(written == output.count)
        return output
    }
}

enum LZEncoderSamples {
    /// Every decoder sample, periods 1 through 40, and sizes around the LZVN threshold and the LZFSE block limits.
    static let all: [(name: String, bytes: [UInt8])] = {
        var samples = LZSamples.all
        for period in 17...40 {
            for size in [40, 300, 5000, 70_000] {
                samples.append(("period \(period) \(size)", LZSamples.periodic(size, period: period, seed: UInt64(period))))
            }
        }
        for size in [4094, 4095, 4096, 4097, 39_999, 40_000, 40_001, 50_021, 131_071, 131_072] {
            samples.append(("text \(size)", LZSamples.text(size, seed: UInt64(size) &+ 7)))
            samples.append(("mixed \(size)", LZSamples.mixed(size, seed: UInt64(size) &+ 7)))
        }
        // Long runs and long literal stretches: L and M split across triples and opcodes.
        samples.append(("run 300 000", [UInt8](repeating: 7, count: 300_000)))
        samples.append(("random then run", LZSamples.random(9000, seed: 9) + [UInt8](repeating: 1, count: 9000)))
        samples.append(("zeros 70 000", [UInt8](repeating: 0, count: 70_000)))
        return samples
    }()

    /// Corpus files, whole and in 64 KiB chunks, if the corpus is present (`Tools/corpus fetch`): each file's first
    /// 16 MiB, or all of it.
    static let corpus: [(name: String, bytes: [UInt8])] = {
        let root = Corpus.root
        return ["silesia/dickens", "silesia/xml", "silesia/x-ray", "silesia/samba", "silesia/mozilla", "web/Main.js"].compactMap { path in
            guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else { return nil }
            return (path, Array(data.prefix(16 << 20)))
        }
    }()
}

@Suite struct LZVNEncoderTests {
    /// The reference's parse, so its bytes (by digest), and decoded back by Bytes' decoder. The encoder samples here;
    /// with the large inputs, against the reference's digest for both, in LZEncoderBulkTests.
    @Test func matchesReference() throws {
        let digest = try Self.referenceDigest(LZEncoderSamples.all)
        #expect(digest == LZReferenceDigests.lzvnEncoderSamples)
    }

    static func referenceDigest(_ samples: [(name: String, bytes: [UInt8])]) throws -> String {
        var encoder = LZVNEncoder(parse: .reference)
        var streams: [[UInt8]] = []
        for (name, bytes) in samples {
            guard case .success(let stream) = lzvnEncode(bytes, encoder: &encoder) else {
                Issue.record("\(name): encoding failed")
                continue
            }
            streams.append(stream)
            #expect(try lzvnDecode(stream, capacity: bytes.count).get() == bytes, "\(name)")
        }
        return goldenDigest(streams)
    }

    static func checkCorpus() throws {
        var encoder = LZVNEncoder(parse: .reference)
        for (name, bytes) in LZEncoderSamples.corpus {
            let stream = try lzvnEncode(bytes, encoder: &encoder).get()
            #expect(goldenDigest([stream]) == LZReferenceDigests.corpus[name]?.lzvn, "\(name)")
            #expect(try lzvnDecode(stream, capacity: bytes.count).get() == bytes, "\(name)")
        }
    }

    /// An encoder reused across inputs (and after a failure) writes what a new one does, with either parse.
    @Test(arguments: [LZVNEncoder.Parse.compression, .reference])
    func reuse(parse: LZVNEncoder.Parse) {
        var encoder = LZVNEncoder(parse: parse)
        for round in 0..<3 {
            for size in [5000, 70_000, 9] {
                let bytes = LZSamples.mixed(size, seed: UInt64(round &* 31 &+ size))
                _ = lzvnEncode(bytes, encoder: &encoder, capacity: size / 3)
                var fresh = LZVNEncoder(parse: parse)
                #expect(lzvnEncode(bytes, encoder: &encoder) == lzvnEncode(bytes, encoder: &fresh), "\(size)")
            }
        }
    }
}

@Suite struct LZFSEEncoderTests {
    /// The reference's stream, byte for byte (by digest), decoded back by Bytes' and Compression's decoders. The
    /// encoder samples here; with the large inputs, against the reference's digest for both, in LZEncoderBulkTests.
    @Test func matchesReference() throws {
        let digest = try Self.referenceDigest(LZEncoderSamples.all)
        #expect(digest == LZReferenceDigests.lzfseEncoderSamples)
    }

    static func referenceDigest(_ samples: [(name: String, bytes: [UInt8])]) throws -> String {
        var encoder = LZFSEEncoder(parse: .reference)
        var decoder = LZFSEDecoder()
        var streams: [[UInt8]] = []
        for (name, bytes) in samples {
            guard case .success(let stream) = lzfseEncode(bytes, encoder: &encoder) else {
                Issue.record("\(name): encoding failed")
                continue
            }
            streams.append(stream)
            #expect(try lzfseDecode(stream, capacity: bytes.count, decoder: &decoder).get() == bytes, "\(name)")
            #expect(appleDecode(stream, capacity: bytes.count, COMPRESSION_LZFSE) == bytes, "\(name)")
        }
        return goldenDigest(streams)
    }

    /// Block kinds where Compression writes them: stored under 8 bytes and where LZVN doesn't shrink the input,
    /// LZVN under 4,096 bytes, LZFSE from there.
    @Test func blockKinds() throws {
        var encoder = LZFSEEncoder()
        func magics(_ bytes: [UInt8]) throws -> [String] {
            try lzfseBlocks(lzfseEncode(bytes, encoder: &encoder).get()).map(\.magic)
        }
        #expect(try magics([]) == ["bvx-", "bvx$"])
        #expect(try magics(LZSamples.text(7, seed: 1)) == ["bvx-", "bvx$"])
        #expect(try magics(LZSamples.random(1000, seed: 1)) == ["bvx-", "bvx$"])
        #expect(try magics(LZSamples.text(4095, seed: 1)) == ["bvxn", "bvx$"])
        #expect(try magics(LZSamples.text(4096, seed: 1)) == ["bvx2", "bvx$"])
        #expect(try magics(LZSamples.text(1 << 20, seed: 1)).dropLast().allSatisfy { $0 == "bvx2" })
        for bytes in [[], LZSamples.text(7, seed: 1), LZSamples.random(1000, seed: 1), LZSamples.text(4095, seed: 1), LZSamples.text(4096, seed: 1)] {
            #expect(try lzfseBlocks(lzfseEncode(bytes, encoder: &encoder).get()).map(\.magic)
                == lzfseBlocks(appleEncode(bytes, COMPRESSION_LZFSE)).map(\.magic))
        }
    }

    /// An encoder reused across hundreds of inputs (past the point where its table is cleared, about 500 at 2 MiB
    /// of bias each), and after failures, writes what a new encoder does.
    @Test func reuse() {
        var encoder = LZFSEEncoder()
        for round in 0..<600 {
            let size = [5000, 3000, 70_000, 9][round % 4]
            let bytes = LZSamples.mixed(size, seed: UInt64(round % 7))
            if round % 50 == 0 { _ = lzfseEncode(bytes, encoder: &encoder, capacity: size / 3) }
            if round % 25 == 0 || round > 490 {
                var fresh = LZFSEEncoder()
                #expect(lzfseEncode(bytes, encoder: &encoder) == lzfseEncode(bytes, encoder: &fresh), "round \(round)")
            } else {
                _ = lzfseEncode(bytes, encoder: &encoder)
            }
        }
    }

    /// The corpus, whole (up to 16 MiB) and in 64 KiB chunks as `decmpfs` stores files: the reference's bytes, decoded
    /// by every decoder, and within 0.1% of Compression's size.
    static func checkCorpus() throws {
        var encoder = LZFSEEncoder(parse: .reference)
        var decoder = LZFSEDecoder()
        for (name, bytes) in LZEncoderSamples.corpus {
            let stream = try lzfseEncode(bytes, encoder: &encoder).get()
            let digests = LZReferenceDigests.corpus[name]
            #expect(goldenDigest([stream]) == digests?.lzfse, "\(name)")
            #expect(try lzfseDecode(stream, capacity: bytes.count, decoder: &decoder).get() == bytes, "\(name)")
            #expect(appleDecode(stream, capacity: bytes.count, COMPRESSION_LZFSE) == bytes, "\(name)")
            let apple = appleEncode(bytes, COMPRESSION_LZFSE).count
            #expect(abs(stream.count - apple) * 1000 <= apple, "\(name): \(stream.count) against Compression's \(apple)")

            var chunked = 0
            var appleChunked = 0
            var chunkStreams: [[UInt8]] = []
            for start in stride(from: 0, to: min(bytes.count, 4 << 20), by: 65_536) {
                let chunk = Array(bytes[start..<min(start + 65_536, bytes.count)])
                let stream = try lzfseEncode(chunk, encoder: &encoder).get()
                chunkStreams.append(stream)
                #expect(appleDecode(stream, capacity: chunk.count, COMPRESSION_LZFSE) == chunk, "\(name) at \(start)")
                chunked += stream.count
                appleChunked += appleEncode(chunk, COMPRESSION_LZFSE).count
            }
            #expect(goldenDigest(chunkStreams) == digests?.lzfseChunks, "\(name) in 64 KiB chunks")
            #expect(abs(chunked - appleChunked) * 1000 <= appleChunked, "\(name) in 64 KiB chunks: \(chunked) against \(appleChunked)")
        }
    }
}

/// The reference's bytes for every sample with the large inputs (the digests recorded from the reference itself),
/// and for the corpus (if present).
@Suite(.bulk) struct LZEncoderBulkTests {
    @Test func lzvnMatchesReference() throws {
        let digest = try LZVNEncoderTests.referenceDigest(LZEncoderSamples.all + LZSamples.large)
        #expect(digest == LZReferenceDigests.lzvnSamples)
    }

    @Test func lzvnCorpus() throws { try LZVNEncoderTests.checkCorpus() }

    @Test func lzfseMatchesReference() throws {
        let digest = try LZFSEEncoderTests.referenceDigest(LZEncoderSamples.all + LZSamples.large)
        #expect(digest == LZReferenceDigests.lzfseSamples)
    }

    @Test func lzfseCorpus() throws { try LZFSEEncoderTests.checkCorpus() }
}
