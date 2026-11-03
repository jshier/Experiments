import Foundation

/// The semantic phase: validates raw fields and converts them to an instant.
extension RawComponents {
    /// Seconds between 1970-01-01 and 2001-01-01, Foundation's reference date.
    private static let unixToReferenceDate: Int64 = 978_307_200

    @inline(always)
    consuming func resolve() throws(ISO8601ParseError) -> Date {
        let year = Int64(year)

        let days: Int64
        switch form {
        case .calendar:
            guard month &- 1 < 12 else { throw .valueOutOfRange(.month, value: Int(month)) }
            // Check against the longest possible month first; only February 29 needs the leap-year
            // division, so the common case skips it.
            guard day &- 1 < Self.maximumDaysInMonth(month),
                  month != 2 || day != 29 || Self.isLeapYear(year)
            else { throw .valueOutOfRange(.day, value: Int(day)) }
            days = Self.daysSinceUnixEpoch(year: year, month: Int64(month), day: Int64(day))
        case .ordinal:
            guard day &- 1 < (Self.isLeapYear(year) ? 366 : 365) else { throw .valueOutOfRange(.ordinalDay, value: Int(day)) }
            days = Self.daysSinceUnixEpoch(year: year, month: 1, day: 1) &+ Int64(day) &- 1
        case .week:
            guard weekdayIsValid else { throw .valueOutOfRange(.weekday, value: Int(day)) }
            let january4 = Self.daysSinceUnixEpoch(year: year, month: 1, day: 4)
            // ISO weekday, Monday = 1. 1970-01-01 was a Thursday (4); bias keeps the dividend positive.
            let january4Weekday = (january4 &+ 3 &+ 7 * 400_000) % 7 &+ 1
            let week1Monday = january4 &- (january4Weekday &- 1)
            guard month &- 1 < Self.weeksInYear(year, january4Weekday: january4Weekday) else {
                throw .valueOutOfRange(.week, value: Int(month))
            }
            days = week1Monday &+ (Int64(month) &- 1) &* 7 &+ Int64(day) &- 1
        }

        // 24:00 is the end of the day (the next day's midnight); 60 seconds is a leap second, which
        // `Date` can't represent, so it lands on the following second.
        if hour == 24 {
            guard minute == 0, second == 0, nanosecond == 0 else { throw .valueOutOfRange(.hour, value: 24) }
        } else {
            guard hour < 24 else { throw .valueOutOfRange(.hour, value: Int(hour)) }
        }
        guard minute < 60 else { throw .valueOutOfRange(.minute, value: Int(minute)) }
        guard second <= 60 else { throw .valueOutOfRange(.second, value: Int(second)) }
        guard offsetHour < 24 else { throw .valueOutOfRange(.offsetHour, value: Int(offsetHour)) }
        guard offsetMinute < 60 else { throw .valueOutOfRange(.offsetMinute, value: Int(offsetMinute)) }

        let offset = Int64(offsetHour) &* 3600 &+ Int64(offsetMinute) &* 60
        let seconds = days &* 86_400
            &+ Int64(hour) &* 3600 &+ Int64(minute) &* 60 &+ Int64(second)
            &- (offsetIsNegative ? -offset : offset)
        let whole = Double(seconds &- Self.unixToReferenceDate)
        return nanosecond == 0
            ? Date(timeIntervalSinceReferenceDate: whole)
            : Date(timeIntervalSinceReferenceDate: whole + Double(nanosecond) / 1_000_000_000)
    }

    private var weekdayIsValid: Bool { day &- 1 < 7 }

    // MARK: Calendar arithmetic (proleptic Gregorian)

    @inline(__always)
    private static func isLeapYear(_ year: Int64) -> Bool {
        // A multiple of 100 is a leap year only if it's a multiple of 400, i.e. of 16. Years are
        // 0...9999, so unsigned 32-bit arithmetic is exact and avoids signed-division fixups.
        let year = UInt32(truncatingIfNeeded: year)
        return year & (year % 100 == 0 ? 15 : 3) == 0
    }

    /// Days in `month` (1...12) of a leap year.
    @inline(__always)
    private static func maximumDaysInMonth(_ month: UInt8) -> UInt16 {
        // Two bits per month, holding (length - 28): Feb=1, 30-day months=2, others=3.
        let lengths: UInt32 = 0b11_10_11_10_11_11_10_11_10_11_01_11
        return 28 &+ UInt16((lengths >> (UInt32(month &- 1) &* 2)) & 3)
    }

    /// An ISO year has 53 weeks if it starts on a Thursday, or is a leap year starting on a Wednesday.
    @inline(__always)
    private static func weeksInYear(_ year: Int64, january4Weekday: Int64) -> Int64 {
        // January 1 is three days before January 4.
        let january1Weekday = (january4Weekday &+ 3) % 7 &+ 1
        return january1Weekday == 4 || (january1Weekday == 3 && isLeapYear(year)) ? 53 : 52
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date, after Neri & Schneider, "Euclidean affine
    /// functions and their application to calendar algorithms" (2022). All arithmetic is unsigned
    /// with power-of-two divisors except one division by 100.
    @inline(__always)
    static func daysSinceUnixEpoch(year: Int64, month: Int64, day: Int64) -> Int64 {
        // Count years from March so the leap day falls at the end; January and February belong to
        // the previous computational year as months 13 and 14. Shift by one 400-year era so year 0's
        // January stays non-negative.
        let isJanuaryOrFebruary = month <= 2
        let y = UInt32(truncatingIfNeeded: year) &+ 400 &- (isJanuaryOrFebruary ? 1 : 0)
        let m = UInt32(truncatingIfNeeded: month) &+ (isJanuaryOrFebruary ? 12 : 0)
        let century = y / 100
        let yearDays = 1461 &* y / 4 &- century &+ century / 4
        let monthDays = (979 &* m &- 2919) / 32
        // 719_468 days from 0000-03-01 to 1970-01-01, plus the 146_097-day era shift above.
        return Int64(yearDays &+ monthDays &+ UInt32(truncatingIfNeeded: day) &- 1) &- (719_468 &+ 146_097)
    }
}
