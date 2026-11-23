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
    /// A negative value, or one that doesn't fit, is a programming error, and traps in every build. (The check
    /// costs nothing where the compiler can see the value fits, such as a `UInt16` in a ``Byte2``.)
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
    /// - Precondition: `value` is 0 through the field's maximum.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    // Disfavored: an integer literal (`Int` by default) keeps choosing the group's own integer type.
    @_disfavoredOverload
    mutating func write<I: FixedWidthInteger, T: ByteGroup>(_ value: I, as fieldType: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        // A precondition, then the value with no mask of its own: the group's initializer masks odd widths,
        // which the check lets the optimizer drop. (An `assert` and a mask wrote the low bytes of a value that
        // didn't fit, in release builds.)
        precondition(value >= 0 && value <= T._mask, "\(value) doesn't fit in \(T.byteCount) bytes")
        try write(T(T.Integer(truncatingIfNeeded: value), byteOrder))
    }

    /// Writes `value` as a `T` field in `byteOrder`, two's complement: the write side of
    /// ``GenericBytesReader/read(_:asSigned:_:)``. A value outside the field's range is a programming error,
    /// and traps in every build.
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
    /// - Precondition: `value` is -2^(8 × `T.byteCount` - 1) through 2^(8 × `T.byteCount` - 1) - 1.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger, T: ByteGroup>(
        _ value: I, asSigned fieldType: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) {
        // Folds away when `I` is no wider than the field.
        precondition(I.bitWidth <= 8 &* T.byteCount || {
            let shift = I.bitWidth &- 8 &* T.byteCount
            return (value &<< shift) &>> shift == value
        }(), "\(value) doesn't fit in \(T.byteCount) bytes")
        // Sign-extended to `T.Integer`: the group's initializer (little-endian) or its byte swap and shift
        // (big-endian) drops the bytes beyond the field.
        try write(T(T.Integer(truncatingIfNeeded: value), byteOrder))
    }
}

public extension BytesWriter {
    /// Writes `value` as a `width`-bit two's complement field. A value outside the field's range is a
    /// programming error, and traps in every build.
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
        precondition(value >= -(1 &<< (width &- 1)) && value < 1 &<< (width &- 1), "\(value) doesn't fit in \(width) bits")
        // The mask stays: it drops a negative value's sign extension above the field.
        try write(Bits<width>(truncatingIfNeeded: value))
    }
}

// MARK: - Byte counts of any integer type

// Lengths and offsets read from data come in the type they were stored as. These take any integer, so a
// `UInt64` size needs no conversion at the call (where `Int(truncatingIfNeeded:)` would be a bug): a count
// that doesn't fit in an `Int` can't be in the data, and a negative one is invalid. For unsigned types
// narrower than `Int`, the checks fold away.

public extension GenericBytesReader {
    /// The error for a count that failed a bounds check: a negative count is invalid, a positive one asks for
    /// more than remains. Only called once a check has failed, so the hot path tests the sign once, in the
    /// check itself (a constant count folds it away).
    @inlinable
    internal static func _countError(_ count: Int) -> BytesError {
        count < 0 ? .invalidValue : .insufficientData
    }

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

// MARK: - Integers of a run-time width

// Fields whose width is data: a binary property list's offset and reference sizes (1, 2, 4, or 8 bytes, named
// in its trailer), DWARF's address size, a codec's variable-width fields. The width comes from the data, so a
// width outside 1 through 8 throws rather than traps.

public extension GenericBytesReader {
    /// Reads the unsigned value of the next `byteCount` bytes in `byteOrder`. Consumes nothing if it throws.
    ///
    /// With 8 bytes left (and the cursor on a byte boundary), one 8-byte load, shifted: no loop over a width the
    /// compiler doesn't know. Otherwise a byte at a time.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _readUnsigned(byteCount: Int, _ byteOrder: ByteOrder) throws(BytesError) -> UInt64 {
        guard byteCount >= 1 && byteCount <= 8 else { throw .invalidValue }
        _assumeInvariant()
        let unusedBits = UInt64(64 &- 8 &* byteCount)
        if _bitOffset == 0, likely(span.byteCount &- _byteOffset >= 8) {
            // Unsafe: an unchecked load. Safe: 8 bytes remain (just checked).
            let raw = unsafe Load.rawBytes(UInt64.self, from: span, at: _byteOffset)
            _byteOffset &+= byteCount
            return switch byteOrder {
            case .bigEndian: UInt64(bigEndian: raw) &>> unusedBits
            case .littleEndian: (UInt64(littleEndian: raw) &<< unusedBits) &>> unusedBits
            }
        }
        guard remainingByteCount >= byteCount else { throw .insufficientData }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            let byte = UInt64(try read(UInt8.self)) // Can't throw: `byteCount` bytes remain.
            switch byteOrder {
            case .bigEndian: value = value &<< 8 | byte
            case .littleEndian: value |= byte &<< UInt64(8 &* index)
            }
        }
        return value
    }

    /// Reads an unsigned integer of `byteCount` bytes in `byteOrder`: a width known only at run time, such as a
    /// binary property list's offsets, whose size its trailer names.
    ///
    /// ```swift
    /// let offset = try table.read(Int.self, byteCount: trailer.offsetSize, .bigEndian)
    /// ```
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if
    ///   `byteCount` isn't 1 through 8 or `I` can't represent the value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger>(_ type: I.Type, byteCount: Int, _ byteOrder: ByteOrder) throws(BytesError) -> I {
        let start = position
        guard let value = I(exactly: try _readUnsigned(byteCount: byteCount, byteOrder)) else {
            rewind(to: start)
            throw .invalidValue
        }
        return value
    }

    /// Reads a two's complement integer of `byteCount` bytes in `byteOrder`, sign-extended to `I`: the signed
    /// counterpart of ``read(_:byteCount:_:)``.
    ///
    /// - Parameters:
    ///   - type: The signed integer type to read, such as `Int64.self`.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if
    ///   `byteCount` isn't 1 through 8 or `I` can't represent the value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger & SignedInteger>(
        _ type: I.Type, signedByteCount byteCount: Int, _ byteOrder: ByteOrder
    ) throws(BytesError) -> I {
        let start = position
        let unsigned = try _readUnsigned(byteCount: byteCount, byteOrder)
        let unusedBits = Int64(64 &- 8 &* byteCount)
        guard let value = I(exactly: Int64(bitPattern: unsigned &<< UInt64(unusedBits)) &>> unusedBits) else {
            rewind(to: start)
            throw .invalidValue
        }
        return value
    }
}

public extension GenericBytesReader where Mode: ByteOrderedCursorMode {
    /// Reads an unsigned integer of `byteCount` bytes in the cursor's byte order, as ``read(_:byteCount:_:)``.
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    /// - Returns: The value.
    /// - Throws: As ``read(_:byteCount:_:)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger>(_ type: I.Type, byteCount: Int) throws(BytesError) -> I {
        try read(I.self, byteCount: byteCount, Mode.byteOrder)
    }

    /// Reads a two's complement integer of `byteCount` bytes in the cursor's byte order, as
    /// ``read(_:signedByteCount:_:)``.
    ///
    /// - Parameters:
    ///   - type: The signed integer type to read, such as `Int64.self`.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    /// - Returns: The value.
    /// - Throws: As ``read(_:signedByteCount:_:)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger & SignedInteger>(_ type: I.Type, signedByteCount byteCount: Int) throws(BytesError) -> I {
        try read(I.self, signedByteCount: byteCount, Mode.byteOrder)
    }
}

public extension GenericBytesWriter {
    /// Writes `bits`' low `byteCount` bytes in `byteOrder`.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _write(lowBytesOf bits: UInt64, byteCount: Int, _ byteOrder: ByteOrder) throws(BytesError) {
        let word = switch byteOrder {
        case .bigEndian: (bits &<< UInt64(64 &- 8 &* byteCount)).byteSwapped // The field's first byte lowest.
        case .littleEndian: bits
        }
        try write(word, byteCount: byteCount, allowingOverrun: false)
    }

    /// Writes `value` as an unsigned integer of `byteCount` bytes in `byteOrder`: the counterpart of
    /// ``GenericBytesReader/read(_:byteCount:_:)``.
    ///
    /// ```swift
    /// try writer.write(offset, byteCount: offsetSize, .bigEndian)
    /// ```
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    ///   - byteOrder: The byte order of the field.
    /// - Throws: ``BytesError/invalidValue`` if `value` is negative or doesn't fit in `byteCount` bytes;
    ///   ``BytesError/insufficientCapacity`` if there isn't room. Nothing is written either way.
    /// - Precondition: `byteCount` is 1 through 8, and the writer is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger>(_ value: I, byteCount: Int, _ byteOrder: ByteOrder) throws(BytesError) {
        precondition(byteCount >= 1 && byteCount <= 8, "Byte count must be 1 through 8")
        guard let bits = UInt64(exactly: value), byteCount == 8 || bits &>> UInt64(8 &* byteCount) == 0 else {
            throw .invalidValue
        }
        try _write(lowBytesOf: bits, byteCount: byteCount, byteOrder)
    }

    /// Writes `value` as a two's complement integer of `byteCount` bytes in `byteOrder`: the counterpart of
    /// ``GenericBytesReader/read(_:signedByteCount:_:)``.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    ///   - byteOrder: The byte order of the field.
    /// - Throws: ``BytesError/invalidValue`` if `value` doesn't fit in `byteCount` bytes;
    ///   ``BytesError/insufficientCapacity`` if there isn't room. Nothing is written either way.
    /// - Precondition: `byteCount` is 1 through 8, and the writer is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger>(_ value: I, signedByteCount byteCount: Int, _ byteOrder: ByteOrder) throws(BytesError) {
        precondition(byteCount >= 1 && byteCount <= 8, "Byte count must be 1 through 8")
        let unusedBits = Int64(64 &- 8 &* byteCount)
        // It fits if sign-extending its low bytes gives it back.
        guard let wide = Int64(exactly: value), (wide &<< unusedBits) &>> unusedBits == wide else { throw .invalidValue }
        try _write(lowBytesOf: UInt64(bitPattern: wide), byteCount: byteCount, byteOrder)
    }
}

public extension GenericBytesWriter where Mode: ByteOrderedCursorMode {
    /// Writes `value` as an unsigned integer of `byteCount` bytes in the writer's byte order, as
    /// ``write(_:byteCount:_:)``.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    /// - Throws: As ``write(_:byteCount:_:)``.
    /// - Precondition: `byteCount` is 1 through 8.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger>(_ value: I, byteCount: Int) throws(BytesError) {
        try write(value, byteCount: byteCount, Mode.byteOrder)
    }

    /// Writes `value` as a two's complement integer of `byteCount` bytes in the writer's byte order, as
    /// ``write(_:signedByteCount:_:)``.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - byteCount: The field's width in bytes, 1 through 8.
    /// - Throws: As ``write(_:signedByteCount:_:)``.
    /// - Precondition: `byteCount` is 1 through 8.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger>(_ value: I, signedByteCount byteCount: Int) throws(BytesError) {
        try write(value, signedByteCount: byteCount, Mode.byteOrder)
    }
}
