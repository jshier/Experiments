import Bytes

// Prototypes of proposed Bytes APIs, as extensions, with before/after probes whose machine code is
// compared (instruction counts, loops, calls). Not part of Bytes.

// MARK: - P: Bool flags

public extension BytesReader {
    /// Reads the next bit as a `Bool` (`true` for 1).
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_: Bool.Type) throws(BytesError) -> Bool { try read(Bit.self).isSet }
}

public extension BytesWriter {
    /// Writes `flag` as one bit.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ flag: Bool) throws(BytesError) { try write(Bit(flag)) }
}

// MARK: - P: signed bit fields

public extension Bits {
    /// The field as a two's-complement value: the top bit is the sign.
    @inlinable @inline(__always)
    var signedValue: Int8 {
        let shift = 8 &- width
        return Int8(bitPattern: rawValue &<< UInt8(shift)) &>> Int8(shift)
    }
}

public extension FixedWidthInteger {
    /// The bits in `range`, sign-extended from the range's top bit, as `I`.
    @inlinable @inline(__always)
    func signedBits<I: FixedWidthInteger & SignedInteger>(_ range: Range<Int>, as _: I.Type = Int.self) -> I {
        precondition(range.lowerBound >= 0 && range.upperBound <= Self.bitWidth && range.count <= I.bitWidth, "Bit range out of range")
        let shift = I.bitWidth &- range.count
        return (I(truncatingIfNeeded: self &>> range.lowerBound) &<< shift) &>> shift
    }

    /// The value with only its low `count` bits kept (0 through `bitWidth`).
    @inlinable @inline(__always)
    func keepingLowBits(_ count: Int) -> Self {
        precondition(count >= 0 && count <= Self.bitWidth, "Bit count out of range")
        return count == Self.bitWidth ? self : self & ((1 &<< count) &- 1)
    }

    /// A mask of the low `count` bits (0 through `bitWidth`).
    @inlinable @inline(__always)
    static func lowBitMask(_ count: Int) -> Self {
        precondition(count >= 0 && count <= bitWidth, "Bit count out of range")
        return count == bitWidth ? ~0 : (1 &<< count) &- 1
    }
}

public extension BytesReader {
    /// Reads the next `bitCount` bits (1 through 64) as a two's-complement integer.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readSigned(bitCount: Int) throws(BytesError) -> Int64 {
        let raw = try read(bitCount: bitCount)
        let shift = 64 &- bitCount
        return Int64(bitPattern: raw &<< UInt64(shift)) &>> Int64(shift)
    }
}

// MARK: - Probes

@inline(never) public func flagsBefore(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    var count = 0
    while reader.remainingBitCount >= 1 {
        if try reader.read(Bit.self).isSet { count &+= 1 }
    }
    return count
}

@inline(never) public func flagsAfter(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    var count = 0
    while reader.remainingBitCount >= 1 {
        if try reader.read(Bool.self) { count &+= 1 }
    }
    return count
}

@inline(never) public func writeFlagBefore(_ buffer: UnsafeMutableRawBufferPointer, _ flag: Bool) throws(BytesError) -> Int {
    var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    try writer.write(Bit(flag))
    try writer.write(Bit(0))
    return writer.byteCount
}

@inline(never) public func writeFlagAfter(_ buffer: UnsafeMutableRawBufferPointer, _ flag: Bool) throws(BytesError) -> Int {
    var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    try writer.write(flag)
    try writer.write(false)
    return writer.byteCount
}

@inline(never) public func signedBitsBefore(_ value: UInt32) -> Int32 {
    // 12-bit signed field at bit 4, by hand.
    Int32(bitPattern: value &<< 16) &>> 20
}

@inline(never) public func signedBitsAfter(_ value: UInt32) -> Int32 {
    value.signedBits(4..<16, as: Int32.self)
}

@inline(never) public func signedNibbleBefore(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    var sum = 0
    reader.forEach(Nibble.self) { sum &+= Int(Int8(bitPattern: $0.rawValue &<< 4) &>> 4) }
    return sum
}

@inline(never) public func signedNibbleAfter(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    var sum = 0
    reader.forEach(Nibble.self) { sum &+= Int($0.signedValue) }
    return sum
}

@inline(never) public func readSignedBefore(_ span: RawSpan) throws(BytesError) -> Int64 {
    var reader = BytesReader(span)
    var sum: Int64 = 0
    while reader.remainingBitCount >= 13 {
        let raw = try reader.read(bitCount: 13)
        sum &+= Int64(bitPattern: raw &<< 51) &>> 51
    }
    return sum
}

@inline(never) public func readSignedAfter(_ span: RawSpan) throws(BytesError) -> Int64 {
    var reader = BytesReader(span)
    var sum: Int64 = 0
    while reader.remainingBitCount >= 13 {
        sum &+= try reader.readSigned(bitCount: 13)
    }
    return sum
}

@inline(never) public func lowBitsBefore(_ value: UInt64, _ count: Int) -> UInt64 {
    count == 64 ? value : value & ((1 &<< UInt64(count)) &- 1)
}

@inline(never) public func lowBitsAfter(_ value: UInt64, _ count: Int) -> UInt64 {
    value.keepingLowBits(count)
}
