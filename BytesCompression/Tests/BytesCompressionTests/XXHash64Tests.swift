import Bytes
import BytesCompression
import BytesTestSupport
import CZstd
import Foundation
import Testing

@Suite struct XXHash64Tests {
    /// libzstd's `ZSTD_XXH64(input, length, seed)`: exported, but declared in no public header.
    typealias XXH64Function = @convention(c) (UnsafeRawPointer?, Int, UInt64) -> UInt64
    static let zstdXXH64: XXH64Function? = {
        // Linking libzstd's other functions keeps its symbols loaded.
        _ = ZSTD_versionNumber()
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ZSTD_XXH64") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: XXH64Function.self)
    }()

    /// The one-shot hash (its own path, no buffer) agrees with the streaming hasher fed in pieces, and with libzstd's
    /// XXH64, at every length to 300, both sides of the 32-byte stripe and each tail case, with several seeds.
    @Test func oneShotMatchesStreamingAndLibzstd() {
        #expect(Self.zstdXXH64 != nil, "libzstd's ZSTD_XXH64 wasn't found")
        var rng = SplitMix64(seed: 0x64)
        let bytes = (0..<300).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for seed: UInt64 in [0, 1, 0x9E37_79B1_85EB_CA87, .max] {
            for length in 0...300 {
                let data = Array(bytes.prefix(length))
                let oneShot = XXHash64.hash(data.span.bytes, seed: seed)
                var hasher = XXHash64(seed: seed)
                var offset = 0
                var step = 1
                while offset < length {
                    let end = min(offset + step, length)
                    hasher.update(data.span.bytes.extracting(offset..<end))
                    offset = end
                    step = step * 5 % 37 + 1
                }
                #expect(hasher.digest == oneShot, "length \(length), seed \(seed)")
                if let reference = Self.zstdXXH64 {
                    let expected = data.withUnsafeBytes { reference($0.baseAddress, $0.count, seed) }
                    #expect(oneShot == expected, "length \(length), seed \(seed)")
                }
            }
        }
    }

    /// Copying while hashing (a raw block's path) copies exactly the bytes and hashes them as `update` does, from
    /// every partial-round state (0–31 bytes buffered first) and at every length around the 32-byte stripes.
    @Test func copyingWhileHashingMatchesUpdate() {
        var rng = SplitMix64(seed: 0xC0)
        let bytes = (0..<400).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for head in 0..<32 {
            for length in [0, 1, 7, 31, 32, 33, 63, 64, 65, 100, 255, 256, 257, 300] {
                var expected = XXHash64()
                expected.update(bytes.span.bytes.extracting(0..<head))
                expected.update(bytes.span.bytes.extracting(head..<(head + length)))
                var hasher = XXHash64()
                hasher.update(bytes.span.bytes.extracting(0..<head))
                var copy = [UInt8](repeating: 0xEE, count: length + 8)
                bytes.withUnsafeBytes { source in
                    copy.withUnsafeMutableBytes { destination in
                        hasher.copyAndUpdate(from: source.baseAddress! + head, to: destination.baseAddress!, count: length)
                    }
                }
                #expect(hasher.digest == expected.digest, "head \(head), length \(length)")
                #expect(copy[..<length] == bytes[head..<(head + length)], "head \(head), length \(length)")
                #expect(copy[length...].allSatisfy { $0 == 0xEE }, "wrote past \(length) bytes")
            }
        }
    }

    /// Hashing a slice reads only the slice: the tail's loads end where the span does.
    @Test func hashesSlicesEndingInsideLargerBuffers() {
        var rng = SplitMix64(seed: 7)
        let bytes = (0..<128).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for start in 0..<8 {
            for end in start...100 {
                let slice = Array(bytes[start..<end])
                #expect(XXHash64.hash(bytes.span.bytes.extracting(start..<end)) == XXHash64.hash(slice.span.bytes))
            }
        }
    }
}
