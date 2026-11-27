import Bytes
import Testing

/// `ByteBuffer`'s copies in, writes in place, and growth; appending a writer's output to an array.
@Suite struct GrowingBufferTests {
    static func pattern(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    /// Bytes for a literal (`[1, 2].span.bytes` would view an `[Int]`).
    static func bytes(_ values: [UInt8]) -> [UInt8] { values }

    // MARK: - append(copying:)

    @Test func appendCopiesAtTheEndWhenItFits() {
        var buffer = ByteBuffer(capacity: 8)
        buffer.append(copying: Self.bytes([1, 2, 3]).span.bytes)
        buffer.consume(1)
        buffer.append(copying: Self.bytes([4, 5]).span.bytes) // 5 free at the end: no move.
        #expect([UInt8](copying: buffer.unread) == [2, 3, 4, 5])
        #expect(buffer.freeCapacity == 3 && buffer.availableCapacity == 4)
    }

    /// Bytes that fit only after the unread ones move to the front: moved first, then copied.
    @Test func appendCompactsWhenTheEndIsTooSmall() {
        var buffer = ByteBuffer(capacity: 8, compactingBelow: 0)
        buffer.append(copying: Self.bytes([1, 2, 3, 4, 5, 6]).span.bytes)
        buffer.consume(4)
        #expect(buffer.freeCapacity == 2 && buffer.availableCapacity == 6)
        buffer.append(copying: Self.bytes([7, 8, 9, 10, 11, 12]).span.bytes)
        #expect([UInt8](copying: buffer.unread) == [5, 6, 7, 8, 9, 10, 11, 12])
        let full = buffer.isFull
        #expect(full)
    }

    @Test func appendingNothingChangesNothing() {
        var buffer = ByteBuffer(capacity: 4)
        buffer.append(copying: [UInt8]().span.bytes)
        #expect(buffer.isEmpty && buffer.freeCapacity == 4)
    }

    @Test func appendingMoreThanTheRoomStops() async {
        await #expect(processExitsWith: .failure) {
            var buffer = ByteBuffer(capacity: 4)
            buffer.append(copying: Self.bytes([1, 2, 3]).span.bytes)
            buffer.consume(1)
            buffer.append(copying: Self.bytes([4, 5, 6]).span.bytes) // 3 bytes, room for 2.
        }
    }

    // MARK: - reserveCapacity(_:)

    /// Growth keeps the unread bytes, whatever their offset, and moves them to the front.
    @Test(arguments: [(0, 0), (0, 5), (3, 5), (5, 5), (2, 8)])
    func growthKeepsTheUnreadBytes(consumed: Int, filled: Int) {
        var buffer = ByteBuffer(capacity: 8)
        let bytes = Self.pattern(filled)
        buffer.append(copying: bytes.span.bytes)
        buffer.consume(consumed)
        buffer.reserveCapacity(64)
        #expect(buffer.capacity == 64)
        #expect([UInt8](copying: buffer.unread) == Array(bytes[consumed...]))
        #expect(buffer.freeCapacity == 64 - (filled - consumed)) // At the front.
        buffer.append(copying: Self.pattern(40, seed: 9).span.bytes)
        #expect([UInt8](copying: buffer.unread) == Array(bytes[consumed...]) + Self.pattern(40, seed: 9))
    }

    @Test func growthToNoMoreIsANoOp() {
        var buffer = ByteBuffer(capacity: 8)
        buffer.append(copying: Self.bytes([1, 2, 3]).span.bytes)
        buffer.consume(1)
        buffer.reserveCapacity(8)
        buffer.reserveCapacity(2)
        #expect(buffer.capacity == 8)
        #expect(buffer.freeCapacity == 5) // Not moved.
        #expect([UInt8](copying: buffer.unread) == [2, 3])
    }

    /// A default threshold stays half the capacity; one given stays as given.
    @Test func growthScalesOnlyTheDefaultThreshold() {
        var halved = ByteBuffer(capacity: 8)
        halved.reserveCapacity(100)
        #expect(halved.compactionThreshold == 50)
        var fixed = ByteBuffer(capacity: 8, compactingBelow: 3)
        fixed.reserveCapacity(100)
        #expect(fixed.compactionThreshold == 3)
    }

    // MARK: - withFreeCapacity

    @Test func withFreeCapacityAddsWhatIsReported() {
        var buffer = ByteBuffer(capacity: 8)
        buffer.append(copying: Self.bytes([1]).span.bytes)
        let added = buffer.withFreeCapacity { span, written in
            #expect(span.byteCount == 7)
            span.storeBytes(of: 9, toByteOffset: 0, as: UInt8.self)
            span.storeBytes(of: 8, toByteOffset: 1, as: UInt8.self)
            written = 2
            return written
        }
        #expect(added == 2)
        #expect([UInt8](copying: buffer.unread) == [1, 9, 8])
        let limited = buffer.withFreeCapacity(byteCount: 3) { span, _ in span.byteCount }
        #expect(limited == 3 && buffer.unreadByteCount == 3)
    }

    @Test func withFreeCapacityAddsNothingWhenItThrows() {
        var buffer = ByteBuffer(capacity: 8)
        #expect(throws: BytesError.invalidValue) {
            try buffer.withFreeCapacity { span, written throws(BytesError) in
                span.storeBytes(of: 1, toByteOffset: 0, as: UInt8.self)
                written = 1
                throw .invalidValue
            }
        }
        let empty = buffer.isEmpty // (`#expect` can't take a `~Copyable` value's property as its whole condition.)
        #expect(empty)
    }

    // MARK: - [UInt8].append(writingUpTo:)

    @Test func arrayAppendAddsWhatTheBodyWrote() {
        var bytes: [UInt8] = [1, 2]
        let result = bytes.append(writingUpTo: 10) { output in
            #expect(output.freeCapacity == 10)
            output.append(copying: [3, 4, 5].span)
            return output.byteCount
        }
        #expect(result == 3)
        #expect(bytes == [1, 2, 3, 4, 5])
        bytes.append(writingUpTo: 0) { output in #expect(output.freeCapacity == 0) }
        #expect(bytes == [1, 2, 3, 4, 5])
    }

    @Test func arrayAppendAddsNothingWhenItThrows() {
        var bytes: [UInt8] = [1, 2]
        #expect(throws: BytesError.insufficientCapacity) {
            try bytes.append(writingUpTo: 4) { output throws(BytesError) in
                output.append(copying: [3].span)
                throw .insufficientCapacity
            }
        }
        #expect(bytes == [1, 2])
    }
}
