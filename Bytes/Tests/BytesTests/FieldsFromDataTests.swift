import Bytes
import Testing

// Lengths, widths, and terminators that come from the data: negative counts throw, integers of a run-time
// width, terminated text, and padded tag-length-value records.

@Suite struct FieldsFromDataTests {
    static let bytes: [UInt8] = Array(0..<40)

    // MARK: Negative counts

    @Test func negativeCountsThrowInsteadOfTrapping() throws {
        var reader = AlignedBytesReader(Self.bytes.span)
        try reader.skip(byteCount: 2)
        let blockLength = 8, headerLength = 12
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(byteCount: blockLength - headerLength) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.readSection(byteCount: -1) }
        #expect(throws: BytesError.invalidValue) { try reader.skip(byteCount: -4) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.readUTF8(byteCount: -1) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(UInt32.self, count: -1) }
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(byteCount: 39) }
        #expect(reader.byteOffset == 2)

        var bits = BytesReader(Self.bytes.span)
        #expect(throws: BytesError.invalidValue) { try bits.skip(bitCount: -1) }
        #expect(throws: BytesError.invalidValue) { try bits.skip(byteCount: -1) }
        #expect(bits.bitPosition == 0)
    }

    // MARK: Integers of a run-time width

    @Test(arguments: 1...8)
    func runTimeWidthsMatchFixedOnes(byteCount: Int) throws {
        // Far from the end (one 8-byte load) and at it (a byte at a time).
        for start in [0, Self.bytes.count - byteCount] {
            var reader = try AlignedBytesReader(Self.bytes.span.bytes, atByteOffset: start)
            var expectedBig: UInt64 = 0, expectedLittle: UInt64 = 0
            for index in 0..<byteCount {
                expectedBig = expectedBig << 8 | UInt64(Self.bytes[start + index])
                expectedLittle |= UInt64(Self.bytes[start + index]) << (8 * index)
            }
            #expect(try reader.read(UInt64.self, byteCount: byteCount, .bigEndian) == expectedBig)
            #expect(reader.byteOffset == start + byteCount)
            try reader.seek(toByteOffset: start)
            #expect(try reader.read(UInt64.self, byteCount: byteCount, .littleEndian) == expectedLittle)

            var ordered = try BigEndianBytesReader(Self.bytes.span.bytes, atByteOffset: start)
            #expect(try ordered.read(UInt64.self, byteCount: byteCount) == expectedBig)
        }
    }

    @Test func signedRunTimeWidths() throws {
        let negative: [UInt8] = [0xFF, 0xFE, 0x80, 0x00, 0x7F]
        var reader = BigEndianBytesReader(negative.span)
        #expect(try reader.read(Int.self, signedByteCount: 2) == -2)
        #expect(try reader.read(Int16.self, signedByteCount: 2) == Int16(bitPattern: 0x8000))
        #expect(try reader.read(Int8.self, signedByteCount: 1) == 127)

        // The widths that don't fit the type, and widths that aren't 1 through 8, consume nothing.
        var wide = BigEndianBytesReader(Self.bytes.span.extracting(30...))
        #expect(throws: BytesError.invalidValue) { _ = try wide.read(UInt8.self, byteCount: 2) }
        #expect(throws: BytesError.invalidValue) { _ = try wide.read(Int.self, byteCount: 0) }
        #expect(throws: BytesError.invalidValue) { _ = try wide.read(Int.self, byteCount: 9) }
        #expect(wide.byteOffset == 0)
        var short = BigEndianBytesReader(Self.bytes.span.extracting(36...))
        #expect(throws: BytesError.insufficientData) { _ = try short.read(UInt64.self, byteCount: 5) }
        #expect(short.byteOffset == 0)
    }

    @Test func runTimeWidthsAtABitOffset() throws {
        var reader = BytesReader(Self.bytes.span)
        try reader.skip(bitCount: 4)
        // 0x00 0x01 0x02, from bit 4: 0x00102 then 4 bits of 0x03 → 0x0010_2003 >> 4.
        let value = try reader.read(UInt32.self, byteCount: 3, .bigEndian)
        var check = BytesReader(Self.bytes.span)
        try check.skip(bitCount: 4)
        #expect(try value == UInt32(check.read(Byte3.self, .bigEndian)))
        #expect(reader.bitPosition == 28)
    }

    @Test func runTimeWidthWritesRoundTrip() throws {
        let bytes = try [UInt8](byteCapacity: 16, mode: BigEndianBytes.self) { (writer) throws(BytesError) in
            try writer.write(0x0102_03, byteCount: 3)
            try writer.write(-2, signedByteCount: 2)
            try writer.write(UInt64.max, byteCount: 8)
            try writer.write(0x0405, byteCount: 2, .littleEndian)
        }
        #expect(bytes == [1, 2, 3, 0xFF, 0xFE] + Array(repeating: 0xFF, count: 8) + [5, 4])
        #expect(throws: BytesError.invalidValue) {
            _ = try [UInt8](byteCapacity: 8, mode: BigEndianBytes.self) { (writer) throws(BytesError) in try writer.write(256, byteCount: 1) }
        }
        #expect(throws: BytesError.invalidValue) {
            _ = try [UInt8](byteCapacity: 8, mode: BigEndianBytes.self) { (writer) throws(BytesError) in try writer.write(-1, byteCount: 2) }
        }
        #expect(throws: BytesError.invalidValue) {
            _ = try [UInt8](byteCapacity: 8, mode: BigEndianBytes.self) { (writer) throws(BytesError) in try writer.write(128, signedByteCount: 1) }
        }
    }

    // MARK: Terminators

    @Test(arguments: 0...70)
    func firstByteOffsetFindsTheFirstMatch(count: Int) {
        for target in [-1] + Array(0..<count) {
            // Matches at `target` and after it, never before; the other bytes all different (every value, so
            // none can look like a match).
            var bytes = (0..<count).map { UInt8(truncatingIfNeeded: 0x70 &+ $0 &* 37) | 1 }
            if target >= 0 {
                for index in stride(from: target, to: count, by: 3) {
                    bytes[index] = 0
                }
            }
            #expect(bytes.span.bytes.firstByteOffset { $0.matching(0) } == (target >= 0 ? target : nil), "\(count), \(target)")
        }
    }

    @Test func terminatedText() throws {
        let bytes: [UInt8] = Array("name\0.text\0\0unterminated".utf8)
        var reader = AlignedBytesReader(bytes.span)
        #expect(try String(copying: reader.read(utf8TerminatedBy: 0)) == "name")
        #expect(try String(copying: reader.read(utf8TerminatedBy: 0)) == ".text")
        #expect(try reader.read(bytesTerminatedBy: 0).byteCount == 0)
        let before = reader.byteOffset
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(bytesTerminatedBy: 0) }
        #expect(reader.byteOffset == before)

        let invalid: [UInt8] = [0x61, 0xFF, 0x00]
        var invalidReader = AlignedBytesReader(invalid.span)
        #expect(throws: BytesError.invalidValue) { _ = try invalidReader.read(utf8TerminatedBy: 0) }
        #expect(invalidReader.byteOffset == 0)

        let line = "a line".utf8Span
        let written = try [UInt8](byteCapacity: 16) { (writer) throws(BytesError) in try writer.write(line, terminatedBy: 0x0A) }
        #expect(written == Array("a line\n".utf8))
        #expect(throws: BytesError.invalidValue) {
            _ = try [UInt8](byteCapacity: 16) { (writer) throws(BytesError) in try writer.write("a\0b".utf8Span, terminatedBy: 0) }
        }
        #expect(throws: BytesError.insufficientCapacity) {
            _ = try [UInt8](byteCapacity: 6) { (writer) throws(BytesError) in try writer.write(line, terminatedBy: 0) }
        }
    }

    // MARK: Padded records

    @Test func paddedRecords() throws {
        // PCAPNG-style options: code, length, value padded to 4.
        let options: [UInt8] = [1, 0, 3, 0, 0x61, 0x62, 0x63, 0xEE, 2, 0, 4, 0, 1, 2, 3, 4, 0, 0, 0, 0]
        var reader = LittleEndianBytesReader(options.span)
        var seen: [(UInt16, Int)] = []
        try reader.forEachRecord(tag: Byte2.self, length: Byte2.self, paddedTo: 4) { code, value throws(BytesError) in
            seen.append((code, value.remainingByteCount))
        }
        #expect(seen.map(\.0) == [1, 2, 0] && seen.map(\.1) == [3, 4, 0])
        #expect(reader.isAtEnd == true)

        // The last value's padding missing.
        let cut: [UInt8] = [1, 0, 3, 0, 0x61, 0x62, 0x63]
        var cutReader = LittleEndianBytesReader(cut.span)
        #expect(throws: BytesError.insufficientData) {
            try cutReader.forEachRecord(tag: Byte2.self, length: Byte2.self, paddedTo: 4) { _, _ throws(BytesError) in }
        }
        #expect(cutReader.byteOffset == 0)
    }
}
