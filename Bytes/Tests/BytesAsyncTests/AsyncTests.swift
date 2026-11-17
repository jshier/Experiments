import Bytes
import BytesAsync
import BytesCompression
import Dispatch
import Synchronization
import Testing

/// Lending spans to tasks, and asynchronous pipeline stages.
@Suite struct AsyncTests {
    static let text: [UInt8] = Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4_000).utf8)

    /// Child tasks read the lent input and write disjoint parts of the lent output.
    @Test func lendingToATaskGroup() async {
        let input = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var storage = [UInt8](repeating: 0, count: input.count)
        var span = storage.mutableSpan
        let written = await span.withOutputRawSpanAsync { output in
            await input.span.bytes.withLentBytes { source in
                await output.withLentFreeCapacity { target in
                    await withDiscardingTaskGroup { group in
                        for lane in 0..<4 {
                            group.addTask {
                                let range = (lane * 2_500)..<((lane + 1) * 2_500)
                                for index in range {
                                    unsafe target.buffer[index] = unsafe source.buffer[index] ^ 0xFF
                                }
                            }
                        }
                    }
                    return input.count
                }
            }
        }
        #expect(written == input.count)
        #expect(storage == input.map { $0 ^ 0xFF })
    }

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
        await #expect(throws: BytesError.self) {
            _ = try await decoder.transform([0xFF, 0xFF, 0xFF].span.bytes, appending: &output, flush: .finish)
        }
    }
}

extension MutableSpan where Element == UInt8 {
    /// An output span over these bytes for an asynchronous body (a test helper).
    mutating func withOutputRawSpanAsync(_ body: (inout OutputRawSpan) async -> Int) async -> Int {
        let buffer = withUnsafeMutableBytes { unsafe $0 }
        var output = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
        let result = await body(&output)
        _ = unsafe output.finalize(for: buffer)
        return result
    }
}
