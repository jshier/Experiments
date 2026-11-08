import BinaryParsing
import Bytes

// A zip central directory: our field-by-field parser (from Bytes' benchmarks) and its `ParserSpan` port,
// each in two styles: reading every field from the main cursor, and reading each fixed 46-byte header
// as a sub-cursor first.

/// A synthetic central directory: `count` entries, each a 46-byte header, a name, an extended-timestamp
/// extra field, and no comment. (The same generator as Bytes' `Fields:` benchmarks.)
public func makeCentralDirectory(count: Int) -> [UInt8] {
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

/// The fields every parser extracts, summed so nothing is optimized away.
struct Fields {
    var checksum: UInt64 = 0
    mutating func add(_ value: some FixedWidthInteger) { checksum &+= UInt64(truncatingIfNeeded: value) }
}

public struct BadSignature: Error {}

public enum CentralDirectory {
    static var signature: Byte4 { 0x50_4B_01_02 }

    // MARK: Bytes

    public static func parseWithBytes(_ span: RawSpan) throws -> UInt64 {
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
                if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                    fields.add(Int32(bitPattern: try field.read(Byte4.self, .littleEndian)))
                }
            }
        }
        return fields.checksum
    }

    public static func parseWithBytesRecords(_ span: RawSpan) throws -> UInt64 {
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
                if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                    fields.add(Int32(bitPattern: try field.read(Byte4.self, .littleEndian)))
                }
            }
        }
        return fields.checksum
    }

    // MARK: BinaryParsing

    public static func parseWithParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var fields = Fields()
        while !input.isEmpty {
            guard try UInt32(parsingLittleEndian: &input) == 0x0201_4B50 else { throw BadSignature() }
            fields.add(try UInt16(parsingLittleEndian: &input)) // made by
            try input.seek(toRelativeOffset: 2)
            fields.add(try UInt16(parsingLittleEndian: &input)) // flags
            fields.add(try UInt16(parsingLittleEndian: &input)) // method
            fields.add(try UInt16(parsingLittleEndian: &input)) // time
            fields.add(try UInt16(parsingLittleEndian: &input)) // date
            fields.add(try UInt32(parsingLittleEndian: &input)) // CRC
            fields.add(try UInt32(parsingLittleEndian: &input)) // compressed
            fields.add(try UInt32(parsingLittleEndian: &input)) // uncompressed
            let nameLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            let extraLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            let commentLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            try input.seek(toRelativeOffset: 4)
            fields.add(try UInt32(parsingLittleEndian: &input)) // external attributes
            fields.add(try UInt32(parsingLittleEndian: &input)) // local header offset
            fields.add(try input.sliceSpan(byteCount: nameLength).count)
            var extra = try input.sliceSpan(byteCount: extraLength)
            try input.seek(toRelativeOffset: commentLength)
            while extra.count >= 4 {
                let id = try UInt16(parsingLittleEndian: &extra)
                let size = try Int(parsing: &extra, storedAsLittleEndian: UInt16.self)
                var field = try extra.sliceSpan(byteCount: size)
                if id == 0x5455, size >= 5, try UInt8(parsing: &field) & 1 != 0 {
                    fields.add(try Int32(parsingLittleEndian: &field))
                }
            }
        }
        return fields.checksum
    }

    public static func parseWithParserSpanRecords(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var fields = Fields()
        while !input.isEmpty {
            var header = try input.sliceSpan(byteCount: 46)
            guard try UInt32(parsingLittleEndian: &header) == 0x0201_4B50 else { throw BadSignature() }
            fields.add(try UInt16(parsingLittleEndian: &header)) // made by
            try header.seek(toRelativeOffset: 2)
            fields.add(try UInt16(parsingLittleEndian: &header)) // flags
            fields.add(try UInt16(parsingLittleEndian: &header)) // method
            fields.add(try UInt16(parsingLittleEndian: &header)) // time
            fields.add(try UInt16(parsingLittleEndian: &header)) // date
            fields.add(try UInt32(parsingLittleEndian: &header)) // CRC
            fields.add(try UInt32(parsingLittleEndian: &header)) // compressed
            fields.add(try UInt32(parsingLittleEndian: &header)) // uncompressed
            let nameLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            let extraLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            let commentLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            try header.seek(toRelativeOffset: 4)
            fields.add(try UInt32(parsingLittleEndian: &header)) // external attributes
            fields.add(try UInt32(parsingLittleEndian: &header)) // local header offset
            fields.add(try input.sliceSpan(byteCount: nameLength).count)
            var extra = try input.sliceSpan(byteCount: extraLength)
            try input.seek(toRelativeOffset: commentLength)
            while extra.count >= 4 {
                var fieldHeader = try extra.sliceSpan(byteCount: 4)
                let id = try UInt16(parsingLittleEndian: &fieldHeader)
                let size = try Int(parsing: &fieldHeader, storedAsLittleEndian: UInt16.self)
                var field = try extra.sliceSpan(byteCount: size)
                if id == 0x5455, size >= 5, try UInt8(parsing: &field) & 1 != 0 {
                    fields.add(try Int32(parsingLittleEndian: &field))
                }
            }
        }
        return fields.checksum
    }
}
