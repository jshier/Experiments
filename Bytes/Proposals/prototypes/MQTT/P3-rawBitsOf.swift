public import Bytes

// PROTOTYPES of APIs proposed for Bytes (scratch copy only).

public extension Bits {
    /// P3: `value`'s raw value as a field, the write-side counterpart of `init?(rawBits:)`. A raw value that
    /// doesn't fit is a programming error: debug builds trap, release builds keep its low `width` bits (as
    /// `BytesWriter.write(_:as:)` does).
    @inlinable @inline(__always)
    init<R: RawRepresentable>(rawBitsOf value: R) where R.RawValue: BinaryInteger {
        assert(Self(exactly: value.rawValue) != nil, "\(value.rawValue) doesn't fit in \(width) bits")
        self.init(truncatingIfNeeded: value.rawValue)
    }
}
