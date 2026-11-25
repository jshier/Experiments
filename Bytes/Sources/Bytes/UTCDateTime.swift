// Civil dates and times in UTC, as binary and text formats write them (X.509's `UTCTime` and `GeneralizedTime`,
// XAR's `creation-time`, ISO 8601 stamps): fields checked once, then seconds since 1970 by Howard Hinnant's
// `days_from_civil`, in the proleptic Gregorian calendar. No time zones, no Foundation.

/// A date and time of day in UTC, to the second, with every field checked: the month 1 through 12, the day within
/// the month (February's 29th only in leap years), the hour, minute, and second in range.
///
/// ```swift
/// let year = try reader.read(Int.self, asciiDigits: 4)
/// try reader.expect(Byte(ascii: "-"))
/// …
/// let time = try UTCDateTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
/// let date = Date(timeIntervalSince1970: TimeInterval(time.secondsSince1970))
/// ```
///
/// Years run from −9999 through 9999 in the proleptic Gregorian calendar (year 0 is 1 BC), which covers four-digit
/// formats and leaves room for dates computed before year 1.
@frozen
public struct UTCDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The year, −9999 through 9999.
    public let year: Int
    /// The month, 1 through 12.
    public let month: Int
    /// The day of the month, 1 through its last day.
    public let day: Int
    /// The hour, 0 through 23.
    public let hour: Int
    /// The minute, 0 through 59.
    public let minute: Int
    /// The second, 0 through 59, or 60 for a leap second if allowed when made.
    public let second: Int

    /// The earliest year a time can have.
    @inlinable public static var minimumYear: Int { -9_999 }
    /// The latest year a time can have.
    @inlinable public static var maximumYear: Int { 9_999 }

    /// A time from its fields, checked.
    ///
    /// - Parameters:
    ///   - year: The year, −9999 through 9999.
    ///   - month: The month, 1 through 12.
    ///   - day: The day of the month, 1 through the month's last day in that year.
    ///   - hour: The hour, 0 through 23.
    ///   - minute: The minute, 0 through 59.
    ///   - second: The second, 0 through 59 (60 too if `allowingLeapSecond`).
    ///   - allowingLeapSecond: Whether to accept a second of 60, which some formats allow for a leap second
    ///     (XAR's times are read so). ``secondsSince1970`` counts it as the next minute's first second, as POSIX
    ///     time does.
    /// - Throws: ``BytesError/invalidValue`` if a field is out of its range.
    @inlinable
    public init(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, allowingLeapSecond: Bool = false
    ) throws(BytesError) {
        // Unsigned compares: one each for both ends of a range.
        guard UInt(bitPattern: year &- Self.minimumYear) <= UInt(Self.maximumYear &- Self.minimumYear),
              UInt(bitPattern: month &- 1) < 12,
              UInt(bitPattern: day &- 1) < UInt(Self.dayCount(inMonth: month, year: year)),
              UInt(bitPattern: hour) < 24, UInt(bitPattern: minute) < 60,
              UInt(bitPattern: second) < (allowingLeapSecond ? 61 : 60)
        else { throw .invalidValue }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The time `seconds` after 1970-01-01 00:00:00 UTC (before it when negative): the inverse of
    /// ``secondsSince1970`` (Howard Hinnant's `civil_from_days`).
    ///
    /// - Parameter seconds: Seconds since 1970, as `Date.timeIntervalSince1970` gives them (whole seconds).
    /// - Throws: ``BytesError/invalidValue`` if the year would be outside −9999 through 9999.
    @inlinable
    public init(secondsSince1970 seconds: Int64) throws(BytesError) {
        // Floor division: a negative time of day belongs to the day before.
        var days = seconds / 86_400
        var secondOfDay = seconds % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        // Days since 1970 to a civil date, in 400-year eras from 0000-03-01.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153 // 0 is March.
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        // Checked before converting: `Int` may be 32 bits.
        guard year >= Int64(Self.minimumYear), year <= Int64(Self.maximumYear) else { throw .invalidValue }
        try self.init(
            year: Int(year), month: Int(month), day: Int(day), hour: Int(secondOfDay / 3_600),
            minute: Int(secondOfDay / 60 % 60), second: Int(secondOfDay % 60)
        )
    }

    /// Seconds since 1970-01-01 00:00:00 UTC (negative before), as `Date(timeIntervalSince1970:)` takes.
    @inlinable
    public var secondsSince1970: Int64 {
        Self.secondsSince1970(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// Seconds since 1970-01-01 00:00:00 UTC of a date and time given by fields that aren't checked: for types
    /// that keep their own (X.509's times). Fields out of range carry into the next (day 32 of January is
    /// February 1st, as long as the month is 1 through 12).
    ///
    /// - Parameters:
    ///   - year: The year (0 is 1 BC).
    ///   - month: The month, 1 through 12.
    ///   - day: The day of the month.
    ///   - hour: The hour.
    ///   - minute: The minute.
    ///   - second: The second.
    /// - Returns: The seconds, negative before 1970.
    @inlinable
    public static func secondsSince1970(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64 {
        // Days from the civil date (Howard Hinnant's `days_from_civil`), counting years from March, so that a
        // leap day is the last of its year.
        let y = Int64(month <= 2 ? year &- 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let m = Int64(month)
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86_400 + Int64(hour) * 3_600 + Int64(minute) * 60 + Int64(second)
    }

    /// Whether `year` is a leap year in the proleptic Gregorian calendar: divisible by 4, and not by 100 unless
    /// by 400.
    ///
    /// - Parameter year: The year (0 is 1 BC).
    /// - Returns: Whether February has 29 days that year.
    @inlinable
    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// The number of days in `month` of `year`: 28 through 31.
    ///
    /// - Parameters:
    ///   - month: The month, 1 through 12.
    ///   - year: The year.
    /// - Returns: The month's last day; 0 for a month outside 1 through 12.
    @inlinable
    public static func dayCount(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        case 1, 3, 5, 7, 8, 10, 12: 31
        default: 0
        }
    }

    /// Compares the fields in order, year first (a leap second sorts before the next minute).
    @inlinable
    public static func <(a: Self, b: Self) -> Bool {
        (a.year, a.month, a.day, a.hour, a.minute, a.second) < (b.year, b.month, b.day, b.hour, b.minute, b.second)
    }

    /// ISO 8601, `2026-11-19T08:05:09Z` (years before 0 with a minus sign, at least four digits).
    public var description: String {
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value.magnitude)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let sign = year < 0 ? "-" : ""
        return "\(sign)\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))T\(padded(hour, 2)):\(padded(minute, 2)):\(padded(second, 2))Z"
    }
}
