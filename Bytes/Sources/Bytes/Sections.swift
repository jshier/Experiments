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
    /// The number of bytes `value` takes encoded, in the fewest bytes.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The byte count, 1 through 10.
    @inlinable
    public static func byteCount(of value: UInt64) -> Int {
        // One byte per started group of 7 significant bits, and one byte for zero.
        (64 &- (value | 1).leadingZeroBitCount &+ 6) / 7
    }

    /// The largest value that fits in `byteCount` bytes: `2^(7 × byteCount) - 1`, or every bit of a `UInt64`
    /// for 10 bytes.
    ///
    /// - Parameter byteCount: The encoded length, 1 through 10.
    /// - Returns: The largest value.
    /// - Precondition: `byteCount` is 1 through 10.
    @inlinable
    public static func maxValue(byteCount: Int) -> UInt64 {
        precondition(byteCount >= 1 && byteCount <= 10, "LEB128 integers are 1 through 10 bytes")
        return UInt64.lowBitMask(7 &* byteCount) // 70 bits for 10 bytes: every bit
    }
}

extension BytesReader {
    /// Reads an unsigned LEB128 integer of at most `maxByteCount` bytes. Nothing is consumed if it throws.
    /// Single-byte values (below 128) take a fast path.
    ///
    /// Padded encodings, such as `80 00` for 0, are accepted, as DWARF and WebAssembly allow, unless
    /// `requiringMinimal`: then a value not in the fewest bytes (MQTT requires them) is rejected. The check
    /// costs nothing on the single-byte fast path and one compare in the multi-byte loop: a value is padded
    /// when it's more than one byte and its last byte is zero.
    ///
    /// - Parameters:
    ///   - format: `LEB128.self`, which selects this encoding.
    ///   - maxByteCount: The longest encoding to accept, 1 through 10.
    ///   - requiringMinimal: Whether to reject an encoding longer than necessary.
    /// - Returns: The value.
    /// - Throws: ``BytesError/insufficientData`` if the data ends before the integer does;
    ///   ``BytesError/invalidValue`` if it's longer than `maxByteCount` bytes, doesn't fit in 64 bits, or is
    ///   padded when `requiringMinimal`.
    /// - Precondition: `maxByteCount` is 1 through 10, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read(_ format: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool = false) throws(BytesError) -> UInt64 {
        precondition(maxByteCount >= 1 && maxByteCount <= 10, "LEB128 integers are 1 through 10 bytes")
        precondition(_bitOffset == 0, "Reading LEB128 requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_byteOffset < span.byteCount) else { throw .insufficientData }
        let first = unsafe Load.native(UInt8.self, from: span, at: _byteOffset)
        if likely(first < 0x80) {
            _byteOffset &+= 1
            return UInt64(first)
        }
        let (value, byteCount) = try Self._readLEB128(
            in: span, at: _byteOffset, maxByteCount: maxByteCount, requiringMinimal: requiringMinimal
        )
        _byteOffset &+= byteCount
        return value
    }

    /// The multi-byte case: the LEB128 integer at `offset` and its length. Out of line and static, like the
    /// other slow paths, so callers keep their cursor in registers.
    ///
    /// - Parameters:
    ///   - span: The bytes being read.
    ///   - offset: The byte offset of the integer.
    ///   - maxByteCount: The longest encoding to accept.
    ///   - requiringMinimal: Whether to reject a padded encoding.
    /// - Returns: The value and the number of bytes it took.
    /// - Throws: As ``read(_:maxByteCount:requiringMinimal:)``.
    @usableFromInline
    static func _readLEB128(
        in span: RawSpan, at offset: Int, maxByteCount: Int, requiringMinimal: Bool
    ) throws(BytesError) -> (UInt64, Int) {
        var value: UInt64 = 0
        var index = 0
        while true {
            // Too long first: more data can't fix it, so a streaming caller mustn't wait for any.
            guard index < maxByteCount else { throw .invalidValue }
            guard offset &+ index < span.byteCount else { throw .insufficientData }
            let byte = span.load(fromByteOffset: offset &+ index, as: UInt8.self) // Rare: checked.
            // The tenth byte can hold only the 64th bit.
            guard index < 9 || byte <= 1 else { throw .invalidValue }
            value |= UInt64(byte & 0x7F) &<< UInt64(7 &* index)
            index &+= 1
            if byte < 0x80 {
                // Only called for more than one byte: a last byte of zero adds nothing, so fewer would do.
                guard !requiringMinimal || byte != 0 else { throw .invalidValue }
                return (value, index)
            }
        }
    }
}

extension BytesWriter {
    /// Writes `value` as unsigned LEB128, in ``LEB128/byteCount(of:)`` bytes.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - format: `LEB128.self`, which selects this encoding.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room, writing nothing.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ value: UInt64, as format: LEB128.Type) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing LEB128 requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        if likely(value < 0x80) {
            guard likely(_byteOffset < _bytes.byteCount) else { throw .insufficientCapacity }
            unsafe Store.little(UInt8(truncatingIfNeeded: value), to: &_bytes, at: _byteOffset) // Unchecked: see `Store`.
            _byteOffset &+= 1
            return
        }
        let byteCount = LEB128.byteCount(of: value)
        guard likely(_bytes.byteCount &- _byteOffset >= byteCount) else { throw .insufficientCapacity }
        Self._storeLEB128(value, byteCount: byteCount, to: &_bytes, at: _byteOffset)
        _byteOffset &+= byteCount
    }

    /// Stores `value` as `byteCount` bytes of LEB128 (at least ``LEB128/byteCount(of:)``) at `offset`.
    /// Capacity already checked.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - byteCount: The number of bytes to write, 1 through 10.
    ///   - bytes: The buffer to write into.
    ///   - offset: The byte offset of the first byte.
    @inlinable
    static func _storeLEB128(_ value: UInt64, byteCount: Int, to bytes: inout MutableRawSpan, at offset: Int) {
        var remaining = value
        for index in 0..<byteCount {
            let more: UInt8 = index &+ 1 < byteCount ? 0x80 : 0
            bytes.storeBytes(of: UInt8(truncatingIfNeeded: remaining & 0x7F) | more, toByteOffset: offset &+ index, as: UInt8.self)
            remaining &>>= 7
        }
    }
}

// MARK: - Sections

public extension BytesReader {
    /// Reads the next `byteCount` bytes as a cursor of their own, with the same bit order: a section to parse
    /// separately, such as a record, a message body, or a list.
    ///
    /// Parsing a section with its own cursor bounds every read in it to the section, and when its length is a
    /// constant the optimizer can see, lets it drop the bounds checks of reads inside it. Call
    /// ``expectEnd()`` on the section if it must be fully consumed.
    ///
    /// - Parameter byteCount: The section's length in bytes.
    /// - Returns: A cursor over the section, borrowing the same memory.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain, consuming nothing.
    /// - Precondition: `byteCount` isn't negative, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readSection(byteCount: Int) throws(BytesError) -> BytesReader {
        try BytesReader(read(byteCount: byteCount), bitOrder: bitOrder)
    }

    /// Reads a section whose byte count comes first, as a `L` in `byteOrder`.
    ///
    /// ```swift
    /// var record = try reader.read(sectionPrefixedBy: Byte2.self, .bigEndian)
    /// ```
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the length is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the length.
    /// - Returns: A cursor over the section, borrowing the same memory.
    /// - Throws: ``BytesError/insufficientData`` if the length or the section isn't all there;
    ///   ``BytesError/invalidValue`` if the length doesn't fit in an `Int`. Nothing is consumed, not even the
    ///   length.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(sectionPrefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> BytesReader {
        try BytesReader(read(bytesPrefixedBy: L.self, byteOrder), bitOrder: bitOrder)
    }

    /// Reads a section whose byte count comes first, as LEB128 of at most `maxByteCount` bytes.
    ///
    /// ```swift
    /// var properties = try reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
    /// ```
    ///
    /// - Parameters:
    ///   - lengthType: `LEB128.self`, which selects this length encoding.
    ///   - maxByteCount: The longest length encoding to accept, 1 through 10.
    ///   - requiringMinimal: Whether to reject a length not in the fewest bytes.
    /// - Returns: A cursor over the section, borrowing the same memory.
    /// - Throws: ``BytesError/insufficientData`` if the length or the section isn't all there;
    ///   ``BytesError/invalidValue`` if the length is longer than `maxByteCount`, doesn't fit in an `Int`, or
    ///   is padded when `requiringMinimal`. Nothing is consumed, not even the length.
    /// - Precondition: `maxByteCount` is 1 through 10, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(
        sectionPrefixedBy lengthType: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool = false
    ) throws(BytesError) -> BytesReader {
        try BytesReader(
            read(bytesPrefixedBy: LEB128.self, maxByteCount: maxByteCount, requiringMinimal: requiringMinimal),
            bitOrder: bitOrder
        )
    }

    /// Reads bytes whose count comes first, as a `L` in `byteOrder`, as a span of the same memory.
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the count is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    /// - Returns: A span of the counted bytes, not including the count.
    /// - Throws: ``BytesError/insufficientData`` if the count or the bytes aren't all there;
    ///   ``BytesError/invalidValue`` if the count doesn't fit in an `Int`. Nothing is consumed.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(bytesPrefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> RawSpan {
        precondition(_bitOffset == 0, "Reading a section requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let length = try peek(L.self, byteOrder)
        guard let count = Int(exactly: length) else { throw .invalidValue }
        let start = _byteOffset &+ L.byteCount
        guard likely(span.byteCount &- start >= count) else { throw .insufficientData }
        _byteOffset = start &+ count
        // One length check: `read(byteCount:)` checked again, and its checked `extracting` a third time (zip
        // directories with `read(sectionPrefixedBy:)` measured 0.7% more instructions than a hand-written
        // check). Unsafe: unchecked extracting. Safe: `peek` proved `start <= span.byteCount`, and the guard
        // that `count` bytes follow.
        return unsafe span.extracting(unchecked: start..<_byteOffset)
    }

    /// Reads a section whose byte count comes first, as a `L` in `byteOrder`, if it's all there: `nil` if
    /// the length or the bytes it counts aren't (or the count doesn't fit in an `Int`), consuming nothing.
    /// For formats that tolerate a truncated last record, such as zip's extra fields, without `try?`.
    /// Requires byte alignment.
    ///
    /// ```swift
    /// while extra.remainingByteCount >= 4 {
    ///     let id = try extra.read(Byte2.self, .littleEndian)
    ///     guard var field = extra.readSectionIfComplete(prefixedBy: Byte2.self, .littleEndian) else { break }
    ///     …
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the length is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the length.
    /// - Returns: A cursor over the section, borrowing the same memory, or `nil` if it isn't all there.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readSectionIfComplete<L: ByteGroup>(prefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) -> BytesReader? {
        precondition(_bitOffset == 0, "Reading a section requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(span.byteCount &- _byteOffset >= L.byteCount) else { return nil }
        // Unsafe: an unchecked load. Safe: `L.byteCount` bytes are there (just checked).
        let length = unsafe Load.group(L.self, from: span, at: _byteOffset)
        guard let count = Int(exactly: length.integer(byteOrder)) else { return nil }
        let start = _byteOffset &+ L.byteCount
        guard likely(span.byteCount &- start >= count) else { return nil }
        _byteOffset = start &+ count
        // Unsafe: unchecked extracting. Safe: `start + count <= span.byteCount`, checked above.
        return BytesReader(unsafe span.extracting(unchecked: start..<_byteOffset), bitOrder: bitOrder)
    }

    /// Calls `body` with each tag-length-value record's tag and a cursor over its value, until fewer bytes
    /// remain than a tag and a length: zip extra fields, TLS extensions, BLE advertising data.
    ///
    /// ```swift
    /// try extra.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { (id, field) throws(BytesError) in
    ///     if id == 0x5455 { … }   // an extended timestamp
    /// }
    /// ```
    ///
    /// Each record is all or nothing: if one's value isn't all there, or `body` throws on it, the cursor is
    /// left at the start of that record (earlier records stay consumed). Trailing bytes too few for a
    /// record's tag and length are left unread, as `forEach` leaves a partial value. To stop quietly at an
    /// incomplete record instead, loop with ``readSectionIfComplete(prefixedBy:_:)``.
    ///
    /// Annotate the closure's error type, as in the example: an unannotated closure that throws is inferred
    /// to throw `any Error`, which doesn't convert.
    ///
    /// - Parameters:
    ///   - tagType: The byte group each tag is stored as, such as `Byte2.self`.
    ///   - lengthType: The byte group each length is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the tags and lengths.
    ///   - body: Called with each record's tag and a cursor over its value.
    /// - Throws: ``BytesError/insufficientData`` if a record's value isn't all there;
    ///   ``BytesError/invalidValue`` if its length doesn't fit in an `Int`; or whatever `body` throws.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEachRecord<Tag: ByteGroup, Length: ByteGroup>(
        tag tagType: Tag.Type, length lengthType: Length.Type, _ byteOrder: ByteOrder,
        _ body: (Tag.Integer, inout BytesReader) throws(BytesError) -> Void
    ) throws(BytesError) {
        precondition(_bitOffset == 0, "Reading records requires byte alignment: call alignToByte() first")
        let headerByteCount = Tag.byteCount &+ Length.byteCount
        // No closures (`atomically`) inside: the loop keeps the cursor in registers.
        while true {
            _assumeInvariant()
            let recordStart = _byteOffset
            guard span.byteCount &- recordStart >= headerByteCount else { return }
            // Unsafe: unchecked loads. Safe: `headerByteCount` bytes are there (just checked).
            let tag = unsafe Load.group(Tag.self, from: span, at: recordStart).integer(byteOrder)
            let length = unsafe Load.group(Length.self, from: span, at: recordStart &+ Tag.byteCount).integer(byteOrder)
            guard let count = Int(exactly: length) else { throw .invalidValue }
            let start = recordStart &+ headerByteCount
            guard likely(span.byteCount &- start >= count) else { throw .insufficientData }
            _byteOffset = start &+ count
            // Unsafe: unchecked extracting. Safe: `start + count <= span.byteCount`, checked above.
            var value = BytesReader(unsafe span.extracting(unchecked: start..<_byteOffset), bitOrder: bitOrder)
            do throws(BytesError) {
                try body(tag, &value)
            } catch {
                _byteOffset = recordStart
                throw error
            }
        }
    }

    /// Reads bytes whose count comes first, as LEB128 of at most `maxByteCount` bytes, as a span of the same
    /// memory.
    ///
    /// - Parameters:
    ///   - lengthType: `LEB128.self`, which selects this count encoding.
    ///   - maxByteCount: The longest count encoding to accept, 1 through 10.
    ///   - requiringMinimal: Whether to reject a count not in the fewest bytes.
    /// - Returns: A span of the counted bytes, not including the count.
    /// - Throws: ``BytesError/insufficientData`` if the count or the bytes aren't all there;
    ///   ``BytesError/invalidValue`` if the count is longer than `maxByteCount`, doesn't fit in an `Int`, or is
    ///   padded when `requiringMinimal`. Nothing is consumed.
    /// - Precondition: `maxByteCount` is 1 through 10, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(
        bytesPrefixedBy lengthType: LEB128.Type, maxByteCount: Int = 10, requiringMinimal: Bool = false
    ) throws(BytesError) -> RawSpan {
        let start = _byteOffset
        let length = try read(LEB128.self, maxByteCount: maxByteCount, requiringMinimal: requiringMinimal)
        guard let count = Int(exactly: length) else {
            _byteOffset = start
            throw .invalidValue
        }
        guard likely(span.byteCount &- _byteOffset >= count) else {
            _byteOffset = start
            throw .insufficientData
        }
        let end = _byteOffset &+ count
        // Unsafe: unchecked extracting. Safe: the cursor is in the span, and `count` bytes follow it (checked).
        let bytes = unsafe span.extracting(unchecked: _byteOffset..<end)
        _byteOffset = end
        return bytes
    }

    /// Checks that every byte has been read (see ``isAtEnd``): for checking that a section was fully consumed.
    ///
    /// - Throws: ``BytesError/trailingData`` if any remain.
    @inlinable @inline(__always)
    func expectEnd() throws(BytesError) {
        guard likely(_byteOffset == span.byteCount) else { throw .trailingData }
    }
}

// MARK: - Strings

public extension BytesReader {
    /// Reads the next `byteCount` bytes as validated UTF-8, viewing the same memory. Convert to a `String`
    /// with `String(copying:)` when you need to keep it.
    ///
    /// - Parameter byteCount: The length of the text in bytes.
    /// - Returns: A UTF-8 view of the bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if they
    ///   aren't valid UTF-8. Nothing is consumed.
    /// - Precondition: `byteCount` isn't negative, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readUTF8(byteCount: Int) throws(BytesError) -> UTF8Span {
        try readUTF8(byteCount: byteCount, excluding: { _ in .none })
    }

    /// Reads the next `byteCount` bytes as validated UTF-8 in which no byte matches `excluded`, viewing
    /// the same memory. ASCII text is checked for both in one pass, 16 bytes at a time (see
    /// `UTF8Span(validating:excluding:)`).
    ///
    /// - Parameters:
    ///   - byteCount: The length of the text in bytes.
    ///   - excluded: Given 16 bytes at a time, matches the bytes that aren't allowed.
    /// - Returns: A UTF-8 view of the bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/invalidValue`` if they
    ///   aren't valid UTF-8 or one matches `excluded`. Nothing is consumed.
    /// - Precondition: `byteCount` isn't negative, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readUTF8(byteCount: Int, excluding excluded: (ByteLanes) -> ByteMatches) throws(BytesError) -> UTF8Span {
        let start = _byteOffset
        let bytes = try read(byteCount: byteCount)
        guard let text = UTF8Span(validating: bytes, excluding: excluded) else {
            _byteOffset = start
            throw .invalidValue
        }
        return text
    }

    /// Reads UTF-8 whose byte count comes first, as a `L` in `byteOrder`, viewing the same memory.
    ///
    /// ```swift
    /// let topic = try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian) // an MQTT string
    /// ```
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the count is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    /// - Returns: A UTF-8 view of the text, not including the count.
    /// - Throws: ``BytesError/insufficientData`` if the count or the bytes aren't all there;
    ///   ``BytesError/invalidValue`` if the count doesn't fit in an `Int` or the bytes aren't valid UTF-8.
    ///   Nothing is consumed.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(utf8PrefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) throws(BytesError) -> UTF8Span {
        try read(utf8PrefixedBy: L.self, byteOrder, excluding: { _ in .none })
    }

    /// Reads UTF-8 whose byte count comes first, as a `L` in `byteOrder`, in which no byte matches
    /// `excluded`, viewing the same memory. ASCII text is checked for both in one pass, 16 bytes at a time
    /// (see `UTF8Span(validating:excluding:)`).
    ///
    /// ```swift
    /// let name = try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian, excluding: { $0.matching(0) })
    /// ```
    ///
    /// - Parameters:
    ///   - lengthType: The byte group the count is stored as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    ///   - excluded: Given 16 bytes at a time, matches the bytes that aren't allowed.
    /// - Returns: A UTF-8 view of the text, not including the count.
    /// - Throws: ``BytesError/insufficientData`` if the count or the bytes aren't all there;
    ///   ``BytesError/invalidValue`` if the count doesn't fit in an `Int`, the bytes aren't valid UTF-8, or one
    ///   matches `excluded`. Nothing is consumed.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read<L: ByteGroup>(
        utf8PrefixedBy lengthType: L.Type, _ byteOrder: ByteOrder, excluding excluded: (ByteLanes) -> ByteMatches
    ) throws(BytesError) -> UTF8Span {
        let start = _byteOffset
        let bytes = try read(bytesPrefixedBy: L.self, byteOrder)
        guard let text = UTF8Span(validating: bytes, excluding: excluded) else {
            _byteOffset = start
            throw .invalidValue
        }
        return text
    }
}

// MARK: - Writing sections

public extension BytesWriter {
    /// Writes `bytes` preceded by their byte count as a `L` in `byteOrder`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    /// - Throws: ``BytesError/invalidValue`` if the count doesn't fit in `L`;
    ///   ``BytesError/insufficientCapacity`` if there isn't room. Nothing is written either way.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup>(_ bytes: RawSpan, prefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        guard let length = L.Integer(exactly: bytes.byteCount), length <= L._mask else { throw .invalidValue }
        guard likely(remainingByteCount &- L.byteCount >= bytes.byteCount) else { throw .insufficientCapacity }
        try write(length, as: L.self, byteOrder)
        try write(bytes)
    }

    /// Writes `text`'s UTF-8 preceded by its byte count as a `L` in `byteOrder`.
    ///
    /// ```swift
    /// try writer.write(topic.utf8Span, prefixedBy: Byte2.self, .bigEndian) // an MQTT string
    /// ```
    ///
    /// - Parameters:
    ///   - text: The text to write.
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    /// - Throws: ``BytesError/invalidValue`` if the count doesn't fit in `L`;
    ///   ``BytesError/insufficientCapacity`` if there isn't room. Nothing is written either way.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup>(_ text: UTF8Span, prefixedBy lengthType: L.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        try write(text.span.bytes, prefixedBy: L.self, byteOrder)
    }

    /// Writes `bytes` preceded by their byte count as LEB128.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - lengthType: `LEB128.self`, which selects this count encoding.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room, writing nothing.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ bytes: RawSpan, prefixedBy lengthType: LEB128.Type) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        let count = UInt64(bytes.byteCount)
        guard likely(remainingByteCount &- LEB128.byteCount(of: count) >= bytes.byteCount) else { throw .insufficientCapacity }
        try write(count, as: LEB128.self)
        try write(bytes)
    }

    /// Writes a section whose byte count comes first, as a `L` in `byteOrder`: `body` writes the section
    /// with a writer of its own, and its byte count is filled in afterwards, with nothing moved or copied.
    ///
    /// ```swift
    /// try writer.write(sectionPrefixedBy: Byte2.self, .bigEndian) { (section) throws(BytesError) in
    ///     try section.write(id, as: Byte4.self, .bigEndian)
    ///     try section.write(name.utf8Span, prefixedBy: Byte2.self, .bigEndian)
    /// }
    /// ```
    ///
    /// If this throws, the cursor doesn't move, though bytes after it may have been overwritten.
    ///
    /// - Parameters:
    ///   - lengthType: The byte group to store the count as, such as `Byte2.self`.
    ///   - byteOrder: The byte order of the count.
    ///   - body: Writes the section with a writer over the free bytes after the count.
    /// - Returns: What `body` returns.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room for the count; ``BytesError/invalidValue``
    ///   if the section is too long for `L`; or whatever `body` throws.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<L: ByteGroup, R: ~Copyable>(
        sectionPrefixedBy lengthType: L.Type, _ byteOrder: ByteOrder, _ body: (inout BytesWriter) throws(BytesError) -> R
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

    /// Writes a section whose byte count comes first as LEB128 of at most `maxByteCount` bytes.
    ///
    /// The count's length isn't known until the section is written, so this reserves `maxByteCount` bytes for
    /// it, and `body` gets the capacity after them. If the count turns out shorter, the section is moved down
    /// (a copy of it), leaving up to `maxByteCount - 1` stale bytes after the cursor. To avoid both, compute
    /// the section's size first and write the count with ``write(_:as:)-(UInt64,_)`` (see
    /// ``LEB128/byteCount(of:)``). Pick the smallest `maxByteCount` your format allows.
    ///
    /// If this throws, the cursor doesn't move, though bytes after it may have been overwritten.
    ///
    /// - Parameters:
    ///   - lengthType: `LEB128.self`, which selects this count encoding.
    ///   - maxByteCount: The most bytes the count may take, 1 through 10.
    ///   - body: Writes the section with a writer over the free bytes after the reserved count.
    /// - Returns: What `body` returns.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `maxByteCount` bytes are free;
    ///   ``BytesError/invalidValue`` if the section is too long for `maxByteCount` bytes of LEB128; or whatever
    ///   `body` throws.
    /// - Precondition: `maxByteCount` is 1 through 10, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<R: ~Copyable>(
        sectionPrefixedBy lengthType: LEB128.Type, maxByteCount: Int, _ body: (inout BytesWriter) throws(BytesError) -> R
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
            // An overlapping move down, byte by byte from the front: the standard library has no safe
            // `memmove` within a span. This path is rare (see above), so the loop costs nothing that matters.
            for index in 0..<written {
                _bytes[destination &+ index] = _bytes[source &+ index]
            }
        }
        Self._storeLEB128(UInt64(written), byteCount: prefixByteCount, to: &_bytes, at: prefixOffset)
        _byteOffset = prefixOffset &+ prefixByteCount &+ written
        return result
    }

    /// Runs `body` with a writer over the free bytes from `start`, sets `written` to how many bytes it wrote,
    /// and returns its result. Capacity for `start` already checked.
    ///
    /// - Parameters:
    ///   - start: The byte offset where the section starts.
    ///   - written: Set to the number of bytes `body` wrote.
    ///   - body: Writes the section.
    /// - Returns: What `body` returns.
    /// - Throws: Whatever `body` throws.
    @inlinable @inline(__always)
    internal mutating func _writeSection<R: ~Copyable>(
        from start: Int, written: inout Int, _ body: (inout BytesWriter) throws(BytesError) -> R
    ) throws(BytesError) -> R {
        var section = BytesWriter(
            _bytes._mutatingExtracting(start...), bitOrder: bitOrder
        )
        let result = try body(&section)
        written = section.byteCount
        return result
    }
}
