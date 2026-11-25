import BytesMacros

// The formats' fixed records, declared once and read (or written) in one call each with one bounds check, by the
// code `@BinaryRecord` generates (the same instructions as reading the fields by hand: Bytes' RESULTS.md). The
// variable parts (auth data, the Apple Archive's tagged fields, blobs) stay hand-parsed.

/// The prologue's fixed part: magic, profile word (profile | scrypt strength << 24), auth data size.
@BinaryRecord(.littleEndian)
struct PrologueHead {
    @Field(Byte4.self, expecting: 0x3141_4541) var magic: UInt32 // "AEA1"
    @Field(Byte4.self) var profileWord: UInt32
    @Field(Byte4.self) var authDataCount: Int
}

/// The 48-byte root header (decrypted on encrypted profiles). The reserved bytes are skipped, not checked.
@BinaryRecord(.littleEndian)
struct RootHeaderRecord {
    @Field(Byte8.self) var rawSize: UInt64
    @Field(Byte8.self) var containerSize: UInt64
    @Field(Byte4.self) var segmentSize: UInt32
    @Field(Byte4.self) var segmentsPerCluster: UInt32
    @Field(Byte.self) var compression: UInt8
    @Field(Byte.self) var checksum: UInt8
    var reserved: Padding<Byte16>
    var reserved2: Padding<Byte4>
    var reserved3: Padding<Byte2>
}

/// A segment's sizes in its cluster header (its checksum follows, of the root header's checksum size).
@BinaryRecord(.littleEndian)
struct SegmentSizes {
    @Field(Byte4.self) var raw: Int
    @Field(Byte4.self) var stored: Int
}

// (`pbz` framing, the streams' and blocks' headers, is BytesCompression's `PBZ`.)
