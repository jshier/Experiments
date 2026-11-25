import Bytes
import BytesAsync
import Testing

/// Lending spans to tasks, and `ByteBuffer.receive`. (The stage adapters' tests with a codec as the stage moved with
/// BytesCompression to its own package: BytesCompression/Tests/BytesCompressionTests/AsyncTests.swift.)
@Suite struct AsyncTests {
    /// Child tasks read the lent input and write disjoint parts of the lent output.
    @Test func lendingToATaskGroup() async {
        let input = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var storage = [UInt8](repeating: 0, count: input.count)
        var span = storage.mutableSpan
        let written = await span.withOutputRawSpanAsync { output in
            // Unsafe: the input and the output's free capacity lent as pointers. Safe: the task group is awaited
            // inside the lending closures.
            await unsafe input.span.bytes.withLentBytes { source in
                await unsafe output.withLentFreeCapacity { target in
                    await withDiscardingTaskGroup { group in
                        for lane in 0..<4 {
                            group.addTask {
                                let range = (lane * 2_500)..<((lane + 1) * 2_500)
                                for index in range {
                                    // Unsafe: the lent buffers' pointers. Safe: the group ends before the lending
                                    // closures do, and each task writes its own range of `target`.
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

    /// `ByteBuffer.receive` from a source whose reads suspend, until it delivers nothing.
    @Test func byteBufferReceive() async throws {
        var buffer = ByteBuffer(capacity: 16)
        var source = Chunks(chunks: [[1, 2, 3], [4, 5], []])
        var total = 0
        while true {
            let count = try await buffer.receive { output throws(BytesError) in try await source.read(into: &output) }
            if count == 0 { break }
            total += count
        }
        #expect(total == 5)
        #expect([UInt8](copying: buffer.unread) == [1, 2, 3, 4, 5])
    }

    /// A stand-in for a socket: each read suspends, then delivers the next chunk.
    struct Chunks {
        var chunks: [[UInt8]]

        mutating func read(into output: inout OutputRawSpan) async throws(BytesError) -> Int {
            await Task.yield()
            let chunk = chunks.removeFirst()
            output.append(copying: chunk.span)
            return chunk.count
        }
    }
}

extension MutableSpan where Element == UInt8 {
    /// An output span over these bytes for an asynchronous body (a test helper).
    mutating func withOutputRawSpanAsync(_ body: (inout OutputRawSpan) async -> Int) async -> Int {
        // Unsafe: the span's buffer, outliving `withUnsafeMutableBytes`' closure. Safe: the span is `inout` for this
        // whole call, so its memory stays put while `output` uses it.
        let buffer = withUnsafeMutableBytes { unsafe $0 }
        // Unsafe: an output span over that buffer. Safe: it's finalized against the same buffer before returning.
        var output = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
        let result = await body(&output)
        // Unsafe: checks `output` still covers `buffer`. Safe: the buffer is the one it was made over.
        _ = unsafe output.finalize(for: buffer)
        return result
    }
}
