import Foundation
@_spi(Benchmarking) import NativeZip
import Testing
import zlib

/// Not a test: times both backends on streams of different shapes, to see where each spends its time.
/// Run with `swift test -c release --filter PerfProbe`.
@Suite(.disabled(if: ProcessInfo.isDebugBuild)) struct PerfProbe {
    @Test func compareShapes() throws {
        var rng = SplitMix64(state: 3)
        let words = ["swift", "byte", "span", "inflate", "huffman", "window", " ", "\n", "the", "a", "decoder", "table"]
        var text: [UInt8] = []
        while text.count < 8 << 20 {
            text += Array(words.randomElement(using: &rng)!.utf8)
        }
        let random = (0..<(8 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let runs = (0..<(8 << 20)).map { UInt8(($0 / 3000) % 5) }
        let shapes: [(String, [UInt8])] = [
            ("literals only (Huffman-only text)", deflate(text, strategy: Z_HUFFMAN_ONLY)),
            ("default text", deflate(text)),
            ("text, fixed code", deflate(text, strategy: Z_FIXED)),
            ("long runs (distance 1)", deflate(runs)),
            ("stored random", deflate(random, level: 0)),
        ]
        for (name, stream) in shapes {
            var results: [String] = []
            for backend in [ZipDecoder.Backend.bytes, .zlib] {
                var decoder = ZipDecoder(backend: backend)
                var best = Duration.seconds(100)
                for _ in 0..<5 {
                    let start = ContinuousClock.now
                    _ = try DeflateBackends.inflate(stream.span.bytes, using: &decoder, discarding: true)
                    best = min(best, ContinuousClock.now - start)
                }
                results.append("\(backend): \(best)")
            }
            print("PROBE \(name): \(results.joined(separator: ", "))")
        }
    }
}

extension ProcessInfo {
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
