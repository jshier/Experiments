import BinaryParsing
import Bytes

// Runs of big-endian integers, summed: 32-bit (a standard width) and 24-bit (an odd one). Per-value reads
// in each library, and Bytes' loop form.

public enum Integers {
    // MARK: 32-bit

    public static func sum32Bytes(_ span: RawSpan) throws -> UInt64 {
        var reader = Bytes(span)
        var sum: UInt64 = 0
        while reader.remainingByteCount >= 4 { sum &+= UInt64(try reader.read(Byte4.self, .bigEndian)) }
        return sum
    }

    public static func sum32BytesForEach(_ span: RawSpan) -> UInt64 {
        var reader = Bytes(span)
        var sum: UInt64 = 0
        reader.forEach(Byte4.self, .bigEndian) { sum &+= UInt64($0) }
        return sum
    }

    public static func sum32ParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var sum: UInt64 = 0
        while input.count >= 4 { sum &+= UInt64(try UInt32(parsingBigEndian: &input)) }
        return sum
    }

    // MARK: 24-bit

    public static func sum24Bytes(_ span: RawSpan) throws -> UInt64 {
        var reader = Bytes(span)
        var sum: UInt64 = 0
        while reader.remainingByteCount >= 3 { sum &+= UInt64(try reader.read(Byte3.self, .bigEndian)) }
        return sum
    }

    public static func sum24BytesForEach(_ span: RawSpan) -> UInt64 {
        var reader = Bytes(span)
        var sum: UInt64 = 0
        reader.forEach(Byte3.self, .bigEndian) { sum &+= UInt64($0) }
        return sum
    }

    public static func sum24ParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var sum: UInt64 = 0
        while input.count >= 3 {
            sum &+= UInt64(try UInt32(parsing: &input, endianness: .big, byteCount: 3))
        }
        return sum
    }
}
