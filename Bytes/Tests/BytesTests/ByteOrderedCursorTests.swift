import Bytes
import Testing

/// `BigEndianBytesReader`/`Writer` and the little-endian pair: integers by type, without an order per call.
@Suite struct ByteOrderedCursorTests {
    enum Kind: UInt16 { case data = 0x0102, control = 0x0304 }

    @Test func bigEndianRoundTrip() throws {
        var storage = [UInt8](repeating: 0, count: 26)
        var output = storage.mutableSpan
        var writer = BigEndianBytesWriter(&output)
        try writer.write(UInt32(0x8950_4E47))
        try writer.write(UInt16(0x0102))
        try writer.write(Int16(-2))
        try writer.write(0x0A0B0C, as: Byte3.self)
        try writer.write(-3, asSigned: Byte3.self)
        try writer.write(Kind.control, as: Byte2.self)
        try writer.write(7 as UInt8) // A bare literal is ambiguous: its width must be stated.
        try writer.write(UInt8(8))
        try writer.write(Int64(-1))
        #expect(writer.byteCount == 26)
        _ = consume writer
        #expect(storage == [0x89, 0x50, 0x4E, 0x47, 1, 2, 0xFF, 0xFE, 0x0A, 0x0B, 0x0C, 0xFF, 0xFF, 0xFD, 3, 4, 7, 8,
                            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        var reader = BigEndianBytesReader(storage.span)
        try reader.expect(0x8950_4E47 as UInt32)
        #expect(try reader.peek(UInt16.self) == 0x0102)
        #expect(try reader.read(UInt16.self) == 0x0102)
        #expect(try reader.read(Int16.self) == -2)
        #expect(try reader.read(Int.self, as: Byte3.self) == 0x0A0B0C)
        #expect(try reader.read(Int.self, asSigned: Byte3.self) == -3)
        #expect(try reader.read(Kind.self, as: Byte2.self) == .control)
        #expect(try reader.read(UInt8.self) == 7)
        #expect(try reader.read(Byte.self) == 8)
        #expect(try reader.read(Int64.self) == -1)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(UInt8.self) }
    }

    @Test func littleEndianMatchesExplicitOrder() throws {
        let data: [UInt8] = [0x04, 0x03, 0x02, 0x01, 0x02, 0x01, 0x02, 0x00, 0xAA, 0xBB, 0x02]
        var ordered = LittleEndianBytesReader(data.span)
        var explicit = AlignedBytesReader(data.span)
        #expect(try ordered.read(UInt32.self) == explicit.read(Byte4.self, .littleEndian))
        #expect(try ordered.read(Kind.self, as: Byte2.self) == explicit.read(Kind.self, as: Byte2.self, .littleEndian))
        var section = try ordered.read(sectionPrefixedBy: Byte2.self)
        #expect(try section.read(UInt16.self) == 0xBBAA)
        #expect(throws: BytesError.mismatch) { try ordered.expect(UInt8(1)) }

        var storage = [UInt8](repeating: 0, count: 4)
        var output = storage.mutableSpan
        var writer = LittleEndianBytesWriter(&output)
        try writer.write(UInt32(0x0102_0304))
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(UInt16(1)) }
        _ = consume writer
        #expect(storage == [4, 3, 2, 1])
    }
}
