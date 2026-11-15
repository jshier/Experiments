internal import Bytes

/// A least-significant-bit-first bit writer for entropy coders (DEFLATE, Brotli): bits accumulate in a
/// 64-bit register and are stored 8 bytes at a time.
///
/// ``flush()`` stores all 8 bytes of the register unaligned and advances by the whole bytes it held, keeping
/// the rest: no branches. It needs 8 bytes of room past the last whole byte, which the encoders reserve.
/// Between flushes, up to 56 bits can be added (`7 + 56 <= 63`): four 14-bit literal codes, or one match's
/// code, extra bits, distance code, and distance extra bits (at most 48).
@safe
struct DeflateBitWriter: ~Copyable, ~Escapable {
    /// The buffer, with at least 8 bytes of slack after anything written.
    var span: MutableRawSpan
    /// Where the next whole byte goes.
    var offset: Int
    /// Bits not yet stored, the next at bit 0.
    var bits: UInt64
    /// The number of valid bits in `bits`, 0 through 63.
    var count: Int

    /// Bits that can be added after a flush before the next flush.
    static var capacity: Int { 56 }
    /// Room needed past the last whole byte written.
    static var slack: Int { 8 }

    @inline(__always)
    @_lifetime(copy span)
    init(_ span: consuming MutableRawSpan, offset: Int, bits: UInt64, count: Int) {
        self.span = span
        self.offset = offset
        self.bits = bits
        self.count = count
    }

    /// Adds `bitCount` bits, the low bits of `value` (the rest must be zero).
    @inline(__always)
    mutating func add(_ value: UInt64, bitCount: Int) {
        bits |= value &<< UInt64(truncatingIfNeeded: count)
        count &+= bitCount
    }

    /// Stores the whole bytes accumulated.
    @inline(__always)
    mutating func flush() {
        // Unsafe: an unchecked store. Safe: the encoders keep `slack` bytes free past `offset`: each block
        // starts with the staging buffer empty, and its capacity covers a block's worst case plus `slack`.
        unsafe span.storeBytes(of: bits.littleEndian, toUncheckedByteOffset: offset, as: UInt64.self)
        let whole = count &>> 3 // At most 7: `count` is at most 63.
        offset &+= whole
        bits &>>= UInt64(truncatingIfNeeded: whole &<< 3)
        count &= 7
    }

    /// Pads to a byte boundary with zero bits and stores everything.
    @inline(__always)
    mutating func alignToByte() {
        flush()
        count = (count &+ 7) & ~7
        flush()
    }

    /// Copies `bytes` to the output.
    ///
    /// - Precondition: The writer is byte-aligned and flushed (`count` is 0).
    mutating func write(_ bytes: RawSpan) {
        precondition(count == 0)
        // Can't throw: the encoders reserve room for whole blocks.
        var writer = try! BytesWriter(&span, atByteOffset: offset)
        try! writer.write(bytes)
        offset = writer.byteCount
    }
}
