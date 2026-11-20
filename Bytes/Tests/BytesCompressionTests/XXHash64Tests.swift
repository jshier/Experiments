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
