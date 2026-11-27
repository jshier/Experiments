import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import Testing

/// Matches 1–15 bytes back, which the decoders copy by repeating the pattern from registers
/// (`GenericBytesWriter.copyShortMatch`): runs of every period between varied filler, encoded by the reference
/// encoders, decoded whole and in pieces against the original.
@Suite struct ShortMatchTests {
    /// Runs of period 1–15 and lengths 3–300 (each stride boundary of the fill), each after 1–40 bytes of random
    /// filler, so the matches start at every alignment and their patterns are varied.
    static let periodic: [UInt8] = {
        var generator = SplitMix64(seed: 0x5107)
        var bytes: [UInt8] = []
        while bytes.count < 300_000 {
            for _ in 0..<Int(1 + generator.next() % 40) {
                bytes.append(UInt8(truncatingIfNeeded: generator.next()))
            }
            let period = Int(1 + generator.next() % 15)
            let pattern = (0..<period).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            for index in 0..<Int(3 + generator.next() % 298) {
                bytes.append(pattern[index % period])
            }
        }
        return bytes
    }()

    @Test(arguments: [1, 6, 9])
    func deflateDecodesShortMatches(level: Int32) {
        let stream = Zlib.compress(Self.periodic, level: level)
        #expect(decodeAll(stream, format: .raw) == .decoded(Self.periodic))
        #expect(decodeStreaming(stream, format: .raw, chunk: 997, outputChunk: 4_099) == .decoded(Self.periodic))
    }

    @Test(arguments: [1, 5, 9])
    func brotliDecodesShortMatches(quality: Int32) {
        let stream = googleBrotliCompress(Self.periodic, quality: quality)
        #expect(brotliDecodeAll(stream) == .decoded(Self.periodic))
    }
}
