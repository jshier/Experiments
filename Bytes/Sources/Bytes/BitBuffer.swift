/// A bit reader for entropy decoders (Huffman, arithmetic, ANS): up to 64 bits held in a register and
/// refilled 8 bytes at a time, so reading a code is a mask and a shift.
///
/// Create one from a ``BytesReader`` cursor, ``refill()`` it, decode from ``bits`` (look up a table with its
/// next bits, then ``consume(bitCount:)`` the code's length), and turn it back into a cursor with ``finish()``:
///
/// ```swift
/// var buffer = BitBuffer(reader)                   // takes over the cursor's position
/// while decoding {
///     buffer.refill()                              // at least 56 bits buffered
///     let entry = table[Int(buffer.bits & 0x7FF)]  // an 11-bit lookup
///     buffer.consume(bitCount: entry.codeLength)
///     …
/// }
/// reader = try buffer.finish()                     // throws if it read past the end
/// ```
///
/// Refilling is branch-free while 8 bytes remain: one unaligned load, a shift, an OR, and adding the
/// whole bytes that fit. Within 8 bytes of the end it adds the remaining bytes, then zeros. Reading the
/// zeros isn't an error until ``finish()`` (or ``isOverrun``): a decoder checks once per block, not per
/// code, as fast DEFLATE decoders do. Each refill guarantees ``minimumRefill`` bits, so a decoder can read
/// that many between refills without checking ``bufferedBitCount``.
///
/// ``BitOrder/leastSignificantFirst`` (DEFLATE, Brotli, zstd) keeps the next bit in bit 0 of ``bits``;
/// ``BitOrder/mostSignificantFirst`` (JPEG, H.264, FLAC) in bit 63.
@safe
public struct BitBuffer: ~Copyable, ~Escapable {
    @usableFromInline let span: RawSpan
    /// The order of bits within each byte.
    public let bitOrder: BitOrder
    /// The next byte to load; past the end once zeros have been added.
    @usableFromInline var _nextByte: Int
    @usableFromInline var _bits: UInt64
    /// Valid bits in `_bits`, 0 through 63. Bits beyond them may hold the next bytes' bits, which the next
    /// refill ORs in again at the same positions.
    @usableFromInline var _count: Int

    /// Bits a refill guarantees: 56, so a decoder can read up to this many before refilling.
    public static var minimumRefill: Int { 56 }

    /// Creates a buffer at `reader`'s position, taking it over. Get a cursor back with ``finish()``.
    ///
    /// Always inlined, so a bit order the caller writes as a literal is a constant in the decode loop.
    ///
    /// - Parameter reader: The cursor to continue from, including any bits already consumed from its current
    ///   byte. Its bit order becomes the buffer's.
    @inlinable @inline(always)
    @_lifetime(copy reader)
    public init(_ reader: consuming BytesReader) {
        span = reader.span
        bitOrder = reader.bitOrder
        _nextByte = reader._byteOffset
        _bits = 0
        _count = 0
        let bitOffset = reader._bitOffset
        if bitOffset > 0 {
            refill()
            consume(bitCount: bitOffset)
        }
    }

    /// Creates a buffer at a bit position in `span`, such as where a resumable decoder stopped.
    ///
    /// ```swift
    /// var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
    /// ```
    ///
    /// Always inlined, like ``init(_:)``, so a literal bit order is a constant in the decode loop.
    ///
    /// - Parameters:
    ///   - span: The data to decode.
    ///   - position: The bit to start at, counted from the start of `span` (see ``BytesReader/bitPosition``),
    ///     0 through `span.byteCount * 8`.
    ///   - bitOrder: The order of bits within each byte.
    /// - Throws: ``BytesError/invalidValue`` if `position` is negative, ``BytesError/insufficientData`` if it
    ///   is past the end of `span`.
    @inlinable @inline(always)
    @_lifetime(copy span)
    public init(_ span: RawSpan, atBitPosition position: Int, bitOrder: BitOrder) throws(BytesError) {
        try self.init(BytesReader(span, atBitPosition: position, bitOrder: bitOrder))
    }

    /// The buffered bits: the next is bit 0 for ``BitOrder/leastSignificantFirst``, bit 63 for
    /// ``BitOrder/mostSignificantFirst``. Only ``bufferedBitCount`` of them are valid.
    @inlinable
    public var bits: UInt64 { _bits }

    /// The number of valid bits in ``bits``, 0 through 63.
    @inlinable
    public var bufferedBitCount: Int { _count }

    /// The position of the next unread bit, in bits from the start of the data. Past the end if zeros have
    /// been read.
    @inlinable
    public var bitPosition: Int { _nextByte &<< 3 &- _count }

    /// Whether more bits have been consumed than the data has: a decoder read the zero padding.
    @inlinable
    public var isOverrun: Bool { bitPosition > span.byteCount &<< 3 }

    /// Fills the buffer to at least ``minimumRefill`` bits, adding zeros past the end of the data.
    ///
    /// Never fails: reading the zeros shows up in ``isOverrun`` and ``finish()``.
    @inlinable @inline(always)
    public mutating func refill() {
        let shift = UInt64(truncatingIfNeeded: _count)
        if likely(span.byteCount &- _nextByte >= 8) {
            // Unsafe: an unchecked load. Safe: the branch just checked that 8 bytes remain. The checked load
            // measured 10% more instructions in DEFLATE decoding: its check also needs `_nextByte >= 0`, which
            // the optimizer can't see, so it isn't folded into this branch.
            let raw = unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: _nextByte, as: UInt64.self)
            switch bitOrder {
            case .leastSignificantFirst: _bits |= UInt64(littleEndian: raw) &<< shift
            case .mostSignificantFirst: _bits |= UInt64(bigEndian: raw) &>> shift
            }
            // Whole bytes that fit: the count becomes 56 + (count % 8), which is count | 56.
            _nextByte &+= (63 &- _count) &>> 3
            _count |= 56
        } else {
            // Values in and out, not `inout`: passing the fields' addresses would keep them in memory on
            // the fast path too.
            (_bits, _count, _nextByte) = Self._refillSlowly(_bits, _count, _nextByte, span: span, bitOrder: bitOrder)
        }
    }

    /// Within 8 bytes of the end: adds bytes one at a time, zeros past the end.
    ///
    /// - Parameters:
    ///   - bits: The buffered bits.
    ///   - count: The number of valid bits in `bits`.
    ///   - nextByte: The offset of the next byte to load.
    ///   - span: The data being read.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The new bits, valid bit count, and next byte offset.
    @usableFromInline
    static func _refillSlowly(
        _ bits: UInt64, _ count: Int, _ nextByte: Int, span: RawSpan, bitOrder: BitOrder
    ) -> (UInt64, Int, Int) {
        var bits = bits
        var count = count
        var nextByte = nextByte
        while count <= 56 {
            let byte = nextByte < span.byteCount ? UInt64(span.load(fromByteOffset: nextByte, as: UInt8.self)) : 0
            switch bitOrder {
            case .leastSignificantFirst: bits |= byte &<< UInt64(truncatingIfNeeded: count)
            case .mostSignificantFirst: bits |= byte &<< UInt64(truncatingIfNeeded: 56 &- count)
            }
            nextByte &+= 1
            count &+= 8
        }
        return (bits, count, nextByte)
    }

    /// The next bits, right-aligned, without consuming them.
    ///
    /// - Parameter count: The number of bits, 0 through 56. They must be buffered.
    /// - Returns: The bits as an integer; the first bit read is the most significant for
    ///   ``BitOrder/mostSignificantFirst`` and the least significant for ``BitOrder/leastSignificantFirst``.
    @inlinable @inline(always)
    public func peek(bitCount count: Int) -> UInt64 {
        switch bitOrder {
        case .leastSignificantFirst: _bits & ((1 &<< UInt64(truncatingIfNeeded: count)) &- 1)
        case .mostSignificantFirst: count == 0 ? 0 : _bits &>> UInt64(truncatingIfNeeded: 64 &- count)
        }
    }

    /// Drops the next bits. They must be buffered: consuming more than ``bufferedBitCount`` gives
    /// meaningless bits (never unsafe memory accesses).
    ///
    /// - Parameter count: The number of bits, 0 through 63.
    @inlinable @inline(always)
    public mutating func consume(bitCount count: Int) {
        assert(count <= _count, "Consumed \(count) bits with \(_count) buffered")
        switch bitOrder {
        case .leastSignificantFirst: _bits &>>= UInt64(truncatingIfNeeded: count)
        case .mostSignificantFirst: _bits &<<= UInt64(truncatingIfNeeded: count)
        }
        _count &-= count
    }

    /// Reads and consumes the next bits, refilling first if needed.
    ///
    /// - Parameter count: The number of bits, 0 through 56.
    /// - Returns: The bits, right-aligned, as ``peek(bitCount:)`` returns them. Zeros if the data ran out.
    @inlinable @inline(always)
    public mutating func read(bitCount count: Int) -> UInt64 {
        if _count < count { refill() }
        let value = peek(bitCount: count)
        consume(bitCount: count)
        return value
    }

    /// Reads and consumes the next `width` bits, refilling first if needed. Zeros if the data ran out.
    ///
    /// - Parameter type: The ``Bits`` type to read, such as `Nibble.self`.
    /// - Returns: The bits.
    @inlinable @inline(always)
    public mutating func read<let width: Int>(_: Bits<width>.Type = Bits<width>.self) -> Bits<width> {
        Bits(truncatingIfNeeded: read(bitCount: width))
    }

    /// Reads and consumes the next bit as a flag: `true` for 1, `false` for 0 or past the end of the data.
    ///
    /// ```swift
    /// let isFinal = bits.read(Bool.self)   // DEFLATE's BFINAL
    /// ```
    ///
    /// - Parameter type: `Bool.self`.
    /// - Returns: The flag.
    @inlinable @inline(always)
    public mutating func read(_: Bool.Type) -> Bool {
        read(bitCount: 1) != 0
    }

    /// Reads the next bits as a two's-complement signed integer, refilling first if needed. See
    /// ``BytesReader/readSigned(bitCount:)``.
    ///
    /// - Parameter count: The number of bits, 1 through 56.
    /// - Returns: The sign-extended value.
    @inlinable @inline(always)
    public mutating func readSigned(bitCount count: Int) -> Int64 {
        assert(count >= 1 && count <= 56, "Bit count must be 1 through 56")
        let shift = Int64(64 &- count)
        return Int64(bitPattern: read(bitCount: count) &<< UInt64(shift)) &>> shift
    }

    /// Reads a `width`-bit field as an `R`, through its raw value. The bits are consumed even if they don't
    /// make a valid `R`.
    ///
    /// - Parameters:
    ///   - type: The `RawRepresentable` type to produce, such as an enum.
    ///   - bitsType: The field's ``Bits`` type, such as `Crumb.self`.
    /// - Returns: The `R` whose raw value is the field.
    /// - Throws: ``BytesError/invalidValue`` if no `R` has the field as its raw value.
    @inlinable @inline(always)
    public mutating func read<R: RawRepresentable, let width: Int>(
        _: R.Type, as _: Bits<width>.Type
    ) throws(BytesError) -> R where R.RawValue: BinaryInteger {
        let bits = read(Bits<width>.self)
        guard let raw = R.RawValue(exactly: bits.rawValue), let value = R(rawValue: raw) else { throw .invalidValue }
        return value
    }

    /// Consumes the bits up to the next byte boundary; does nothing if already on one.
    @inlinable
    public mutating func alignToByte() {
        let partial = bitPosition & 7
        if partial != 0 {
            if _count < 8 { refill() }
            consume(bitCount: 8 &- partial)
        }
    }

    /// Ends the buffer, returning a cursor at the next unread bit.
    ///
    /// - Returns: A ``BytesReader`` over the same data and bit order.
    /// - Throws: ``BytesError/insufficientData`` if more bits were consumed than the data has.
    @inlinable
    @_lifetime(copy self)
    public consuming func finish() throws(BytesError) -> BytesReader {
        let position = bitPosition
        guard position <= span.byteCount &<< 3 else { throw .insufficientData }
        return BytesReader(span, byteOffset: position &>> 3, bitOffset: position & 7, bitOrder: bitOrder)
    }
}

public extension BytesReader {
    /// Runs `body` with a ``BitBuffer`` at this cursor's position, for decoding codes at full speed, then
    /// moves this cursor past what the buffer consumed.
    ///
    /// - Parameter body: Receives the buffer. If it throws, the cursor doesn't move.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws; ``BytesError/insufficientData`` if `body` consumed more bits than
    ///   remain (the cursor doesn't move).
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func withBitBuffer<R>(_ body: (inout BitBuffer) throws(BytesError) -> R) throws(BytesError) -> R {
        var buffer = BitBuffer(BytesReader(span, byteOffset: _byteOffset, bitOffset: _bitOffset, bitOrder: bitOrder))
        let result = try body(&buffer)
        let position = buffer.bitPosition
        guard position <= span.byteCount &<< 3 else { throw .insufficientData }
        _byteOffset = position &>> 3
        _bitOffset = position & 7
        return result
    }
}
