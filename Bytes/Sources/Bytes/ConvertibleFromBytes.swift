// MARK: - Raw-value types

// Fields whose values map to a type through its raw value: enums with integer raw values, and option
// sets. Reading converts after the field is read and throws `invalidValue` (consuming nothing) when the
// raw value isn't valid; writing converts first. A field is an unsigned value, so negative raw values
// can't be read or written.

public extension RawRepresentable where RawValue: BinaryInteger {
    /// Creates a value from a field already read, through its raw value; `nil` if the field isn't a valid one.
    ///
    /// ```swift
    /// guard let qos = QualityOfService(rawBits: flags[Crumb.self, at: 1]) else { … }
    /// ```
    ///
    /// To read a field as an `R` directly, use `read(_:as:)` on ``BytesReader``.
    ///
    /// - Parameter bits: The field.
    @inlinable
    init?<let width: Int>(rawBits bits: Bits<width>) {
        guard let raw = RawValue(exactly: bits.rawValue) else { return nil }
        self.init(rawValue: raw)
    }
}

public extension BytesReader {
    /// Reads a `width`-bit field as an `R`, through its raw value.
    ///
    /// ```swift
    /// enum QualityOfService: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }
    /// let qos = try reader.read(QualityOfService.self, as: Crumb.self)
    /// ```
    ///
    /// - Parameters:
    ///   - type: The type to read, such as `QualityOfService.self`.
    ///   - fieldType: The field's width, such as `Crumb.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain;
    ///   ``BytesError/invalidValue`` if the field isn't a valid raw value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<R: RawRepresentable, let width: Int>(
        _ type: R.Type, as fieldType: Bits<width>.Type
    ) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        let bits = try peek(Bits<width>.self)
        guard let raw = R.RawValue(exactly: bits.rawValue), let value = R(rawValue: raw) else { throw .invalidValue }
        _advance(bitCount: width)
        return value
    }

    /// Reads a `T` field in `byteOrder` as an `R`, through its raw value.
    ///
    /// - Parameters:
    ///   - type: The type to read, such as `QualityOfService.self`.
    ///   - fieldType: The byte group the field is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain than the field takes;
    ///   ``BytesError/invalidValue`` if the field isn't a valid raw value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<R: RawRepresentable, T: ByteGroup>(
        _ type: R.Type, as fieldType: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        let integer = try peek(T.self, byteOrder)
        guard let raw = R.RawValue(exactly: integer), let value = R(rawValue: raw) else { throw .invalidValue }
        _byteOffset &+= T.byteCount
        return value
    }

    /// Reads a `T` field in `byteOrder` as an `I`: for sizes, counts, and offsets from untrusted data, which
    /// should fail rather than trap when they don't fit.
    ///
    /// ```swift
    /// let size = try reader.read(Int.self, as: Byte8.self, .littleEndian) // a zip64 size, as an Int
    /// ```
    ///
    /// The field is its unsigned value. For signed fields, read the group and use
    /// ``ByteGroup/signedInteger(_:as:)``.
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - fieldType: The byte group the field is stored as, such as `Byte8.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain than the field takes;
    ///   ``BytesError/invalidValue`` if `I` can't represent the value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger, T: ByteGroup>(
        _ type: I.Type, as fieldType: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) -> I {
        let integer = try peek(T.self, byteOrder)
        guard let value = I(exactly: integer) else { throw .invalidValue }
        _byteOffset &+= T.byteCount
        return value
    }
}

public extension BytesWriter {
    /// Writes `value`'s raw value as a `width`-bit field. A raw value that doesn't fit is a programming
    /// error: debug builds trap, release builds write its low `width` bits.
    ///
    /// - Parameters:
    ///   - value: The value whose raw value to write.
    ///   - fieldType: The field's width, such as `Crumb.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<R: RawRepresentable, let width: Int>(
        _ value: R, as fieldType: Bits<width>.Type
    ) throws(BytesError) where R.RawValue: BinaryInteger {
        assert(Bits<width>(exactly: value.rawValue) != nil, "\(value.rawValue) doesn't fit in \(width) bits")
        try write(Bits<width>(truncatingIfNeeded: value.rawValue))
    }

    /// Writes `value`'s raw value as a `T` field in `byteOrder`. A raw value that doesn't fit is a
    /// programming error: debug builds trap, release builds write its low `T.byteCount` bytes.
    ///
    /// - Parameters:
    ///   - value: The value whose raw value to write.
    ///   - fieldType: The byte group to store the field as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<R: RawRepresentable, T: ByteGroup>(
        _ value: R, as fieldType: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) where R.RawValue: BinaryInteger {
        assert(T.Integer(exactly: value.rawValue).map { $0 <= T._mask } ?? false,
               "\(value.rawValue) doesn't fit in \(T.byteCount) bytes")
        try write(T.Integer(truncatingIfNeeded: value.rawValue) & T._mask, as: T.self, byteOrder)
    }
}

// MARK: - ConvertibleFromBytes

// Reading the standard library's `ConvertibleFromBytes` types: integers, `Float16`/`Float`/`Double`,
// `Duration`, `SIMD2`–`SIMD64` vectors, and `InlineArray`s of them. Every bit pattern is a valid value of
// these types, so they can be loaded from arbitrary bytes, or viewed in place, safely. Each takes
// `MemoryLayout<T>.size` bytes, which for 3-lane vectors includes a padding lane: `SIMD3<Float>` is 16.

public extension BytesReader {
    /// Returns the next `T`, from its `MemoryLayout<T>.size` bytes in native byte order (little-endian on
    /// Apple platforms), without consuming them.
    ///
    /// For data in a specific byte order, read integers with ``read(_:_:)`` instead (`Byte4` and so on), and
    /// floating-point values from their bits: `Float(bitPattern: try reader.read(Byte4.self, .bigEndian))`.
    ///
    /// - Parameter type: The type to load, such as `Float.self`. Inferred from context when omitted.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain than `T` takes.
    @inlinable @inline(__always)
    func peekLoad<T: ConvertibleFromBytes>(_ type: T.Type = T.self) throws(BytesError) -> T {
        _assumeInvariant()
        let size = MemoryLayout<T>.size
        if likely(_bitOffset == 0) {
            guard likely(span.byteCount &- _byteOffset >= size) else { throw .insufficientData }
            return unsafe Load.rawBytes(T.self, from: span, at: _byteOffset)
        }
        guard remainingByteCount >= size else { throw .insufficientData }
        return Self._unalignedRawBytes(T.self, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
    }

    /// Reads the next `T`, from its `MemoryLayout<T>.size` bytes in native byte order (little-endian on
    /// Apple platforms): one unaligned load, at any offset.
    ///
    /// ```swift
    /// let sample = try reader.load(Float.self)            // little-endian IEEE 754
    /// let pixel = try reader.load(SIMD4<UInt8>.self)
    /// let address = try reader.load(InlineArray<4, UInt8>.self)
    /// ```
    ///
    /// - Parameter type: The type to load, such as `Float.self`. Inferred from context when omitted.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain than `T` takes, consuming
    ///   nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func load<T: ConvertibleFromBytes>(_ type: T.Type = T.self) throws(BytesError) -> T {
        let value = try peekLoad(T.self)
        _byteOffset &+= MemoryLayout<T>.size // Whole bytes leave the bit offset unchanged.
        return value
    }

    /// Reads the next `count` values of `T` as a typed span of the same memory: no copying, no decoding.
    /// Values are in native byte order (little-endian on Apple platforms).
    ///
    /// A `Span` is `Iterable`, so this is the fastest way to loop over typed values: the loop runs directly
    /// over the input, as fast as reading raw bytes.
    ///
    /// ```swift
    /// let addresses = try reader.read(InlineArray<4, UInt8>.self, count: 1_000)
    /// for address in addresses { … }
    /// ```
    ///
    /// Types with an alignment of 1, such as `InlineArray<N, UInt8>`, can be viewed at any offset and are
    /// never misaligned.
    ///
    /// - Parameters:
    ///   - type: The element type to view, such as `InlineArray<4, UInt8>.self`.
    ///   - count: The number of values, each `MemoryLayout<T>.stride` bytes.
    /// - Returns: A span of the values, borrowing the same memory.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/misaligned`` if the bytes
    ///   aren't aligned for `T`. Nothing is consumed either way.
    /// - Precondition: `count` isn't negative, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<T: ConvertibleFromBytes>(_ type: T.Type, count: Int) throws(BytesError) -> Span<T> {
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Reading a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !overflow, likely(span.byteCount &- _byteOffset >= byteCount) else { throw .insufficientData }
        let bytes = span.extracting(_byteOffset..<(_byteOffset &+ byteCount))
        // An empty view can't be misaligned, but `Span(viewing:)` checks alignment even when empty.
        guard byteCount > 0 else { return Span() }
        if MemoryLayout<T>.alignment > 1 {
            let address = bytes.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            guard address & UInt(MemoryLayout<T>.alignment &- 1) == 0 else { throw .misaligned }
        }
        _byteOffset &+= byteCount
        return Span(viewing: bytes)
    }
}
