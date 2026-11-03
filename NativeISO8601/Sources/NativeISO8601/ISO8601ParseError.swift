/// Why a timestamp couldn't be parsed.
///
/// Lexical failures (wrong shape) carry the byte offset where scanning stopped; semantic failures
/// (right shape, impossible value) carry the offending field and its value. Every case is trivial,
/// so throwing one never allocates.
public enum ISO8601ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The input ended at `offset` while more was required.
    case unexpectedEnd(offset: Int)
    /// `byte` at `offset` doesn't fit the grammar at that point (including trailing bytes).
    case unexpectedByte(UInt8, offset: Int)
    /// A field was well-formed but outside its valid range (e.g. month 13, February 30).
    case valueOutOfRange(Field, value: Int)

    /// A component of an ISO 8601 timestamp.
    public enum Field: Hashable, Sendable {
        case month, day, ordinalDay, week, weekday
        case hour, minute, second
        case offsetHour, offsetMinute
    }

    public var description: String {
        switch self {
        case let .unexpectedEnd(offset):
            "Unexpected end of input at offset \(offset)."
        case let .unexpectedByte(byte, offset):
            "Unexpected byte 0x\(String(byte, radix: 16)) at offset \(offset)."
        case let .valueOutOfRange(field, value):
            "\(field) value \(value) is out of range."
        }
    }
}
