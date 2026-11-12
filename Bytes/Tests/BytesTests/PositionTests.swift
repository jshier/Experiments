import Bytes
import Testing

/// `position`/`rewind(to:)`, and cursors created at an offset.
@Suite struct PositionTests {
    let data: [UInt8] = (0..<32).map { UInt8($0) }

    @Test func rewindUndoesByteAndBitReads() throws {
        var reader = BytesReader(data.span)
        try reader.skip(byteCount: 3)
        _ = try reader.read(Bits<3>.self)
        let mark = reader.position
        #expect(mark.byteOffset == 3 && mark.bitOffset == 3 && mark.bitPosition == 27)
        let first = try reader.read(Byte2.self, .bigEndian)
        _ = try reader.read(Bit.self)
        try reader.skip(byteCount: 5)
        reader.rewind(to: mark)
        let back = reader.position
        #expect(back == mark)
        #expect(try reader.read(Byte2.self, .bigEndian) == first)

        // Rewinding to where the cursor already is changes nothing.
        let here = reader.position
        reader.rewind(to: here)
        let same = reader.position
        #expect(same == here)
    }

    @Test func rewindAfterAFailedMessage() throws {
        // A length-prefixed message whose body hasn't fully arrived: read what's there, then rewind.
        let partial: [UInt8] = [0x01, 0x00, 0x05, 0xAA, 0xBB]
        var reader = BytesReader(partial.span)
        let start = reader.position
        do {
            _ = try reader.read(Byte.self)
            let length = try Int(reader.read(Byte2.self, .bigEndian))
            _ = try reader.read(byteCount: length)
            Issue.record("expected insufficient data")
        } catch {
            #expect(error == .insufficientData)
            reader.rewind(to: start)
        }
        let rewound = reader.byteOffset
        #expect(rewound == 0)
    }

    @Test func readersAtAnOffset() throws {
        var reader = try BytesReader(data.span.bytes, atByteOffset: UInt64(10))
        #expect(try reader.read(Byte.self) == 10)
        var end = try BytesReader(data.span.bytes, atByteOffset: 32)
        let atEnd = end.isAtEnd
        #expect(atEnd)
        #expect(throws: BytesError.insufficientData) { _ = try BytesReader(data.span.bytes, atByteOffset: 33) }
        #expect(throws: BytesError.insufficientData) { _ = try BytesReader(data.span.bytes, atByteOffset: UInt64.max) }
        #expect(throws: BytesError.invalidValue) { _ = try BytesReader(data.span.bytes, atByteOffset: -1) }
        #expect(throws: BytesError.invalidValue) { _ = try BytesReader(data.span.bytes, atByteOffset: Int8(-1)) }
        _ = try end.read(byteCount: 0)

        var bits = try BytesReader(data.span.bytes, atBitPosition: 8 * 5 + 4, bitOrder: .leastSignificantFirst)
        #expect(try bits.read(Nibble.self) == Nibble(5 >> 4))
        let offset = bits.byteOffset
        #expect(offset == 6)
        #expect(throws: BytesError.insufficientData) { _ = try BytesReader(data.span.bytes, atBitPosition: 8 * 32 + 1) }
    }

    @Test(arguments: [BitOrder.leastSignificantFirst, .mostSignificantFirst])
    func bitBufferAtABitPosition(order: BitOrder) throws {
        for position in [0, 3, 8, 13, 64, 100] {
            var expected = try BytesReader(data.span.bytes, atBitPosition: position, bitOrder: order)
            var bits = try BitBuffer(data.span.bytes, atBitPosition: position, bitOrder: order)
            #expect(bits.bitPosition == position)
            bits.refill()
            #expect(try bits.read(Bits<7>.self) == (expected.read(Bits<7>.self)), "\(position)")
        }
        #expect(throws: BytesError.invalidValue) { _ = try BitBuffer(data.span.bytes, atBitPosition: -1, bitOrder: order) }
    }

    @Test func writerAfterAPrefix() throws {
        var buffer: [UInt8] = [1, 2, 3, 0, 0, 0]
        var span = buffer.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        var writer = try BytesWriter(&raw, atByteOffset: 3)
        #expect(writer.byteCount == 3)
        try writer.copy(fromDistance: 3, count: 3) // The prefix counts as written: it can be copied from.
        #expect(Array(writer.writtenBytes.withUnsafeBytes { Array($0) }) == [1, 2, 3, 1, 2, 3])
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(Byte(9)) }
        _ = consume writer
        #expect(throws: BytesError.insufficientCapacity) { _ = try BytesWriter(&raw, atByteOffset: 7) }
        #expect(throws: BytesError.invalidValue) { _ = try BytesWriter(&raw, atByteOffset: -1) }
        _ = consume raw
        _ = consume span
        #expect(buffer == [1, 2, 3, 1, 2, 3])
    }
}
