/// A bit writer for entropy coders (DEFLATE, Brotli, zstd): bits accumulate least significant first in a
/// 64-bit register and are stored 8 bytes at a time, the writing counterpart of ``BitBuffer``.
///
/// ```swift
/// var bits = BitWriter(output)                       // a MutableRawSpan with 8 bytes of slack
/// for symbol in symbols {
///     bits.add(UInt64(code[symbol]), bitCount: length[symbol])
///     bits.flush()                                   // up to 56 bits between flushes
/// }
/// bits.alignToByte()
/// let written = bits.byteOffset
/// ```
///
/// Adding is an OR and a shift. ``flush()`` stores all 8 bytes of the register at ``byteOffset`` and moves
/// it past the whole bytes they held, with no branches beyond one capacity check: so it needs ``slack``
/// bytes of room past the last whole byte, which callers reserve (an encoder sizes its buffer for a
/// block's worst case plus ``slack``). ``GenericBytesWriter/write(_:bitCount:)`` checks capacity and merges a
/// partial byte on every write, and tests its bit order at run time: for codes written by the million, this
/// is the faster form.
@safe @frozen
public struct BitWriter: ~Copyable, ~Escapable {
    @usableFromInline var _span: MutableRawSpan
    @usableFromInline var _byteOffset: Int
    @usableFromInline var _bits: UInt64
    @usableFromInline var _count: Int

    /// Room needed past the last whole byte written: ``flush()`` stores 8 bytes.
    @inlinable
    public static var slack: Int { 8 }

    /// Bits that can be added after a flush before the next one: 56 (a flush leaves at most 7).
    @inlinable
    public static var capacity: Int { 56 }

    /// Creates a writer at `byteOffset` in `span`, with `bitCount` bits not yet stored: where an earlier
    /// writer stopped (``byteOffset``, ``pendingBits``, ``pendingBitCount``).
    ///
    /// - Parameters:
    ///   - span: The memory to write into; bytes before `byteOffset` are kept.
    ///   - byteOffset: Where the next whole byte goes, 0 through `span.byteCount`.
    ///   - bits: The bits not yet stored, the next at bit 0; bits above `bitCount` must be 0.
    ///   - bitCount: The number of valid bits in `bits`, 0 through 63.
    /// - Precondition: `byteOffset` and `bitCount` are in range.
    @inlinable @inline(__always)
    @_lifetime(copy span)
    public init(_ span: consuming MutableRawSpan, byteOffset: Int = 0, bits: UInt64 = 0, bitCount: Int = 0) {
        precondition(byteOffset >= 0 && byteOffset <= span.byteCount && bitCount >= 0 && bitCount < 64, "A bit writer's position out of range")
        _span = span
        _byteOffset = byteOffset
        _bits = bits
        _count = bitCount
    }

    /// Where the next whole byte goes: the bytes before it are written.
    @inlinable
    public var byteOffset: Int { _byteOffset }

    /// The bits added but not yet stored, the next at bit 0.
    @inlinable
    public var pendingBits: UInt64 { _bits }

    /// The number of valid bits in ``pendingBits``, 0 through 63.
    @inlinable
    public var pendingBitCount: Int { _count }

    /// The position of the next bit, in bits from the start of the span.
    @inlinable
    public var bitPosition: Int { _byteOffset &<< 3 &+ _count }

    /// Adds `bitCount` bits, the low bits of `value`, after those pending.
    ///
    /// - Parameters:
    ///   - value: The bits, the first at bit 0. Bits above `bitCount` must be 0.
    ///   - bitCount: The number of bits. At most ``capacity`` in all between flushes; more lose bits (the
    ///     output is then meaningless, never written out of bounds).
    @inlinable @inline(__always)
    public mutating func add(_ value: UInt64, bitCount: Int) {
        _bits |= value &<< UInt64(truncatingIfNeeded: _count)
        _count &+= bitCount
    }

    /// Stores the whole bytes accumulated, keeping the rest pending.
    ///
    /// - Precondition: At least ``slack`` bytes remain from ``byteOffset``.
    @inlinable @inline(__always)
    public mutating func flush() {
        precondition(_span.byteCount &- _byteOffset >= 8, "A bit writer flushed with less than 8 bytes of room")
        // Unsafe: an unchecked store. Safe: the precondition just checked the 8 bytes.
        unsafe unsafeFlush()
    }

    /// ``flush()`` without its capacity check, for encoders that reserve room once per block: a block's
    /// worst case plus ``slack``, checked before writing it.
    ///
    /// The check is two instructions and a branch per flush, against about five for the flush: DEFLATE level
    /// 1 and Brotli quality 1, which flush after every few codes, ran 1.1–1.7% more instructions with it.
    ///
    /// Unsafe: stores 8 bytes at ``byteOffset`` unchecked. The caller must keep at least ``slack`` bytes of
    /// room from ``byteOffset``.
    @unsafe @inlinable @inline(__always)
    public mutating func unsafeFlush() {
        unsafe _span.storeBytes(of: _bits.littleEndian, toUncheckedByteOffset: _byteOffset, as: UInt64.self)
        // At most 7 whole bytes while the bits added fit the register. (More, and the offset jumps ahead; the
        // next flush's check still holds.)
        let whole = _count &>> 3
        _byteOffset &+= whole
        _bits &>>= UInt64(truncatingIfNeeded: whole &<< 3)
        _count &= 7
    }

    /// Pads to a byte boundary with zero bits and stores everything pending.
    ///
    /// - Precondition: At least ``slack`` bytes remain from ``byteOffset``.
    @inlinable @inline(__always)
    public mutating func alignToByte() {
        flush()
        _count = (_count &+ 7) & ~7
        flush()
    }

    /// Copies `bytes` to the output after the bytes written.
    ///
    /// - Parameter bytes: The bytes to copy.
    /// - Precondition: Nothing is pending (``pendingBitCount`` is 0: call ``alignToByte()`` first), and
    ///   `bytes` fits.
    @inlinable
    public mutating func write(_ bytes: RawSpan) {
        precondition(_count == 0, "Writing bytes with bits pending: call alignToByte() first")
        _span.copyBytes(from: bytes, toByteOffset: _byteOffset)
        _byteOffset &+= bytes.byteCount
    }
}
