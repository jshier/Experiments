// Integers read and written directly, for fields that are numbers: a one-byte length or count as `UInt8`
// or `Int8`, and sub-byte fields as the integer type the code computes with, without a `Bits` value in
// between.

// MARK: - One-byte integers

public extension GenericBytesReader {
    /// Returns the next byte as a `UInt8`, without consuming it.
    ///
    /// For a byte that holds a number (a length, a count, a version); read flags and packed fields as a
    /// ``Byte`` and take them apart by name (``BitFlag``, ``BitField``).
    ///
    /// - Parameter type: `UInt8.self`.
    /// - Returns: The byte's value.
    /// - Throws: ``BytesError/insufficientData`` if no whole byte remains.
    @inlinable @inline(__always)
    func peek(_ type: UInt8.Type) throws(BytesError) -> UInt8 {
        try peek(Byte.self).rawValue
    }

    /// Reads the next byte as a `UInt8`.
    ///
    /// ```swift
    /// let nameLength = Int(try reader.read(UInt8.self))
    /// ```
    ///
    /// - Parameter type: `UInt8.self`.
    /// - Returns: The byte's value.
    /// - Throws: ``BytesError/insufficientData`` if no whole byte remains, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_ type: UInt8.Type) throws(BytesError) -> UInt8 {
        try read(Byte.self).rawValue
    }

    /// Reads the next byte as an `Int8`, two's complement: -128 through 127.
    ///
    /// - Parameter type: `Int8.self`.
    /// - Returns: The byte's value.
    /// - Throws: ``BytesError/insufficientData`` if no whole byte remains, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_ type: Int8.Type) throws(BytesError) -> Int8 {
        Int8(bitPattern: try read(Byte.self).rawValue)
    }
}

public extension GenericBytesWriter {
    /// Writes `value` as a byte.
    ///
    /// - Parameter value: The byte's value.
    /// - Throws: ``BytesError/insufficientCapacity`` if no whole byte remains. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ value: UInt8) throws(BytesError) {
        try write(Byte(_unchecked: value))
    }

    /// Writes `value` as a byte, two's complement.
    ///
    /// - Parameter value: The byte's value.
    /// - Throws: ``BytesError/insufficientCapacity`` if no whole byte remains. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ value: Int8) throws(BytesError) {
        try write(Byte(_unchecked: UInt8(bitPattern: value)))
    }
}

// MARK: - Sub-byte fields as integers

public extension BytesReader {
    /// Reads a `width`-bit field as an `I`: its unsigned value, 0 through `2^width - 1`.
    ///
    /// ```swift
    /// let literalCodeCount = try reader.read(Int.self, as: Bits<5>.self) + 257   // DEFLATE's HLIT
    /// ```
    ///
    /// For a two's complement field, use ``Bits/signedValue``.
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - fieldType: The field's width, such as `Bits<5>.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain, consuming nothing.
    /// - Precondition: `I` holds every `width`-bit value (checked when the types are known, at no cost).
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger, let width: Int>(
        _ type: I.Type, as fieldType: Bits<width>.Type
    ) throws(BytesError) -> I {
        precondition(I.bitWidth - (I.isSigned ? 1 : 0) >= width, "\(I.self) can't hold every \(width)-bit value")
        return I(truncatingIfNeeded: try read(Bits<width>.self).rawValue)
    }
}

public extension BytesWriter {
    /// Writes `value` as a `width`-bit field. A value that doesn't fit is a programming error: debug builds
    /// trap, release builds write its low `width` bits.
    ///
    /// ```swift
    /// try writer.write(literalCodeCount - 257, as: Bits<5>.self)
    /// ```
    ///
    /// - Parameters:
    ///   - value: The value, 0 through `2^width - 1`.
    ///   - fieldType: The field's width, such as `Bits<5>.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger, let width: Int>(_ value: I, as fieldType: Bits<width>.Type) throws(BytesError) {
        assert(Bits<width>(exactly: value) != nil, "\(value) doesn't fit in \(width) bits")
        try write(Bits<width>(truncatingIfNeeded: value))
    }
}

public extension BitBuffer {
    /// Reads and consumes a `width`-bit field as an `I`, refilling first if needed: its unsigned value, 0
    /// through `2^width - 1`. Zeros if the data ran out.
    ///
    /// ```swift
    /// let distanceCodeCount = bits.read(Int.self, as: Bits<5>.self) + 1   // DEFLATE's HDIST
    /// ```
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - fieldType: The field's width, such as `Bits<5>.self`.
    /// - Returns: The value.
    /// - Precondition: `I` holds every `width`-bit value (checked when the types are known, at no cost).
    @inlinable @inline(__always)
    mutating func read<I: FixedWidthInteger, let width: Int>(_ type: I.Type, as fieldType: Bits<width>.Type) -> I {
        precondition(I.bitWidth - (I.isSigned ? 1 : 0) >= width, "\(I.self) can't hold every \(width)-bit value")
        return I(truncatingIfNeeded: read(bitCount: width))
    }
}

// MARK: - Signed fields

public extension BytesReader {
    /// Reads a `width`-bit two's complement field, sign-extended to `I`: -2^(width-1) through 2^(width-1) - 1.
    ///
    /// ```swift
    /// let delta = try reader.read(Int.self, asSigned: Nibble.self)   // -8 through 7
    /// ```
    ///
    /// - Parameters:
    ///   - type: The signed integer type to read, such as `Int.self`.
    ///   - fieldType: The field's width, such as `Nibble.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger & SignedInteger, let width: Int>(
        _ type: I.Type, asSigned fieldType: Bits<width>.Type
    ) throws(BytesError) -> I {
        I(try read(Bits<width>.self).signedValue)
    }
}

public extension BitBuffer {
    /// Reads and consumes a `width`-bit two's complement field, sign-extended to `I`, refilling first if
    /// needed. Zeros if the data ran out.
    ///
    /// - Parameters:
    ///   - type: The signed integer type to read, such as `Int.self`.
    ///   - fieldType: The field's width, such as `Nibble.self`.
    /// - Returns: The value.
    @inlinable @inline(__always)
    mutating func read<I: FixedWidthInteger & SignedInteger, let width: Int>(
        _ type: I.Type, asSigned fieldType: Bits<width>.Type
    ) -> I {
        I(read(Bits<width>.self).signedValue)
    }
}

public extension GenericBytesWriter {
    /// Writes `value`, any integer, as a `T` field in `byteOrder`: the write side of `read(_:as:_:)`.
    /// A negative value, or one that doesn't fit, is a programming error: debug builds trap, release builds
    /// write its low `T.byteCount` bytes.
    ///
    /// ```swift
    /// try writer.write(name.utf8.count, as: Byte2.self, .littleEndian)
    /// ```
    ///
    /// - Parameters:
    ///   - value: The value, 0 through the field's maximum.
    ///   - fieldType: The byte group to store the field as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    // Disfavored: an integer literal (`Int` by default) keeps choosing the group's own integer type.
    @_disfavoredOverload
    mutating func write<I: FixedWidthInteger, T: ByteGroup>(_ value: I, as fieldType: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        assert(T.Integer(exactly: value).map { $0 <= T._mask } ?? false, "\(value) doesn't fit in \(T.byteCount) bytes")
        try write(T.Integer(truncatingIfNeeded: value) & T._mask, as: T.self, byteOrder)
    }

    /// Writes `value` as a `T` field in `byteOrder`, two's complement: the write side of
    /// ``GenericBytesReader/read(_:asSigned:_:)``. A value outside the field's range is a programming error:
    /// debug builds trap, release builds write its low `T.byteCount` bytes.
    ///
    /// ```swift
    /// try writer.write(seconds, asSigned: Byte4.self, .littleEndian)
    /// ```
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - fieldType: The byte group to store the field as, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger, T: ByteGroup>(
        _ value: I, asSigned fieldType: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) {
        assert(I.bitWidth <= 8 &* T.byteCount || {
            let shift = I.bitWidth &- 8 &* T.byteCount
            return (value &<< shift) &>> shift == value
        }(), "\(value) doesn't fit in \(T.byteCount) bytes")
        try write(T.Integer(truncatingIfNeeded: value) & T._mask, as: T.self, byteOrder)
    }
}

public extension BytesWriter {
    /// Writes `value` as a `width`-bit two's complement field. A value outside the field's range is a
    /// programming error: debug builds trap, release builds write its low `width` bits.
    ///
    /// - Parameters:
    ///   - value: The value, -2^(width-1) through 2^(width-1) - 1.
    ///   - fieldType: The field's width, such as `Nibble.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger, let width: Int>(
        _ value: I, asSigned fieldType: Bits<width>.Type
    ) throws(BytesError) {
        assert(value >= -(1 &<< (width &- 1)) && value < 1 &<< (width &- 1), "\(value) doesn't fit in \(width) bits")
        try write(Bits<width>(truncatingIfNeeded: value))
    }
}

// MARK: - Byte counts of any integer type

// Lengths and offsets read from data come in the type they were stored as. These take any integer, so a
// `UInt64` size needs no conversion at the call (where `Int(truncatingIfNeeded:)` would be a bug): a count
// that doesn't fit in an `Int` can't be in the data, and a negative one is invalid. For unsigned types
// narrower than `Int`, the checks fold away.

public extension GenericBytesReader {
    /// The count as an `Int`.
    ///
    /// - Throws: ``BytesError/insufficientData`` if it's beyond `Int`; ``BytesError/invalidValue`` if it's
    ///   negative.
    @inlinable @inline(__always)
    internal static func _byteCount(_ count: some BinaryInteger) throws(BytesError) -> Int {
        guard let count = Int(exactly: count) else { throw count < 0 ? .invalidValue : .insufficientData }
        guard count >= 0 else { throw .invalidValue }
        return count
    }

    /// Reads the next `byteCount` bytes as a span borrowing the same memory, for a count of any integer
    /// type: as ``read(byteCount:)-(Int)``.
    ///
    /// ```swift
    /// let data = try reader.read(byteCount: entry.compressedSize)   // a UInt64
    /// ```
    ///
    /// - Parameter byteCount: The number of bytes to read.
    /// - Returns: A span of the bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if
    ///   `byteCount` is negative. Nothing is consumed either way.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(byteCount: some BinaryInteger) throws(BytesError) -> RawSpan {
        try read(byteCount: Self._byteCount(byteCount))
    }

    /// Reads the next `byteCount` bytes as a cursor of their own, for a count of any integer type: as
    /// ``readSection(byteCount:)-(Int)``.
    ///
    /// - Parameter byteCount: The section's length in bytes.
    /// - Returns: A cursor over the section, borrowing the same memory.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if
    ///   `byteCount` is negative. Nothing is consumed either way.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readSection(byteCount: some BinaryInteger) throws(BytesError) -> Self {
        try readSection(byteCount: Self._byteCount(byteCount))
    }

    /// Skips the next `byteCount` bytes, for a count of any integer type: as ``skip(byteCount:)-(Int)``.
    ///
    /// - Parameter byteCount: The number of bytes to skip.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain; ``BytesError/invalidValue`` if
    ///   `byteCount` is negative. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func skip(byteCount: some BinaryInteger) throws(BytesError) {
        try skip(byteCount: Self._byteCount(byteCount))
    }
}
