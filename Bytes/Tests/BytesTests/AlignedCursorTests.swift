import Bytes
import Testing

/// `AlignedBytesReader` and `AlignedBytesWriter`: the byte-level API, with no bit state.
@Suite struct AlignedCursorTests {
    enum Code: UInt8 { case zero, one, two }

    /// A message of every byte-level field kind, written by `write`.
    static func write<Mode: BytesCursorMode>(_ writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
        try writer.write(0x7F as Byte)
        try writer.write(0x0102 as Byte2)
        try writer.write(0x0304_05, as: Byte3.self, .bigEndian)
        try writer.write(300, as: LEB128.self)
        try writer.write(Code.two, as: Byte.self)
        try writer.write(([0xAA, 0xBB] as [UInt8]).span.bytes, prefixedBy: Byte2.self, .littleEndian)
        try writer.write(repeating: 0xEE as Byte, count: 3)
        try writer.copy(fromDistance: 3, count: 2)
    }

    @Test func alignedWriterWritesWhatTheBitAddressableOneDoes() throws {
        let aligned = try [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in try Self.write(&writer) }
        let plain = try [UInt8](byteCapacity: 64) { (writer) throws(BytesError) in try Self.write(&writer) }
        #expect(aligned == plain)
        #expect(aligned.count == 1 + 2 + 3 + 2 + 1 + 4 + 3 + 2)
    }

    @Test func alignedReaderReadsEveryFieldKind() throws {
        let bytes = try [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in try Self.write(&writer) }
        var reader = AlignedBytesReader(bytes.span)
        #expect(try reader.read(Byte.self) == 0x7F)
        #expect(try reader.read(Byte2.self) == 0x0102 as Byte2)
        #expect(try reader.read(Byte3.self, .bigEndian) == 0x0304_05)
        #expect(try reader.read(LEB128.self) == 300)
        #expect(try reader.read(Code.self, as: Byte.self) == .two)
        var section = try reader.read(sectionPrefixedBy: Byte2.self, .littleEndian)
        #expect(try section.read(Byte2.self, .bigEndian) == 0xAABB)
        try section.expectEnd()
        _ = consume section
        try reader.expect(0xEE as Byte)
        #expect(try reader.read(byteCount: 4).byteCount == 4)
        let atEnd = reader.isAtEnd
        #expect(atEnd)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(Byte.self) }
    }

    @Test func positionsAndAtomicReads() throws {
        let bytes: [UInt8] = [1, 2, 3, 4]
        var reader = AlignedBytesReader(bytes.span)
        let start = reader.position
        _ = try reader.read(Byte2.self)
        reader.rewind(to: start)
        #expect(reader.byteOffset == 0)
        #expect(throws: BytesError.insufficientData) {
            try reader.atomically { copy throws(BytesError) in _ = try copy.read(Byte8.self) }
        }
        #expect(reader.byteOffset == 0)
        try reader.seek(toByteOffset: 3)
        #expect(try reader.read(Byte.self) == 4)
    }

    @Test func convertingBetweenModes() throws {
        let bytes: [UInt8] = [0b1010_0000, 0x12, 0x34]
        var bits = BytesReader(bytes.span)
        #expect(try bits.read(Crumb.self) == 0b10)
        // Partway through a byte: not convertible. (Not in `#expect(throws:)`: its closure can't consume a
        // captured cursor.)
        do throws(BytesError) {
            _ = try AlignedBytesReader(bits)
            Issue.record("Converted a cursor partway through a byte")
        } catch {
            #expect(error == .misaligned)
        }
        var again = BytesReader(bytes.span)
        _ = try again.read(Nibble.self)
        again.alignToByte()
        var aligned = try AlignedBytesReader(again)
        #expect(try aligned.read(Byte2.self, .bigEndian) == 0x1234)

        var back = BytesReader(AlignedBytesReader(bytes.span))
        #expect(try back.read(Nibble.self) == 0b1010)
    }

    @Test func outputSpanBuilders() throws {
        var output = [UInt8](repeating: 0, count: 8)
        let written = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try span.withAlignedBytesWriter { writer throws(BytesError) in try writer.write(0x0A0B as Byte2) }
            return span.byteCount
        }
        #expect(written == 2 && output[0] == 0x0A && output[1] == 0x0B) // `Byte2` literals are in memory order.

        var array: [UInt8] = [9]
        try array.append(alignedByteCapacity: 4) { writer throws(BytesError) in try writer.write(7 as Byte) }
        #expect(array == [9, 7])

        let text = String(utf8Capacity: 5) { writer in try! writer.write(Array("hello".utf8).span) }
        #expect(text == "hello")
    }
}
