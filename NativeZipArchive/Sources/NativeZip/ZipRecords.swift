internal import BytesMacros

// The zip format's fixed records, declared once (APPNOTE 4.3.12, 4.4.6): read in one call each, with one
// bounds check, by the code `@BinaryRecord` and `@BitFields` generate.

/// A central directory entry's fixed header, before its name, extra field, and comment.
@BinaryRecord(.littleEndian)
struct CentralDirectoryHeader {
    @Field(Byte4.self, expecting: 0x0201_4B50) var signature: UInt32
    @Field(Byte2.self) var versionMadeBy: UInt16
    @Field(Byte2.self) var versionNeeded: UInt16
    @Field(Byte2.self) var flags: UInt16
    @Field(Byte2.self) var method: UInt16
    var time: DOSTime
    var date: DOSDate
    @Field(Byte4.self) var crc32: UInt32
    @Field(Byte4.self) var compressedSize: UInt32
    @Field(Byte4.self) var uncompressedSize: UInt32
    @Field(Byte2.self) var nameLength: Int
    @Field(Byte2.self) var extraLength: Int
    @Field(Byte2.self) var commentLength: Int
    @Field(Byte2.self) var diskNumberStart: UInt16
    @Field(Byte2.self) var internalAttributes: UInt16
    @Field(Byte4.self) var externalAttributes: UInt32
    @Field(Byte4.self) var localHeaderOffset: UInt32
}

/// An MS-DOS time: hour, minute, and seconds / 2.
@BitFields(UInt16.self, .littleEndian)
struct DOSTime {
    @Field(bits: 11...15) var hour: Int
    @Field(bits: 5...10) var minute: Int
    @Field(bits: 0...4) var halfSeconds: Int
}

/// An MS-DOS date: years since 1980, month, and day.
@BitFields(UInt16.self, .littleEndian)
struct DOSDate {
    @Field(bits: 9...15) var yearsSince1980: Int
    @Field(bits: 5...8) var month: Int
    @Field(bits: 0...4) var day: Int
}

/// The extended timestamp extra field's flags: which times follow.
@BitFields(Byte.self)
struct ExtendedTimestampFlags {
    @Flag(bit: 0) var modification: Bool
    @Flag(bit: 1) var access: Bool
    @Flag(bit: 2) var creation: Bool
}
