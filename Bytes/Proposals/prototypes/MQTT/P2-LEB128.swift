public import Bytes

// PROTOTYPES of APIs proposed for Bytes (scratch copy only).

public extension BytesReader {
    /// P2: LEB128 of at most `maxByteCount` bytes that, if `requiringMinimal`, must be in the fewest bytes
    /// (no padding with 0x80 continuation bytes and a final 0x00): MQTT's Variable Byte Integer, and the
    /// canonical form some formats require. Throws ``BytesError/invalidValue`` for a padded encoding, consuming
    /// nothing.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_: LEB128.Type, maxByteCount: Int, requiringMinimal: Bool) throws(BytesError) -> UInt64 {
        guard requiringMinimal else { return try read(LEB128.self, maxByteCount: maxByteCount) }
        return try atomically { reader throws(BytesError) in
            let start = reader.byteOffset
            let value = try reader.read(LEB128.self, maxByteCount: maxByteCount)
            let byteCount = reader.byteOffset &- start
            guard byteCount == 1 || byteCount == LEB128.byteCount(of: value) else { throw .invalidValue }
            return value
        }
    }

    /// P2: bytes whose count comes first as LEB128, in the fewest bytes if `requiringMinimal`. Throws without
    /// consuming anything, as ``read(bytesPrefixedBy:maxByteCount:)`` does.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(bytesPrefixedBy _: LEB128.Type, maxByteCount: Int, requiringMinimal: Bool) throws(BytesError) -> RawSpan {
        let start = byteOffset
        let bytes = try read(bytesPrefixedBy: LEB128.self, maxByteCount: maxByteCount)
        let prefixByteCount = byteOffset &- start &- bytes.byteCount
        guard !requiringMinimal || prefixByteCount == 1 || prefixByteCount == LEB128.byteCount(of: UInt64(bytes.byteCount)) else {
            try! seek(toByteOffset: start)
            throw .invalidValue
        }
        return bytes
    }
}
