import Bytes
import BytesMacros
import Foundation // `PropertyListSerialization`, for synthetic property lists.

// Binary property lists: swift-binary-parsing's BPListParser example (`ExampleBPList`), ported to `Bytes`. It
// reads the trailer and its offset table, then the object graph from the top object, into the example's own
// types, so both sides build the same result: the offset table as an `[Int]`, and every string, data, array, and
// dictionary of the graph (none reserved: the example appends to empty ones). Only the parsing differs.
//
// - Big-endian throughout: `BigEndianBytesReader`s, one per object, at the offset the table gives.
// - Each object's marker byte is two named 4-bit fields: its type, and a size or count.
// - Arrays' and dictionaries' references are sections of `count × reference size` bytes, read in a loop.
// - The trailer is a `@BinaryRecord` (one-byte fields, and `Padding` for its first six bytes), so its fields'
//   checks fold to one.
// - The format's integers have widths known only at run time (the trailer's offset and reference sizes, and 2^n
//   bytes for an integer object): `read(UInt64.self, byteCount:)` and `read(Int64.self, signedByteCount:)` read
//   one with one load.
//
// Results match the example's, including where it departs from Apple's format: 1-, 2-, and 4-byte integers are
// sign-extended (the format's are unsigned), 4-byte reals are taken as the low bits of a `Double`, dates as an
// `Int64`, and UIDs as data. One exception: UTF-16 strings are decoded big-endian, as the format stores them;
// the example decodes them in the machine's order (little-endian here). None of the test files has one.
//
// An object referenced from several places (a shared dictionary key) is parsed at each reference, in both: the
// example's model has no identity to share, and caching parsed objects would allocate a table.

/// The trailer: the last 32 bytes.
@BinaryRecord(.bigEndian)
struct BPListTrailer {
    var unused: Padding<Byte6> // Unused, and the sort version.
    @Field(Byte.self) var offsetSize: Int
    @Field(Byte.self) var objectReferenceSize: Int
    @Field(Byte8.self) var objectCount: Int
    @Field(Byte8.self) var topObjectIndex: Int
    @Field(Byte8.self) var offsetTableStart: Int
}

/// A binary property list's object marker byte, by name.
enum BPListMarker {
    /// The object type: the high 4 bits.
    static var type: BitField<Int> { BitField(bits: 4...7) }
    /// The type's argument: a value (null, booleans), a size exponent (integers, reals), or a count (15: the
    /// count follows, as an integer object).
    static var info: BitField<Int> { BitField(bits: 0...3) }
}

public enum BPList {
    /// Parses a binary property list with `Bytes`, as the example does.
    ///
    /// - Parameter data: The property list (`bplist00`; the header isn't checked, as in the example).
    /// - Returns: The trailer and the top object, as the example's types.
    /// - Throws: `BytesError.invalidValue` for an unknown marker, a non-string dictionary key, an object index
    ///   out of the offset table, or an integer that doesn't fit; `BytesError.insufficientData` if an object or
    ///   table is cut short or an offset is past the end.
    public static func parseWithBytes(_ data: RawSpan) throws(BytesError) -> ExampleBPList {
        let trailer = try readTrailer(data)
        return try ExampleBPList(trailer: trailer, topObject: readObject(index: trailer.topObjectIndex, data, trailer))
    }

    static func readTrailer(_ data: RawSpan) throws(BytesError) -> ExampleBPList.Trailer {
        var reader = try BigEndianBytesReader(data, atByteOffset: data.byteCount &- 32)
        let fields = try reader.read(BPListTrailer.self)
        let (offsetSize, objectReferenceSize) = (fields.offsetSize, fields.objectReferenceSize)
        let (topObjectIndex, offsetTableStart) = (fields.topObjectIndex, fields.offsetTableStart)

        let (tableSize, overflow) = offsetSize.multipliedReportingOverflow(by: fields.objectCount)
        guard !overflow else { throw .invalidValue }
        var table = try BigEndianBytesReader(data, atByteOffset: offsetTableStart)
        var entries = try table.readSection(byteCount: tableSize)
        var offsetTable: [Int] = []
        while !entries.isAtEnd {
            guard let offset = try Int(exactly: readUnsigned(&entries, byteCount: offsetSize)) else { throw .invalidValue }
            offsetTable.append(offset)
        }
        return ExampleBPList.Trailer(
            topObjectIndex: topObjectIndex, objectReferenceSize: objectReferenceSize, offsetTable: offsetTable
        )
    }

    /// Reads the object at `index` in the offset table.
    static func readObject(
        index: Int, _ data: RawSpan, _ trailer: ExampleBPList.Trailer
    ) throws(BytesError) -> ExampleBPList.Object {
        guard index >= 0, index < trailer.offsetTable.count else { throw .invalidValue }
        var reader = try BigEndianBytesReader(data, atByteOffset: trailer.offsetTable[index])
        let marker = try reader.read(Byte.self)
        switch (marker[BPListMarker.type], marker[BPListMarker.info]) {
        case (0x0, 0x0): return .null
        case (0x0, 0x8): return .boolean(false)
        case (0x0, 0x9): return .boolean(true)
        case let (0x1, size): return try .int(readSigned(&reader, byteCount: 1 &<< size))
        case let (0x2, size): return try .real(Double(bitPattern: readUnsigned(&reader, byteCount: 1 &<< size)))
        case (0x3, 0x3): return try .date(reader.read(Int64.self))
        case let (0x4, count):
            let count = try readCount(&reader, count)
            return try .data([UInt8](copying: reader.read(byteCount: count)))
        case let (0x5, count): // ASCII
            let count = try readCount(&reader, count)
            // Validated, where the example repairs invalid UTF-8: the same for ASCII.
            return try .string(String(copying: reader.readUTF8(byteCount: count)))
        case let (0x6, count): // UTF-16, big-endian
            let count = try readCount(&reader, count)
            let (byteCount, overflow) = count.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw .invalidValue }
            var units = try reader.readSection(byteCount: byteCount)
            // The code units in the machine's order first: one more allocation than the example's in-place
            // decoding, which can only decode the machine's order.
            var codeUnits: [UInt16] = []
            codeUnits.reserveCapacity(count)
            while !units.isAtEnd {
                try codeUnits.append(units.read(UInt16.self))
            }
            return .string(String(decoding: codeUnits, as: UTF16.self))
        case let (0x8, size): // A UID: read as data, as in the example.
            return try .data([UInt8](copying: reader.read(byteCount: size &+ 1)))
        case let (0xA, marker):
            var references = try readReferences(&reader, count: readCount(&reader, marker), trailer)
            var array: [ExampleBPList.Object] = []
            while !references.isAtEnd {
                try array.append(readObject(index: readReference(&references, trailer), data, trailer))
            }
            return .array(array)
        case let (0xD, marker):
            let count = try readCount(&reader, marker) // Once, for both lists.
            var keys = try readReferences(&reader, count: count, trailer)
            var values = try readReferences(&reader, count: count, trailer)
            var dictionary: [String: ExampleBPList.Object] = [:]
            while !keys.isAtEnd {
                let key = try readObject(index: readReference(&keys, trailer), data, trailer)
                let value = try readObject(index: readReference(&values, trailer), data, trailer)
                guard case let .string(name) = key else { throw .invalidValue }
                dictionary[name] = value
            }
            return .dictionary(dictionary)
        default:
            throw .invalidValue
        }
    }

    /// An object's count: the marker's, or (15) an integer object after it.
    @inline(__always)
    static func readCount(_ reader: inout BigEndianBytesReader, _ marker: Int) throws(BytesError) -> Int {
        guard marker == 0xF else { return marker }
        // An integer marker, 0x1n: 2^n bytes follow. Only n is used, as in the example.
        let size = try reader.read(Byte.self)
        guard let count = try Int(exactly: readUnsigned(&reader, byteCount: 1 &<< size[BPListMarker.info])) else {
            throw .invalidValue
        }
        return count
    }

    /// `count` object references of an array or dictionary, as a section.
    @inline(__always)
    @_lifetime(copy reader)
    static func readReferences(
        _ reader: inout BigEndianBytesReader, count: Int, _ trailer: ExampleBPList.Trailer
    ) throws(BytesError) -> BigEndianBytesReader {
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: trailer.objectReferenceSize)
        guard !overflow else { throw .invalidValue }
        return try reader.readSection(byteCount: byteCount)
    }

    @inline(__always)
    static func readReference(_ references: inout BigEndianBytesReader, _ trailer: ExampleBPList.Trailer) throws(BytesError) -> Int {
        guard let index = try Int(exactly: readUnsigned(&references, byteCount: trailer.objectReferenceSize)) else {
            throw .invalidValue
        }
        return index
    }

    // MARK: Integers of any width

    /// An unsigned big-endian integer of `byteCount` bytes, as swift-binary-parsing's `byteCount:` parsers read
    /// one: over 8 bytes, the extra leading bytes must be zero.
    @inline(__always)
    static func readUnsigned(_ reader: inout BigEndianBytesReader, byteCount: Int) throws(BytesError) -> UInt64 {
        guard byteCount > 0 else { throw .invalidValue }
        if byteCount <= 8 { return try reader.read(UInt64.self, byteCount: byteCount) }
        return try readWide(&reader, byteCount: byteCount) { fill, _ in fill == 0 }
    }

    /// A two's complement big-endian integer of `byteCount` bytes, sign-extended, as swift-binary-parsing's
    /// `byteCount:` parsers read one: over 8 bytes, the extra leading bytes must all be 0x00 or all 0xFF, and
    /// 0x00 only for a value that isn't negative.
    @inline(__always)
    static func readSigned(_ reader: inout BigEndianBytesReader, byteCount: Int) throws(BytesError) -> Int64 {
        guard byteCount > 0 else { throw .invalidValue }
        if byteCount <= 8 { return try reader.read(Int64.self, signedByteCount: byteCount) }
        let value = try readWide(&reader, byteCount: byteCount) { fill, value in
            fill == 0xFF || (fill == 0 && Int64(bitPattern: value) >= 0)
        }
        return Int64(bitPattern: value)
    }

    /// The low 8 bytes of an integer of more than 8, after checking its leading bytes are one repeated value
    /// that `isValid` accepts with the value.
    static func readWide(
        _ reader: inout BigEndianBytesReader, byteCount: Int, isValid: (UInt8, UInt64) -> Bool
    ) throws(BytesError) -> UInt64 {
        var padding = try reader.readSection(byteCount: byteCount &- 8)
        let fill = try padding.read(UInt8.self)
        while !padding.isAtEnd {
            guard try padding.read(UInt8.self) == fill else { throw .invalidValue }
        }
        let value = try reader.read(UInt64.self)
        guard isValid(fill, value) else { throw .invalidValue }
        return value
    }
}

// MARK: - Synthetic property lists

/// A synthetic binary property list for the benchmarks, written by Foundation: an array of `recordCount`
/// dictionaries of ASCII strings, integers, reals, booleans, dates, data, and a nested array.
///
/// - Parameter recordCount: The number of dictionaries.
/// - Returns: The property list's bytes.
public func makeBinaryPList(recordCount: Int) -> [UInt8] {
    let records: [[String: Any]] = (0..<recordCount).map { index in
        [
            "name": "Record \(index)",
            "identifier": "com.example.record.\(index % 97)",
            "index": index,
            "count": index % 200,
            "score": Double(index) / 7,
            "enabled": index.isMultiple(of: 3),
            "created": Date(timeIntervalSinceReferenceDate: Double(index) * 3_600),
            "checksum": Data((0..<(index % 24)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) }),
            "tags": ["tag\(index % 5)", "group\(index % 11)", index % 7],
        ]
    }
    let root: [String: Any] = ["version": 3, "generator": "BinaryParsingComparison", "records": records]
    return [UInt8](try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
}
