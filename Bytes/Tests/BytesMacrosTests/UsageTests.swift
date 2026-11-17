import BytesMacros
import Testing

enum QualityOfService: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }

@BitFields(Byte.self, reserved: 0...0)
struct ConnectFlags: Equatable {
    @Flag(bit: 7) var userName: Bool
    @Flag(bit: 6) var password: Bool
    @Flag(bit: 5) var willRetain: Bool
    @Field(bits: 3...4) var willQoS: QualityOfService
    @Flag(bit: 2) var will: Bool
    @Flag(bit: 1) var cleanStart: Bool
}

@BitFields(UInt16.self, .littleEndian)
struct DOSDate: Equatable {
    @Field(bits: 9...15) var yearsSince1980: Int
    @Field(bits: 5...8) var month: Int
    @Field(bits: 0...4) var day: Int
}

@BitFields(Byte.self)
struct Specification: Equatable {
    @Field(bitsFromMostSignificant: 0...1) var version: Crumb
    @Flag(bitFromMostSignificant: 2) var marker: Bool
    @Field(bitsFromMostSignificant: 3...7) var length: UInt8
}

enum CompressionMethod: UInt16 { case stored = 0, deflate = 8 }

@BinaryRecord(.littleEndian)
struct Header: Equatable {
    @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
    @Field(Byte2.self) var version: Int
    @Field(Byte2.self) var method: CompressionMethod
    var date: DOSDate
    @Field(Byte4.self) var offset: Int32
    @Field(Byte3.self) var length: UInt32
}

@Suite struct UsageTests {
    @Test func bitFieldsRoundTrip() throws {
        let flags = ConnectFlags(userName: true, password: false, willRetain: true, willQoS: .exactlyOnce, will: true, cleanStart: false)
        #expect(flags.rawValue == 0b1011_0100)
        #expect(try ConnectFlags(rawValue: 0b1011_0100) == flags)
        #expect(ConnectFlags.byteCount == 1)

        let bytes = try [UInt8](byteCapacity: 1) { (writer) throws(BytesError) in try writer.write(flags) }
        var reader = AlignedBytesReader(bytes.span)
        #expect(try reader.read(ConnectFlags.self) == flags)

        // A reserved bit, and QoS 3.
        #expect(throws: BytesError.invalidValue) { _ = try ConnectFlags(rawValue: 0b0000_0001) }
        #expect(throws: BytesError.invalidValue) { _ = try ConnectFlags(rawValue: 0b0001_1000) }
    }

    @Test func wideAndMostSignificantFields() throws {
        let date = DOSDate(yearsSince1980: 46, month: 11, day: 16)
        #expect(date.rawValue == 46 << 9 | 11 << 5 | 16)
        let bytes = try [UInt8](byteCapacity: 2) { (writer) throws(BytesError) in try writer.write(date) }
        #expect(bytes == [UInt8(truncatingIfNeeded: date.rawValue), UInt8(date.rawValue >> 8)])
        var reader = BytesReader(bytes.span)
        #expect(try reader.read(DOSDate.self) == date)

        let specification = try Specification(rawValue: 0b10_1_00110)
        #expect(specification.version == 0b10 && specification.marker && specification.length == 6)
    }

    @Test func recordsRoundTrip() throws {
        let header = Header(version: 20, method: .deflate, date: DOSDate(yearsSince1980: 1, month: 2, day: 3), offset: -5, length: 0xABCDEF)
        #expect(Header.byteCount == 17)
        let bytes = try [UInt8](byteCapacity: Header.byteCount) { (writer) throws(BytesError) in try writer.write(header) }
        #expect(bytes.prefix(4) == [0x50, 0x4B, 0x03, 0x04])
        var reader = AlignedBytesReader(bytes.span)
        #expect(try reader.read(Header.self) == header)
        #expect(reader.isAtEnd == true)
    }

    @Test func recordsConsumeNothingWhenTheyThrow() throws {
        var bytes = try [UInt8](byteCapacity: Header.byteCount) { (writer) throws(BytesError) in
            try writer.write(Header(version: 20, method: .deflate, date: DOSDate(yearsSince1980: 1, month: 2, day: 3), offset: 0, length: 0))
        }
        bytes[6] = 9 // No method 9.
        var reader = AlignedBytesReader(bytes.span)
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(Header.self) }
        #expect(reader.byteOffset == 0)
        bytes[0] = 0 // Not the signature.
        var again = AlignedBytesReader(bytes.span)
        #expect(throws: BytesError.mismatch) { _ = try again.read(Header.self) }
        var short = AlignedBytesReader(bytes.span.bytes.extracting(0..<10))
        #expect(throws: BytesError.insufficientData) { _ = try short.read(Header.self) }
    }
}
