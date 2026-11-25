import Bytes
import BytesAsync
import BytesCompression
import Testing

// BytesAsync's `concurrently()` with a codec as the stage: moved with BytesCompression from Bytes' BytesAsyncTests (the
// actor test, which needs no codec, stayed there).

/// `concurrently()`: a stage's calls run in a `@concurrent` function, off the caller's actor.
@Suite struct ConcurrentTransformTests {
    static let text: [UInt8] = Array(String(repeating: "Pack my box with five dozen liquor jugs. ", count: 4_000).utf8)

    /// The concurrent adapter produces the stage's output, through the drive loop.
    @Test func roundTrips() async throws {
        var reference: [UInt8] = []
        var encoder = DeflateEncoder(format: .gzip, level: 6)
        _ = try encoder.transform(Self.text.span.bytes, appending: &reference, flush: .finish)

        var concurrent = DeflateEncoder(format: .gzip, level: 6).concurrently()
        var compressed: [UInt8] = []
        let progress = try await concurrent.transform(Self.text.span.bytes, appending: &compressed, flush: .finish, growth: 1_000)
        #expect(progress.status == .finished && compressed == reference)

        var decoder = DeflateDecoder(format: .gzip).concurrently()
        var decoded: [UInt8] = []
        _ = try await decoder.transform(compressed.span.bytes, appending: &decoded, flush: .finish)
        #expect(decoded == Self.text)
    }

    /// A concurrent stage's error comes back to the caller, and nothing it wrote is counted.
    @Test func errorsPropagate() async {
        var decoder = DeflateDecoder(format: .zlib).concurrently()
        var output: [UInt8] = []
        await #expect(throws: BytesError.self) {
            _ = try await decoder.transform([0xFF, 0xFF, 0xFF].span.bytes, appending: &output, flush: .finish)
        }
        #expect(output.isEmpty)
    }
}
