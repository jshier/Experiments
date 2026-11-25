import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing

@Suite struct BrotliIncompressibleTests {
    /// Random bytes (whose meta-blocks the sampled entropy check stores without building codes) come out stored:
    /// a few bytes per 256 KB meta-block over the input, and decode back, at every quality.
    @Test(arguments: [1, 5, 9])
    func randomInputIsStored(quality: Int) {
        var rng = SplitMix64(seed: 0xB0)
        let input = (0..<(600 << 10)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let encoded = brotliEncodeAll(input, quality: quality)
        #expect(encoded.count > input.count && encoded.count < input.count + 64)
        #expect(brotliDecodeAll(encoded) == .decoded(input))
    }

    /// Mostly random bytes with a repeated stretch in each meta-block: enough copies to fail the check's command
    /// count, so it compresses (smaller than the input), and decodes back.
    @Test func repeatsInRandomDataStillCompress() {
        var rng = SplitMix64(seed: 0xB1)
        var input: [UInt8] = []
        while input.count < 600 << 10 {
            input += (0..<1000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            input += [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next()), count: 1000)
        }
        let encoded = brotliEncodeAll(input, quality: 5)
        #expect(encoded.count < input.count * 3 / 4)
        #expect(brotliDecodeAll(encoded) == .decoded(input))
    }

    /// Random letters from a 16-letter alphabet (4 bits of entropy each, few useful matches) are coded, not stored:
    /// about half the input.
    @Test func lowEntropyLiteralsAreCoded() {
        var rng = SplitMix64(seed: 0xB2)
        let input = (0..<(300 << 10)).map { _ in UInt8(truncatingIfNeeded: rng.next() & 15) &+ 0x41 }
        let encoded = brotliEncodeAll(input, quality: 5)
        #expect(encoded.count < input.count * 6 / 10)
        #expect(brotliDecodeAll(encoded) == .decoded(input))
    }
}
