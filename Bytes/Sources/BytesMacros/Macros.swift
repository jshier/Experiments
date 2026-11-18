@_exported public import Bytes

// The `BytesMacros` product: `@BitFields` and `@BinaryRecord` (with their `@Flag` and `@Field` markers), kept out
// of the `Bytes` product so it needs no swift-syntax. Everything they generate can be written by hand with
// `BinaryParsable`, `BinaryWritable`, `FixedSizeBinary`, and `BitFlag`/`BitField`.

// MARK: - Packed flags

/// A struct of flags and fields packed into one value, read and written in one call.
///
/// ```swift
/// @BitFields(Byte.self, reserved: 0...0)
/// struct ConnectFlags {
///     @Flag(bit: 7) var userName: Bool
///     @Flag(bit: 6) var password: Bool
///     @Flag(bit: 5) var willRetain: Bool
///     @Field(bits: 3...4) var willQoS: QualityOfService     // an enum with UInt8 raw values
///     @Flag(bit: 2) var will: Bool
///     @Flag(bit: 1) var cleanStart: Bool
/// }
///
/// let flags = try reader.read(ConnectFlags.self)        // throws for a reserved bit set, or QoS 3
/// try writer.write(flags)
/// ```
///
/// Generates a memberwise initializer, `init(rawValue:) throws(BytesError)` (every field decoded, the
/// reserved bits checked), `rawValue`, and conformances to `BinaryParsable`, `BinaryWritable`, and
/// `FixedSizeBinary`. Every stored property is a field: `@Flag` for a `Bool`, `@Field` for an integer, a
/// `Bits` type, or a `RawRepresentable` enum. Positions count from the least significant bit, 0; the
/// `…FromMostSignificant` forms count from the other end, as specifications that draw bit 0 on the left do.
///
/// Each field compiles to the shift and mask written by hand.
///
/// Over `UInt16`, `UInt32`, or `UInt64` without a byte order, the value is stored in the byte order of the
/// cursor that reads it, as in a `@BinaryRecord` without one: the conformances are then `ByteOrderedParsable`
/// and `ByteOrderedWritable`, read from ``BigEndianBytesReader`` and ``LittleEndianBytesReader``.
///
/// - Parameters:
///   - storage: The packed value's type: `Byte.self` or `UInt8.self` for one byte; `UInt16.self`,
///     `UInt32.self`, or `UInt64.self` for one in the cursor's byte order.
///   - reserved: Bit ranges that must be 0.
@attached(member, names: named(init), named(rawValue))
@attached(extension, conformances: BinaryParsable, BinaryWritable, ByteOrderedParsable, ByteOrderedWritable, FixedSizeBinary,
          names: named(init(parsing:)), named(write(to:)), named(byteCount))
public macro BitFields(_ storage: Any.Type, reserved: ClosedRange<Int>...) =
    #externalMacro(module: "BytesMacrosPlugin", type: "BitFieldsMacro")

/// A struct of flags and fields packed into a `UInt16`, `UInt32`, or `UInt64` stored in `byteOrder`.
///
/// ```swift
/// @BitFields(UInt16.self, .littleEndian)
/// struct DOSDate {
///     @Field(bits: 9...15) var yearsSince1980: Int
///     @Field(bits: 5...8) var month: Int
///     @Field(bits: 0...4) var day: Int
/// }
/// ```
///
/// - Parameters:
///   - storage: The packed value's type.
///   - byteOrder: The byte order it's stored in.
///   - reserved: Bit ranges that must be 0.
@attached(member, names: named(init), named(rawValue))
@attached(extension, conformances: BinaryParsable, BinaryWritable, FixedSizeBinary, names: named(init(parsing:)), named(write(to:)), named(byteCount))
public macro BitFields(_ storage: Any.Type, _ byteOrder: ByteOrder, reserved: ClosedRange<Int>...) =
    #externalMacro(module: "BytesMacrosPlugin", type: "BitFieldsMacro")

/// A one-bit flag of a `@BitFields` struct, at `bit`, counting from the least significant (0).
@attached(peer)
public macro Flag(bit: Int) = #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")

/// A one-bit flag of a `@BitFields` struct, counting from the most significant bit (0).
@attached(peer)
public macro Flag(bitFromMostSignificant: Int) = #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")

/// A field of a `@BitFields` struct covering `bits`, counting from the least significant bit (0).
@attached(peer)
public macro Field(bits: ClosedRange<Int>) = #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")

/// A field of a `@BitFields` struct covering `bits`, counting from the most significant bit (0).
@attached(peer)
public macro Field(bitsFromMostSignificant: ClosedRange<Int>) =
    #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")

// MARK: - Records

/// A record of fixed fields in order, read and written in one call.
///
/// ```swift
/// @BinaryRecord(.littleEndian)
/// struct LocalFileHeader {
///     @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
///     @Field(Byte2.self) var versionNeeded: Int
///     var flags: GeneralPurposeFlags                     // a @BitFields type, or another record
///     @Field(Byte2.self) var method: CompressionMethod   // an enum with integer raw values
///     @Field(Byte4.self) var crc32: UInt32
///     …
/// }
///
/// let header = try reader.read(LocalFileHeader.self)
/// ```
///
/// Generates a memberwise initializer (a field's expected value is its default), `byteCount` (the fields'
/// sizes summed, a constant), and conformances to `BinaryParsable`, `BinaryWritable`, and `FixedSizeBinary`.
/// Reading takes the record's bytes with one bounds check, then each field once, from a cursor whose length
/// the optimizer knows, so the fields' own checks fold away; a field with an expected value throws
/// `BytesError.mismatch` for another, and the record consumes nothing when it throws.
///
/// Fields:
/// - `@Field(Byte4.self)` and the other byte groups, through `Byte16`; `@Field(Byte.self)` for one byte.
/// - Integers: `Int` and the unsigned types read the field's unsigned value (throwing
///   `BytesError.invalidValue` if it doesn't fit); `Int8` through `Int64` read it as two's complement.
/// - Enums with integer raw values, through their raw values.
/// - Without `@Field`: a nested record, a `@BitFields` type, or anything `BinaryParsable`, `BinaryWritable`, and
///   `FixedSizeBinary`. `Padding<Byte7>` skips bytes and `Reserved<Byte2>` requires them to be zero; both
///   store nothing, and default in the initializer.
///
/// - Parameter byteOrder: The byte order of the record's integer fields.
@attached(member, names: named(init), named(byteCount))
@attached(extension, conformances: BinaryParsable, BinaryWritable, FixedSizeBinary, names: named(init(parsing:)), named(write(to:)))
public macro BinaryRecord(_ byteOrder: ByteOrder) = #externalMacro(module: "BytesMacrosPlugin", type: "BinaryRecordMacro")

/// A record of fixed fields in order whose integers are in the byte order of the cursor that reads it: for
/// formats that name their byte order in their first bytes (ELF, PCAPNG, TIFF), so one declaration serves both.
///
/// ```swift
/// @BinaryRecord
/// struct ProgramHeader64 {
///     @Field(Byte4.self) var type: SegmentType
///     @Field(Byte4.self) var flags: UInt32
///     @Field(Byte8.self) var offset: UInt64
///     …
/// }
///
/// static func parse<Mode: ByteOrderedCursorMode>(_ reader: inout GenericBytesReader<Mode>) throws(BytesError) -> … {
///     let header = try reader.read(ProgramHeader64.self)
/// }
/// ```
///
/// As `@BinaryRecord(_:)` in every other way, but the conformances are `ByteOrderedParsable` and
/// `ByteOrderedWritable`: such a record is read from ``BigEndianBytesReader`` or ``LittleEndianBytesReader``
/// (or generic code over ``ByteOrderedCursorMode``), each specialized with its order a constant. Reading it from
/// any other cursor doesn't compile. Nested records and `@BitFields` types without a byte order are read in
/// the same order.
@attached(member, names: named(init), named(byteCount))
@attached(extension, conformances: ByteOrderedParsable, ByteOrderedWritable, FixedSizeBinary, names: named(init(parsing:)), named(write(to:)))
public macro BinaryRecord() = #externalMacro(module: "BytesMacrosPlugin", type: "BinaryRecordMacro")

/// A field of a `@BinaryRecord` stored as `group` (`Byte.self`, `Byte2.self`, `Byte4.self`, …).
@attached(peer)
public macro Field(_ group: Any.Type) = #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")

/// A field of a `@BinaryRecord` stored as `group` that must hold `expected`: a signature or magic number.
@attached(peer)
public macro Field(_ group: Any.Type, expecting expected: Int) =
    #externalMacro(module: "BytesMacrosPlugin", type: "FieldMarkerMacro")
