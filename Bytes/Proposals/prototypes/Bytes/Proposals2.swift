import Bytes

// Second batch of prototypes (see Proposals.swift), from call sites in the dependent packages.

// MARK: - P: one closure to write a new array

public extension Array where Element == UInt8 {
    /// A new array of what `body` writes, with room for `byteCapacity` bytes.
    @inlinable @inline(always)
    init<E: Error>(
        byteCapacity: Int, bitOrder: BitOrder = .mostSignificantFirst, writing body: (inout BytesWriter) throws(E) -> Void
    ) throws(E) {
        try self.init(capacity: byteCapacity) { (output) throws(E) in
            try output.withBytesWriter(bitOrder: bitOrder, body)
        }
    }
}

// MARK: - P: a reader that starts at an offset

public extension BytesReader {
    /// A reader positioned `byteOffset` bytes into `span`; throws ``BytesError/insufficientData`` past its end.
    @inlinable @inline(__always)
    @_lifetime(copy span)
    init(_ span: RawSpan, atByteOffset byteOffset: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError) {
        self.init(span, bitOrder: bitOrder)
        try seek(toByteOffset: byteOffset)
    }

    /// Everything left, consumed (byte-aligned readers).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    mutating func readRemainingBytes() -> RawSpan {
        try! read(byteCount: remainingByteCount)
    }

    /// Reads a group and sign-extends it to `I`.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readSigned<T: ByteGroup, I: FixedWidthInteger & SignedInteger>(
        _: T.Type, _ byteOrder: ByteOrder, as _: I.Type
    ) throws(BytesError) -> I {
        try read(T.self).signedInteger(byteOrder, as: I.self)
    }

    /// Calls `body` with each tag-length-value record's tag and a cursor bounded to its value, until the
    /// end. A record that doesn't fit throws without consuming it.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func forEachRecord<Tag: ByteGroup, Length: ByteGroup>(
        tag _: Tag.Type, length _: Length.Type, _ byteOrder: ByteOrder,
        _ body: (Tag.Integer, inout BytesReader) throws(BytesError) -> Void
    ) throws(BytesError) {
        while !isAtEnd {
            try atomically { (reader) throws(BytesError) in
                let tag = try reader.read(Tag.self, byteOrder)
                var section = try reader.read(sectionPrefixedBy: Length.self, byteOrder)
                try body(tag, &section)
            }
        }
    }

    /// A LEB128 that must use the fewest bytes (MQTT's variable byte integer); throws
    /// ``BytesError/invalidValue`` and consumes nothing otherwise.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(minimal _: LEB128.Type, maxByteCount: Int) throws(BytesError) -> UInt64 {
        try atomically { (reader) throws(BytesError) in
            let start = reader.byteOffset
            let value = try reader.read(LEB128.self, maxByteCount: maxByteCount)
            guard reader.byteOffset &- start == LEB128.byteCount(of: value) else { throw .invalidValue }
            return value
        }
    }
}

public extension BytesWriter {
    /// Writes `count` copies of `value`.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(repeating value: Byte, count: Int) throws(BytesError) {
        try write(Byte.self, count: count) { _ in value }
    }
}

// MARK: - Probes

public struct Header { public var kind: UInt16; public var length: UInt32; public var flag: Bool }

@inline(never) public func encodeBefore(_ header: Header) throws(BytesError) -> [UInt8] {
    try [UInt8](capacity: 7) { (output) throws(BytesError) in
        try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
            try writer.write(header.kind, as: Byte2.self, .bigEndian)
            try writer.write(header.length, as: Byte4.self, .bigEndian)
            try writer.write(Bit(header.flag))
        }
    }
}

@inline(never) public func encodeAfter(_ header: Header) throws(BytesError) -> [UInt8] {
    try [UInt8](byteCapacity: 7) { (writer) throws(BytesError) in
        try writer.write(header.kind, as: Byte2.self, .bigEndian)
        try writer.write(header.length, as: Byte4.self, .bigEndian)
        try writer.write(Bit(header.flag))
    }
}

@inline(never) public func atOffsetBefore(_ span: RawSpan, _ offset: Int) throws(BytesError) -> UInt32 {
    var reader = BytesReader(span)
    try reader.seek(toByteOffset: offset)
    return try reader.read(Byte4.self, .littleEndian)
}

@inline(never) public func atOffsetAfter(_ span: RawSpan, _ offset: Int) throws(BytesError) -> UInt32 {
    var reader = try BytesReader(span, atByteOffset: offset)
    return try reader.read(Byte4.self, .littleEndian)
}

@inline(never) public func remainingBefore(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    _ = try reader.read(Byte2.self, .bigEndian)
    return try reader.read(byteCount: reader.remainingByteCount).byteCount
}

@inline(never) public func remainingAfter(_ span: RawSpan) throws(BytesError) -> Int {
    var reader = BytesReader(span)
    _ = try reader.read(Byte2.self, .bigEndian)
    return reader.readRemainingBytes().byteCount
}

@inline(never) public func signedBefore(_ span: RawSpan) throws(BytesError) -> Int64 {
    var reader = BytesReader(span)
    var sum: Int64 = 0
    while reader.remainingByteCount >= 4 { sum &+= Int64(try Int32(bitPattern: reader.read(Byte4.self, .littleEndian))) }
    return sum
}

@inline(never) public func signedAfter(_ span: RawSpan) throws(BytesError) -> Int64 {
    var reader = BytesReader(span)
    var sum: Int64 = 0
    while reader.remainingByteCount >= 4 { sum &+= Int64(try reader.readSigned(Byte4.self, .littleEndian, as: Int32.self)) }
    return sum
}

// Zip extra fields: 2-byte id, 2-byte size, data. The checksum adds each extended timestamp (0x5455).
@inline(never) public func recordsBefore(_ span: RawSpan) throws(BytesError) -> Int64 {
    var extra = BytesReader(span)
    var sum: Int64 = 0
    while !extra.isAtEnd {
        let id = try extra.read(Byte2.self, .littleEndian)
        var field = try extra.read(sectionPrefixedBy: Byte2.self, .littleEndian)
        if id == 0x5455, field.remainingByteCount >= 5, try field.read(Byte.self)[bit: 0] {
            sum &+= Int64(try Int32(bitPattern: field.read(Byte4.self, .littleEndian)))
        }
    }
    return sum
}

@inline(never) public func recordsAfter(_ span: RawSpan) throws(BytesError) -> Int64 {
    var extra = BytesReader(span)
    var sum: Int64 = 0
    try extra.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { (id, field) throws(BytesError) in
        if id == 0x5455, field.remainingByteCount >= 5, try field.read(Byte.self)[bit: 0] {
            sum &+= Int64(try Int32(bitPattern: field.read(Byte4.self, .littleEndian)))
        }
    }
    return sum
}

@inline(never) public func padBefore(_ buffer: UnsafeMutableRawBufferPointer, _ count: Int) throws(BytesError) -> Int {
    var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    for _ in 0..<count { try writer.write(0x3D as Byte) }
    return writer.byteCount
}

@inline(never) public func padAfter(_ buffer: UnsafeMutableRawBufferPointer, _ count: Int) throws(BytesError) -> Int {
    var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    try writer.write(repeating: 0x3D, count: count)
    return writer.byteCount
}

// MQTT's variable byte integer (Basics.swift:334-343), by hand and with the proposal.
@inline(never) public func minimalBefore(_ span: RawSpan) throws(BytesError) -> UInt64 {
    var reader = BytesReader(span)
    let start = reader.byteOffset
    let value = try reader.read(LEB128.self, maxByteCount: 4)
    let byteCount = reader.byteOffset &- start
    guard byteCount == 1 || byteCount == LEB128.byteCount(of: value) else {
        try! reader.seek(toByteOffset: start)
        throw .invalidValue
    }
    return value &+ UInt64(reader.byteOffset)
}

@inline(never) public func minimalAfter(_ span: RawSpan) throws(BytesError) -> UInt64 {
    var reader = BytesReader(span)
    let value = try reader.read(minimal: LEB128.self, maxByteCount: 4)
    return value &+ UInt64(reader.byteOffset)
}
