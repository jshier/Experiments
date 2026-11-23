public import Bytes

/// QUIC's variable-length integers (RFC 9000 §16), which HTTP/3 frames and settings use: the first byte's two high bits
/// give the length (1, 2, 4, or 8 bytes), the rest of the bits the value, big-endian, up to 2⁶² − 1.
public enum QUICVariableLengthInteger {
    /// The largest value: 2⁶² − 1.
    @inlinable public static var maximum: UInt64 { (1 &<< 62) &- 1 }

    /// The integer at `offset` of `bytes` and its length, or `nil` if `bytes` ends first.
    ///
    /// With 8 bytes available (nearly always, mid-stream), one big-endian 64-bit load, then a mask and a shift chosen by
    /// the length: no branch on the length. Near the end, a byte at a time.
    @inlinable @inline(__always)
    public static func read(_ bytes: RawSpan, at offset: Int) -> (value: UInt64, length: Int)? {
        let available = bytes.byteCount &- offset
        guard available > 0 else { return nil }
        let first = bytes.load(fromByteOffset: offset, as: UInt8.self)
        let length = 1 &<< Int(first &>> 6)
        if available >= 8 {
            let word = UInt64(bigEndian: bytes.load(fromByteOffset: offset, as: UInt64.self)) & 0x3FFF_FFFF_FFFF_FFFF
            return (word &>> UInt64(64 &- length &* 8), length)
        }
        guard available >= length else { return nil }
        var value = UInt64(first & 0x3F)
        for index in 1..<length {
            value = value &<< 8 | UInt64(bytes.load(fromByteOffset: offset &+ index, as: UInt8.self))
        }
        return (value, length)
    }

    /// The bytes `value` takes in its shortest encoding.
    @inlinable
    public static func length(of value: UInt64) -> Int {
        value < 64 ? 1 : value < 16_384 ? 2 : value < 1 &<< 30 ? 4 : 8
    }

    /// Writes `value` in its shortest encoding (`value` ≤ ``maximum``).
    @inlinable
    public static func write(_ value: UInt64, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        precondition(value <= maximum, "a QUIC variable-length integer has 62 bits")
        switch length(of: value) {
        case 1: try writer.write(UInt8(truncatingIfNeeded: value))
        case 2: try writer.write(UInt16(truncatingIfNeeded: value) | 0x4000)
        case 4: try writer.write(UInt32(truncatingIfNeeded: value) | 0x8000_0000)
        default: try writer.write(value | 0xC000_0000_0000_0000)
        }
    }
}
