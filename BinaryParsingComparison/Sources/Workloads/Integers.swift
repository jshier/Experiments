import BinaryParsing
import Bytes

// Runs of big-endian integers, summed: 32-bit (a standard width) and 24-bit (an odd one). Per-value reads
// in each library, and Bytes' loop form.

public enum Integers {
    // MARK: 32-bit

    /// Sums the big-endian `UInt32`s of `span`, one `read` each; a partial last value is ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum, wrapping.
    /// - Throws: Never in practice: each read is of bytes known to remain.
    public static func sum32Bytes(_ span: RawSpan) throws -> UInt64 {
        var reader = BytesReader(span)
        var sum: UInt64 = 0
        while reader.remainingByteCount >= 4 {
            try sum &+= UInt64(reader.read(Byte4.self, .bigEndian))
        }
        return sum
    }

    /// Sums the big-endian `UInt32`s of `span` with `forEach`; a partial last value is ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum, wrapping.
    public static func sum32BytesForEach(_ span: RawSpan) -> UInt64 {
        var reader = BytesReader(span)
        var sum: UInt64 = 0
        reader.forEach(Byte4.self, .bigEndian) { sum &+= UInt64($0) }
        return sum
    }

    /// Sums the big-endian `UInt32`s of `span` with `ParserSpan`, one parse each; a partial last value is
    /// ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum, wrapping.
    /// - Throws: Never in practice: each parse is of bytes known to remain.
    public static func sum32ParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var sum: UInt64 = 0
        while input.count >= 4 {
            try sum &+= UInt64(UInt32(parsingBigEndian: &input))
        }
        return sum
    }

    // MARK: 24-bit

    /// Sums the big-endian 24-bit integers of `span`, one `read` each; a partial last value is ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum.
    /// - Throws: Never in practice: each read is of bytes known to remain.
    public static func sum24Bytes(_ span: RawSpan) throws -> UInt64 {
        var reader = BytesReader(span)
        var sum: UInt64 = 0
        while reader.remainingByteCount >= 3 {
            try sum &+= UInt64(reader.read(Byte3.self, .bigEndian))
        }
        return sum
    }

    /// Sums the big-endian 24-bit integers of `span` with `forEach`; a partial last value is ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum.
    public static func sum24BytesForEach(_ span: RawSpan) -> UInt64 {
        var reader = BytesReader(span)
        var sum: UInt64 = 0
        reader.forEach(Byte3.self, .bigEndian) { sum &+= UInt64($0) }
        return sum
    }

    /// Sums the big-endian 24-bit integers of `span` with `ParserSpan` (`byteCount: 3`), one parse each; a
    /// partial last value is ignored.
    ///
    /// - Parameter span: The bytes.
    /// - Returns: The sum.
    /// - Throws: Never in practice: each parse is of bytes known to remain.
    public static func sum24ParserSpan(_ span: RawSpan) throws -> UInt64 {
        var input = ParserSpan(span)
        var sum: UInt64 = 0
        while input.count >= 3 {
            try sum &+= UInt64(UInt32(parsing: &input, endianness: .big, byteCount: 3))
        }
        return sum
    }
}
