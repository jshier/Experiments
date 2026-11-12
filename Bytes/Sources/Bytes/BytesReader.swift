/// The order in which ``BytesReader`` reads the bits within each byte.
public enum BitOrder: Hashable, Sendable {
    /// The most significant bit (bit 7) first, as in most network protocols and media formats.
    case mostSignificantFirst
    /// The least significant bit (bit 0) first, as in DEFLATE.
    case leastSignificantFirst
}

/// An error reading ``BytesReader``. A read that throws doesn't consume anything.
public enum BytesError: Error, Hashable, Sendable {
    /// Fewer bits remain than the read needs, or a seek went past the end.
    case insufficientData
    /// An `expect` found a different value.
    case mismatch
    /// ``BytesReader/read(_:count:)`` was asked to view memory that isn't aligned for its element type.
    case misaligned
    /// A ``BytesWriter`` has less room left than the write needs.
    case insufficientCapacity
    /// A field's value isn't valid for the type it's read as: an undefined enum case, malformed UTF-8, a
    /// LEB128 integer longer than allowed, a negative seek offset, or a length too large for its prefix when
    /// writing.
    case invalidValue
    /// ``BytesReader/expectEnd()`` found unread bytes in a section that should have been fully consumed.
    case trailingData
}

/// A ``BytesError`` with the byte offset of the read that threw it, from ``BytesReader/located(_:)``.
public struct LocatedBytesError: Error, Hashable, Sendable {
    /// What went wrong.
    public var error: BytesError
    /// Where: the byte offset, in the cursor that made it, of the read that failed.
    public var byteOffset: Int

    /// Creates a located error.
    ///
    /// - Parameters:
    ///   - error: What went wrong.
    ///   - byteOffset: The byte offset of the read that failed.
    @inlinable
    public init(_ error: BytesError, byteOffset: Int) {
        self.error = error
        self.byteOffset = byteOffset
    }
}

/// A cursor that parses binary data from borrowed memory, field by field, at bit or byte granularity.
///
/// Read fixed-width fields as ``ByteGroup`` values (``Byte2`` through ``Byte16``) or directly as integers in
/// a `ByteOrder`, and sub-byte fields as ``Bits`` (``Bit``, ``Crumb``, ``Nibble``, ``Byte``), in any mix:
///
/// ```swift
/// var reader = BytesReader(span)
/// try reader.expect(0x50_4B_03_04 as Byte4)
/// let version = try reader.read(Byte2.self, .littleEndian) // UInt16
/// let length = try reader.read(Byte3.self, .bigEndian)     // UInt32
/// let flag = try reader.read(Bit.self)
/// let kind = try reader.read(Bits<3>.self)
/// ```
///
/// Fields are packed with no implicit padding: after a bit-level read, multi-byte reads continue mid-byte,
/// each byte made of the next 8 bits in ``bitOrder``. Call ``alignToByte()`` to skip to the next byte.
/// Byte-aligned reads take a fast path: one bounds check and one or two unaligned loads.
///
/// `BytesReader` is `~Escapable`, so it can't outlive the memory it reads, and every span it returns borrows that
/// same memory without copying. It's `~Copyable`, so a cursor position can't be duplicated by accident:
/// pass it `inout` to helper functions.
@safe
public struct BytesReader: ~Copyable, ~Escapable {
    /// All the bytes being read, including those already consumed.
    public let span: RawSpan
    /// The order of bits within each byte: for ``Bits``, ``read(bitCount:)``, and multi-byte reads that start
    /// mid-byte.
    public let bitOrder: BitOrder
    @usableFromInline var _byteOffset: Int
    /// Bits already consumed from the byte at `_byteOffset`: always 0 through 7.
    @usableFromInline var _bitOffset: Int

    /// Creates a cursor at the start of `span`.
    ///
    /// - Parameters:
    ///   - span: The bytes to read. The cursor borrows them.
    ///   - bitOrder: The order of bits within each byte for sub-byte reads.
    @inlinable
    @_lifetime(copy span)
    public init(_ span: RawSpan, bitOrder: BitOrder = .mostSignificantFirst) {
        self.span = span
        self.bitOrder = bitOrder
        _byteOffset = 0
        _bitOffset = 0
    }

    /// Creates a cursor at the start of `span`.
    ///
    /// - Parameters:
    ///   - span: The bytes to read. The cursor borrows them.
    ///   - bitOrder: The order of bits within each byte for sub-byte reads.
    @inlinable
    @_lifetime(copy span)
    public init(_ span: Span<UInt8>, bitOrder: BitOrder = .mostSignificantFirst) {
        self.init(span.bytes, bitOrder: bitOrder)
    }

    /// Creates a cursor at the byte at `offset` in `span`, which may be its end: a record found through an
    /// offset in the data, such as a zip archive's central directory.
    ///
    /// ```swift
    /// var header = try BytesReader(archive, atByteOffset: entry.localHeaderOffset) // a UInt64
    /// ```
    ///
    /// Any integer type: offsets usually come from the data, in its own width.
    ///
    /// - Parameters:
    ///   - span: The bytes to read. The cursor borrows them.
    ///   - offset: The byte offset to start at, 0 through `span.byteCount`.
    ///   - bitOrder: The order of bits within each byte for sub-byte reads.
    /// - Throws: ``BytesError/insufficientData`` if `offset` is past the end (or beyond `Int`);
    ///   ``BytesError/invalidValue`` if it's negative, as ``seek(toByteOffset:)`` does.
    @inlinable @inline(__always)
    @_lifetime(copy span)
    public init(_ span: RawSpan, atByteOffset offset: some BinaryInteger, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError) {
        self.init(span, bitOrder: bitOrder)
        guard let offset = Int(exactly: offset) else { throw offset < 0 ? .invalidValue : .insufficientData }
        try seek(toByteOffset: offset)
    }

    /// Creates a cursor at bit `position` in `span` (see ``bitPosition``), which may be its end: where a
    /// resumable decoder stopped.
    ///
    /// - Parameters:
    ///   - span: The bytes to read. The cursor borrows them.
    ///   - position: The bit position to start at, 0 through `8 × span.byteCount`.
    ///   - bitOrder: The order of bits within each byte for sub-byte reads.
    /// - Throws: ``BytesError/insufficientData`` if `position` is past the end; ``BytesError/invalidValue`` if
    ///   it's negative, as ``seek(toBitPosition:)`` does.
    @inlinable @inline(__always)
    @_lifetime(copy span)
    public init(_ span: RawSpan, atBitPosition position: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError) {
        self.init(span, bitOrder: bitOrder)
        try seek(toBitPosition: position)
    }
}

// MARK: - Position

public extension BytesReader {
    /// The offset in ``span`` of the byte the next read starts in.
    @inlinable
    var byteOffset: Int { _byteOffset }

    /// The number of bits already consumed from the byte at ``byteOffset``, from 0 through 7.
    @inlinable
    var bitOffset: Int { _bitOffset }

    /// The position of the next bit in ``span``, counted in bits: `8 × byteOffset + bitOffset`. Matches
    /// ``BitBuffer/bitPosition``, so a decoder can store either and resume with ``seek(toBitPosition:)``.
    @inlinable
    var bitPosition: Int { _byteOffset &<< 3 | _bitOffset }

    /// Whether the next read starts at the beginning of a byte.
    @inlinable
    var isByteAligned: Bool { _bitOffset == 0 }

    /// Whether every bit has been read.
    @inlinable
    var isAtEnd: Bool { _byteOffset == span.byteCount }

    /// The number of bits not yet read.
    @inlinable
    var remainingBitCount: Int { (span.byteCount &- _byteOffset) &<< 3 &- _bitOffset }

    /// The number of whole bytes not yet read. A partly read byte doesn't count.
    @inlinable
    var remainingByteCount: Int { span.byteCount &- _byteOffset &- (_bitOffset == 0 ? 0 : 1) }

    /// The whole bytes not yet read, borrowing the same memory. A partly read byte isn't included.
    @inlinable
    var remainingBytes: RawSpan {
        @_lifetime(copy self)
        get { span.extracting(droppingFirst: span.byteCount &- remainingByteCount) }
    }

    /// Moves to the start of the next byte, unless already at the start of one.
    @inlinable
    @_lifetime(self: copy self)
    mutating func alignToByte() {
        if _bitOffset != 0 {
            _byteOffset &+= 1
            _bitOffset = 0
        }
    }

    /// Moves to the start of the byte at `offset` in ``span``, which may be `span.byteCount`, the end.
    ///
    /// Offsets usually come from the data itself, so a bad one throws, leaving the cursor where it was.
    ///
    /// - Parameter offset: The byte offset, 0 through `span.byteCount`.
    /// - Throws: ``BytesError/insufficientData`` if `offset` is past the end; ``BytesError/invalidValue`` if it's
    ///   negative.
    @inlinable
    @_lifetime(self: copy self)
    mutating func seek(toByteOffset offset: Int) throws(BytesError) {
        guard offset >= 0 else { throw .invalidValue }
        guard offset <= span.byteCount else { throw .insufficientData }
        _byteOffset = offset
        _bitOffset = 0
    }

    /// Moves to bit `position` in ``span`` (see ``bitPosition``), which may be the end. A bad position throws,
    /// leaving the cursor where it was.
    ///
    /// - Parameter position: The bit position, 0 through `8 × span.byteCount`.
    /// - Throws: ``BytesError/insufficientData`` if `position` is past the end; ``BytesError/invalidValue`` if it's
    ///   negative.
    @inlinable
    @_lifetime(self: copy self)
    mutating func seek(toBitPosition position: Int) throws(BytesError) {
        guard position >= 0 else { throw .invalidValue }
        guard position <= span.byteCount &<< 3 else { throw .insufficientData }
        _byteOffset = position &>> 3
        _bitOffset = position & 7
    }

    /// A place in the data this cursor was at: see ``position`` and ``rewind(to:)``.
    struct Position: Hashable, Sendable {
        /// The offset of the byte the next read started in.
        public let byteOffset: Int
        /// The bits already consumed from that byte, from 0 through 7.
        public let bitOffset: Int

        @inlinable
        init(byteOffset: Int, bitOffset: Int) {
            self.byteOffset = byteOffset
            self.bitOffset = bitOffset
        }

        /// The position in bits: `8 × byteOffset + bitOffset`.
        @inlinable
        public var bitPosition: Int { byteOffset &<< 3 | bitOffset }
    }

    /// Where the next read starts, to come back to with ``rewind(to:)``.
    @inlinable
    var position: Position { Position(byteOffset: _byteOffset, bitOffset: _bitOffset) }

    /// Moves back to a ``position`` taken from this cursor earlier: undoing reads, such as a message that
    /// turned out to be incomplete or invalid. Unlike ``seek(toByteOffset:)`` it can't fail, so it doesn't
    /// throw; it's two stores.
    ///
    /// ```swift
    /// let start = reader.position
    /// do {
    ///     return try readMessage(&reader)
    /// } catch {
    ///     reader.rewind(to: start) // All or nothing.
    ///     throw error
    /// }
    /// ```
    ///
    /// The all-or-nothing reads of ``atomically(_:)`` without its closure, at a steady cost whatever the body
    /// (see there): prefer this for long bodies, and where `atomically` can't return the result, such as a
    /// view of the data that depends on the cursor's lifetime.
    ///
    /// - Parameter position: A position from this cursor's ``position``.
    /// - Precondition: `position` is at or before the current position.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func rewind(to position: Position) {
        // Keeps the invariant `_assumeInvariant` states: a position no later than this cursor's is within its
        // span, and a `Position` only comes from a cursor, so its bit offset is 0 through 7.
        precondition(position.bitPosition <= bitPosition, "Rewinding to a position after the cursor")
        _byteOffset = position.byteOffset
        _bitOffset = position.bitOffset
    }

    /// Runs `body` on a copy of this cursor, and moves this one past what it read only if `body` succeeds:
    /// several reads that are all or nothing, as each single read is. A streaming parser can read a whole
    /// message this way; if its later fields haven't arrived, the cursor is still at its start.
    ///
    /// ```swift
    /// let message = try reader.atomically { (reader) throws(BytesError) in
    ///     let type = try reader.read(Byte.self)
    ///     let body = try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian)
    ///     return (type, body.byteCount)
    /// }
    /// ```
    ///
    /// When a read throws, the cursor's ``byteOffset`` is where the failing read started (it consumed
    /// nothing), so it is also the error's location; inside `atomically`, check the copy's.
    ///
    /// For a long `body`, use ``position`` and ``rewind(to:)`` instead. A long closure literal isn't inlined,
    /// and then the copy of the cursor lives in memory: each entry of a zip central directory written out in
    /// the closure took 50% more instructions than the same reads without it (453 K against 301 K), the same
    /// body in an `@inline(__always)` function called from the closure cost nothing, and `position` and
    /// `rewind(to:)` cost 2% either way (Bytes' benchmarks, "Fields: Bytes, entries …").
    ///
    /// - Parameter body: Reads from the copy of the cursor passed to it.
    /// - Returns: What `body` returns.
    /// - Throws: Whatever `body` throws, leaving this cursor where it was.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func atomically<R: ~Copyable, E: Error>(_ body: (inout BytesReader) throws(E) -> R) throws(E) -> R {
        var copy = BytesReader(span, byteOffset: _byteOffset, bitOffset: _bitOffset, bitOrder: bitOrder)
        let result = try body(&copy)
        _byteOffset = copy._byteOffset
        _bitOffset = copy._bitOffset
        return result
    }

    /// Skips the next `byteCount` bytes (`8 × byteCount` bits, if not byte-aligned).
    ///
    /// - Parameter byteCount: The number of bytes to skip.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain, consuming nothing.
    /// - Precondition: `byteCount` isn't negative.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func skip(byteCount: Int) throws(BytesError) {
        precondition(byteCount >= 0, "Negative byte count")
        _assumeInvariant()
        guard likely(remainingByteCount >= byteCount) else { throw .insufficientData }
        _byteOffset &+= byteCount
    }

    /// Skips the next `bitCount` bits.
    ///
    /// - Parameter bitCount: The number of bits to skip.
    /// - Throws: ``BytesError/insufficientData`` if fewer bits remain, consuming nothing.
    /// - Precondition: `bitCount` isn't negative.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func skip(bitCount: Int) throws(BytesError) {
        precondition(bitCount >= 0, "Negative bit count")
        _assumeInvariant()
        guard likely(remainingBitCount >= bitCount) else { throw .insufficientData }
        _advance(bitCount: bitCount)
    }

    /// States the cursor's invariant to the optimizer. With it, LLVM knows `span.byteCount - _byteOffset`
    /// can't wrap, so consecutive bounds checks fold into comparisons against constants.
    ///
    /// Deliberately not also `_byteOffset >= 0`, though it's equally true: measured, that one assumption
    /// stops loops of `read` calls from vectorizing (it's the only one that does; 14 against 113 GB/s for
    /// `Byte4`), at the cost of 11% more instructions in field-by-field parsing (263 against 291 K for the
    /// 2,000-entry zip directory; the fixed-size-record style is unchanged).
    @inlinable @inline(__always)
    internal func _assumeInvariant() {
        unsafe assume(_byteOffset <= span.byteCount)
        unsafe assume(_bitOffset >= 0)
        unsafe assume(_bitOffset < 8)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _advance(bitCount: Int) {
        let total = _bitOffset &+ bitCount
        _byteOffset &+= total &>> 3
        _bitOffset = total & 7
    }
}

// MARK: - Byte groups

public extension BytesReader {
    /// Returns the next `T.byteCount` bytes without consuming them. Not byte-aligned, each byte is made of
    /// the next 8 bits in ``bitOrder``.
    ///
    /// - Parameter type: The byte group to read, such as `Byte4.self`. Inferred from context when omitted.
    /// - Returns: The group of bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain.
    @inlinable @inline(__always)
    func peek<T: ByteGroup>(_ type: T.Type = T.self) throws(BytesError) -> T {
        _assumeInvariant()
        if likely(_bitOffset == 0) {
            guard likely(span.byteCount &- _byteOffset >= T.byteCount) else { throw .insufficientData }
            return unsafe Load.group(T.self, from: span, at: _byteOffset)
        }
        guard remainingByteCount >= T.byteCount else { throw .insufficientData }
        let bytes = Self._unalignedBytes(T.byteCount, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
        return T(littleEndian: T.Integer(truncatingIfNeeded: bytes))
    }

    /// Reads the next `T.byteCount` bytes.
    ///
    /// - Parameter type: The byte group to read, such as `Byte4.self`. Inferred from context when omitted.
    /// - Returns: The group of bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<T: ByteGroup>(_ type: T.Type = T.self) throws(BytesError) -> T {
        let value = try peek(T.self)
        _byteOffset &+= T.byteCount // Whole bytes leave the bit offset unchanged.
        return value
    }

    /// Returns the next `T.byteCount` bytes as an integer in `byteOrder`, without consuming them.
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The integer, unsigned.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain.
    @inlinable @inline(__always)
    func peek<T: ByteGroup>(_ type: T.Type, _ byteOrder: ByteOrder) throws(BytesError) -> T.Integer {
        try peek(T.self).integer(byteOrder)
    }

    /// Reads the next `T.byteCount` bytes as an integer in `byteOrder`.
    ///
    /// ```swift
    /// let size = try reader.read(Byte4.self, .littleEndian) // UInt32
    /// ```
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the field.
    /// - Returns: The integer, unsigned.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<T: ByteGroup>(_ type: T.Type, _ byteOrder: ByteOrder) throws(BytesError) -> T.Integer {
        try read(T.self).integer(byteOrder)
    }

    /// Consumes `expected` if it's next.
    ///
    /// - Parameter expected: The bytes that must come next.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain; ``BytesError/mismatch`` if the
    ///   next bytes differ. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<T: ByteGroup>(_ expected: T) throws(BytesError) {
        guard try peek(T.self) == expected else { throw .mismatch }
        _byteOffset &+= T.byteCount
    }

    /// Consumes the next `T.byteCount` bytes if the bits selected by `mask` equal `expected`: a header whose
    /// version and reserved bits are fixed and whose other bits vary.
    ///
    /// ```swift
    /// try reader.expect(0x00_01 as Byte2, mask: 0x00_FF)   // any first byte, then 0x01
    /// ```
    ///
    /// - Parameters:
    ///   - expected: The bytes that must come next, where `mask` is set.
    ///   - mask: The bits to compare.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain; ``BytesError/mismatch`` if the
    ///   selected bits differ. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<T: ByteGroup>(_ expected: T, mask: T) throws(BytesError) {
        guard try peek(T.self).matches(expected, mask: mask) else { throw .mismatch }
        _byteOffset &+= T.byteCount
    }

    /// Reads the next `T.byteCount` bytes as a two's-complement signed integer in `byteOrder`,
    /// sign-extended to `I`: the signed counterpart of ``read(_:_:)``.
    ///
    /// ```swift
    /// let offset = try reader.readSigned(Byte4.self, .littleEndian, as: Int32.self)
    /// let sample = try reader.readSigned(Byte3.self, .bigEndian, as: Int32.self)   // FF FF FE → -2
    /// ```
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the field.
    ///   - integerType: The signed integer type to return.
    /// - Returns: The signed value.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole bytes remain, consuming nothing.
    /// - Precondition: `I` is at least as wide as the group.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readSigned<T: ByteGroup, I: FixedWidthInteger & SignedInteger>(
        _ type: T.Type, _ byteOrder: ByteOrder, as integerType: I.Type = Int.self
    ) throws(BytesError) -> I {
        try read(T.self).signedInteger(byteOrder, as: I.self)
    }

    /// Pairs `error` with this cursor's byte offset, which is where the read that threw it started: a read
    /// that throws consumes nothing. For parsers that report where the data went wrong:
    ///
    /// ```swift
    /// var reader = BytesReader(span)
    /// do throws(BytesError) {
    ///     while !reader.isAtEnd { try parseEntry(&reader) }
    /// } catch {
    ///     throw reader.located(error)
    /// }
    /// ```
    ///
    /// Use it in a `catch`, as here: the success path is unchanged (+1.3% instructions for a 2,000-entry
    /// zip directory, all in the catch). Don't wrap the parse in a closure that adds the location
    /// instead: the closure isn't inlined, so the cursor lives in memory (+15%).
    ///
    /// The offset is in this cursor. A read that failed inside a section (``readSection(byteCount:)``) is
    /// reported at the section's start or end in its parent; locate it in the section to be exact.
    ///
    /// - Parameter error: The error a read threw.
    /// - Returns: `error` with the cursor's current byte offset.
    @inlinable @inline(__always)
    func located(_ error: BytesError) -> LocatedBytesError {
        LocatedBytesError(error, byteOffset: _byteOffset)
    }

    /// The next `count` bytes (1 through 16) when not byte-aligned, as a little-endian integer. Bounds already
    /// checked.
    ///
    /// Out of line and static, taking plain values: if it borrowed `self`, every caller would spill the
    /// whole cursor to the stack to pass its address, even on the aligned fast path.
    ///
    /// - Parameters:
    ///   - count: The number of bytes to assemble.
    ///   - span: The bytes being read.
    ///   - byteOffset: The byte the first of them starts in.
    ///   - bit: Bits already consumed from that byte, 1 through 7.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The bytes, the first in the low bits.
    @usableFromInline
    internal static func _unalignedBytes(_ count: Int, in span: RawSpan, atByte byteOffset: Int, bit: Int, bitOrder: BitOrder) -> UInt128 {
        var value: UInt128 = 0
        for index in 0..<count {
            let byte = _bits(8, in: span, atByte: byteOffset &+ index, bit: bit, bitOrder: bitOrder)
            value |= UInt128(byte) &<< (8 &* index)
        }
        return value
    }
}

// MARK: - Bits

public extension BytesReader {
    /// Returns the next `width` bits without consuming them.
    ///
    /// - Parameter type: The bit field to read, such as `Nibble.self`. Inferred from context when omitted.
    /// - Returns: The bits, as a ``Bits`` value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain.
    @inlinable @inline(__always)
    func peek<let width: Int>(_ type: Bits<width>.Type = Bits<width>.self) throws(BytesError) -> Bits<width> {
        Bits<width>._checkWidth()
        _assumeInvariant()
        if width == 8, likely(_bitOffset == 0) {
            guard likely(_byteOffset < span.byteCount) else { throw .insufficientData }
            return Bits(_unchecked: unsafe Load.native(UInt8.self, from: span, at: _byteOffset))
        }
        guard likely(remainingBitCount >= width) else { throw .insufficientData }
        return Bits(_unchecked: Self._bits(width, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder))
    }

    /// Reads the next `width` bits, in ``bitOrder``.
    ///
    /// - Parameter type: The bit field to read, such as `Nibble.self`. Inferred from context when omitted.
    /// - Returns: The bits, as a ``Bits`` value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<let width: Int>(_ type: Bits<width>.Type = Bits<width>.self) throws(BytesError) -> Bits<width> {
        let value = try peek(Bits<width>.self)
        _advance(bitCount: width)
        return value
    }

    /// Consumes `expected` if it's next.
    ///
    /// - Parameter expected: The bits that must come next.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain; ``BytesError/mismatch`` if
    ///   the next bits differ. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<let width: Int>(_ expected: Bits<width>) throws(BytesError) {
        guard try peek(Bits<width>.self) == expected else { throw .mismatch }
        _advance(bitCount: width)
    }

    /// Consumes the next `width` bits if the bits selected by `mask` equal `expected`.
    ///
    /// - Parameters:
    ///   - expected: The bits that must come next, where `mask` is set.
    ///   - mask: The bits to compare.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `width` bits remain; ``BytesError/mismatch`` if
    ///   the selected bits differ. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<let width: Int>(_ expected: Bits<width>, mask: Bits<width>) throws(BytesError) {
        guard try peek(Bits<width>.self).matches(expected, mask: mask) else { throw .mismatch }
        _advance(bitCount: width)
    }

    /// Returns whether the next bit is set, without consuming it.
    ///
    /// - Parameter type: `Bool.self`, which selects this overload.
    /// - Returns: `true` if the next bit is 1.
    /// - Throws: ``BytesError/insufficientData`` if no bits remain.
    @inlinable @inline(__always)
    func peek(_ type: Bool.Type) throws(BytesError) -> Bool {
        try peek(Bit.self).isSet
    }

    /// Reads the next bit as a flag: `true` for 1.
    ///
    /// ```swift
    /// let hasTimestamp = try header.read(Bool.self)
    /// ```
    ///
    /// Several flags that fill a byte, at a byte boundary, are cheaper as one ``Byte`` taken apart with
    /// `[bit:]`: see <doc:WritingParsers#Keep-it-fast>.
    ///
    /// - Parameter type: `Bool.self`, which selects this overload.
    /// - Returns: `true` if the bit is 1.
    /// - Throws: ``BytesError/insufficientData`` if no bits remain, consuming nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_ type: Bool.Type) throws(BytesError) -> Bool {
        try read(Bit.self).isSet
    }

    /// Reads the next `bitCount` bits (1 through 64) as a two's-complement signed integer: the first bit
    /// of the field is its sign for ``BitOrder/mostSignificantFirst``, the last for
    /// ``BitOrder/leastSignificantFirst``, as ``read(bitCount:)`` assembles them.
    ///
    /// ```swift
    /// let delta = try reader.readSigned(bitCount: 12)   // -2048 through 2047
    /// ```
    ///
    /// - Parameter bitCount: The field's width in bits, 1 through 64.
    /// - Returns: The sign-extended value.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `bitCount` bits remain, consuming nothing.
    /// - Precondition: `bitCount` is 1 through 64.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readSigned(bitCount: Int) throws(BytesError) -> Int64 {
        precondition(bitCount >= 1 && bitCount <= 64, "Bit count must be 1 through 64")
        let raw = try read(bitCount: bitCount)
        let shift = Int64(64 &- bitCount)
        return Int64(bitPattern: raw &<< UInt64(shift)) &>> shift
    }

    /// Returns the next `bitCount` bits (0 through 64) as an integer, without consuming them.
    ///
    /// The first bit read is the most significant for ``BitOrder/mostSignificantFirst``, and the least
    /// significant for ``BitOrder/leastSignificantFirst``.
    ///
    /// - Parameter bitCount: The number of bits, 0 through 64.
    /// - Returns: The bits, right-aligned: 0 for a `bitCount` of 0.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `bitCount` bits remain.
    /// - Precondition: `bitCount` is 0 through 64.
    @inlinable @inline(__always)
    func peek(bitCount: Int) throws(BytesError) -> UInt64 {
        precondition(bitCount >= 0 && bitCount <= 64, "Bit count must be 0 through 64")
        _assumeInvariant()
        guard likely(remainingBitCount >= bitCount) else { throw .insufficientData }
        guard bitCount > 0 else { return 0 }
        if likely(bitCount <= 57) {
            return Self._wideBits(bitCount, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
        }
        // Beyond 57 bits, the bits can span 9 bytes: read them as 32 bits, then the rest.
        let first = Self._wideBits(32, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
        let second = Self._wideBits(bitCount &- 32, in: span, atByte: _byteOffset &+ 4, bit: _bitOffset, bitOrder: bitOrder)
        return switch bitOrder {
        case .mostSignificantFirst: first &<< (bitCount &- 32) | second
        case .leastSignificantFirst: first | second &<< 32
        }
    }

    /// Reads the next `bitCount` bits (0 through 64) as an integer, as ``peek(bitCount:)`` returns them.
    ///
    /// - Parameter bitCount: The number of bits, 0 through 64.
    /// - Returns: The bits, right-aligned.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `bitCount` bits remain, consuming nothing.
    /// - Precondition: `bitCount` is 0 through 64.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(bitCount: Int) throws(BytesError) -> UInt64 {
        let value = try peek(bitCount: bitCount)
        _advance(bitCount: bitCount)
        return value
    }

    /// Returns the bits ahead of the cursor, as many as fit in 64 (at least 57, or all that remain), without
    /// consuming them. Bits past the end of the data are zero.
    ///
    /// For decoders that look further ahead than they consume, such as Huffman decoders: index a table with
    /// the window's next bits, then ``skip(bitCount:)`` the length of the code found. The next bit is bit 0 of
    /// the window for ``BitOrder/leastSignificantFirst`` and bit 63 for ``BitOrder/mostSignificantFirst``.
    ///
    /// ```swift
    /// let window = reader.peekBitWindow()            // DEFLATE: least significant bit first
    /// let entry = table[Int(window & 0x3FF)]         // a 10-bit lookup
    /// try reader.skip(bitCount: entry.codeLength)    // throws if the code runs past the end
    /// ```
    ///
    /// One unaligned 8-byte load and a shift; within 8 bytes of the end, the remaining bytes, padded.
    ///
    /// - Returns: The window, with the next bit at the position given above.
    @inlinable @inline(__always)
    func peekBitWindow() -> UInt64 {
        _assumeInvariant()
        let window: UInt64
        if likely(span.byteCount &- _byteOffset >= 8) {
            let raw = unsafe Load.native(UInt64.self, from: span, at: _byteOffset)
            window = bitOrder == .mostSignificantFirst ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw)
        } else {
            window = Self._partialWindow(in: span, atByte: _byteOffset, bitOrder: bitOrder)
        }
        return bitOrder == .mostSignificantFirst ? window &<< _bitOffset : window &>> _bitOffset
    }

    /// `count` bits starting `bit` bits into the byte at `byteOffset`. Bounds already checked.
    ///
    /// - Parameters:
    ///   - count: The number of bits, 1 through 8.
    ///   - span: The bytes being read.
    ///   - byteOffset: The byte the bits start in.
    ///   - bit: Bits already consumed from that byte, 0 through 7.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The bits, right-aligned.
    @inlinable @inline(__always)
    internal static func _bits(_ count: Int, in span: RawSpan, atByte byteOffset: Int, bit: Int, bitOrder: BitOrder) -> UInt8 {
        // A 16-bit window covers any 8 bits at any bit offset; near the end, the last byte padded with zeros.
        let window: UInt16
        if likely(span.byteCount &- byteOffset >= 2) {
            let raw = unsafe Load.native(UInt16.self, from: span, at: byteOffset)
            window = bitOrder == .mostSignificantFirst ? UInt16(bigEndian: raw) : UInt16(littleEndian: raw)
        } else {
            let byte = UInt16(unsafe Load.native(UInt8.self, from: span, at: byteOffset))
            window = bitOrder == .mostSignificantFirst ? byte &<< 8 : byte
        }
        return switch bitOrder {
        case .mostSignificantFirst: UInt8(truncatingIfNeeded: (window &<< bit) &>> (16 &- count))
        case .leastSignificantFirst: UInt8(truncatingIfNeeded: window &>> bit) & UInt8(truncatingIfNeeded: (1 &<< count) &- 1)
        }
    }

    /// `count` bits starting `bit` bits into the byte at `byteOffset`. Bounds already checked.
    ///
    /// - Parameters:
    ///   - count: The number of bits, 1 through 57.
    ///   - span: The bytes being read.
    ///   - byteOffset: The byte the bits start in.
    ///   - bit: Bits already consumed from that byte, 0 through 7.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The bits, right-aligned.
    @inlinable @inline(__always)
    internal static func _wideBits(_ count: Int, in span: RawSpan, atByte byteOffset: Int, bit: Int, bitOrder: BitOrder) -> UInt64 {
        let window: UInt64
        if likely(span.byteCount &- byteOffset >= 8) {
            let raw = unsafe Load.native(UInt64.self, from: span, at: byteOffset)
            window = bitOrder == .mostSignificantFirst ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw)
        } else {
            window = _partialWindow(in: span, atByte: byteOffset, bitOrder: bitOrder)
        }
        return switch bitOrder {
        case .mostSignificantFirst: (window &<< bit) &>> (64 &- count)
        case .leastSignificantFirst: (window &>> bit) & ((1 &<< count) &- 1)
        }
    }

    /// The last (fewer than 8) bytes from `byteOffset`, as a 64-bit window padded with zeros.
    ///
    /// - Parameters:
    ///   - span: The bytes being read.
    ///   - byteOffset: The first byte of the window.
    ///   - bitOrder: The order of bits within each byte: the first byte is the window's top for
    ///     ``BitOrder/mostSignificantFirst``, its bottom for ``BitOrder/leastSignificantFirst``.
    /// - Returns: The window.
    @usableFromInline
    internal static func _partialWindow(in span: RawSpan, atByte byteOffset: Int, bitOrder: BitOrder) -> UInt64 {
        var window: UInt64 = 0
        var index = 0
        for offset in byteOffset..<span.byteCount {
            let byte = UInt64(unsafe Load.native(UInt8.self, from: span, at: offset))
            let shift = bitOrder == .mostSignificantFirst ? 56 &- 8 &* index : 8 &* index
            window |= byte &<< shift
            index &+= 1
        }
        return window
    }
}

// MARK: - Spans

public extension BytesReader {
    /// Reads the next `byteCount` bytes as a span borrowing the same memory.
    ///
    /// - Parameter byteCount: The number of bytes to read.
    /// - Returns: A span of the bytes.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain, consuming nothing.
    /// - Precondition: `byteCount` isn't negative, and the cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(byteCount: Int) throws(BytesError) -> RawSpan {
        precondition(byteCount >= 0, "Negative byte count")
        precondition(_bitOffset == 0, "Reading a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(span.byteCount &- _byteOffset >= byteCount) else { throw .insufficientData }
        let bytes = span.extracting(_byteOffset..<(_byteOffset &+ byteCount))
        _byteOffset &+= byteCount
        return bytes
    }

    /// Reads everything that remains as a span borrowing the same memory, leaving the cursor at the end: a
    /// packet's payload after its header. Never fails, so no `try`.
    ///
    /// ```swift
    /// payload = body.readRemainingBytes()
    /// ```
    ///
    /// - Returns: A span of the remaining bytes, empty at the end.
    /// - Precondition: The cursor is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readRemainingBytes() -> RawSpan {
        precondition(_bitOffset == 0, "Reading a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let start = _byteOffset
        _byteOffset = span.byteCount
        // `start` is within the span (the invariant), so the range is valid.
        return unsafe span.extracting(unchecked: start..<span.byteCount)
    }
}

// MARK: - Bulk operations

public extension BytesReader {
    /// Reads consecutive `T` groups as integers in `byteOrder` until `output` is full.
    ///
    /// For example, to decode a table of big-endian 32-bit offsets:
    ///
    /// ```swift
    /// let offsets = try [UInt32](capacity: count) { output in
    ///     try reader.read(Byte4.self, .bigEndian, into: &output)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the fields.
    ///   - output: Receives the values, filling its free capacity.
    /// - Throws: ``BytesError/insufficientData`` if fewer whole `T`s remain than `output` has room for,
    ///   consuming nothing and appending nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<T: ByteGroup>(
        _ type: T.Type,
        _ byteOrder: ByteOrder,
        into output: inout OutputSpan<T.Integer>
    ) throws(BytesError) {
        _assumeInvariant()
        let count = output.freeCapacity
        guard likely(remainingByteCount / T.byteCount >= count) else { throw .insufficientData }
        // An empty output may have no memory behind it: nothing to read, nothing to unwrap.
        guard count > 0 else { return }
        guard likely(_bitOffset == 0) else {
            for _ in 0..<count {
                try output.append(read(T.self, byteOrder))
            }
            return
        }
        let span = span
        let start = _byteOffset
        // Unsafe: initializes the output's free capacity through a pointer. Safe: exactly `count` values,
        // the free capacity, are initialized and counted. `OutputSpan.append` is the safe form, but its
        // per-value capacity check and count update keep the loop from vectorizing.
        unsafe output.withUnsafeMutableBufferPointer { buffer, initializedCount in
            let destination = unsafe buffer.baseAddress! + initializedCount
            var unpacked = 0
            #if NEONShuffle
            // Odd widths: whole steps unpacked with table lookups straight into the output's lanes (each
            // value's integer type is exactly one lane), 64 bytes per step. The loops below finish the rest.
            if Shuffle.handles(T.self) {
                let steps = Shuffle.unpackableSteps(T.self, count: count, availableBytes: span.byteCount &- start)
                let indices = Shuffle.unpackIndices(T.self, bigEndian: byteOrder == .bigEndian)
                let raw = UnsafeMutableRawPointer(destination)
                for step in 0..<steps {
                    let lanes = unsafe Shuffle.unpack(T.self, step: step, from: span, at: start, indices)
                    unsafe raw.storeBytes(of: lanes.0, toByteOffset: step &* 64, as: SIMD16<UInt8>.self)
                    unsafe raw.storeBytes(of: lanes.1, toByteOffset: step &* 64 &+ 16, as: SIMD16<UInt8>.self)
                    unsafe raw.storeBytes(of: lanes.2, toByteOffset: step &* 64 &+ 32, as: SIMD16<UInt8>.self)
                    unsafe raw.storeBytes(of: lanes.3, toByteOffset: step &* 64 &+ 48, as: SIMD16<UInt8>.self)
                }
                unpacked = steps &* Shuffle.valuesPerStep(T.byteCount)
            }
            #endif
            // One loop per byte order, so each is a straight-line load/swap/store the compiler can vectorize.
            switch byteOrder {
            case .littleEndian:
                for index in unpacked..<count {
                    let group = unsafe Load.streamingGroup(T.self, from: span, at: start &+ index &* T.byteCount)
                    unsafe (destination + index).initialize(to: group.littleEndian)
                }
            case .bigEndian:
                for index in unpacked..<count {
                    let group = unsafe Load.streamingGroup(T.self, from: span, at: start &+ index &* T.byteCount)
                    unsafe (destination + index).initialize(to: group.bigEndian)
                }
            }
            initializedCount &+= count
        }
        _byteOffset &+= count &* T.byteCount
    }

    /// Reads every remaining whole `T`, in order, calling `body` with each.
    ///
    /// When byte-aligned, this is a counted loop of unchecked loads at fixed strides, with one bounds
    /// check up front, so the compiler can vectorize it together with `body`:
    ///
    /// ```swift
    /// var sum: UInt64 = 0
    /// reader.forEach(Byte4.self) { sum &+= UInt64($0.bigEndian) }
    /// ```
    ///
    /// Unlike `for`-`in` over the cursor (which never moves it), this consumes what it reads, like any
    /// `read`. Trailing bytes too few for a whole `T` are left unread. If `body` throws, the value it threw
    /// on and everything before it are consumed.
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - body: Called with each value, in order.
    /// - Throws: Whatever `body` throws.
    // Always inlined: if the optimizer outlines a loop that calls a closure, the closure's captured
    // variables live in memory (stored every iteration) and the loop can't vectorize. That happened to
    // `Byte16`, the largest body, under the default heuristics.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEach<T: ByteGroup, E: Error>(_ type: T.Type, _ body: (T) throws(E) -> Void) throws(E) {
        try _forEach(T.self, limit: .max, body)
    }

    /// Reads every remaining whole `T` as an integer in `byteOrder`, in order, calling `body` with each: the
    /// loop counterpart of ``read(_:_:)``.
    ///
    /// ```swift
    /// var sum: UInt64 = 0
    /// reader.forEach(Byte4.self, .bigEndian) { sum &+= UInt64($0) }
    /// ```
    ///
    /// Exactly as fast as `forEach(_:_:)` with the conversion in `body`, which is what it is.
    ///
    /// - Parameters:
    ///   - type: The byte group to read, such as `Byte4.self`.
    ///   - byteOrder: The byte order of the fields.
    ///   - body: Called with each value, in order.
    /// - Throws: Whatever `body` throws; the value it threw on and everything before it are consumed.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEach<T: ByteGroup, E: Error>(
        _ type: T.Type, _ byteOrder: ByteOrder, _ body: (T.Integer) throws(E) -> Void
    ) throws(E) {
        try _forEach(T.self, limit: .max) { (group: T) throws(E) in try body(group.integer(byteOrder)) }
    }

    /// `forEach(_:_:)`, reading at most `limit` values.
    ///
    /// - Parameters:
    ///   - limit: The most values to read.
    ///   - body: Called with each value, in order.
    /// - Throws: Whatever `body` throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _forEach<T: ByteGroup, E: Error>(_: T.Type, limit: Int, _ body: (T) throws(E) -> Void) throws(E) {
        _assumeInvariant()
        let count = Swift.min(limit, remainingByteCount / T.byteCount)
        guard likely(_bitOffset == 0) else {
            for _ in 0..<count {
                let bytes = Self._unalignedBytes(T.byteCount, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
                _byteOffset &+= T.byteCount
                try body(T(littleEndian: T.Integer(truncatingIfNeeded: bytes)))
            }
            return
        }
        let span = span
        let start = _byteOffset
        var index = 0
        do throws(E) {
            #if NEONShuffle
            // 5 to 7 bytes: whole steps unpacked with table lookups, then `body` for each value in the step.
            if Shuffle.handlesIteration(T.self) {
                let perStep = Shuffle.valuesPerStep(T.byteCount)
                let steps = Shuffle.unpackableSteps(T.self, count: count, availableBytes: span.byteCount &- start)
                let indices = Shuffle.unpackIndices(T.self, bigEndian: false)
                for step in 0..<steps {
                    let lanes = unsafe Shuffle.unpack(T.self, step: step, from: span, at: start, indices)
                    for slot in 0..<perStep {
                        try body(T(littleEndian: Shuffle.lane(T.self, lanes, slot)))
                        index &+= 1
                    }
                }
            }
            #endif
            while index < count {
                try body(unsafe Load.streamingGroup(T.self, from: span, at: start &+ index &* T.byteCount))
                index &+= 1
            }
        } catch {
            _byteOffset = start &+ (index &+ 1) &* T.byteCount
            throw error
        }
        _byteOffset = start &+ count &* T.byteCount
    }

    /// Reads every remaining whole `Bits<width>` value, in ``bitOrder``, calling `body` with each.
    ///
    /// When byte-aligned, this loads whole blocks that hold a fixed number of values and extracts them with
    /// constant shifts: a counted loop the compiler vectorizes together with `body`. Blocks are as narrow as
    /// possible, since narrower lanes mean more values per vector instruction: one byte when `width`
    /// divides 8, three bytes (as 32 bits, loaded bytewise so it becomes NEON `ld3`) for 3-bit values, and
    /// `width` bytes (8 values, as 64 bits) otherwise. Starting mid-byte, it reads single values until it
    /// reaches a byte boundary (if the width ever lands on one), then switches to blocks.
    ///
    /// Unlike `for`-`in` over the cursor (which never moves it), this consumes what it reads, like any
    /// `read`. Trailing bits too few for a whole value are left unread. If `body` throws, the value it threw
    /// on and everything before it are consumed.
    ///
    /// - Parameters:
    ///   - type: The bit field to read, such as `Nibble.self`.
    ///   - body: Called with each value, in order.
    /// - Throws: Whatever `body` throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEach<let width: Int, E: Error>(
        _ type: Bits<width>.Type,
        _ body: (Bits<width>) throws(E) -> Void
    ) throws(E) {
        try _forEach(Bits<width>.self, limit: .max, body)
    }

    /// ``forEach(_:_:)-(Bits<width>.Type,_)``, reading at most `limit` values. A `limit` that's a multiple
    /// of 8 keeps the cursor byte-aligned for the next call.
    ///
    /// - Parameters:
    ///   - limit: The most values to read.
    ///   - body: Called with each value, in order.
    /// - Throws: Whatever `body` throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _forEach<let width: Int, E: Error>(
        _: Bits<width>.Type,
        limit: Int,
        _ body: (Bits<width>) throws(E) -> Void
    ) throws(E) {
        Bits<width>._checkWidth()
        _assumeInvariant()
        var remaining = limit
        // Mid-byte: single values until a byte boundary. Whether one is reachable depends on the width and
        // the bit offset (it always is for odd widths, within 7 values), so give up after 8. Whole bytes
        // never realign, so for them the loop is compiled out (its mere presence slowed `for`-`in` over
        // `Byte` values by 30%).
        var aligning = 0
        while width != 8, _bitOffset != 0, aligning < 8, remaining > 0, remainingBitCount >= width {
            let bits = Self._bits(width, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
            _advance(bitCount: width)
            remaining &-= 1
            aligning &+= 1
            try body(Bits(_unchecked: bits))
        }
        if likely(_bitOffset == 0) {
            let span = span
            if 8 % width == 0 {
                try _forEachBlock(UInt8.self, byteCount: 1, valueCount: 8 / width, limit: &remaining, body) { offset in
                    let byte = unsafe Load.native(UInt8.self, from: span, at: offset)
                    return (byte, byte)
                }
            } else if width == 3 {
                try _forEachBlock(UInt32.self, byteCount: 3, valueCount: 8, limit: &remaining, body) { offset in
                    let first = unsafe UInt32(Load.native(UInt8.self, from: span, at: offset))
                    let second = unsafe UInt32(Load.native(UInt8.self, from: span, at: offset &+ 1))
                    let third = unsafe UInt32(Load.native(UInt8.self, from: span, at: offset &+ 2))
                    return (first &<< 16 | second &<< 8 | third, first | second &<< 8 | third &<< 16)
                }
            } else {
                try _forEachBlock(UInt64.self, byteCount: width, valueCount: 8, limit: &remaining, body) { offset in
                    let littleEndian = unsafe Load.block(width, from: span, at: offset)
                    return (littleEndian.byteSwapped &>> (64 &- 8 &* width), littleEndian)
                }
            }
        }
        // Less than a block left (or under the limit), or not byte-aligned: one at a time.
        while remaining > 0, remainingBitCount >= width {
            let bits = Self._bits(width, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
            _advance(bitCount: width)
            remaining &-= 1
            try body(Bits(_unchecked: bits))
        }
    }

    /// Calls `body` with each value in each whole block of `byteCount` bytes from the current (byte-aligned)
    /// offset, for as many whole blocks as `limit` values allow, and subtracts the values read from `limit`.
    ///
    /// - Parameters:
    ///   - byteCount: The bytes in a block.
    ///   - valueCount: The values of `width` bits in a block.
    ///   - limit: The most values to read, reduced by the number read.
    ///   - body: Called with each value, in order.
    ///   - load: Given a block's byte offset, returns its bits interpreted big-endian and little-endian,
    ///     right-aligned.
    /// - Throws: Whatever `body` throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _forEachBlock<let width: Int, Block: FixedWidthInteger & UnsignedInteger, E: Error>(
        _: Block.Type,
        byteCount: Int,
        valueCount: Int,
        limit: inout Int,
        _ body: (Bits<width>) throws(E) -> Void,
        load: (Int) -> (bigEndian: Block, littleEndian: Block)
    ) throws(E) {
        let blocks = Swift.min((span.byteCount &- _byteOffset) / byteCount, limit / valueCount)
        limit &-= blocks &* valueCount
        let start = _byteOffset
        let mask = Block(Bits<width>.mask)
        let blockBits = 8 &* byteCount
        var block = 0
        var value = 0
        do throws(E) {
            switch bitOrder {
            case .mostSignificantFirst:
                while block < blocks {
                    let bits = load(start &+ block &* byteCount).bigEndian
                    value = 0
                    while value < valueCount {
                        let shift = blockBits &- width &* (value &+ 1)
                        try body(Bits(_unchecked: UInt8(truncatingIfNeeded: bits &>> shift & mask)))
                        value &+= 1
                    }
                    block &+= 1
                }
            case .leastSignificantFirst:
                while block < blocks {
                    let bits = load(start &+ block &* byteCount).littleEndian
                    value = 0
                    while value < valueCount {
                        try body(Bits(_unchecked: UInt8(truncatingIfNeeded: bits &>> (width &* value) & mask)))
                        value &+= 1
                    }
                    block &+= 1
                }
            }
        } catch {
            _byteOffset = start &+ block &* byteCount
            _advance(bitCount: (value &+ 1) &* width)
            throw error
        }
        _byteOffset = start &+ blocks &* byteCount
    }

    /// The offset in ``span`` of the first occurrence of `pattern` in ``remainingBytes``, or `nil`.
    ///
    /// Scans 16 positions at a time with SIMD, comparing the pattern's first and last bytes, and checks
    /// the whole pattern only where both match.
    ///
    /// - Parameter pattern: The bytes to find.
    /// - Returns: The offset of the first match, or `nil` if there is none. The cursor doesn't move.
    @inlinable
    func firstByteOffset<T: ByteGroup>(of pattern: T) -> Int? {
        _assumeInvariant()
        let last = span.byteCount &- T.byteCount // The last offset the pattern fits at.
        var offset = span.byteCount &- remainingByteCount
        let head = SIMD16<UInt8>(repeating: pattern[0])
        let tail = SIMD16<UInt8>(repeating: pattern[T.byteCount &- 1])
        // Each block tests 16 starting offsets, reading through `offset + 15 + byteCount - 1`.
        while offset &+ 15 <= last {
            let candidates = unsafe Load.candidates(in: span, at: offset, byteCount: T.byteCount, head: head, tail: tail)
            if unlikely(any(candidates)) {
                for index in 0..<16 where candidates[index] {
                    if unsafe Load.group(T.self, from: span, at: offset &+ index) == pattern { return offset &+ index }
                }
            }
            offset &+= 16
        }
        while offset <= last {
            if unsafe Load.group(T.self, from: span, at: offset) == pattern { return offset }
            offset &+= 1
        }
        return nil
    }

    /// The offset in ``span`` of the last occurrence of `pattern` in ``remainingBytes``, or `nil`.
    ///
    /// Scans backwards 16 positions at a time, like ``firstByteOffset(of:)``.
    ///
    /// - Parameter pattern: The bytes to find.
    /// - Returns: The offset of the last match, or `nil` if there is none. The cursor doesn't move.
    @inlinable
    func lastByteOffset<T: ByteGroup>(of pattern: T) -> Int? {
        _assumeInvariant()
        let first = span.byteCount &- remainingByteCount
        var end = span.byteCount &- T.byteCount &+ 1 // One past the last offset still to test.
        let head = SIMD16<UInt8>(repeating: pattern[0])
        let tail = SIMD16<UInt8>(repeating: pattern[T.byteCount &- 1])
        while end &- 16 >= first {
            let offset = end &- 16
            let candidates = unsafe Load.candidates(in: span, at: offset, byteCount: T.byteCount, head: head, tail: tail)
            if unlikely(any(candidates)) {
                for index in (0..<16).reversed() where candidates[index] {
                    if unsafe Load.group(T.self, from: span, at: offset &+ index) == pattern { return offset &+ index }
                }
            }
            end = offset
        }
        while end > first {
            end &-= 1
            if unsafe Load.group(T.self, from: span, at: end) == pattern { return end }
        }
        return nil
    }
}

// MARK: - Unchecked loads

/// Unchecked loads from a span. Callers check bounds first.
///
/// Unsafe, and the one place `Bytes` reads memory without a check of its own: every caller checks that the
/// bytes it reads are in bounds first, once per read or once per bulk operation, and the offsets these take
/// are derived from that check. Unchecked because the standard library's checked `RawSpan.load` measured
/// far slower here (baseline `pre-safety` against `safe1`): its check also needs `offset >= 0`, which the
/// cursor doesn't state to the optimizer (stating it stops loops of reads from vectorizing, see
/// `_assumeInvariant`), so the check isn't folded into the caller's. Field-by-field parsing took 24% more
/// instructions, two-load widths (`Byte3`, `Byte5`–`Byte15`) 2–8x more, and bulk loops stopped vectorizing.
@usableFromInline @unsafe
enum Load {
    /// The `I` at `offset`, in native byte order.
    ///
    /// - Parameters:
    ///   - span: The bytes to load from.
    ///   - offset: The byte offset of the first byte.
    /// - Returns: The integer.
    @unsafe @inlinable @inline(__always)
    static func native<I: FixedWidthInteger & ConvertibleFromBytes>(_: I.Type, from span: RawSpan, at offset: Int) -> I {
        unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: I.self)
    }

    /// Which of the 16 offsets from `offset` hold a `byteCount`-byte run starting with `head` and ending
    /// with `tail` (both splatted). Reads `offset ..< offset + 15 + byteCount`.
    ///
    /// - Parameters:
    ///   - span: The bytes to search.
    ///   - offset: The first of the 16 starting offsets.
    ///   - byteCount: The length of the run.
    ///   - head: The run's first byte, in every lane.
    ///   - tail: The run's last byte, in every lane.
    /// - Returns: A mask with a lane set for each offset whose first and last bytes match.
    @unsafe @inlinable @inline(__always)
    static func candidates(
        in span: RawSpan, at offset: Int, byteCount: Int, head: SIMD16<UInt8>, tail: SIMD16<UInt8>
    ) -> SIMDMask<SIMD16<Int8>> {
        let starts = unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
        let ends = unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ byteCount &- 1, as: SIMD16<UInt8>.self)
        return (starts .== head) .& (ends .== tail)
    }

    /// Like ``group(_:from:at:)``, tuned for loops over consecutive groups. Three-byte groups load each
    /// byte separately, which the vectorizer turns into NEON `ld3` (de-interleaving 48 bytes into three
    /// vectors): 46% more throughput in a loop than two overlapping 16-bit loads (13 → 19 GB/s), but one
    /// load more for a single read. Five- to seven-byte groups have no such instruction and stay faster
    /// with overlapping loads.
    ///
    /// - Parameters:
    ///   - span: The bytes to load from.
    ///   - offset: The byte offset of the group.
    /// - Returns: The group.
    @unsafe @inlinable @inline(__always)
    static func streamingGroup<T: ByteGroup>(_: T.Type, from span: RawSpan, at offset: Int) -> T {
        guard T.byteCount == 3 else { return unsafe group(T.self, from: span, at: offset) }
        let first = unsafe UInt32(native(UInt8.self, from: span, at: offset))
        let second = unsafe UInt32(native(UInt8.self, from: span, at: offset &+ 1))
        let third = unsafe UInt32(native(UInt8.self, from: span, at: offset &+ 2))
        return T(littleEndian: T.Integer(truncatingIfNeeded: first | second &<< 8 | third &<< 16))
    }

    /// The `count` (1 through 8) bytes at `offset`, as a little-endian integer. Like ``group(_:from:at:)``,
    /// odd counts use two overlapping loads.
    ///
    /// - Parameters:
    ///   - count: The number of bytes, 1 through 8.
    ///   - span: The bytes to load from.
    ///   - offset: The byte offset of the first byte.
    /// - Returns: The bytes, the first in the low bits.
    @unsafe @inlinable @inline(__always)
    static func block(_ count: Int, from span: RawSpan, at offset: Int) -> UInt64 {
        switch count {
        case 1:
            return unsafe UInt64(native(UInt8.self, from: span, at: offset))
        case 2:
            return unsafe UInt64(little(UInt16.self, from: span, at: offset))
        case 3:
            let low = unsafe UInt64(little(UInt16.self, from: span, at: offset))
            return unsafe low | UInt64(little(UInt16.self, from: span, at: offset &+ 1)) &<< 8
        case 4:
            return unsafe UInt64(little(UInt32.self, from: span, at: offset))
        case 5, 6, 7:
            let low = unsafe UInt64(little(UInt32.self, from: span, at: offset))
            return unsafe low | UInt64(little(UInt32.self, from: span, at: offset &+ count &- 4)) &<< (8 &* (count &- 4))
        default:
            return unsafe little(UInt64.self, from: span, at: offset)
        }
    }

    /// The little-endian `I` at `offset`.
    ///
    /// - Parameters:
    ///   - span: The bytes to load from.
    ///   - offset: The byte offset of the first byte.
    /// - Returns: The integer.
    @unsafe @inlinable @inline(__always)
    static func little<I: FixedWidthInteger & ConvertibleFromBytes>(_: I.Type, from span: RawSpan, at offset: Int) -> I {
        unsafe I(littleEndian: native(I.self, from: span, at: offset))
    }

    /// The `T.byteCount` bytes at `offset`. Widths between the standard integer sizes use two overlapping
    /// loads of the next size down, so every width is at most two loads and never reads out of bounds.
    ///
    /// - Parameters:
    ///   - span: The bytes to load from.
    ///   - offset: The byte offset of the group.
    /// - Returns: The group.
    /// - Precondition: `T.byteCount` is 2 through 16.
    @unsafe @inlinable @inline(__always)
    static func group<T: ByteGroup>(_: T.Type, from span: RawSpan, at offset: Int) -> T {
        let count = T.byteCount
        switch count {
        case 2:
            return unsafe T(littleEndian: T.Integer(truncatingIfNeeded: little(UInt16.self, from: span, at: offset)))
        case 3:
            let low = unsafe UInt32(little(UInt16.self, from: span, at: offset))
            let high = unsafe UInt32(little(UInt16.self, from: span, at: offset &+ 1))
            return T(littleEndian: T.Integer(truncatingIfNeeded: low | high &<< 8))
        case 4:
            return unsafe T(littleEndian: T.Integer(truncatingIfNeeded: little(UInt32.self, from: span, at: offset)))
        case 5, 6, 7:
            let low = unsafe UInt64(little(UInt32.self, from: span, at: offset))
            let high = unsafe UInt64(little(UInt32.self, from: span, at: offset &+ count &- 4))
            return T(littleEndian: T.Integer(truncatingIfNeeded: low | high &<< (8 &* (count &- 4))))
        case 8:
            return unsafe T(littleEndian: T.Integer(truncatingIfNeeded: little(UInt64.self, from: span, at: offset)))
        case 16:
            // One 128-bit load. Building 16 bytes from 64-bit halves like 9–15 measured slower in loops
            // (32 against 56 GB/s for big-endian `Byte16`): the cost model then keeps the loop scalar.
            return unsafe T(littleEndian: T.Integer(truncatingIfNeeded: little(UInt128.self, from: span, at: offset)))
        case 9...15:
            // Build the two 64-bit halves separately (the high half is the top `count - 8` bytes of the
            // second load), so no operation crosses them: LLVM won't vectorize 128-bit arithmetic, but once
            // the halves are independent it splits the value into two 64-bit lanes and vectorizes those.
            let low = unsafe little(UInt64.self, from: span, at: offset)
            let high = unsafe little(UInt64.self, from: span, at: offset &+ count &- 8) &>> (8 &* (16 &- count))
            return T(littleEndian: T.Integer(truncatingIfNeeded: UInt128(high) &<< 64 | UInt128(low)))
        default:
            preconditionFailure("\(T.self).byteCount must be 2 through 16")
        }
    }
}

// MARK: - Copying out

public extension [UInt8] {
    /// Creates an array with a copy of `bytes`: the byte counterpart of `String(copying:)`, for keeping
    /// what a span read from ``BytesReader`` borrows.
    ///
    /// - Parameter bytes: The bytes to copy.
    @inlinable
    init(copying bytes: RawSpan) {
        // Unsafe: the span's memory as a buffer pointer. Safe: it's only read, within the closure, by the
        // standard library's `Array` initializer (a `memcpy`). Not `init(unsafeUninitializedCapacity:)`
        // with a `memcpy`: that called an unspecialized allocator, `ContiguousArray._allocateBufferUninitialized`,
        // and copying an MQTT packet's payload took about 590 instructions more per packet.
        self = bytes.withUnsafeBytes { buffer in unsafe Array(buffer) }
    }

    /// Appends a copy of `bytes`: the appending counterpart of ``init(copying:)``.
    ///
    /// - Parameter bytes: The bytes to copy.
    @inlinable
    mutating func append(copying bytes: RawSpan) {
        // Unsafe: the span's memory as a buffer pointer. Safe: it's only read, within the closure, by the
        // standard library's bulk append (a `memcpy`). Through a `BytesWriter` instead, it measured 37
        // instructions against 13, with a trap path for an error that can't happen.
        bytes.withUnsafeBytes { buffer in unsafe append(contentsOf: buffer) }
    }
}

public extension RawSpan {
    /// Whether the span starts with `prefix`'s bytes: one load and a compare, and `false` if the span is
    /// shorter.
    ///
    /// ```swift
    /// let isShared = topic.span.bytes.hasPrefix(0x24_73_68_61_72_65_2F as Byte7)   // "$share/"
    /// ```
    ///
    /// - Parameter prefix: The bytes to compare with the start of the span.
    /// - Returns: `true` if the span starts with `prefix`.
    @inlinable @inline(__always)
    func hasPrefix<T: ByteGroup>(_ prefix: T) -> Bool {
        // Unsafe: an unchecked load. Safe: the span has at least `T.byteCount` bytes (checked first).
        guard byteCount >= T.byteCount else { return false }
        return unsafe Load.group(T.self, from: self, at: 0) == prefix
    }
}

public extension String {
    /// A string of the UTF-8 that `body` writes with a ``BytesWriter`` over `utf8Capacity` bytes: one
    /// allocation (none for 15 bytes or fewer).
    ///
    /// ```swift
    /// let text = try String(utf8Capacity: Base64.encodedByteCount(of: bytes.byteCount)) { (writer) throws(BytesError) in
    ///     try Base64.encode(bytes, into: &writer)
    /// }
    /// ```
    ///
    /// Bytes that aren't valid UTF-8 are repaired, as `String(decoding:as:)` does; ASCII needs no repair.
    /// Annotate the closure's error type in hot code; see ``Swift/Array/init(byteCapacity:bitOrder:writing:)``.
    ///
    /// - Parameters:
    ///   - utf8Capacity: The most bytes `body` can write.
    ///   - body: Writes the UTF-8; the string is as long as what it wrote.
    /// - Throws: Whatever `body` throws, such as ``BytesError/insufficientCapacity`` if it writes more than
    ///   `utf8Capacity` bytes.
    @inlinable @inline(always)
    init<E: Error>(utf8Capacity: Int, writing body: (inout BytesWriter) throws(E) -> Void) throws(E) {
        // Unsafe: the string's uninitialized storage, which only this initializer exposes (no `OutputSpan`
        // initializer is public). Safe: the writer covers exactly the `utf8Capacity` bytes the initializer
        // allocated, and the initializer gets back the count written, which the writer keeps within them.
        // The initializer rethrows `body`'s error as it is. (Capturing it in a variable instead, and throwing
        // it after, cost more on the success path: Base64's `encodedString`, +1.2% at 40 bytes.)
        do {
            self = try String(unsafeUninitializedCapacity: utf8Capacity) { buffer throws(E) in
                var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(buffer)))
                try body(&writer)
                return writer.byteCount
            }
        } catch {
            throw error
        }
    }

    /// A string of the UTF-8 that `body` writes, for a body that can't fail: an exactly sized encoding,
    /// say, with `try!` inside. See the throwing `init(utf8Capacity:writing:)`.
    ///
    /// ```swift
    /// let text = String(utf8Capacity: count) { writer in try! Base64.encode(bytes, into: &writer) }
    /// ```
    ///
    /// A little cheaper than the throwing form: Base64's `encodedString` took 984 instructions per call at
    /// 40 bytes this way, 994 with the throwing form and `try!` around it (1,290 and 1,300 at 64 bytes).
    ///
    /// - Parameters:
    ///   - utf8Capacity: The most bytes `body` can write.
    ///   - body: Writes the UTF-8; the string is as long as what it wrote.
    @inlinable @inline(always)
    init(utf8Capacity: Int, writing body: (inout BytesWriter) -> Void) {
        // Unsafe and safe as for the throwing form.
        self = String(unsafeUninitializedCapacity: utf8Capacity) { buffer in
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(buffer)))
            body(&writer)
            return writer.byteCount
        }
    }
}
