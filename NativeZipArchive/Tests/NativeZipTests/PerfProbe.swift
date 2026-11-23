import BytesReferenceCodecs
import BytesTestSupport
import BytesTesting
import Foundation
@_spi(Benchmarking) import NativeZip
import Testing

/// Not a test: times NativeZip's DEFLATE decoding and zlib's on streams of different shapes, to see where each spends its time.
/// Run with `swift test -c release --filter PerfProbe`.
@Suite(.optimizedOnly) struct PerfProbe {
    @Test func compareShapes() throws {
        var rng = SplitMix64(seed: 3)
        let words = ["swift", "byte", "span", "inflate", "huffman", "window", " ", "\n", "the", "a", "decoder", "table"]
        var text: [UInt8] = []
        while text.count < 8 << 20 {
            text += Array(words.randomElement(using: &rng)!.utf8)
        }
        let random = (0..<(8 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let runs = (0..<(8 << 20)).map { UInt8(($0 / 3000) % 5) }
        let shapes: [(String, [UInt8])] = [
            ("literals only (Huffman-only text)", Zlib.compress(text, strategy: Zlib.huffmanOnlyStrategy)),
            ("default text", Zlib.compress(text)),
            ("text, fixed code", Zlib.compress(text, strategy: Zlib.fixedStrategy)),
            ("long runs (distance 1)", Zlib.compress(runs)),
            ("stored random", Zlib.compress(random, level: 0)),
        ]
        /// The best of five runs of `body`.
        func best(_ body: () throws -> Void) rethrows -> Duration {
            var best = Duration.seconds(100)
            for _ in 0..<5 {
                let start = ContinuousClock.now
                try body()
                best = min(best, ContinuousClock.now - start)
            }
            return best
        }
        var decoder = ZipDecoder()
        for (name, stream) in shapes {
            let native = try best { _ = try DeflateBackends.inflate(stream.span.bytes, using: &decoder, discarding: true) }
            // zlib through BytesReferenceCodecs, which also copies its output into an array.
            let zlib = best { _ = Zlib.decompress(stream) }
            print("PROBE \(name): NativeZip: \(native), zlib: \(zlib)")
        }
    }
}
