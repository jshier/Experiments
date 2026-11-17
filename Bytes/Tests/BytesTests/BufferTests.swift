import Bytes
import Testing

/// Copies into spans and output spans, output spans over arrays, and `ByteBuffer`.
@Suite struct BufferTests {
    /// Every length the inline copies distinguish (0, 1–3, 4–7, 8–16, 17–32, 33–64) and the `memmove` path.
    static let lengths = [0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 47, 63, 64, 65, 200, 4_096]

    static func pattern(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    @Test(arguments: lengths)
    func copyBytesFromASpan(count: Int) {
        let source = Self.pattern(count)
        for offset in [0, 1, 5] {
            var buffer = [UInt8](repeating: 0xEE, count: count + offset + 3)
            var span = buffer.mutableSpan
            span.copyBytes(from: source.span.bytes, toByteOffset: offset)
            _ = consume span
            // Exactly `source` at `offset`; nothing before or after touched.
            #expect(Array(buffer[..<offset]) == [UInt8](repeating: 0xEE, count: offset))
            #expect(Array(buffer[offset..<(offset + count)]) == source)
            #expect(Array(buffer[(offset + count)...]) == [0xEE, 0xEE, 0xEE])
        }
    }

    @Test func copyBytesFromASpanIntoARawSpan() {
        var buffer = [UInt8](repeating: 0, count: 8)
        var span = buffer.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        // (Typed: an untyped literal is an `[Int]`, whose `span.bytes` is 24 bytes.)
        raw.copyBytes(from: ([1, 2, 3] as [UInt8]).span.bytes, toByteOffset: 5) // Fills to the end exactly.
        _ = consume raw
        _ = consume span
        #expect(buffer == [0, 0, 0, 0, 0, 1, 2, 3])
    }

    @Test(arguments: [(0..<10, 0), (6..<16, 0), (0..<10, 6), (3..<13, 2), (2..<12, 5), (4..<4, 0), (0..<16, 0)])
    func copyBytesWithinOverlapping(range: Range<Int>, offset: Int) {
        let original = Self.pattern(16)
        var buffer = original
        var span = buffer.mutableSpan
        span.copyBytes(within: range, toByteOffset: offset)
        _ = consume span
        var expected = original
        expected.replaceSubrange(offset..<(offset + range.count), with: original[range])
        #expect(buffer == expected)
    }

    @Test(arguments: lengths)
    func appendCopyingToAnOutputSpan(count: Int) {
        let source = Self.pattern(count)
        let prefix: [UInt8] = [9, 9]
        let bytes = [UInt8](capacity: count + 2) { (output: inout OutputSpan<UInt8>) in
            output.withBytesWriter { writer in try! writer.write(prefix.span) }
        }
        var result = bytes
        result.append(addingCapacity: count) { (output: inout OutputSpan<UInt8>) in
            // Unsafe: the test's way to reach an `OutputRawSpan`: one over the array's new capacity.
            unsafe output.withUnsafeMutableBufferPointer { buffer, initializedCount in
                let region = UnsafeMutableRawBufferPointer(buffer)
                var raw = unsafe OutputRawSpan(buffer: region, initializedCount: initializedCount)
                raw.append(copying: source.span)
                initializedCount = unsafe raw.finalize(for: region)
            }
        }
        #expect(result == prefix + source)
    }

    @Test func withFreeCapacityCountsOnlyWhatIsReported() throws {
        var buffer = [UInt8](repeating: 0, count: 16)
        let (produced, result) = buffer.withOutputRawSpan { output in
            output.append(1)
            let result = output.withFreeCapacity { span, written in
                #expect(span.byteCount == 15)
                span.copyBytes(from: ([2, 3, 4, 5] as [UInt8]).span.bytes, toByteOffset: 0)
                written = 3 // The fourth byte isn't kept.
                return "done"
            }
            // A sized span: exactly 2 bytes, both kept.
            output.withFreeCapacity(byteCount: 2) { span, written in
                #expect(span.byteCount == 2)
                span.copyBytes(from: ([7, 8] as [UInt8]).span.bytes, toByteOffset: 0)
                written = 2
            }
            return (output.byteCount, result)
        }
        #expect(result == "done")
        #expect(produced == 6)
        #expect(Array(buffer[..<6]) == [1, 2, 3, 4, 7, 8])
    }

    @Test func withFreeCapacityAppendsNothingWhenItThrows() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let produced = buffer.withOutputRawSpan { output in
            #expect(throws: BytesError.invalidValue) {
                try output.withFreeCapacity { span, written throws(BytesError) in
                    span.copyBytes(from: ([1, 2] as [UInt8]).span.bytes, toByteOffset: 0)
                    written = 2
                    throw .invalidValue
                }
            }
            return output.byteCount
        }
        #expect(produced == 0)
    }

    @Test func outputSpanOverAnArrayFromAnOffset() throws {
        var buffer: [UInt8] = [1, 2, 3, 0, 0, 0, 0]
        let produced = try buffer.withOutputRawSpan(overwritingFrom: 3) { output throws(BytesError) in
            try output.withBytesWriter { writer throws(BytesError) in try writer.write(0xA0_B0 as Byte2) }
            return output.byteCount
        }
        #expect(produced == 2)
        #expect(buffer == [1, 2, 3, 0xA0, 0xB0, 0, 0]) // The count doesn't change.
    }

    @Test func outputSpanOverAnArrayKeepsTheErrorType() {
        var buffer = [UInt8](repeating: 0, count: 2)
        // The typed error arrives as itself (through the array's `withUnsafeMutableBytes`, Swift 6.4.2 delivered
        // garbage, swiftlang/swift#90291).
        #expect(throws: BytesError.insufficientCapacity) {
            try buffer.withOutputRawSpan { output throws(BytesError) in
                try output.withBytesWriter { writer throws(BytesError) in try writer.write(0x01_02_03 as Byte3) }
            }
        }
    }

    // MARK: - ByteBuffer

    @Test func byteBufferFillsAndDrains() {
        var buffer = ByteBuffer(capacity: 8)
        #expect(buffer.isEmpty && !buffer.isFull && buffer.freeCapacity == 8)
        let added = buffer.fill { output in
            output.append(copying: [1, 2, 3, 4, 5].span)
            return output.byteCount
        }
        #expect(added == 5)
        #expect([UInt8](copying: buffer.unread) == [1, 2, 3, 4, 5])
        buffer.consume(2)
        #expect([UInt8](copying: buffer.unread) == [3, 4, 5] && buffer.unreadByteCount == 3)
        #expect(buffer.freeCapacity == 3)
        buffer.consume(3)
        // Empty: the next fill starts at the front again.
        #expect(buffer.isEmpty && buffer.freeCapacity == 8)
    }

    @Test func byteBufferCompactsBelowItsThreshold() {
        var buffer = ByteBuffer(capacity: 8) // Compacts when fewer than 4 bytes are free at the end.
        buffer.fill { output in output.append(copying: [1, 2, 3, 4, 5, 6].span) }
        buffer.consume(4)
        #expect(buffer.freeCapacity == 2)
        // 2 free at the end, under the threshold: the unread [5, 6] move to the front first.
        buffer.fill { output in
            #expect(output.freeCapacity == 6)
            output.append(copying: [7, 8, 9].span)
        }
        #expect([UInt8](copying: buffer.unread) == [5, 6, 7, 8, 9])

        var lazy = ByteBuffer(capacity: 8, compactingBelow: 1)
        lazy.fill { output in output.append(copying: [1, 2, 3, 4, 5, 6].span) }
        lazy.consume(4)
        // 2 free at the end, not under this buffer's threshold: no move, a smaller fill.
        lazy.fill { output in #expect(output.freeCapacity == 2) }
        // (`#expect` can't take a call on a `~Copyable` value as its whole condition.)
        let moved = lazy.compact()
        let movedAgain = lazy.compact() // Already at the front.
        #expect(moved && !movedAgain)
        #expect([UInt8](copying: lazy.unread) == [5, 6] && lazy.freeCapacity == 6)
    }

    @Test func byteBufferWhenFull() {
        var buffer = ByteBuffer(capacity: 4)
        buffer.fill { output in output.append(copying: [1, 2, 3, 4].span) }
        let full = buffer.isFull
        #expect(full)
        buffer.fill { output in #expect(output.freeCapacity == 0) }
        buffer.consume(1)
        #expect(!buffer.isFull && buffer.freeCapacity == 0) // Room only after compacting.
        buffer.removeAll()
        #expect(buffer.isEmpty && buffer.freeCapacity == 4)
    }

    @Test func byteBufferKeepsWhatAThrowingFillAppended() {
        var buffer = ByteBuffer(capacity: 8)
        #expect(throws: BytesError.invalidValue) {
            try buffer.fill { output throws(BytesError) in
                output.append(copying: [1, 2].span)
                throw .invalidValue
            }
        }
        #expect([UInt8](copying: buffer.unread) == [1, 2])
    }

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
