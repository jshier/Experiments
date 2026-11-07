// Variable-size parts of a format: variable-length integers, sections whose length comes first, and
// strings. Reads are atomic (a read that throws consumes nothing), so a streaming parser can tell "not
// enough data yet" (`insufficientData`) from "malformed" (`invalidValue`, `trailingData`) and retry later.

// MARK: - LEB128

/// Unsigned LEB128, the variable-length integer encoding of MQTT ("Variable Byte Integer"), Protocol
/// Buffers ("varint"), WebAssembly, and DWARF: 7 bits per byte, least significant group first, with the
/// high bit set on every byte but the last.
///
/// Read and write it like a field type:
///
/// ```swift
/// let remainingLength = try reader.read(LEB128.self, maxByteCount: 4) // MQTT allows up to 4 bytes
/// try writer.write(remainingLength, as: LEB128.self)
/// ```
public enum LEB128 {
    /// The number of bytes `value` takes encoded: 1 through 10.
    @inlinable
    public static func byteCount(of value: UInt64) -> Int {
        // One byte per started group of 7 significant bits, and one byte for zero.
        (64 &- (value | 1).leadingZeroBitCount &+ 6) / 7
    }

    /// The largest value that fits in `byteCount` bytes, 1 through 10.
    @inlinable
    public static func maxValue(byteCount: Int) -> UInt64 {
        precondition(byteCount >= 1 && byteCount <= 10, "LEB128 integers are 1 through 10 bytes")
        return byteCount == 10 ? .max : (1 &<< UInt64(7 &* byteCount)) &- 1
    }
}

extension Bytes {
    /// Reads an unsigned LEB128 integer of at most `maxByteCount` bytes (1 through 10). Requires byte
    /// alignment.
    ///
    /// Throws ``BytesError/insufficientData`` if the data ends before the integer does, and
    /// ``BytesError/invalidValue`` if it's longer than `maxByteCount` bytes or doesn't fit in 64 bits.
    /// Either way, nothing is consumed. Single-byte values (below 128) take a fast path.
    ///
    /// Padded encodings, such as `80 00` for 0, are accepted, as DWARF and WebAssembly allow. If your
    /// format requires the shortest encoding (MQTT does), compare the bytes consumed with
    /// ``LEB128/byteCount(of:)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read(_: LEB128.Type, maxByteCount: Int = 10) throws(BytesError) -> UInt64 {
        precondition(maxByteCount >= 1 && maxByteCount <= 10, "LEB128 integers are 1 through 10 bytes")
        precondition(_bitOffset == 0, "Reading LEB128 requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_byteOffset < span.byteCount) else { throw .insufficientData }
        let first = unsafe Load.native(UInt8.self, from: span, at: _byteOffset)
        if likely(first < 0x80) {
            _byteOffset &+= 1
            return UInt64(first)
        }
        let (value, byteCount) = try Self._readLEB128(in: span, at: _byteOffset, maxByteCount: maxByteCount)
        _byteOffset &+= byteCount
        return value
    }

    /// The multi-byte case: the LEB128 integer at `offset` and its length. Out of line and static, like the
    /// other slow paths, so callers keep their cursor in registers.
    @usableFromInline
    static func _readLEB128(in span: RawSpan, at offset: Int, maxByteCount: Int) throws(BytesError) -> (UInt64, Int) {
        var value: UInt64 = 0
        var index = 0
        while true {
            // Too long first: more data can't fix it, so a streaming caller mustn't wait for any.
            guard index < maxByteCount else { throw .invalidValue }
            guard offset &+ index < span.byteCount else { throw .insufficientData }
            let byte = unsafe Load.native(UInt8.self, from: span, at: offset &+ index)
            // The tenth byte can hold only the 64th bit.
            guard index < 9 || byte <= 1 else { throw .invalidValue }
            value |= UInt64(byte & 0x7F) &<< UInt64(7 &* index)
            index &+= 1
            if byte < 0x80 { return (value, index) }
        }
    }
}

extension BytesWriter {
    /// Writes `value` as unsigned LEB128, in ``LEB128/byteCount(of:)`` bytes. Requires byte alignment.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ value: UInt64, as _: LEB128.Type) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing LEB128 requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        if likely(value < 0x80) {
            guard likely(_byteOffset < _bytes.byteCount) else { throw .insufficientCapacity }
            unsafe _bytes.storeBytes(of: UInt8(truncatingIfNeeded: value), toUncheckedByteOffset: _byteOffset, as: UInt8.self)
            _byteOffset &+= 1
            return
        }
        let byteCount = LEB128.byteCount(of: value)
        guard likely(_bytes.byteCount &- _byteOffset >= byteCount) else { throw .insufficientCapacity }
        unsafe Self._storeLEB128(value, byteCount: byteCount, to: &_bytes, at: _byteOffset)
        _byteOffset &+= byteCount
    }

    /// Stores `value` as `byteCount` bytes of LEB128 (at least ``LEB128/byteCount(of:)``) at `offset`.
    /// Capacity already checked.
    @unsafe @inlinable
    static func _storeLEB128(_ value: UInt64, byteCount: Int, to bytes: inout MutableRawSpan, at offset: Int) {
        var remaining = value
        for index in 0..<byteCount {
            let more: UInt8 = index &+ 1 < byteCount ? 0x80 : 0
            unsafe bytes.storeBytes(of: UInt8(truncatingIfNeeded: remaining & 0x7F) | more, toUncheckedByteOffset: offset &+ index, as: UInt8.self)
            remaining &>>= 7
        }
    }
}

// MARK: - Sections

extension Bytes {
    /// Reads the next `byteCount` bytes as a cursor of their own, with the same bit order: a section to parse
    /// separately, such as a record, a message body, or a list. Requires byte alignment.
    ///
    /// Parsing a section with its own cursor bounds every read in it to the section, and when its length is a
    /// constant the optimizer can see, lets it drop the bounds checks of reads inside it. Call
    /// ``expectEnd()`` on the section if it must be fully consumed.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func readSection(byteCount: Int) throws(BytesError) -> Bytes {
        Bytes(try read(byteCount: byteCount), bitOrder: bitOrder)
    }

    /// Reads a section whose byte count comes first, as a `L` in `byteOrder`. Requires byte alignment.
    ///
    /// ```swift
    /// var record = try reader.read(sectionPrefixedBy: Byte2.self, .bigEndian)
    /// ```
    ///
    /// Throws ``BytesError/insufficientData`` without consuming anything (not even the length) if the section
    /// isn't all there.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read<L: ByteGroup>(sectionPrefixedBy _: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> Bytes {
        Bytes(try read(bytesPrefixedBy: L.self, byteOrder), bitOrder: bitOrder)
    }

    /// Reads a section whose byte count comes first, as LEB128 of at most `maxByteCount` bytes. Requires byte
    /// alignment.
    ///
    /// ```swift
    /// var properties = try reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
    /// ```
    ///
    /// Throws without consuming anything (not even the length) if the section isn't all there
    /// (``BytesError/insufficientData``) or the length is malformed (``BytesError/invalidValue``).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read(sectionPrefixedBy _: LEB128.Type, maxByteCount: Int = 10) throws(BytesError) -> Bytes {
        Bytes(try read(bytesPrefixedBy: LEB128.self, maxByteCount: maxByteCount), bitOrder: bitOrder)
    }

    /// Reads bytes whose count comes first, as a `L` in `byteOrder`, as a span of the same memory. Requires
    /// byte alignment. Throws without consuming anything if they aren't all there
    /// (``BytesError/insufficientData``) or the count doesn't fit in an `Int` (``BytesError/invalidValue``).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read<L: ByteGroup>(bytesPrefixedBy _: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> RawSpan {
        precondition(_bitOffset == 0, "Reading a section requires byte alignment: call alignToByte() first")
        let length = try peek(L.self, byteOrder)
        guard let count = Int(exactly: length) else { throw .invalidValue }
        guard likely(span.byteCount &- _byteOffset &- L.byteCount >= count) else { throw .insufficientData }
        _byteOffset &+= L.byteCount
        return try read(byteCount: count)
    }

    /// Reads bytes whose count comes first, as LEB128 of at most `maxByteCount` bytes, as a span of the same
    /// memory. Requires byte alignment. Throws without consuming anything if they aren't all there
    /// (``BytesError/insufficientData``) or the length is malformed (``BytesError/invalidValue``).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read(bytesPrefixedBy _: LEB128.Type, maxByteCount: Int = 10) throws(BytesError) -> RawSpan {
        let start = _byteOffset
        let length = try read(LEB128.self, maxByteCount: maxByteCount)
        guard let count = Int(exactly: length) else {
            _byteOffset = start
            throw .invalidValue
        }
        guard likely(span.byteCount &- _byteOffset >= count) else {
            _byteOffset = start
            throw .insufficientData
        }
        return try read(byteCount: count)
    }

    /// Throws ``BytesError/trailingData`` unless every byte has been read: for checking that a section was
    /// fully consumed.
    @inlinable @inline(__always)
    public func expectEnd() throws(BytesError) {
        guard likely(_byteOffset == span.byteCount) else { throw .trailingData }
    }
}

// MARK: - Strings

extension Bytes {
    /// Reads the next `byteCount` bytes as validated UTF-8, viewing the same memory. Requires byte alignment.
    ///
    /// Throws ``BytesError/invalidValue`` without consuming anything if they aren't valid UTF-8. Convert
    /// to a `String` with `String(copying:)` when you need to keep it.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func readUTF8(byteCount: Int) throws(BytesError) -> UTF8Span {
        let start = _byteOffset
        let bytes = try read(byteCount: byteCount)
        do {
            return try UTF8Span(validating: Span(viewing: bytes))
        } catch {
            _byteOffset = start
            throw .invalidValue
        }
    }

    /// Reads UTF-8 whose byte count comes first, as a `L` in `byteOrder`, viewing the same memory. Requires
    /// byte alignment.
    ///
    /// ```swift
    /// let topic = try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian) // an MQTT string
    /// ```
    ///
    /// Throws without consuming anything if the bytes aren't all there (``BytesError/insufficientData``) or
    /// aren't valid UTF-8 (``BytesError/invalidValue``).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    public mutating func read<L: ByteGroup>(utf8PrefixedBy _: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> UTF8Span {
        let start = _byteOffset
        let bytes = try read(bytesPrefixedBy: L.self, byteOrder)
        do {
            return try UTF8Span(validating: Span(viewing: bytes))
        } catch {
            _byteOffset = start
            throw .invalidValue
        }
    }
}

// MARK: - Writing sections

extension BytesWriter {
    /// Writes `bytes` preceded by their byte count as a `L` in `byteOrder`. Requires byte alignment.
    ///
    /// Throws ``BytesError/invalidValue`` if the count doesn't fit in `L`, and
    /// ``BytesError/insufficientCapacity`` if there isn't room; either way nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<L: ByteGroup>(_ bytes: RawSpan, prefixedBy _: L.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        guard let length = L.Integer(exactly: bytes.byteCount), length <= L._mask else { throw .invalidValue }
        guard likely(remainingByteCount &- L.byteCount >= bytes.byteCount) else { throw .insufficientCapacity }
        try write(length, as: L.self, byteOrder)
        try write(bytes)
    }

    /// Writes `text`'s UTF-8 preceded by its byte count as a `L` in `byteOrder`. Requires byte alignment.
    ///
    /// ```swift
    /// try writer.write(topic.utf8Span, prefixedBy: Byte2.self, .bigEndian) // an MQTT string
    /// ```
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<L: ByteGroup>(_ text: UTF8Span, prefixedBy _: L.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        try write(text.span.bytes, prefixedBy: L.self, byteOrder)
    }

    /// Writes `bytes` preceded by their byte count as LEB128. Requires byte alignment. Nothing is written if
    /// it throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ bytes: RawSpan, prefixedBy _: LEB128.Type) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        let count = UInt64(bytes.byteCount)
        guard likely(remainingByteCount &- LEB128.byteCount(of: count) >= bytes.byteCount) else { throw .insufficientCapacity }
        try write(count, as: LEB128.self)
        try write(bytes)
    }

    /// Writes a section whose byte count comes first, as a `L` in `byteOrder`: `body` writes the section
    /// with a writer of its own, and its byte count is filled in afterwards, with nothing moved or copied.
    /// Requires byte alignment.
    ///
    /// ```swift
    /// try writer.write(sectionPrefixedBy: Byte2.self, .bigEndian) { (section) throws(BytesError) in
    ///     try section.write(id, as: Byte4.self, .bigEndian)
    ///     try section.write(name.utf8Span, prefixedBy: Byte2.self, .bigEndian)
    /// }
    /// ```
    ///
    /// If `body` throws, or the section is too long for `L` (``BytesError/invalidValue``), the cursor doesn't
    /// move, though bytes after it may have been overwritten.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<L: ByteGroup, R: ~Copyable>(
        sectionPrefixedBy _: L.Type, _ byteOrder: ByteOrder, _ body: (inout BytesWriter) throws(BytesError) -> R
    ) throws(BytesError) -> R {
        precondition(_bitOffset == 0, "Writing a section requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= L.byteCount) else { throw .insufficientCapacity }
        let prefixOffset = _byteOffset
        let sectionStart = prefixOffset &+ L.byteCount
        var written = 0
        let result = try _writeSection(from: sectionStart, written: &written, body)
        guard let length = L.Integer(exactly: written), length <= L._mask else { throw .invalidValue }
        unsafe Store.group(L(length, byteOrder), to: &_bytes, at: prefixOffset)
        _byteOffset = sectionStart &+ written
        return result
    }

    /// Writes a section whose byte count comes first as LEB128 of at most `maxByteCount` bytes. Requires byte
    /// alignment.
    ///
    /// The count's length isn't known until the section is written, so this reserves `maxByteCount` bytes for
    /// it, and `body` gets the capacity after them. If the count turns out shorter, the section is moved down
    /// (a copy of it), leaving up to `maxByteCount - 1` stale bytes after the cursor. To avoid both, compute
    /// the section's size first and write the count with ``write(_:as:)-(UInt64,_)`` (see
    /// ``LEB128/byteCount(of:)``). Pick the smallest `maxByteCount` your format allows.
    ///
    /// If `body` throws, or the section is too long for `maxByteCount` bytes of LEB128
    /// (``BytesError/invalidValue``), the cursor doesn't move, though bytes after it may have been overwritten.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<R: ~Copyable>(
        sectionPrefixedBy _: LEB128.Type, maxByteCount: Int, _ body: (inout BytesWriter) throws(BytesError) -> R
    ) throws(BytesError) -> R {
        precondition(maxByteCount >= 1 && maxByteCount <= 10, "LEB128 integers are 1 through 10 bytes")
        precondition(_bitOffset == 0, "Writing a section requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= maxByteCount) else { throw .insufficientCapacity }
        let prefixOffset = _byteOffset
        var written = 0
        let result = try _writeSection(from: prefixOffset &+ maxByteCount, written: &written, body)
        guard UInt64(written) <= LEB128.maxValue(byteCount: maxByteCount) else { throw .invalidValue }
        let prefixByteCount = LEB128.byteCount(of: UInt64(written))
        if prefixByteCount < maxByteCount, written > 0 {
            let source = prefixOffset &+ maxByteCount
            let destination = prefixOffset &+ prefixByteCount
            _bytes.withUnsafeMutableBytes { bytes in
                let base = bytes.baseAddress!
                // Overlapping move: `copyMemory` is `memmove`.
                unsafe (base + destination).copyMemory(from: base + source, byteCount: written)
            }
        }
        unsafe Self._storeLEB128(UInt64(written), byteCount: prefixByteCount, to: &_bytes, at: prefixOffset)
        _byteOffset = prefixOffset &+ prefixByteCount &+ written
        return result
    }

    /// Runs `body` with a writer over the free bytes from `start`, sets `written` to how many bytes it wrote,
    /// and returns its result. Capacity for `start` already checked.
    @inlinable @inline(__always)
    mutating func _writeSection<R: ~Copyable>(
        from start: Int, written: inout Int, _ body: (inout BytesWriter) throws(BytesError) -> R
    ) throws(BytesError) -> R {
        var section = unsafe BytesWriter(
            _bytes._mutatingExtracting(unchecked: Range(uncheckedBounds: (start, _bytes.byteCount))), bitOrder: bitOrder
        )
        let result = try body(&section)
        written = section.byteCount
        return result
    }
}
