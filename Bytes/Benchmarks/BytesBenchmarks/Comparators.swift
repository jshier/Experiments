import Bytes

// The implementations `Bytes` is measured against.

enum ComparatorError: Error { case truncated, badSignature }

/// NativeZipArchive's original `ByteReader`, verbatim apart from the error type: a copyable `~Escapable`
/// reader that shrinks its `RawSpan` with `extracting(droppingFirst:)` after every field.
struct ByteReader: ~Escapable {
    private(set) var remaining: RawSpan

    @_lifetime(copy bytes)
    init(_ bytes: RawSpan) {
        remaining = bytes
    }

    var count: Int { remaining.byteCount }

    @_lifetime(self: copy self)
    mutating func read<T: FixedWidthInteger & ConvertibleFromBytes>(_: T.Type = T.self) throws(ComparatorError) -> T {
        let size = MemoryLayout<T>.size
        guard remaining.byteCount >= size else { throw .truncated }
        defer { remaining = remaining.extracting(droppingFirst: size) }
        return remaining.load(fromByteOffset: 0, as: T.self, .littleEndian)
    }

    @_lifetime(self: copy self)
    mutating func expect(_ signature: UInt32) throws(ComparatorError) {
        guard try read(UInt32.self) == signature else { throw .badSignature }
    }

    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(count: Int) throws(ComparatorError) -> RawSpan {
        guard count >= 0, count <= remaining.byteCount else { throw .truncated }
        defer { remaining = remaining.extracting(droppingFirst: count) }
        return remaining.extracting(first: count)
    }

    @_lifetime(self: copy self)
    mutating func skip(_ count: Int) throws(ComparatorError) {
        _ = try read(count: count)
    }
}

/// A conventional LSB- or MSB-first bit reader: a 64-bit buffer refilled a byte at a time.
struct BitBufferReader: ~Escapable {
    let bytes: Span<UInt8>
    var offset = 0
    var buffer: UInt64 = 0
    var bufferedBits = 0
    let mostSignificantFirst: Bool

    @_lifetime(copy bytes)
    init(_ bytes: Span<UInt8>, mostSignificantFirst: Bool) {
        self.bytes = bytes
        self.mostSignificantFirst = mostSignificantFirst
    }

    @_lifetime(self: copy self)
    mutating func read(_ count: Int) throws(ComparatorError) -> UInt64 {
        while bufferedBits < count {
            guard offset < bytes.count else { throw .truncated }
            let byte = UInt64(bytes[offset])
            offset += 1
            if mostSignificantFirst {
                buffer = buffer << 8 | byte
            } else {
                buffer |= byte << bufferedBits
            }
            bufferedBits += 8
        }
        bufferedBits -= count
        let mask: UInt64 = count == 64 ? .max : (1 << count) - 1
        if mostSignificantFirst {
            return buffer >> bufferedBits & mask
        } else {
            defer { buffer = count == 64 ? 0 : buffer >> count }
            return buffer & mask
        }
    }
}

// MARK: - Zip central directory parsing, three ways

/// A synthetic central directory: `count` entries, each a 46-byte header, a name, an extended-timestamp
/// extra field, and no comment.
func makeCentralDirectory(count: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
    for index in 0..<count {
        let name = Array("Sources/Module\(index % 37)/File\(index).swift".utf8)
        append(UInt32(0x0201_4B50))
        append(UInt16(0x031E)) // made by: Unix
        append(UInt16(20)) // version needed
        append(UInt16(0x0808)) // flags
        append(UInt16(8)) // deflated
        append(UInt16(index & 0xFFFF)) // time
        append(UInt16(0x5A21)) // date
        append(UInt32(truncatingIfNeeded: index &* 2_654_435_761)) // CRC
        append(UInt32(index * 100)) // compressed
        append(UInt32(index * 300)) // uncompressed
        append(UInt16(name.count))
        append(UInt16(9)) // extra length
        append(UInt16(0)) // comment length
        append(UInt16(0)) // disk
        append(UInt16(0)) // internal attributes
        append(UInt32(0o100644) << 16) // external attributes
        append(UInt32(index * 400)) // local header offset
        bytes += name
        append(UInt16(0x5455))
        append(UInt16(5))
        bytes.append(1)
        append(Int32(1_700_000_000 + index))
    }
    return bytes
}

/// The fields every parser extracts, summed so nothing is optimized away. A plain sum, not a
/// multiply-accumulate hash: a serial multiply chain (13 per record) took longer than the parsing itself
/// and hid the differences between parsers.
struct Fields {
    var checksum: UInt64 = 0
    mutating func add(_ value: some FixedWidthInteger) { checksum &+= UInt64(truncatingIfNeeded: value) }
}

enum CentralDirectory {
    static let signature: Byte4 = [0x50, 0x4B, 0x01, 0x02]

    static func parseWithBytes(_ span: RawSpan) throws(BytesError) -> UInt64 {
        var reader = Bytes(span)
        var fields = Fields()
        while !reader.isAtEnd {
            try reader.expect(signature)
            fields.add(try reader.read(Byte2.self, .littleEndian)) // made by
            try reader.skip(byteCount: 2)
            fields.add(try reader.read(Byte2.self, .littleEndian)) // flags
            fields.add(try reader.read(Byte2.self, .littleEndian)) // method
            fields.add(try reader.read(Byte2.self, .littleEndian)) // time
            fields.add(try reader.read(Byte2.self, .littleEndian)) // date
            fields.add(try reader.read(Byte4.self, .littleEndian)) // CRC
            fields.add(try reader.read(Byte4.self, .littleEndian)) // compressed
            fields.add(try reader.read(Byte4.self, .littleEndian)) // uncompressed
            let nameLength = Int(try reader.read(Byte2.self, .littleEndian))
            let extraLength = Int(try reader.read(Byte2.self, .littleEndian))
            let commentLength = Int(try reader.read(Byte2.self, .littleEndian))
            try reader.skip(byteCount: 4)
            fields.add(try reader.read(Byte4.self, .littleEndian)) // external attributes
            fields.add(try reader.read(Byte4.self, .littleEndian)) // local header offset
            fields.add(try reader.read(byteCount: nameLength).byteCount)
            var extra = Bytes(try reader.read(byteCount: extraLength))
            try reader.skip(byteCount: commentLength)
            while extra.remainingByteCount >= 4 {
                let id = try extra.read(Byte2.self, .littleEndian)
                let size = Int(try extra.read(Byte2.self, .littleEndian))
                var field = Bytes(try extra.read(byteCount: size))
                if id == 0x5455, size >= 5, try field.read(Byte.self).rawValue & 1 != 0 {
                    fields.add(Int32(bitPattern: try field.read(Byte4.self, .littleEndian)))
                }
            }
        }
        return fields.checksum
    }

    /// Like `parseWithBytes`, but reads each fixed 46-byte header as a sub-cursor first. Its length is then
    /// a constant the optimizer can see, so it proves every field read in bounds: one check per record.
    static func parseWithBytesRecords(_ span: RawSpan) throws(BytesError) -> UInt64 {
        var reader = Bytes(span)
        var fields = Fields()
        while !reader.isAtEnd {
            var header = Bytes(try reader.read(byteCount: 46))
            try header.expect(signature)
            fields.add(try header.read(Byte2.self, .littleEndian)) // made by
            try header.skip(byteCount: 2)
            fields.add(try header.read(Byte2.self, .littleEndian)) // flags
            fields.add(try header.read(Byte2.self, .littleEndian)) // method
            fields.add(try header.read(Byte2.self, .littleEndian)) // time
            fields.add(try header.read(Byte2.self, .littleEndian)) // date
            fields.add(try header.read(Byte4.self, .littleEndian)) // CRC
            fields.add(try header.read(Byte4.self, .littleEndian)) // compressed
            fields.add(try header.read(Byte4.self, .littleEndian)) // uncompressed
            let nameLength = Int(try header.read(Byte2.self, .littleEndian))
            let extraLength = Int(try header.read(Byte2.self, .littleEndian))
            let commentLength = Int(try header.read(Byte2.self, .littleEndian))
            try header.skip(byteCount: 4)
            fields.add(try header.read(Byte4.self, .littleEndian)) // external attributes
            fields.add(try header.read(Byte4.self, .littleEndian)) // local header offset
            fields.add(try reader.read(byteCount: nameLength).byteCount)
            var extra = Bytes(try reader.read(byteCount: extraLength))
            try reader.skip(byteCount: commentLength)
            while extra.remainingByteCount >= 4 {
                var fieldHeader = Bytes(try extra.read(byteCount: 4))
                let id = try fieldHeader.read(Byte2.self, .littleEndian)
                let size = Int(try fieldHeader.read(Byte2.self, .littleEndian))
                var field = Bytes(try extra.read(byteCount: size))
                if id == 0x5455, size >= 5, try field.read(Byte.self).rawValue & 1 != 0 {
                    fields.add(Int32(bitPattern: try field.read(Byte4.self, .littleEndian)))
                }
            }
        }
        return fields.checksum
    }

    static func parseWithByteReader(_ span: RawSpan) throws(ComparatorError) -> UInt64 {
        var reader = ByteReader(span)
        var fields = Fields()
        while reader.count > 0 {
            try reader.expect(0x0201_4B50)
            fields.add(try reader.read(UInt16.self))
            try reader.skip(2)
            fields.add(try reader.read(UInt16.self))
            fields.add(try reader.read(UInt16.self))
            fields.add(try reader.read(UInt16.self))
            fields.add(try reader.read(UInt16.self))
            fields.add(try reader.read(UInt32.self))
            fields.add(try reader.read(UInt32.self))
            fields.add(try reader.read(UInt32.self))
            let nameLength = Int(try reader.read(UInt16.self))
            let extraLength = Int(try reader.read(UInt16.self))
            let commentLength = Int(try reader.read(UInt16.self))
            try reader.skip(4)
            fields.add(try reader.read(UInt32.self))
            fields.add(try reader.read(UInt32.self))
            fields.add(try reader.read(count: nameLength).byteCount)
            var extra = ByteReader(try reader.read(count: extraLength))
            try reader.skip(commentLength)
            while extra.count >= 4 {
                let id = try extra.read(UInt16.self)
                let size = Int(try extra.read(UInt16.self))
                var field = ByteReader(try extra.read(count: size))
                if id == 0x5455, size >= 5, try field.read(UInt8.self) & 1 != 0 {
                    fields.add(try field.read(Int32.self))
                }
            }
        }
        return fields.checksum
    }

    /// Hand-written offsets with the standard library's `RawSpan.load(fromByteOffset:as:_:)`, one bounds
    /// check per record and per extra field: the fastest straightforward code without a reader type.
    static func parseWithOffsets(_ span: RawSpan) throws(ComparatorError) -> UInt64 {
        var fields = Fields()
        var offset = 0
        func u16(_ at: Int) -> UInt16 { span.load(fromByteOffset: at, as: UInt16.self, .littleEndian) }
        func u32(_ at: Int) -> UInt32 { span.load(fromByteOffset: at, as: UInt32.self, .littleEndian) }
        while offset < span.byteCount {
            guard span.byteCount - offset >= 46 else { throw .truncated }
            guard u32(offset) == 0x0201_4B50 else { throw .badSignature }
            fields.add(u16(offset + 4))
            fields.add(u16(offset + 8))
            fields.add(u16(offset + 10))
            fields.add(u16(offset + 12))
            fields.add(u16(offset + 14))
            fields.add(u32(offset + 16))
            fields.add(u32(offset + 20))
            fields.add(u32(offset + 24))
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            fields.add(u32(offset + 38))
            fields.add(u32(offset + 42))
            offset += 46
            guard span.byteCount - offset >= nameLength + extraLength + commentLength else { throw .truncated }
            fields.add(nameLength)
            var extra = offset + nameLength
            let extraEnd = extra + extraLength
            while extraEnd - extra >= 4 {
                let id = u16(extra)
                let size = Int(u16(extra + 2))
                extra += 4
                guard extraEnd - extra >= size else { throw .truncated }
                if id == 0x5455, size >= 5, span.load(fromByteOffset: extra, as: UInt8.self) & 1 != 0 {
                    fields.add(span.load(fromByteOffset: extra + 1, as: Int32.self, .littleEndian))
                }
                extra += size
            }
            offset = extraEnd + commentLength
        }
        return fields.checksum
    }
}

// MARK: - Bit-field parsing, two ways

/// A record of mixed-width bit fields, MSB-first, like a media or network header:
/// 1 + 3 + 4 + 2 + 6 + 13 + 3 + 32 = 64 bits.
enum BitFields {
    static func parseWithBytes(_ span: Span<UInt8>) throws(BytesError) -> UInt64 {
        var reader = Bytes(span)
        var fields = Fields()
        while reader.remainingBitCount >= 64 {
            fields.add(try reader.read(Bit.self).rawValue)
            fields.add(try reader.read(Bits<3>.self).rawValue)
            fields.add(try reader.read(Nibble.self).rawValue)
            fields.add(try reader.read(Crumb.self).rawValue)
            fields.add(try reader.read(Bits<6>.self).rawValue)
            fields.add(try reader.read(bitCount: 13))
            fields.add(try reader.read(Bits<3>.self).rawValue)
            fields.add(try reader.read(bitCount: 32))
        }
        return fields.checksum
    }

    static func parseWithBitBuffer(_ span: Span<UInt8>) throws(ComparatorError) -> UInt64 {
        var reader = BitBufferReader(span, mostSignificantFirst: true)
        var fields = Fields()
        for _ in 0..<span.count / 8 {
            fields.add(try reader.read(1))
            fields.add(try reader.read(3))
            fields.add(try reader.read(4))
            fields.add(try reader.read(2))
            fields.add(try reader.read(6))
            fields.add(try reader.read(13))
            fields.add(try reader.read(3))
            fields.add(try reader.read(32))
        }
        return fields.checksum
    }
}
