import Bytes
import Testing

/// `BitFlag`, `BitField`, `BitPattern`, and the one-byte and sub-byte integer reads.
@Suite struct NamedFieldTests {
    enum QoS: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }

    /// MQTT's CONNECT flags, declared once by name.
    enum ConnectFlags {
        static var userName: BitFlag { BitFlag(bit: 7) }
        static var password: BitFlag { BitFlag(bit: 6) }
        static var willRetain: BitFlag { BitFlag(bit: 5) }
        static var willQoS: BitField<QoS> { BitField(bits: 3...4) }
        static var will: BitFlag { BitFlag(bit: 2) }
        static var cleanStart: BitFlag { BitFlag(bit: 1) }
        static var reserved: BitFlag { BitFlag(bit: 0) }
    }

    /// A DOS date: yyyyyyy mmmm ddddd.
    enum DOSDate {
        static var year: BitField<Int> { BitField(bits: 9...15) }
        static var month: BitField<Nibble> { BitField(bits: 5...8) }
        static var day: BitField<Int> { BitField(offset: 0, width: 5) }
    }

    @Test func flagsAndFieldsOfAByte() throws {
        let flags: Byte = 0b1101_0110
        #expect(flags[ConnectFlags.userName])
        #expect(flags[ConnectFlags.password])
        #expect(!flags[ConnectFlags.willRetain])
        #expect(flags[ConnectFlags.willQoS] == .exactlyOnce)
        #expect(try flags.value(of: ConnectFlags.willQoS) == .exactlyOnce)
        #expect(flags[ConnectFlags.will])
        #expect(flags[ConnectFlags.cleanStart])
        #expect(flags.isClear(ConnectFlags.reserved))
        try flags.requireClear(ConnectFlags.reserved)

        // QoS 3 has no case.
        let invalid: Byte = 0b0001_1000
        #expect(invalid[ConnectFlags.willQoS] == nil)
        #expect(throws: BytesError.invalidValue) { _ = try invalid.value(of: ConnectFlags.willQoS) }
        #expect(throws: BytesError.invalidValue) { try Byte(0b1).requireClear(ConnectFlags.reserved) }
    }

    @Test func buildingAByteByName() {
        let flags = Byte {
            $0[ConnectFlags.userName] = true
            $0[ConnectFlags.willQoS] = .atLeastOnce
            $0[ConnectFlags.cleanStart] = true
        }
        #expect(flags == 0b1000_1010)

        var changed = flags
        changed[ConnectFlags.willQoS] = .exactlyOnce
        changed[ConnectFlags.userName] = false
        #expect(changed == 0b0001_0010)
        changed[ConnectFlags.willQoS] = nil
        #expect(changed == 0b0000_0010)
    }

    @Test func fieldsOfIntegers() {
        // 2026-11-16: year 46 (1980 + 46), month 11, day 16.
        var date: UInt16 = 0
        date[DOSDate.year] = 2026 - 1980
        date[DOSDate.month] = Nibble(11)
        date[DOSDate.day] = 16
        #expect(date == 46 << 9 | 11 << 5 | 16)
        #expect(1980 + date[DOSDate.year] == 2026)
        #expect(date[DOSDate.month] == 11)
        #expect(date[DOSDate.day] == 16)
        #expect(date[BitFlag(bit: 4)])
        #expect(!date.isZero(DOSDate.year))
        #expect(throws: BytesError.invalidValue) { try date.requireZero(DOSDate.day) }
    }

    @Test func positionsFromTheMostSignificantBit() {
        // A specification that numbers bit 0 on the left: bits 0–1 of a byte are its top two.
        let version = BitField<Int>(bitsFromMostSignificant: 0...1)
        #expect(version.offset == 6 && version.width == 2)
        let flag = BitFlag(bitFromMostSignificant: 0, of: 16)
        #expect(flag.bit == 15)
        #expect(Byte(0b1000_0000)[version] == 2)
        #expect(Byte.Field<Int>(bitsFromMostSignificant: 2...4).offset == 3)
    }

    @Test func bitPatterns() {
        let pattern: BitPattern = "01??_??0?"
        #expect(pattern.mask == 0b1100_0010)
        #expect(pattern.value == 0b0100_0000)
        #expect(pattern.bitCount == 8)
        #expect(Byte(0b0111_1101).matches(pattern))
        #expect(!Byte(0b0111_1111).matches(pattern))
        #expect(!Byte(0b1100_0000).matches(pattern))
        #expect(UInt8(0b0100_0000).matches("01?? ??0?"))
        #expect(UInt16(0x8001).matches("1??????? ???????1"))
        #expect(Nibble(0b1010).matches("1?10"))
    }

    @Test func bitValues() {
        #expect(Nibble(9).value == 9)
        #expect(Crumb(0).value(minus: 2) == -2)
        #expect(Crumb(3).value(minus: 2) == 1)
        #expect(Nibble(0b1010).toggled() == 0b0101)
        #expect(Bit.set.isSet && Bit.clear.isClear)
    }

    @Test func oneByteIntegers() throws {
        let bytes = try [UInt8](byteCapacity: 3) { (writer) throws(BytesError) in
            try writer.write(UInt8(200))
            try writer.write(Int8(-2))
            try writer.write(Byte(7))
        }
        #expect(bytes == [200, 0xFE, 7])
        var reader = AlignedBytesReader(bytes.span)
        #expect(try reader.peek(UInt8.self) == 200)
        #expect(try reader.read(UInt8.self) == 200)
        #expect(try reader.read(Int8.self) == -2)
        #expect(try reader.read(UInt8.self) == 7)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(UInt8.self) }

        // A bit-addressable cursor partway through a byte reads the next 8 bits.
        var bits = BytesReader([0b1010_1111, 0b0000_0000].span)
        _ = try bits.read(Nibble.self)
        #expect(try bits.read(UInt8.self) == 0b1111_0000)
    }

    @Test func subByteIntegers() throws {
        let bytes = try [UInt8](byteCapacity: 2) { (writer) throws(BytesError) in
            try writer.write(29, as: Bits<5>.self)
            try writer.write(UInt8(3), as: Bits<3>.self)
            try writer.write(QoS.exactlyOnce, as: Crumb.self)
            try writer.write(0, as: Bits<6>.self)
        }
        #expect(bytes == [0b1110_1011, 0b1000_0000])
        var reader = BytesReader(bytes.span)
        #expect(try reader.read(Int.self, as: Bits<5>.self) + 257 == 286)
        #expect(try reader.read(UInt8.self, as: Bits<3>.self) == 3)
        #expect(try reader.read(QoS.self, as: Crumb.self) == .exactlyOnce)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(Int.self, as: Bits<7>.self) }

        var buffer = BitBuffer(BytesReader([0b0001_1101].span, bitOrder: .leastSignificantFirst))
        #expect(buffer.read(Int.self, as: Bits<5>.self) == 29)
    }

    struct Permissions: OptionSet {
        let rawValue: UInt8
        static let read = Permissions(rawValue: 1 << 0)
        static let write = Permissions(rawValue: 1 << 1)
        static let execute = Permissions(rawValue: 1 << 2)
    }

    struct WideOptions: OptionSet {
        let rawValue: UInt16
        static let first = WideOptions(rawValue: 1 << 0)
        static let last = WideOptions(rawValue: 1 << 15)
    }

    @Test func optionSets() throws {
        let bytes = try [UInt8](byteCapacity: 4) { (writer) throws(BytesError) in
            try writer.write(Permissions([.read, .execute]), as: Byte.self)
            try writer.write(WideOptions([.first, .last]), as: Byte2.self, .bigEndian)
            try writer.write(Permissions.write, as: Nibble.self)
            try writer.write(Nibble(0))
        }
        #expect(bytes == [0b101, 0x80, 0x01, 0b0010_0000])
        var reader = BytesReader(bytes.span)
        #expect(try reader.read(Permissions.self, as: Byte.self) == Permissions([.read, .execute]))
        #expect(try reader.read(WideOptions.self, as: Byte2.self, .bigEndian) == WideOptions([.first, .last]))
        #expect(try reader.read(Permissions.self, as: Nibble.self) == .write)
    }

    @Test func signedFields() throws {
        let bytes = try [UInt8](byteCapacity: 10) { (writer) throws(BytesError) in
            try writer.write(Int32(-2), asSigned: Byte4.self, .littleEndian)
            try writer.write(-2, asSigned: Byte3.self, .bigEndian)
            try writer.write(Int8(-3), asSigned: Nibble.self)
            try writer.write(7, asSigned: Nibble.self)
            try writer.write(300, as: Byte2.self, .bigEndian)
        }
        #expect(bytes == [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0xD7, 0x01, 0x2C])
        var reader = BytesReader(bytes.span)
        #expect(try reader.read(Int32.self, asSigned: Byte4.self, .littleEndian) == -2)
        #expect(try reader.read(Int.self, asSigned: Byte3.self, .bigEndian) == -2)
        #expect(try reader.read(Int.self, asSigned: Nibble.self) == -3)
        #expect(try reader.read(Int8.self, asSigned: Nibble.self) == 7)
        #expect(try reader.read(Int.self, as: Byte2.self, .bigEndian) == 300)

        var buffer = BitBuffer(BytesReader([0b1111_1110].span, bitOrder: .leastSignificantFirst))
        #expect(buffer.read(Int.self, asSigned: Nibble.self) == -2)
    }

    @Test func byteCountsOfAnyIntegerType() throws {
        let data: [UInt8] = [1, 2, 3, 4, 5, 6]
        var reader = AlignedBytesReader(data.span)
        try reader.skip(byteCount: UInt16(1))
        #expect(try reader.read(byteCount: UInt64(2)).byteCount == 2)
        var section = try reader.readSection(byteCount: UInt32(2))
        #expect(try section.read(UInt8.self) == 4)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(byteCount: UInt64.max) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(byteCount: Int32(-1)) }
        #expect(throws: BytesError.insufficientData) { try reader.skip(byteCount: UInt8(2)) }
        #expect(reader.remainingByteCount == 1)
    }
}
