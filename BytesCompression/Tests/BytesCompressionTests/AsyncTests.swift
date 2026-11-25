import Bytes
import BytesAsync
import BytesCompression
import Dispatch
import Testing

// BytesAsync's stage adapters with a codec as the stage: moved with BytesCompression from Bytes' BytesAsyncTests (the
// adapter tests that need no codec stayed there).

/// Asynchronous pipeline stages.
@Suite struct AsyncTests {
    static let text: [UInt8] = Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4_000).utf8)

    /// The synchronous adapter, the offloaded one, and the drive loop all produce the stage's output.
    @Test func adaptedStagesRoundTrip() async throws {
        var reference: [UInt8] = []
        var encoder = DeflateEncoder(format: .gzip, level: 6)
        _ = try encoder.transform(Self.text.span.bytes, appending: &reference, flush: .finish)

        var synchronous = DeflateEncoder(format: .gzip, level: 6).synchronously()
        var viaSynchronous: [UInt8] = []
        let first = try await synchronous.transform(Self.text.span.bytes, appending: &viaSynchronous, flush: .finish, growth: 1_000)
        #expect(first.status == .finished && viaSynchronous == reference)

        var offloaded = DeflateEncoder(format: .gzip, level: 6).offloaded(to: .global())
        var viaQueue: [UInt8] = []
        let second = try await offloaded.transform(Self.text.span.bytes, appending: &viaQueue, flush: .finish, growth: 1_000)
        #expect(second.status == .finished && viaQueue == reference)

        var decoder = DeflateDecoder(format: .gzip).offloaded(to: .global())
        var decoded: [UInt8] = []
        _ = try await decoder.transform(viaQueue.span.bytes, appending: &decoded, flush: .finish)
        #expect(decoded == Self.text)
    }

    /// An offloaded stage's error comes back to the caller.
    @Test func offloadedErrorsPropagate() async {
        var decoder = DeflateDecoder(format: .zlib).offloaded(to: .global())
        var output: [UInt8] = []
        await #expect(throws: BytesError.invalidValue) { // The header's method isn't 8.
            _ = try await decoder.transform([0xFF, 0xFF, 0xFF].span.bytes, appending: &output, flush: .finish)
        }
    }
}
