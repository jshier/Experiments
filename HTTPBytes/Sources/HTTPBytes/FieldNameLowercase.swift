import Bytes

extension HTTPFieldName {
    /// The known name spelled exactly `name`, in lowercase (HTTP/2's and HTTP/3's spelling), or `nil`: for names the
    /// table doesn't have, and for any other spelling of one it has (`Content-Type`, or bytes that only fold to it).
    ///
    /// The same perfect hash as ``init(caseInsensitive:)``, then the name's bytes compared with the table's exactly, so
    /// `name` can be any bytes (a decoded HPACK or QPACK literal): a known name found this way is a valid lowercase name,
    /// and a field whose ``HTTPFieldView/knownName`` came from here needs no character check of its name.
    @inlinable
    public init?(lowercase name: RawSpan) {
        guard let index = Self.lookUpLowercase(name) else { return nil }
        self.init(uncheckedIndex: index)
    }

    /// The name's words as stored, unfolded: the loads ``words(_:)`` makes.
    @inline(__always)
    static func exactWords(_ name: RawSpan) -> (UInt64, UInt64) {
        let count = name.byteCount
        if count >= 8 {
            // Unsafe: 8-byte loads at 0 and count − 8. Safe: count ≥ 8.
            let first = unsafe name.unsafeLoadUnaligned(fromUncheckedByteOffset: 0, as: UInt64.self)
            let last = unsafe name.unsafeLoadUnaligned(fromUncheckedByteOffset: count &- 8, as: UInt64.self)
            return (UInt64(littleEndian: first), UInt64(littleEndian: last))
        }
        if count >= 4 {
            // Unsafe: 4-byte loads at 0 and count − 4. Safe: count ≥ 4.
            let first = unsafe name.unsafeLoadUnaligned(fromUncheckedByteOffset: 0, as: UInt32.self)
            let last = unsafe name.unsafeLoadUnaligned(fromUncheckedByteOffset: count &- 4, as: UInt32.self)
            return (UInt64(UInt32(littleEndian: first)), UInt64(UInt32(littleEndian: last)))
        }
        // Unsafe: single bytes at 0, count / 2, and count − 1. Safe: 1 ≤ count ≤ 3 (the caller checks count > 0).
        let b0 = UInt64(unsafe name.unsafeLoad(fromUncheckedByteOffset: 0, as: UInt8.self))
        let b1 = UInt64(unsafe name.unsafeLoad(fromUncheckedByteOffset: count &>> 1, as: UInt8.self))
        let b2 = UInt64(unsafe name.unsafeLoad(fromUncheckedByteOffset: count &- 1, as: UInt8.self))
        return (b0 | b1 &<< 8 | b2 &<< 16, 0)
    }

    /// The table's words are the lowercase names' bytes ORed with 0x20 per byte, which changes none of the bytes the
    /// table's names use (lowercase letters, digits, `-`, `:`): so an exact match is the unfolded words equal to them.
    @usableFromInline
    static func lookUpLowercase(_ name: RawSpan) -> UInt8? {
        let count = name.byteCount
        guard count > 0, count <= 64 else { return nil }
        let (first, last) = exactWords(name)
        let fold: UInt64 = count >= 8 ? 0x2020_2020_2020_2020 : count >= 4 ? 0x2020_2020 : 0x20_2020
        let foldedLast = count >= 4 ? last | fold : 0
        let key = (first | fold) ^ (foldedLast &<< 29 | foldedLast &>> 35) ^ UInt64(truncatingIfNeeded: count)
        let index = FieldNameTable.slots[Int(truncatingIfNeeded: (key &* hashMultiplier) &>> UInt64(64 &- slotBits))]
        guard index != 0xFF else { return nil }
        let entry = Int(index)
        let range = range(index)
        guard range.count == count, FieldNameTable.firstWords[entry] == first, FieldNameTable.lastWords[entry] == last else {
            return nil
        }
        // Over 16 bytes, the middle the two words didn't cover.
        if count > 16, !name.extracting(8..<count &- 8).bytesEqual(lowercaseTable.extracting(range.lowerBound &+ 8..<range.upperBound &- 8)) {
            return nil
        }
        return index
    }
}

extension HTTPFieldName {
    /// The name at table index `index`, which the caller knows is below ``knownCount`` (an index from a generated
    /// table, such as HPACK's static table's names): no check.
    @inlinable @inline(__always)
    package init(tableIndex index: UInt8) {
        self.init(uncheckedIndex: index)
    }
}
