import Foundation

extension ISO8601 {
    /// A parsed ISO 8601 timestamp: the components exactly as written, validated, together with the
    /// instant they denote.
    ///
    /// Use ``ISO8601/date(from:)-(String)`` when only the instant matters; it skips building this.
    public struct Timestamp: Sendable, Hashable {
        /// The date part as written.
        public enum DateValue: Sendable, Hashable {
            /// `1985-04-12` / `19850412`.
            case calendarDate(year: Int, month: Int, day: Int)
            /// `1985-102` / `1985102`.
            case ordinalDate(year: Int, dayOfYear: Int)
            /// `1985-W15-5` / `1985W155`; `weekday` runs from Monday (1) to Sunday (7).
            case weekDate(year: Int, week: Int, weekday: Int)
            /// `1985-W15` / `1985W15` (reduced precision).
            case week(year: Int, week: Int)
            /// `1985-04` (reduced precision).
            case month(year: Int, month: Int)
            /// `1985` (reduced precision).
            case year(Int)
            /// `198`: the decade 1980...1989 (reduced precision).
            case decade(Int)
            /// `19`: the century 1900...1999 (reduced precision).
            case century(Int)
        }

        /// A decimal fraction as written: `,5` is 5 with 1 digit; `.250` is 250 with 3 digits.
        /// Digits beyond the ninth are truncated.
        public struct DecimalFraction: Sendable, Hashable {
            public var value: Int
            public var digits: Int

            public init(value: Int, digits: Int) {
                self.value = value
                self.digits = digits
            }

            /// The fraction as a number in 0..<1.
            public var doubleValue: Double { Double(value) / pow(10, Double(digits)) }
        }

        /// The time of day as written. Fields after the last one written are `nil`.
        public struct TimeOfDay: Sendable, Hashable {
            public var hour: Int
            public var minute: Int?
            public var second: Int?
            /// The decimal fraction of the last field present: the second, minute, or hour.
            public var fraction: DecimalFraction?

            public init(hour: Int, minute: Int? = nil, second: Int? = nil, fraction: DecimalFraction? = nil) {
                self.hour = hour
                self.minute = minute
                self.second = second
                self.fraction = fraction
            }
        }

        /// A UTC offset as written.
        public struct UTCOffset: Sendable, Hashable {
            /// Whether it was written as the UTC designator `Z`.
            public var isUTCDesignator: Bool
            public var isNegative: Bool
            public var hours: Int
            /// Zero when written as hours only.
            public var minutes: Int
            /// Whether it was written as hours only (`+05`), with no minutes.
            public var isHoursOnly: Bool

            public init(isUTCDesignator: Bool = false, isNegative: Bool, hours: Int, minutes: Int = 0, isHoursOnly: Bool = false) {
                self.isUTCDesignator = isUTCDesignator
                self.isNegative = isNegative
                self.hours = hours
                self.minutes = minutes
                self.isHoursOnly = isHoursOnly
            }

            /// UTC, written as the designator `Z`.
            public static let utc = UTCOffset(isUTCDesignator: true, isNegative: false, hours: 0)

            /// The offset from UTC in seconds, east positive.
            public var seconds: Int {
                let magnitude = hours * 3600 + minutes * 60
                return isNegative ? -magnitude : magnitude
            }
        }

        /// The instant denoted. Reduced-precision dates resolve to the start of their period; with no
        /// time it's midnight, and with no offset, UTC.
        public var date: Date
        public var dateValue: DateValue
        /// `nil` when only a date was written.
        public var time: TimeOfDay?
        /// `nil` when no offset was written.
        public var utcOffset: UTCOffset?
    }

    /// Parses a timestamp from UTF-8 bytes, keeping its components.
    public static func timestamp(from bytes: RawSpan) throws(ISO8601ParseError) -> Timestamp {
        let raw = try Lexer(bytes).lex()
        return Timestamp(raw, date: try raw.resolve())
    }

    /// Parses a timestamp from UTF-8 bytes, keeping its components.
    public static func timestamp(from bytes: Span<UInt8>) throws(ISO8601ParseError) -> Timestamp {
        try timestamp(from: bytes.bytes)
    }

    /// Parses a timestamp from validated UTF-8, keeping its components.
    public static func timestamp(from text: UTF8Span) throws(ISO8601ParseError) -> Timestamp {
        try timestamp(from: text.span)
    }

    /// Parses a timestamp from a string, keeping its components.
    public static func timestamp(from string: borrowing String) throws(ISO8601ParseError) -> Timestamp {
        try timestamp(from: string.utf8.span)
    }

    /// Parses a timestamp from UTF-8 encoded data, keeping its components.
    public static func timestamp(from data: borrowing Data) throws(ISO8601ParseError) -> Timestamp {
        try timestamp(from: data.bytes)
    }
}

extension ISO8601.Timestamp {
    @inline(__always)
    init(_ raw: RawComponents, date: Date) {
        self.date = date
        let year = Int(raw.year), month = Int(raw.month), day = Int(raw.day)
        dateValue = switch raw.dateForm {
        case .calendarDate: .calendarDate(year: year, month: month, day: day)
        case .ordinalDate: .ordinalDate(year: year, dayOfYear: day)
        case .weekDate: .weekDate(year: year, week: month, weekday: day)
        case .week: .week(year: year, week: month)
        case .month: .month(year: year, month: month)
        case .year: .year(year)
        case .decade: .decade(year)
        case .century: .century(year)
        }

        let fraction = raw.fractionDigits == 0
            ? nil
            : DecimalFraction(value: Int(raw.fraction), digits: Int(raw.fractionDigits))
        time = switch raw.timePrecision {
        case .none: nil
        case .hour: TimeOfDay(hour: Int(raw.hour), fraction: fraction)
        case .minute: TimeOfDay(hour: Int(raw.hour), minute: Int(raw.minute), fraction: fraction)
        case .second: TimeOfDay(hour: Int(raw.hour), minute: Int(raw.minute), second: Int(raw.second), fraction: fraction)
        }

        utcOffset = switch raw.offsetForm {
        case .none: nil
        case .utc: .utc
        case .hours: UTCOffset(isNegative: raw.offsetIsNegative, hours: Int(raw.offsetHour), isHoursOnly: true)
        case .hoursMinutes: UTCOffset(isNegative: raw.offsetIsNegative, hours: Int(raw.offsetHour), minutes: Int(raw.offsetMinute))
        }
    }
}
