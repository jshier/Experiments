import BinaryParsing
import Bytes

// A zip central directory: our field-by-field parser (from Bytes' benchmarks) and its `ParserSpan` port,
// each in two styles: reading every field from the main cursor, and reading each fixed 46-byte header
// as a sub-cursor first.

/// A synthetic central directory: `count` entries, each a 46-byte header, a name, an extended-timestamp
/// extra field, and no comment. (The same generator as Bytes' `Fields:` benchmarks.)
///
/// - Parameter count: The number of entries.
/// - Returns: The directory's bytes.
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

/// An entry that doesn't start with the central directory signature (`PK\1\2`), in the `ParserSpan` parsers.
public struct BadSignature: Error {}

public enum CentralDirectory {
    static var signature: Byte4 { 0x50_4B_01_02 }

    // MARK: Bytes

    /// Parses a central directory with `Bytes`, reading every field from one reader.
    ///
    /// - Parameter span: The directory: entries to the end of the span.
    /// - Returns: The sum of the fields read, so nothing is optimized away.
    /// - Throws: `BytesError.mismatch` if an entry doesn't start with the signature;
    ///   `BytesError.insufficientData` if one is cut short.
    public static func parseWithBytes(_ span: RawSpan) throws -> UInt64 {
        var reader = BytesReader(span)
        var fields = Fields()
        while !reader.isAtEnd {
            try reader.expect(signature)
            try fields.add(reader.read(Byte2.self, .littleEndian)) // made by
            try reader.skip(byteCount: 2)
            try fields.add(reader.read(Byte2.self, .littleEndian)) // flags
            try fields.add(reader.read(Byte2.self, .littleEndian)) // method
            try fields.add(reader.read(Byte2.self, .littleEndian)) // time
            try fields.add(reader.read(Byte2.self, .littleEndian)) // date
            try fields.add(reader.read(Byte4.self, .littleEndian)) // CRC
            try fields.add(reader.read(Byte4.self, .littleEndian)) // compressed
            try fields.add(reader.read(Byte4.self, .littleEndian)) // uncompressed
            let nameLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
            let extraLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
            let commentLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
            try reader.skip(byteCount: 4)
            try fields.add(reader.read(Byte4.self, .littleEndian)) // external attributes
            try fields.add(reader.read(Byte4.self, .littleEndian)) // local header offset
            try fields.add(reader.read(byteCount: nameLength).byteCount)
            var extra = try reader.readSection(byteCount: extraLength)
            try reader.skip(byteCount: commentLength)
            try extra.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { id, field throws(BytesError) in
                if id == 0x5455, field.remainingByteCount >= 5, try field.read(Byte.self)[bit: 0] {
                    try fields.add(field.readSigned(Byte4.self, .littleEndian, as: Int32.self))
                }
            }
        }
        return fields.checksum
    }

    /// Parses a central directory with `Bytes`, reading each fixed 46-byte header, and each extra field's
    /// header, through a sub-reader.
    ///
    /// - Parameter span: The directory.
    /// - Returns: The sum of the fields read, as ``parseWithBytes(_:)``.
    /// - Throws: As ``parseWithBytes(_:)``.
    public static func parseWithBytesRecords(_ span: RawSpan) throws -> UInt64 {
        var reader = BytesReader(span)
        var fields = Fields()
        while !reader.isAtEnd {
            var header = try reader.readSection(byteCount: 46)
            try header.expect(signature)
            try fields.add(header.read(Byte2.self, .littleEndian)) // made by
            try header.skip(byteCount: 2)
            try fields.add(header.read(Byte2.self, .littleEndian)) // flags
            try fields.add(header.read(Byte2.self, .littleEndian)) // method
            try fields.add(header.read(Byte2.self, .littleEndian)) // time
            try fields.add(header.read(Byte2.self, .littleEndian)) // date
            try fields.add(header.read(Byte4.self, .littleEndian)) // CRC
            try fields.add(header.read(Byte4.self, .littleEndian)) // compressed
            try fields.add(header.read(Byte4.self, .littleEndian)) // uncompressed
            let nameLength = try header.read(Int.self, as: Byte2.self, .littleEndian)
            let extraLength = try header.read(Int.self, as: Byte2.self, .littleEndian)
            let commentLength = try header.read(Int.self, as: Byte2.self, .littleEndian)
            try header.skip(byteCount: 4)
            try fields.add(header.read(Byte4.self, .littleEndian)) // external attributes
            try fields.add(header.read(Byte4.self, .littleEndian)) // local header offset
            try fields.add(reader.read(byteCount: nameLength).byteCount)
            var extra = try reader.readSection(byteCount: extraLength)
            try reader.skip(byteCount: commentLength)
            while extra.remainingByteCount >= 4 {
                var fieldHeader = try extra.readSection(byteCount: 4)
                let id = try fieldHeader.read(Byte2.self, .littleEndian)
                let size = try fieldHeader.read(Int.self, as: Byte2.self, .littleEndian)
                var field = try extra.readSection(byteCount: size)
                if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                    try fields.add(field.readSigned(Byte4.self, .littleEndian, as: Int32.self))
                }
            }
        }
        return fields.checksum
    }

    // MARK: BinaryParsing

    /// Parses a central directory with `ParserSpan`, reading every field from one cursor.
    ///
    /// - Parameter span: The directory.
    /// - Returns: The sum of the fields read, as ``parseWithBytes(_:)``.
    /// - Throws: ``BadSignature`` if an entry doesn't start with the signature; `ParsingError` if one is cut
    ///   short.
    public static func parseWithParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var fields = Fields()
        while !input.isEmpty {
            guard try UInt32(parsingLittleEndian: &input) == 0x0201_4B50 else { throw BadSignature() }
            try fields.add(UInt16(parsingLittleEndian: &input)) // made by
            try input.seek(toRelativeOffset: 2)
            try fields.add(UInt16(parsingLittleEndian: &input)) // flags
            try fields.add(UInt16(parsingLittleEndian: &input)) // method
            try fields.add(UInt16(parsingLittleEndian: &input)) // time
            try fields.add(UInt16(parsingLittleEndian: &input)) // date
            try fields.add(UInt32(parsingLittleEndian: &input)) // CRC
            try fields.add(UInt32(parsingLittleEndian: &input)) // compressed
            try fields.add(UInt32(parsingLittleEndian: &input)) // uncompressed
            let nameLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            let extraLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            let commentLength = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            try input.seek(toRelativeOffset: 4)
            try fields.add(UInt32(parsingLittleEndian: &input)) // external attributes
            try fields.add(UInt32(parsingLittleEndian: &input)) // local header offset
            try fields.add(input.sliceSpan(byteCount: nameLength).count)
            var extra = try input.sliceSpan(byteCount: extraLength)
            try input.seek(toRelativeOffset: commentLength)
            while extra.count >= 4 {
                let id = try UInt16(parsingLittleEndian: &extra)
                let size = try Int(parsing: &extra, storedAsLittleEndian: UInt16.self)
                var field = try extra.sliceSpan(byteCount: size)
                if id == 0x5455, size >= 5, try UInt8(parsing: &field) & 1 != 0 {
                    try fields.add(Int32(parsingLittleEndian: &field))
                }
            }
        }
        return fields.checksum
    }

    /// Parses a central directory with `ParserSpan`, reading each fixed 46-byte header, and each extra
    /// field's header, through a sub-cursor.
    ///
    /// - Parameter span: The directory.
    /// - Returns: The sum of the fields read, as ``parseWithBytes(_:)``.
    /// - Throws: As ``parseWithParserSpan(_:)``.
    public static func parseWithParserSpanRecords(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var fields = Fields()
        while !input.isEmpty {
            var header = try input.sliceSpan(byteCount: 46)
            guard try UInt32(parsingLittleEndian: &header) == 0x0201_4B50 else { throw BadSignature() }
            try fields.add(UInt16(parsingLittleEndian: &header)) // made by
            try header.seek(toRelativeOffset: 2)
            try fields.add(UInt16(parsingLittleEndian: &header)) // flags
            try fields.add(UInt16(parsingLittleEndian: &header)) // method
            try fields.add(UInt16(parsingLittleEndian: &header)) // time
            try fields.add(UInt16(parsingLittleEndian: &header)) // date
            try fields.add(UInt32(parsingLittleEndian: &header)) // CRC
            try fields.add(UInt32(parsingLittleEndian: &header)) // compressed
            try fields.add(UInt32(parsingLittleEndian: &header)) // uncompressed
            let nameLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            let extraLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            let commentLength = try Int(parsing: &header, storedAsLittleEndian: UInt16.self)
            try header.seek(toRelativeOffset: 4)
            try fields.add(UInt32(parsingLittleEndian: &header)) // external attributes
            try fields.add(UInt32(parsingLittleEndian: &header)) // local header offset
            try fields.add(input.sliceSpan(byteCount: nameLength).count)
            var extra = try input.sliceSpan(byteCount: extraLength)
            try input.seek(toRelativeOffset: commentLength)
            while extra.count >= 4 {
                var fieldHeader = try extra.sliceSpan(byteCount: 4)
                let id = try UInt16(parsingLittleEndian: &fieldHeader)
                let size = try Int(parsing: &fieldHeader, storedAsLittleEndian: UInt16.self)
                var field = try extra.sliceSpan(byteCount: size)
                if id == 0x5455, size >= 5, try UInt8(parsing: &field) & 1 != 0 {
                    try fields.add(Int32(parsingLittleEndian: &field))
                }
            }
        }
        return fields.checksum
    }
}
