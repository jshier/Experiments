import Bytes
import Testing

/// Flags, signed values, bit-field helpers, records, errors with locations, and the small conveniences.
@Suite struct FieldHelperTests {
    // MARK: Flags

    @Test func boolReadsAndWrites() throws {
        let bytes = try [UInt8](byteCapacity: 1) { (writer) throws(BytesError) in
            try writer.write(true)
            try writer.write(false)
            try writer.write(true)
            try writer.write(Bits<5>(0))
        }
        #expect(bytes == [0b1010_0000])
        var reader = BytesReader(bytes.span)
        // (`#expect` can't take a call on a non-copyable cursor as its whole condition: compare instead.)
        #expect(try reader.peek(Bool.self) == true)
        #expect(try reader.read(Bool.self) == true)
        #expect(try reader.read(Bool.self) == false)
        #expect(try reader.read(Bool.self) == true)

        var lsb = BitBuffer(BytesReader([0b0000_0101].span, bitOrder: .leastSignificantFirst))
        let flags = (lsb.read(Bool.self), lsb.read(Bool.self), lsb.read(Bool.self))
        #expect(flags == (true, false, true))
    }

    // MARK: Signed values

    @Test func signedGroupReads() throws {
        let data: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0x00, 0x00, 0x7F]
        var reader = BytesReader(data.span)
        #expect(try reader.readSigned(Byte4.self, .littleEndian, as: Int32.self) == -2)
        #expect(try reader.readSigned(Byte3.self, .bigEndian, as: Int32.self) == -2)
        #expect(try reader.readSigned(Byte3.self, .bigEndian) == 127)
        #expect(reader.remainingByteCount == 0)
        #expect(throws: BytesError.insufficientData) { try reader.readSigned(Byte2.self, .bigEndian, as: Int16.self) }
    }

    @Test func signedBitReads() throws {
        // 12 bits of 0xFFF (-1), then 4 bits of 0b0111 (7), most significant first; then the same values
        // least significant first.
        var reader = BytesReader([0xFF, 0xF7].span)
        #expect(try reader.readSigned(bitCount: 12) == -1)
        #expect(try reader.readSigned(bitCount: 4) == 7)
        var lsb = BytesReader([0x00, 0x08].span, bitOrder: .leastSignificantFirst)
        #expect(try lsb.readSigned(bitCount: 12) == -2048)
        #expect(try lsb.readSigned(bitCount: 4) == 0)
        var full = BytesReader([UInt8](repeating: 0xFF, count: 8).span)
        #expect(try full.readSigned(bitCount: 64) == -1)
        var buffer = BitBuffer(BytesReader([0x0E].span, bitOrder: .leastSignificantFirst))
        #expect(buffer.readSigned(bitCount: 4) == -2)
    }

    @Test func signedFields() {
        let word: UInt32 = 0x0000_FFF0
        #expect(word.signedBits(4..<16, as: Int32.self) == -1)
        #expect(word.signedBits(4..<17, as: Int32.self) == 4095)
        #expect(UInt8(0x80).signedBits(0..<8, as: Int8.self) == -128)
        #expect(UInt64.max.signedBits(0..<64) == -1)
        #expect((0b1111 as Nibble).signedValue == -1)
        #expect((0b0111 as Nibble).signedValue == 7)
        #expect((0b1000 as Nibble).signedValue == -8)
        #expect((0x80 as Byte).signedValue == -128)
        #expect((1 as Bit).signedValue == -1)
    }

    // MARK: Bit-field helpers

    @Test func uncheckedBitRanges() {
        let value: UInt64 = 0xABCD_EF01_2345_6789
        for low in 0..<64 {
            for high in low..<64 {
                #expect(value.bits(from: low, upTo: high) == value[bits: low..<high])
            }
        }
        #expect(value.bits(from: 7, upTo: 7) == 0)
    }

    @Test func lowBitMasks() {
        #expect(UInt64.lowBitMask(0) == 0)
        #expect(UInt64.lowBitMask(1) == 1)
        #expect(UInt64.lowBitMask(63) == .max >> 1)
        #expect(UInt64.lowBitMask(64) == .max)
        #expect(UInt64.lowBitMask(70) == .max)
        #expect(UInt8.lowBitMask(8) == 0xFF)
        #expect(Int32.lowBitMask(32) == -1)
        #expect(UInt32(0xFFFF_FFFF).keepingLowBits(12) == 0xFFF)
        #expect(UInt32(0xFFFF_FFFF).keepingLowBits(32) == 0xFFFF_FFFF)
        #expect(UInt32(0xFFFF_FFFF).keepingLowBits(0) == 0)
    }

    @Test func maskedMatches() throws {
        // LZ4 frame flags: version 01 (bits 6–7), reserved bit 1 clear, independent blocks (bit 5).
        let flags: UInt8 = 0b0110_0100
        #expect(flags.matches(0b0110_0000, mask: 0b1110_0010))
        #expect(!UInt8(0b1010_0000).matches(0b0110_0000, mask: 0b1110_0010))
        #expect((0b0110_0101 as Byte).matches(0b0110_0000, mask: 0b1110_0010))
        #expect(!(0b0110_0111 as Byte).matches(0b0110_0000, mask: 0b1110_0010))
        #expect((0x12_01 as Byte2).matches(0x00_01, mask: 0x00_FF))
        #expect(!(0x12_02 as Byte2).matches(0x00_01, mask: 0x00_FF))

        var reader = BytesReader([0x34, 0x01, 0x34, 0x02, 0b1010_0000].span)
        try reader.expect(0x00_01 as Byte2, mask: 0x00_FF)
        #expect(throws: BytesError.mismatch) { try reader.expect(0x00_01 as Byte2, mask: 0x00_FF) }
        #expect(reader.byteOffset == 2)
        try reader.skip(byteCount: 2)
        try reader.expect(0b1000 as Nibble, mask: 0b1100)
        #expect(throws: BytesError.mismatch) { try reader.expect(0b0100 as Nibble, mask: 0b1100) }
    }

    @Test func rawBitsOf() {
        enum QoS: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }
        #expect(Crumb(rawBitsOf: QoS.exactlyOnce) == 0b10)
        var options: Byte = 0
        options[Crumb.self, at: 0] = Crumb(rawBitsOf: QoS.atLeastOnce)
        #expect(options == 0b01)
        #expect(QoS(rawBits: Crumb(rawBitsOf: QoS.exactlyOnce)) == .exactlyOnce)
    }

    // MARK: Records

    /// Zip extra fields: a 2-byte id and a 2-byte size, little-endian.
    let extra: [UInt8] = [0x55, 0x54, 0x05, 0x00, 0x01, 0x10, 0x00, 0x00, 0x00, // 0x5455, 5 bytes
                          0x01, 0x00, 0x00, 0x00, // 0x0001, empty
                          0xAA, 0xBB] // too short for a header: left unread

    @Test func records() throws {
        var reader = BytesReader(extra.span)
        var seen: [(UInt16, Int)] = []
        try reader.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { id, field throws(BytesError) in
            seen.append((id, field.remainingByteCount))
            if id == 0x5455 {
                #expect(try field.read(Byte.self) == 0x01)
                #expect(try field.read(Byte4.self, .littleEndian) == 0x10)
            }
        }
        #expect(seen.map(\.0) == [0x5455, 0x0001])
        #expect(seen.map(\.1) == [5, 0])
        #expect(reader.byteOffset == 13)
    }

    @Test func recordsAreAllOrNothing() throws {
        // The second record claims 9 bytes, with 2 there: it throws, and the cursor stays at its start.
        let truncated: [UInt8] = [0x01, 0x00, 0x01, 0x00, 0xFF, 0x02, 0x00, 0x09, 0x00, 0xAA, 0xBB]
        var reader = BytesReader(truncated.span)
        var count = 0
        #expect(throws: BytesError.insufficientData) {
            try reader.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { _, _ throws(BytesError) in
                count += 1
            }
        }
        #expect(count == 1)
        #expect(reader.byteOffset == 5)

        // A body that throws leaves the cursor at the start of its record.
        var again = BytesReader(extra.span)
        #expect(throws: BytesError.mismatch) {
            try again.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { id, _ throws(BytesError) in
                if id == 0x0001 { throw .mismatch }
            }
        }
        #expect(again.byteOffset == 9)
    }

    // MARK: Errors with their location

    @Test func locatedErrors() throws {
        let data: [UInt8] = [0x50, 0x4B, 0x01, 0x02, 0x50, 0x4B, 0x09, 0x09]
        var reader = BytesReader(data.span)
        do throws(BytesError) {
            while !reader.isAtEnd {
                try reader.expect(0x50_4B_01_02 as Byte4)
            }
            Issue.record("expected a mismatch")
        } catch {
            let located = reader.located(error)
            #expect(located == LocatedBytesError(.mismatch, byteOffset: 4))
        }
    }

    // MARK: Small conveniences

    @Test func readRemainingBytes() throws {
        var reader = BytesReader([1, 2, 3, 4, 5].span)
        _ = try reader.read(Byte2.self)
        let rest = reader.readRemainingBytes()
        #expect([UInt8](copying: rest) == [3, 4, 5])
        #expect(reader.remainingByteCount == 0)
        #expect(reader.readRemainingBytes().byteCount == 0)
    }

    @Test func checksumContinuing() {
        let data: [UInt8] = Array("The quick brown fox jumps over the lazy dog".utf8)
        let whole = CRC32.checksum(data.span.bytes)
        #expect(whole == 0x414F_A339)
        let first = CRC32.checksum(data.span.bytes.extracting(first: 10))
        #expect(CRC32.checksum(data.span.bytes.extracting(droppingFirst: 10), continuing: first) == whole)
        #expect(CRC32.checksum(data.span.extracting(droppingFirst: 10), continuing: first) == whole)
        #expect(CRC32.checksum(RawSpan(), continuing: whole) == whole)
    }

    @Test func prefixes() {
        func isShared(_ topic: String) -> Bool {
            Array(topic.utf8).span.bytes.hasPrefix(0x24_73_68_61_72_65_2F as Byte7) // "$share/"
        }
        #expect(isShared("$share/group/a"))
        #expect(isShared("$share/"))
        #expect(!isShared("$shar"))
        #expect(!isShared("$sys/abc"))
    }

    @Test func appendCopying() {
        var bytes: [UInt8] = [1, 2]
        let more: [UInt8] = Array(3...70)
        bytes.append(copying: more.span.bytes)
        #expect(bytes == Array(1...70))
        bytes.append(copying: RawSpan())
        #expect(bytes.count == 70)
    }

    @Test func stringBuilder() throws {
        let text = try String(utf8Capacity: 5) { writer throws(BytesError) in
            try writer.write(0x68_65_6C_6C_6F as Byte5)
        }
        #expect(text == "hello")
        let partial = try String(utf8Capacity: 64) { writer throws(BytesError) in try writer.write(0x6F_6B as Byte2) }
        #expect(partial == "ok")
        #expect(throws: BytesError.insufficientCapacity) {
            try String(utf8Capacity: 1) { writer throws(BytesError) in try writer.write(0x6F_6B as Byte2) }
        }
    }

    @Test func vectors() {
        let group: Byte16 = 0x00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F
        let vector = group.vector
        for lane in 0..<16 {
            #expect(vector[lane] == UInt8(lane))
        }
        #expect(Byte16(vector) == group)
    }
}
