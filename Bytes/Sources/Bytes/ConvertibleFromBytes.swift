// MARK: - Raw-value types

// Fields whose values map to a type through its raw value: enums with integer raw values, and option
// sets. Reading converts after the field is read and throws `invalidValue` (consuming nothing) when the
// raw value isn't valid; writing converts first. A field is an unsigned value, so negative raw values
// can't be read or written.

extension Bytes {
    /// Reads a `width`-bit field as an `R`, through its raw value.
    ///
    /// ```swift
    /// enum QualityOfService: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }
    /// let qos = try reader.read(QualityOfService.self, as: Crumb.self)
    /// ```
    ///
    /// Throws ``BytesError/invalidValue`` without consuming anything if the field isn't a valid raw value.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read<R: RawRepresentable, let width: Int>(
        _: R.Type, as _: Bits<width>.Type
    ) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        let bits = try peek(Bits<width>.self)
        guard let raw = R.RawValue(exactly: bits.rawValue), let value = R(rawValue: raw) else { throw .invalidValue }
        _advance(bitCount: width)
        return value
    }

    /// Reads a `T` field in `byteOrder` as an `R`, through its raw value.
    ///
    /// Throws ``BytesError/invalidValue`` without consuming anything if the field isn't a valid raw value.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read<R: RawRepresentable, T: ByteGroup>(
        _: R.Type, as _: T.Type, _ byteOrder: ByteOrder
    ) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        let integer = try peek(T.self, byteOrder)
        guard let raw = R.RawValue(exactly: integer), let value = R(rawValue: raw) else { throw .invalidValue }
        _byteOffset &+= T.byteCount
        return value
    }
}

extension BytesWriter {
    /// Writes `value`'s raw value as a `width`-bit field. A raw value that doesn't fit is a programming
    /// error: debug builds trap, release builds write its low `width` bits.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<R: RawRepresentable, let width: Int>(
        _ value: R, as _: Bits<width>.Type
    ) throws(BytesError) where R.RawValue: BinaryInteger {
        assert(Bits<width>(exactly: value.rawValue) != nil, "\(value.rawValue) doesn't fit in \(width) bits")
        try write(Bits<width>(truncatingIfNeeded: value.rawValue))
    }

    /// Writes `value`'s raw value as a `T` field in `byteOrder`. A raw value that doesn't fit is a
    /// programming error: debug builds trap, release builds write its low `T.byteCount` bytes.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<R: RawRepresentable, T: ByteGroup>(
        _ value: R, as _: T.Type, _ byteOrder: ByteOrder
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

extension Bytes {
    /// Returns the next `T`, from its `MemoryLayout<T>.size` bytes in native byte order (little-endian on
    /// Apple platforms), without consuming them.
    ///
    /// For data in a specific byte order, read integers with ``read(_:_:)`` instead (`Byte4` and so on), and
    /// floating-point values from their bits: `Float(bitPattern: try reader.read(Byte4.self, .bigEndian))`.
    @inlinable @inline(__always)
    public func peekLoad<T: ConvertibleFromBytes>(_: T.Type = T.self) throws(BytesError) -> T {
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
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func load<T: ConvertibleFromBytes>(_: T.Type = T.self) throws(BytesError) -> T {
        let value = try peekLoad(T.self)
        _byteOffset &+= MemoryLayout<T>.size // Whole bytes leave the bit offset unchanged.
        return value
    }

    /// Reads the next `count` values of `T` as a typed span of the same memory: no copying, no decoding.
    /// Values are in native byte order (little-endian on Apple platforms). Requires byte alignment.
    ///
    /// A `Span` is `Iterable`, so this is the fastest way to loop over typed values: the loop runs directly
    /// over the input, as fast as reading raw bytes.
    ///
    /// ```swift
    /// let addresses = try reader.read(InlineArray<4, UInt8>.self, count: 1_000)
    /// for address in addresses { … }
    /// ```
    ///
    /// Throws ``BytesError/misaligned`` if the bytes aren't aligned for `T`. That can't happen for types
    /// with an alignment of 1, such as `InlineArray<N, UInt8>`, which can be viewed at any offset.
    /// Nothing is consumed when it throws.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read<T: ConvertibleFromBytes>(_: T.Type, count: Int) throws(BytesError) -> Span<T> {
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Reading a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !overflow, likely(span.byteCount &- _byteOffset >= byteCount) else { throw .insufficientData }
        let bytes = unsafe span.extracting(unchecked: Range(uncheckedBounds: (_byteOffset, _byteOffset &+ byteCount)))
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
