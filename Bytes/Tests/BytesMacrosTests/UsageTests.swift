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

enum ColorType: UInt8 { case grayscale = 0, truecolor = 2, indexed = 3 }

/// One-byte fields, padding, and reserved bytes: a PNG `IHDR`-like record.
@BinaryRecord(.bigEndian)
struct ImageHeader: Equatable {
    @Field(Byte4.self) var width: Int
    @Field(Byte4.self) var height: Int
    @Field(Byte.self) var bitDepth: UInt8
    @Field(Byte.self) var colorType: ColorType
    @Field(Byte.self, expecting: 1) var version: Int
    @Field(Byte.self) var offset: Int16
    var unused: Padding<Byte2>
    var reserved: Reserved<Byte3>
}

/// Flags in the cursor's byte order.
@BitFields(UInt16.self)
struct SegmentFlags: Equatable {
    @Flag(bit: 15) var executable: Bool
    @Field(bits: 0...3) var kind: Int
}

/// A record in the cursor's byte order, with a nested one.
@BinaryRecord
struct Segment: Equatable {
    @Field(Byte4.self, expecting: 0x5345_474D) var magic: UInt32
    @Field(Byte2.self) var type: CompressionMethod
    var flags: SegmentFlags
    @Field(Byte8.self) var offset: UInt64
    @Field(Byte3.self) var delta: Int32
    @Field(Byte.self) var count: Int
}

@BinaryRecord
struct SegmentPair: Equatable {
    var first: Segment
    var second: Segment
}

@Suite struct UsageTests {
    @Test func oneByteFieldsPaddingAndReservedBytes() throws {
        let header = ImageHeader(width: 640, height: 480, bitDepth: 8, colorType: .truecolor, offset: -3)
        #expect(ImageHeader.byteCount == 17)
        let bytes = try [UInt8](byteCapacity: ImageHeader.byteCount) { (writer) throws(BytesError) in try writer.write(header) }
        #expect(bytes == [0, 0, 2, 0x80, 0, 0, 1, 0xE0, 8, 2, 1, 0xFD, 0, 0, 0, 0, 0])
        var reader = AlignedBytesReader(bytes.span)
        #expect(try reader.read(ImageHeader.self) == header)

        var padded = bytes
        padded[12] = 0xFF // Padding: ignored.
        var paddedReader = AlignedBytesReader(padded.span)
        #expect(try paddedReader.read(ImageHeader.self) == header)
        var reserved = bytes
        reserved[15] = 1 // Reserved: must be zero.
        var reservedReader = AlignedBytesReader(reserved.span)
        #expect(throws: BytesError.invalidValue) { _ = try reservedReader.read(ImageHeader.self) }
        #expect(reservedReader.byteOffset == 0)
        var version = bytes
        version[10] = 2
        var versionReader = AlignedBytesReader(version.span)
        #expect(throws: BytesError.mismatch) { _ = try versionReader.read(ImageHeader.self) }

        let tooBig = ImageHeader(width: 1, height: 1, bitDepth: 8, colorType: .indexed, offset: 200)
        #expect(throws: BytesError.invalidValue) {
            _ = try [UInt8](byteCapacity: ImageHeader.byteCount) { (writer) throws(BytesError) in try writer.write(tooBig) }
        }
    }

    @Test func recordsInTheCursorsByteOrder() throws {
        let segment = Segment(type: .deflate, flags: SegmentFlags(executable: true, kind: 5), offset: 0x0102_0304_0506_0708,
                              delta: -2, count: 200)
        let pair = SegmentPair(first: segment, second: Segment(type: .stored, flags: SegmentFlags(executable: false, kind: 1),
                                                               offset: 9, delta: 7, count: 0))
        #expect(Segment.byteCount == 20 && SegmentPair.byteCount == 40)

        let big = try [UInt8](byteCapacity: SegmentPair.byteCount, mode: BigEndianBytes.self) { (writer) throws(BytesError) in
            try writer.write(pair)
        }
        let little = try [UInt8](byteCapacity: SegmentPair.byteCount, mode: LittleEndianBytes.self) { (writer) throws(BytesError) in
            try writer.write(pair)
        }
        #expect(big.prefix(8) == [0x53, 0x45, 0x47, 0x4D, 0, 8, 0x80, 5])
        #expect(little.prefix(8) == [0x4D, 0x47, 0x45, 0x53, 8, 0, 5, 0x80])
        #expect(big[16...19] == [0xFF, 0xFF, 0xFE, 200])
        var bigReader = BigEndianBytesReader(big.span)
        var littleReader = LittleEndianBytesReader(little.span)
        #expect(try bigReader.read(SegmentPair.self) == pair)
        #expect(try littleReader.read(SegmentPair.self) == pair)
        // The other order: the magic doesn't match, and nothing is consumed.
        var wrongReader = LittleEndianBytesReader(big.span)
        #expect(throws: BytesError.mismatch) { _ = try wrongReader.read(SegmentPair.self) }
        #expect(wrongReader.byteOffset == 0)
    }

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
