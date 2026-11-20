// Integers by type, in the cursor's byte order (``ByteOrderedCursorMode``): `read(UInt32.self)` instead of
// `read(Byte4.self, .bigEndian)`, and the byte-group forms without their order argument. Each forwards to the
// ordered form with `Mode.byteOrder`, a constant, so it compiles to the same code.

public extension GenericBytesReader where Mode: ByteOrderedCursorMode {
    /// Returns the next `I`, from its `MemoryLayout<I>.size` bytes in the cursor's byte order, without
    /// consuming it.
    ///
    /// - Parameter type: The integer type, such as `UInt32.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain.
    @inlinable @inline(__always)
    func peek<I: FixedWidthInteger & ConvertibleFromBytes>(_ type: I.Type) throws(BytesError) -> I {
        _assumeInvariant()
        guard likely(span.byteCount &- _byteOffset >= MemoryLayout<I>.size) else { throw .insufficientData }
        // Unsafe: an unchecked load. Safe: `MemoryLayout<I>.size` bytes remain (just checked).
        let raw = unsafe Load.rawBytes(I.self, from: span, at: _byteOffset)
        // A switch, not `==`: the synthesized `==` stayed an out-of-line call in specialized code.
        return switch Mode.byteOrder { case .bigEndian: I(bigEndian: raw); case .littleEndian: I(littleEndian: raw) }
    }

    /// Reads the next `I`, from its `MemoryLayout<I>.size` bytes in the cursor's byte order.
    ///
    /// ```swift
    /// let length = try reader.read(UInt16.self)
    /// let offset = try reader.read(Int32.self)   // two's complement
    /// ```
    ///
    /// - Parameter type: The integer type, such as `UInt32.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger & ConvertibleFromBytes>(_ type: I.Type) throws(BytesError) -> I {
        let value = try peek(I.self)
        _byteOffset &+= MemoryLayout<I>.size
        return value
    }

    /// Reads a `T` field as an `I`: its unsigned value, as `read(_:as:_:)` in the cursor's
    /// byte order.
    ///
    /// ```swift
    /// let size = try reader.read(Int.self, as: Byte3.self)
    /// ```
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - fieldType: The byte group the field is stored as, such as `Byte3.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if `I`
    ///   can't represent the value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger, T: ByteGroup>(_ type: I.Type, as fieldType: T.Type) throws(BytesError) -> I {
        try read(I.self, as: T.self, Mode.byteOrder)
    }

    /// Reads a `T` field as a two's complement integer sign-extended to `I`, as
    /// ``GenericBytesReader/read(_:asSigned:_:)`` in the cursor's byte order.
    ///
    /// - Parameters:
    ///   - type: The signed integer type to read, such as `Int.self`.
    ///   - fieldType: The byte group the field is stored as, such as `Byte3.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger & SignedInteger, T: ByteGroup>(
        _ type: I.Type, asSigned fieldType: T.Type
    ) throws(BytesError) -> I {
        try read(I.self, asSigned: T.self, Mode.byteOrder)
    }

    /// Reads a `T` field as an `R`, through its raw value, in the cursor's byte order.
    ///
    /// - Parameters:
    ///   - type: The type to read, such as a message-type enum.
    ///   - fieldType: The byte group the field is stored as, such as `Byte2.self`.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if the
    ///   field isn't a valid raw value. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<R: RawRepresentable, T: ByteGroup>(_ type: R.Type, as fieldType: T.Type) throws(BytesError) -> R
        where R.RawValue: BinaryInteger {
        try read(R.self, as: T.self, Mode.byteOrder)
    }

    /// Consumes `expected` if it's next, in the cursor's byte order: a magic number.
    ///
    /// ```swift
    /// try reader.expect(0x8950_4E47 as UInt32)
    /// ```
    ///
    /// - Parameter expected: The value that must come next.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/mismatch`` if the next
    ///   value differs. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<I: FixedWidthInteger & ConvertibleFromBytes>(_ expected: I) throws(BytesError) {
        guard try peek(I.self) == expected else { throw .mismatch }
        _byteOffset &+= MemoryLayout<I>.size
    }

    /// Reads a section whose byte count comes first, as a `L`, in the cursor's byte order.
    ///
    /// - Parameter lengthType: The byte group the length is stored as, such as `Byte2.self`.
    /// - Returns: A cursor over the section, borrowing the same memory.
    /// - Throws: As ``GenericBytesReader/read(sectionPrefixedBy:_:)``.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(sectionPrefixedBy lengthType: L.Type) throws(BytesError) -> Self {
        try read(sectionPrefixedBy: L.self, Mode.byteOrder)
    }
}

public extension GenericBytesWriter where Mode: ByteOrderedCursorMode {
    /// Writes `value`'s `MemoryLayout<I>.size` bytes in the writer's byte order.
    ///
    /// ```swift
    /// try writer.write(UInt16(payload.byteCount))
    /// ```
    ///
    /// A bare integer literal doesn't compile (it could be a ``Byte``, a `UInt8`, or an `Int8`): state its
    /// width, as `UInt32(0)` or `0 as UInt16`.
    ///
    /// - Parameter value: The value.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    @_disfavoredOverload
    mutating func write<I: FixedWidthInteger & BitwiseCopyable>(_ value: I) throws(BytesError) {
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= MemoryLayout<I>.size) else { throw .insufficientCapacity }
        let ordered = switch Mode.byteOrder { case .bigEndian: value.bigEndian; case .littleEndian: value.littleEndian }
        // unsafe: the check above leaves `MemoryLayout<I>.size` bytes from `_byteOffset`.
        unsafe _bytes.storeBytes(of: ordered, toUncheckedByteOffset: _byteOffset, as: I.self)
        _byteOffset &+= MemoryLayout<I>.size
    }

    /// Writes `value`, any integer, as a `T` field in the writer's byte order, as
    /// `write(_:as:_:)`.
    ///
    /// - Parameters:
    ///   - value: The value, 0 through the field's maximum.
    ///   - fieldType: The byte group to store the field as, such as `Byte3.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger, T: ByteGroup>(_ value: I, as fieldType: T.Type) throws(BytesError) {
        try write(value, as: T.self, Mode.byteOrder)
    }

    /// Writes `value` as a two's complement `T` field in the writer's byte order.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - fieldType: The byte group to store the field as, such as `Byte3.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<I: FixedWidthInteger & SignedInteger, T: ByteGroup>(_ value: I, asSigned fieldType: T.Type) throws(BytesError) {
        try write(value, asSigned: T.self, Mode.byteOrder)
    }

    /// Writes `value`'s raw value as a `T` field in the writer's byte order.
    ///
    /// - Parameters:
    ///   - value: The value whose raw value to write.
    ///   - fieldType: The byte group to store the field as, such as `Byte2.self`.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<R: RawRepresentable, T: ByteGroup>(_ value: R, as fieldType: T.Type) throws(BytesError)
        where R.RawValue: BinaryInteger {
        try write(value, as: T.self, Mode.byteOrder)
    }
}

// MARK: - Length-prefixed fields

public extension GenericBytesReader where Mode: ByteOrderedCursorMode {
    /// Reads bytes whose count comes first, as a `L` in the cursor's byte order, as
    /// ``GenericBytesReader/read(bytesPrefixedBy:_:)``.
    ///
    /// - Parameter lengthType: The byte group the count is stored as, such as `Byte2.self`.
    /// - Returns: A span of the counted bytes, not including the count.
    /// - Throws: As ``GenericBytesReader/read(bytesPrefixedBy:_:)``.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(bytesPrefixedBy lengthType: L.Type) throws(BytesError) -> RawSpan {
        try read(bytesPrefixedBy: L.self, Mode.byteOrder)
    }

    /// Reads UTF-8 text whose byte count comes first, as a `L` in the cursor's byte order, as
    /// ``GenericBytesReader/read(utf8PrefixedBy:_:)``.
    ///
    /// - Parameter lengthType: The byte group the count is stored as, such as `Byte2.self`.
    /// - Returns: The validated text.
    /// - Throws: As ``GenericBytesReader/read(utf8PrefixedBy:_:)``.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(utf8PrefixedBy lengthType: L.Type) throws(BytesError) -> UTF8Span {
        try read(utf8PrefixedBy: L.self, Mode.byteOrder)
    }

    /// Reads UTF-8 text whose byte count comes first, rejecting the bytes `excluded` matches, as
    /// ``GenericBytesReader/read(utf8PrefixedBy:_:excluding:)`` in the cursor's byte order.
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the count is stored as, such as `Byte2.self`.
    ///   - excluded: The bytes the text may not contain, sixteen at a time.
    /// - Returns: The validated text.
    /// - Throws: As ``GenericBytesReader/read(utf8PrefixedBy:_:excluding:)``.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(
        utf8PrefixedBy lengthType: L.Type, excluding excluded: (ByteLanes) -> ByteMatches
    ) throws(BytesError) -> UTF8Span {
        try read(utf8PrefixedBy: L.self, Mode.byteOrder, excluding: excluded)
    }

    /// The section whose byte count comes first, if it's all there, in the cursor's byte order, as
    /// ``GenericBytesReader/readSectionIfComplete(prefixedBy:_:)``.
    ///
    /// - Parameter lengthType: The byte group the count is stored as, such as `Byte2.self`.
    /// - Returns: A cursor over the section, or `nil` (consuming nothing) if it isn't all there.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readSectionIfComplete<L: ByteGroup>(prefixedBy lengthType: L.Type) -> Self? {
        readSectionIfComplete(prefixedBy: L.self, Mode.byteOrder)
    }

    /// Calls `body` with each tag-length-value record's tag and a cursor over its value, tags and lengths in the
    /// cursor's byte order, as ``GenericBytesReader/forEachRecord(tag:length:_:paddedTo:_:)``.
    ///
    /// ```swift
    /// try options.forEachRecord(tag: Byte2.self, length: Byte2.self, paddedTo: 4) { (code, value) throws(BytesError) in
    ///     …
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - tagType: The byte group each tag is stored as, such as `Byte2.self`.
    ///   - lengthType: The byte group each length is stored as, such as `Byte2.self`.
    ///   - alignment: The multiple each value is padded to, a power of two: 1 (the default) for no padding.
    ///   - body: Called with each record's tag and a cursor over its value.
    /// - Throws: As ``GenericBytesReader/forEachRecord(tag:length:_:paddedTo:_:)``.
    /// - Precondition: `alignment` is a power of two.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEachRecord<Tag: ByteGroup, Length: ByteGroup>(
        tag tagType: Tag.Type, length lengthType: Length.Type, paddedTo alignment: Int = 1,
        _ body: (Tag.Integer, inout Self) throws(BytesError) -> Void
    ) throws(BytesError) {
        try forEachRecord(tag: Tag.self, length: Length.self, Mode.byteOrder, paddedTo: alignment, body)
    }
}

public extension GenericBytesWriter where Mode: ByteOrderedCursorMode {
    /// Writes `bytes` after their count, as a `L` in the writer's byte order.
    ///
    /// - Parameters:
    ///   - bytes: The bytes.
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    /// - Throws: As ``GenericBytesWriter/write(_:prefixedBy:_:)-(RawSpan,_,_)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup>(_ bytes: RawSpan, prefixedBy lengthType: L.Type) throws(BytesError) {
        try write(bytes, prefixedBy: L.self, Mode.byteOrder)
    }

    /// Writes `text`'s UTF-8 after its byte count, as a `L` in the writer's byte order.
    ///
    /// - Parameters:
    ///   - text: The text.
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    /// - Throws: As ``GenericBytesWriter/write(_:prefixedBy:_:)-(UTF8Span,_,_)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup>(_ text: UTF8Span, prefixedBy lengthType: L.Type) throws(BytesError) {
        try write(text, prefixedBy: L.self, Mode.byteOrder)
    }

    /// Writes a section that `body` fills, after its byte count as a `L` in the writer's byte order, as
    /// ``GenericBytesWriter/write(sectionPrefixedBy:_:_:)``.
    ///
    /// - Parameters:
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    ///   - body: Writes the section.
    /// - Returns: What `body` returns.
    /// - Throws: As ``GenericBytesWriter/write(sectionPrefixedBy:_:_:)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup, R: ~Copyable>(
        sectionPrefixedBy lengthType: L.Type, _ body: (inout Self) throws(BytesError) -> R
    ) throws(BytesError) -> R {
        try write(sectionPrefixedBy: L.self, Mode.byteOrder, body)
    }
}
