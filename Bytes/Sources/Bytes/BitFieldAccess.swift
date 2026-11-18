// MARK: - Fields of integers

public extension FixedWidthInteger {
    /// The flag's bit, as a `Bool`.
    ///
    /// ```swift
    /// let isEncrypted = generalFlags[ZipFlags.encrypted]
    /// ```
    @inlinable
    subscript(flag: BitFlag) -> Bool {
        @inline(__always) get { self[bit: flag.bit] }
        @inline(__always) set { self[bit: flag.bit] = newValue }
    }

    /// The field's bits, right-aligned, as an `Int`.
    ///
    /// ```swift
    /// components.year = 1980 + dosDate[DOSDate.year]
    /// ```
    ///
    /// Setting stores the low `field.width` bits of the new value (debug builds check that it fits) and leaves
    /// the other bits alone.
    @inlinable
    subscript(field: BitField<Int>) -> Int {
        @inline(__always) get { Int(truncatingIfNeeded: _bits(of: field)) }
        @inline(__always) set {
            assert(newValue >= 0 && UInt64(newValue) <= field._mask, "\(newValue) doesn't fit in \(field.width) bits")
            _setBits(UInt64(truncatingIfNeeded: newValue), of: field)
        }
    }

    /// The field's bits as a ``Bits`` value of the same width.
    @inlinable
    subscript<let width: Int>(field: BitField<Bits<width>>) -> Bits<width> {
        @inline(__always) get {
            precondition(field.width == width, "A Bits<\(width)> field must be \(width) bits wide")
            return Bits(_unchecked: UInt8(truncatingIfNeeded: _bits(of: field)))
        }
        @inline(__always) set {
            precondition(field.width == width, "A Bits<\(width)> field must be \(width) bits wide")
            _setBits(UInt64(newValue.rawValue), of: field)
        }
    }

    /// The field as an `R` through its raw value, or `nil` if no `R` has that raw value. Setting stores the new
    /// value's raw value (`nil` stores 0).
    ///
    /// ```swift
    /// flags[ConnectFlags.willQoS] = will.qos
    /// ```
    @inlinable
    subscript<R: RawRepresentable>(field: BitField<R>) -> R? where R.RawValue: BinaryInteger {
        @inline(__always) get {
            guard let raw = R.RawValue(exactly: _bits(of: field)) else { return nil }
            return R(rawValue: raw)
        }
        @inline(__always) set {
            guard let newValue else { return _setBits(0, of: field) }
            // Checked, then stored unmasked: for an enum whose raw values the optimizer can see (all of them
            // fit), the check folds away and so does the mask (MQTT's PUBLISH flags: an assertion and a mask
            // cost 0.8% more instructions encoding packets).
            let raw = UInt64(truncatingIfNeeded: newValue.rawValue)
            precondition(newValue.rawValue >= 0 && raw <= field._mask, "\(newValue.rawValue) doesn't fit in \(field.width) bits")
            _setBits(unmasked: raw, of: field)
        }
    }

    /// The field as an `R` through its raw value.
    ///
    /// ```swift
    /// let qos = try flags.value(of: ConnectFlags.willQoS)
    /// ```
    ///
    /// - Parameter field: The field, such as `ConnectFlags.willQoS`.
    /// - Returns: The value whose raw value is the field's.
    /// - Throws: ``BytesError/invalidValue`` if no `R` has the field's value as its raw value.
    @inlinable @inline(__always)
    func value<R: RawRepresentable>(of field: BitField<R>) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        guard let value = self[field] else { throw .invalidValue }
        return value
    }

    /// Whether every bit of the field is 0.
    ///
    /// - Parameter field: The field to test.
    @inlinable @inline(__always)
    func isZero<Value>(_ field: BitField<Value>) -> Bool { _bits(of: field) == 0 }

    /// Checks that every bit of the field is 0: a reserved field.
    ///
    /// ```swift
    /// try flags.requireZero(ConnectAcknowledgeFlags.reserved)
    /// ```
    ///
    /// - Parameter field: The field that must be 0.
    /// - Throws: ``BytesError/invalidValue`` if any bit is set.
    @inlinable @inline(__always)
    func requireZero<Value>(_ field: BitField<Value>) throws(BytesError) {
        guard isZero(field) else { throw .invalidValue }
    }

    /// Whether the flag's bit is 0.
    ///
    /// - Parameter flag: The flag to test.
    @inlinable @inline(__always)
    func isClear(_ flag: BitFlag) -> Bool { !self[flag] }

    /// Checks that the flag's bit is 0: a reserved bit.
    ///
    /// - Parameter flag: The flag that must be clear.
    /// - Throws: ``BytesError/invalidValue`` if it's set.
    @inlinable @inline(__always)
    func requireClear(_ flag: BitFlag) throws(BytesError) {
        guard isClear(flag) else { throw .invalidValue }
    }

    /// Whether the value matches `pattern`: its `0` and `1` digits, ignoring its `?`s.
    ///
    /// ```swift
    /// guard descriptor.matches("0???_0000") else { throw .invalidValue }
    /// ```
    ///
    /// - Parameter pattern: The pattern, one digit per bit, most significant first.
    /// - Precondition: The pattern has `bitWidth` digits.
    @inlinable @inline(__always)
    func matches(_ pattern: BitPattern) -> Bool {
        precondition(pattern.bitCount == Self.bitWidth, "A pattern for \(Self.bitWidth) bits needs \(Self.bitWidth) digits")
        return UInt64(truncatingIfNeeded: self) & pattern.mask == pattern.value
    }

    @inlinable @inline(__always)
    internal func _bits<Value>(of field: BitField<Value>) -> UInt64 {
        precondition(field.offset &+ field.width <= Self.bitWidth, "A field past bit \(Self.bitWidth)")
        return UInt64(truncatingIfNeeded: self) &>> UInt64(field.offset) & field._mask
    }

    @inlinable @inline(__always)
    internal mutating func _setBits<Value>(_ bits: UInt64, of field: BitField<Value>) {
        precondition(field.offset &+ field.width <= Self.bitWidth, "A field past bit \(Self.bitWidth)")
        let mask = Self(truncatingIfNeeded: field._mask &<< UInt64(field.offset))
        self = self & ~mask | Self(truncatingIfNeeded: bits &<< UInt64(field.offset)) & mask
    }

    /// `_setBits(_:of:)` for bits already known to fit the field.
    @inlinable @inline(__always)
    internal mutating func _setBits<Value>(unmasked bits: UInt64, of field: BitField<Value>) {
        precondition(field.offset &+ field.width <= Self.bitWidth, "A field past bit \(Self.bitWidth)")
        let mask = Self(truncatingIfNeeded: field._mask &<< UInt64(field.offset))
        self = self & ~mask | Self(truncatingIfNeeded: bits &<< UInt64(field.offset))
    }
}

// MARK: - Fields of Bits

public extension Bits {
    /// A one-bit flag, for declaring a format's flags: `Byte.Flag(bit: 7)`.
    typealias Flag = BitFlag
    /// A field of adjacent bits, for declaring a format's fields: `Byte.Field<QualityOfService>(bits: 3...4)`.
    typealias Field<Value> = BitField<Value>

    /// The flag's bit, as a `Bool`.
    @inlinable
    subscript(flag: BitFlag) -> Bool {
        @inline(__always) get { self[bit: flag.bit] }
        @inline(__always) set { self[bit: flag.bit] = newValue }
    }

    /// The field's bits, right-aligned, as an `Int`.
    @inlinable
    subscript(field: BitField<Int>) -> Int {
        @inline(__always) get { _checkField(field); return rawValue[field] }
        @inline(__always) set { _checkField(field); _rawValue[field] = newValue }
    }

    /// The field's bits as a ``Bits`` value of the same width.
    @inlinable
    subscript<let fieldWidth: Int>(field: BitField<Bits<fieldWidth>>) -> Bits<fieldWidth> {
        @inline(__always) get { _checkField(field); return rawValue[field] }
        @inline(__always) set { _checkField(field); _rawValue[field] = newValue }
    }

    /// The field as an `R` through its raw value, or `nil` if no `R` has that raw value. Setting stores the new
    /// value's raw value (`nil` stores 0).
    @inlinable
    subscript<R: RawRepresentable>(field: BitField<R>) -> R? where R.RawValue: BinaryInteger {
        @inline(__always) get { _checkField(field); return rawValue[field] }
        @inline(__always) set { _checkField(field); _rawValue[field] = newValue }
    }

    /// The field as an `R` through its raw value.
    ///
    /// - Parameter field: The field, such as `ConnectFlags.willQoS`.
    /// - Returns: The value whose raw value is the field's.
    /// - Throws: ``BytesError/invalidValue`` if no `R` has the field's value as its raw value.
    @inlinable @inline(__always)
    func value<R: RawRepresentable>(of field: BitField<R>) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        _checkField(field)
        return try rawValue.value(of: field)
    }

    /// Whether every bit of the field is 0.
    ///
    /// - Parameter field: The field to test.
    @inlinable @inline(__always)
    func isZero<Value>(_ field: BitField<Value>) -> Bool { _checkField(field); return rawValue.isZero(field) }

    /// Checks that every bit of the field is 0: a reserved field.
    ///
    /// - Parameter field: The field that must be 0.
    /// - Throws: ``BytesError/invalidValue`` if any bit is set.
    @inlinable @inline(__always)
    func requireZero<Value>(_ field: BitField<Value>) throws(BytesError) {
        guard isZero(field) else { throw .invalidValue }
    }

    /// Whether the flag's bit is 0.
    ///
    /// - Parameter flag: The flag to test.
    @inlinable @inline(__always)
    func isClear(_ flag: BitFlag) -> Bool { !self[flag] }

    /// Checks that the flag's bit is 0: a reserved bit.
    ///
    /// - Parameter flag: The flag that must be clear.
    /// - Throws: ``BytesError/invalidValue`` if it's set.
    @inlinable @inline(__always)
    func requireClear(_ flag: BitFlag) throws(BytesError) {
        guard isClear(flag) else { throw .invalidValue }
    }

    /// Whether the value matches `pattern`: its `0` and `1` digits, ignoring its `?`s.
    ///
    /// - Parameter pattern: The pattern, one digit per bit, most significant first.
    /// - Precondition: The pattern has `width` digits.
    @inlinable @inline(__always)
    func matches(_ pattern: BitPattern) -> Bool {
        precondition(pattern.bitCount == width, "A pattern for \(width) bits needs \(width) digits")
        return UInt64(rawValue) & pattern.mask == pattern.value
    }

    @inlinable @inline(__always)
    internal func _checkField<Value>(_ field: BitField<Value>) {
        precondition(field.offset &+ field.width <= width, "A field past bit \(width) of Bits<\(width)>")
    }

    // MARK: Values

    /// The bits as a number: 0 through `2^width - 1`.
    ///
    /// ```swift
    /// let literalCount = token.highHalf.value
    /// ```
    @inlinable
    var value: Int { Int(rawValue) }

    /// The bits as a number less `bias`: a field stored with an offset, such as QOI's 2-bit color
    /// differences, stored plus 2 (`0b00` is -2).
    ///
    /// - Parameter bias: What the stored value has added.
    /// - Returns: `value - bias`.
    @inlinable @inline(__always)
    func value(minus bias: Int) -> Int { Int(rawValue) &- bias }

    /// A value built by setting its fields, starting from zero.
    ///
    /// ```swift
    /// let header = Byte {
    ///     $0[PacketHeader.type] = .publish
    ///     $0[PacketHeader.retain] = true
    /// }
    /// ```
    ///
    /// - Parameter build: Sets the fields.
    @inlinable @inline(__always)
    init(_ build: (inout Self) -> Void) {
        self = .zero
        build(&self)
    }

    /// Every bit flipped.
    @inlinable @inline(__always)
    func toggled() -> Self { Self(_unchecked: ~rawValue & Self.mask) }
}

public extension Bits where width == 1 {
    /// A set bit: 1.
    @inlinable
    static var set: Self { Self(_unchecked: 1) }

    /// A clear bit: 0.
    @inlinable
    static var clear: Self { Self(_unchecked: 0) }

    /// Whether the bit is 0.
    @inlinable
    var isClear: Bool { rawValue == 0 }
}
