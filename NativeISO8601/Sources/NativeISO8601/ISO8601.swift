import Foundation

/// A non-allocating ISO 8601 / RFC 3339 timestamp parser.
///
/// Parsing runs in two phases: a lexical phase (``Lexer``) scans the bytes into raw numeric fields,
/// then a semantic phase (``RawComponents/resolve()``) range-checks them against the calendar and
/// converts them to a `Date`.
///
/// Accepted forms:
/// - Dates: calendar (`2024-01-15`, `20240115`), ordinal (`2024-015`, `2024015`),
///   and week (`2024-W03-1`, `2024W031`).
/// - Times, after `T`, `t`, or a space: `hh:mm`, `hh:mm:ss`, `hhmm`, `hhmmss`, each with an optional
///   `.` or `,` fraction (nanosecond precision; further digits are truncated).
/// - Offsets: `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm`. A missing offset means UTC.
///
/// `24:00:00` means the following midnight and a leap second (`:60`) rolls into the next second,
/// since `Date` can't represent it. Out-of-range values such as February 30 are rejected rather
/// than rolled over.
public enum ISO8601 {
    /// Parses a timestamp from UTF-8 bytes.
    public static func date(from bytes: Span<UInt8>) throws(ISO8601ParseError) -> Date {
        try date(from: bytes.bytes)
    }

    /// Parses a timestamp from raw bytes holding UTF-8 (or ASCII) text.
    public static func date(from bytes: RawSpan) throws(ISO8601ParseError) -> Date {
        try Lexer(bytes).lex().resolve()
    }

    /// Parses a timestamp from validated UTF-8.
    public static func date(from text: UTF8Span) throws(ISO8601ParseError) -> Date {
        try date(from: text.span)
    }

    /// Parses a timestamp from a string.
    public static func date(from string: borrowing String) throws(ISO8601ParseError) -> Date {
        try date(from: string.utf8.span)
    }

    /// Parses a timestamp from UTF-8 encoded data.
    public static func date(from data: borrowing Data) throws(ISO8601ParseError) -> Date {
        // Obtaining either `Data.bytes` or `Data.span` costs about as much as the parse itself
        // (Foundation's representation switch); callers with a span already in hand should pass it.
        try date(from: data.bytes)
    }
}

extension Date {
    /// Creates a date from an ISO 8601 timestamp, or returns `nil` if it isn't one.
    /// Use ``ISO8601/date(from:)-(String)`` to learn why parsing failed.
    public init?(iso8601 string: borrowing String) {
        guard let date = try? ISO8601.date(from: string) else { return nil }
        self = date
    }
}
