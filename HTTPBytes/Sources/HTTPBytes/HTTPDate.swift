public import Bytes
#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

/// A point in time as HTTP fields carry it (`Date`, `Last-Modified`, `Expires`, `If-Modified-Since`, `Retry-After`):
/// whole seconds since 1970-01-01 00:00:00 UTC (RFC 9110 §5.6.7).
///
/// Parsing accepts the three formats a recipient must (RFC 9110 §5.6.7), case-sensitively as the grammar is written:
/// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`, what senders write), the obsolete RFC 850 form (`Sunday, 06-Nov-94
/// 08:49:37 GMT`, its two-digit year read as at most 50 years ahead of a reference date), and asctime (`Sun Nov  6
/// 08:49:37 1994`). The day name must be the date's, the day must exist in its month, and a leap second (`:60`) is
/// accepted as the next minute's first. Writing produces IMF-fixdate.
///
/// IMF-fixdate, 29 bytes, is read as four 8-byte words: the fixed bytes checked with masks, the 14 digits with one SWAR
/// test, the month by a perfect hash of its three letters, and the date turned into days without branches (Howard
/// Hinnant's `days_from_civil`); the day name is checked against the one the date has.
@frozen
public struct HTTPDate: Sendable, Hashable, Comparable {
    /// Seconds since 1970-01-01 00:00:00 UTC (negative before).
    public var secondsSince1970: Int64

    /// The date `secondsSince1970` seconds after 1970-01-01 00:00:00 UTC.
    @inlinable
    public init(secondsSince1970: Int64) { self.secondsSince1970 = secondsSince1970 }

    @inlinable
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.secondsSince1970 < rhs.secondsSince1970 }

    /// The current time, to the second (the system's real-time clock).
    public static var now: HTTPDate {
        var time = timespec()
        // Unsafe: a pointer to a local for the call. Safe: `clock_gettime` writes one `timespec` there and keeps nothing.
        _ = unsafe clock_gettime(CLOCK_REALTIME, &time)
        return HTTPDate(secondsSince1970: Int64(time.tv_sec))
    }

    /// The date of a calendar date and time (UTC; years 0–9999), or `nil` if there's no such date and time.
    public init?(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        guard let seconds = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second),
              second < 60 else { return nil }
        self.init(secondsSince1970: seconds)
    }

    /// Parses an HTTP-date, reading an RFC 850 date's two-digit year against the current time.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidDate``.
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        if let seconds = Self.imfFixdate(value) {
            self.init(secondsSince1970: seconds)
        } else if let seconds = Self.obsoleteDate(value, reference: nil) {
            self.init(secondsSince1970: seconds)
        } else {
            throw .invalidDate
        }
    }

    /// Parses an HTTP-date, reading an RFC 850 date's two-digit year as the year with those digits that's at most 50
    /// years after `reference` (RFC 9110 §5.6.7: one that would be more than 50 years in the future is in the past).
    ///
    /// - Throws: ``HTTPFieldValueError/invalidDate``.
    public init(parsing value: RawSpan, relativeTo reference: HTTPDate) throws(HTTPFieldValueError) {
        if let seconds = Self.imfFixdate(value) {
            self.init(secondsSince1970: seconds)
        } else if let seconds = Self.obsoleteDate(value, reference: reference) {
            self.init(secondsSince1970: seconds)
        } else {
            throw .invalidDate
        }
    }

    /// A date's calendar fields (UTC).
    @frozen
    public struct Components: Sendable, Hashable {
        /// The year (0–9999 for dates HTTP can write).
        public var year: Int
        /// The month, 1–12.
        public var month: Int
        /// The day of the month, 1–31.
        public var day: Int
        /// The hour, 0–23.
        public var hour: Int
        /// The minute, 0–59.
        public var minute: Int
        /// The second, 0–59.
        public var second: Int
        /// The day of the week, 0 (Sunday) to 6 (Saturday).
        public var weekday: Int

        @inlinable
        public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, weekday: Int) {
            (self.year, self.month, self.day, self.hour, self.minute, self.second, self.weekday) =
                (year, month, day, hour, minute, second, weekday)
        }
    }

    /// The date's calendar fields (UTC), for dates from year 0 to 9999 (others are given as the first or last second those
    /// years allow, as when written).
    public var components: Components {
        let (days, time) = Self.daysAndTime(Swift.min(Swift.max(secondsSince1970, -62_167_219_200), 253_402_300_799))
        let (year, month, day) = Self.civil(days: days)
        return Components(year: year, month: month, day: day, hour: time / 3600, minute: time / 60 % 60, second: time % 60,
                          weekday: Self.weekday(days: days))
    }

    /// The length of an IMF-fixdate: 29 bytes.
    @inlinable
    public static var imfFixdateByteCount: Int { 29 }

    /// Writes the date as an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), 29 bytes. Dates before year 0 or after
    /// 9999 are written as the first or last second those years allow.
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        let (first, second, third, fourth) = Self.imfFixdateWords(secondsSince1970)
        try writer.write(first, as: Byte8.self, .littleEndian)
        try writer.write(second, as: Byte8.self, .littleEndian)
        try writer.write(third, as: Byte8.self, .littleEndian)
        try writer.write(UInt32(truncatingIfNeeded: fourth), as: Byte4.self, .littleEndian)
        try writer.write(UInt8(truncatingIfNeeded: fourth &>> 32))
    }
}

extension HTTPDate: CustomStringConvertible {
    /// The IMF-fixdate.
    public var description: String {
        let (first, second, third, fourth) = Self.imfFixdateWords(secondsSince1970)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(29)
        for word in [first, second, third] { for lane in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: word &>> (8 &* lane))) } }
        for lane in 0..<5 { bytes.append(UInt8(truncatingIfNeeded: fourth &>> (8 &* lane))) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A server's `Date` field: the current second's IMF-fixdate, formatted once per second and reused within it. One per
/// thread or connection (its 29 bytes can't be replaced atomically for several readers); the time comes from the caller,
/// who usually has it already (an event loop's tick), so the cache reads no clock.
@frozen
public struct HTTPDateCache: Sendable {
    @usableFromInline var second: Int64 = .min
    @usableFromInline var text = InlineArray<29, UInt8>(repeating: 0)

    /// An empty cache.
    @inlinable
    public init() {}

    /// `date` as an IMF-fixdate, formatted only when its second differs from the last one asked for.
    @inlinable
    @_lifetime(&self)
    public mutating func imfFixdate(_ date: HTTPDate) -> RawSpan {
        if date.secondsSince1970 != second { refill(date) }
        return text.span.bytes
    }

    @usableFromInline
    mutating func refill(_ date: HTTPDate) {
        second = date.secondsSince1970
        let (first, second, third, fourth) = HTTPDate.imfFixdateWords(date.secondsSince1970)
        // Once a second: a byte at a time is fine.
        for lane in 0..<8 {
            text[lane] = UInt8(truncatingIfNeeded: first &>> (8 &* lane))
            text[8 &+ lane] = UInt8(truncatingIfNeeded: second &>> (8 &* lane))
            text[16 &+ lane] = UInt8(truncatingIfNeeded: third &>> (8 &* lane))
        }
        for lane in 0..<5 { text[24 &+ lane] = UInt8(truncatingIfNeeded: fourth &>> (8 &* lane)) }
    }
}

// MARK: - Calendar arithmetic

extension HTTPDate {
    /// Days since 1970-01-01 of a proleptic Gregorian date (`month` 1–12): Hinnant's `days_from_civil`, no branches.
    @inlinable
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = year &- (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y &- 399) / 400
        let yearOfEra = y &- era &* 400
        let dayOfYear = (153 &* (month > 2 ? month &- 3 : month &+ 9) &+ 2) / 5 &+ day &- 1
        let dayOfEra = yearOfEra &* 365 &+ yearOfEra / 4 &- yearOfEra / 100 &+ dayOfYear
        return era &* 146_097 &+ dayOfEra &- 719_468
    }

    /// The date `days` after 1970-01-01: Hinnant's `civil_from_days`.
    @inlinable
    static func civil(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days &+ 719_468
        let era = (z >= 0 ? z : z &- 146_096) / 146_097
        let dayOfEra = z &- era &* 146_097
        let yearOfEra = (dayOfEra &- dayOfEra / 1460 &+ dayOfEra / 36_524 &- dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra &- (365 &* yearOfEra &+ yearOfEra / 4 &- yearOfEra / 100)
        let shiftedMonth = (5 &* dayOfYear &+ 2) / 153
        let day = dayOfYear &- (153 &* shiftedMonth &+ 2) / 5 &+ 1
        let month = shiftedMonth < 10 ? shiftedMonth &+ 3 : shiftedMonth &- 9
        return (yearOfEra &+ era &* 400 &+ (month <= 2 ? 1 : 0), month, day)
    }

    /// The weekday of the day `days` after 1970-01-01 (a Thursday): 0 is Sunday.
    @inlinable
    static func weekday(days: Int) -> Int { (days % 7 &+ 11) % 7 }

    /// Whole days since 1970 and the seconds into the last one.
    @inlinable
    static func daysAndTime(_ seconds: Int64) -> (days: Int, time: Int) {
        let value = Int(seconds)
        let days = value >= 0 ? value / 86_400 : (value &- 86_399) / 86_400
        return (days, value &- days &* 86_400)
    }

    /// The days in `month` of `year`: 30 or 31 by the month's parity, which flips after July; February 28 or 29.
    @inlinable
    static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        guard month == 2 else { return 30 &+ ((month ^ (month &>> 3)) & 1) }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return leap ? 29 : 28
    }

    /// Seconds since 1970 of a date and time, checked: `nil` unless it exists. A second of 60 is a leap second, so only at
    /// 23:59 (UTC's leap seconds end a day), and not on 9999-12-31 (the next second has no four-digit year).
    @usableFromInline
    static func seconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64? {
        guard UInt(bitPattern: year) <= 9999, UInt(bitPattern: month &- 1) < 12, day >= 1, day <= daysInMonth(month, year),
              UInt(bitPattern: hour) < 24, UInt(bitPattern: minute) < 60, UInt(bitPattern: second) <= 60 else { return nil }
        if second == 60 {
            guard hour == 23, minute == 59, year != 9999 || month != 12 || day != 31 else { return nil }
        }
        let days = Self.days(year: year, month: month, day: day)
        return Int64(days &* 86_400 &+ hour &* 3600 &+ minute &* 60 &+ second)
    }
}

// MARK: - Names

/// The month names' perfect hash: slot `(letters × 26596) >> 28` (the three letters as a little-endian 24-bit number,
/// the product's low 32 bits) holds `letters << 8 | month`; empty slots are 0, which no three letters match.
let monthSlots: InlineArray<16, UInt32> = [
    0x6C75_4A07, 0x766F_4E0B, 0, 0x7463_4F0A, 0x7961_4D05, 0x6365_440C, 0x7261_4D03, 0x7270_4104,
    0, 0x7065_5309, 0, 0, 0x6E61_4A01, 0x6E75_4A06, 0x6265_4602, 0x6775_4108,
]

/// Month names' letters (little-endian), January first.
let monthNames: InlineArray<12, UInt32> = [
    0x6E61_4A, 0x6265_46, 0x7261_4D, 0x7270_41, 0x7961_4D, 0x6E75_4A, 0x6C75_4A, 0x6775_41, 0x7065_53, 0x7463_4F,
    0x766F_4E, 0x6365_44,
]

/// Day names' letters (little-endian), Sunday first.
let dayNames: InlineArray<7, UInt32> = [0x6E75_53, 0x6E6F_4D, 0x6575_54, 0x6465_57, 0x7568_54, 0x6972_46, 0x7461_53]

extension HTTPDate {
    /// The month of three letters (little-endian), or 0.
    @usableFromInline
    static func month(_ letters: UInt32) -> Int {
        let slot = monthSlots[Int((letters &* 26_596) &>> 28)]
        return slot &>> 8 == letters ? Int(slot & 0xFF) : 0
    }

    /// RFC 850's full day name for `weekday` (0 is Sunday).
    static func longDayName(_ weekday: Int) -> StaticString {
        switch weekday {
        case 0: "Sunday"
        case 1: "Monday"
        case 2: "Tuesday"
        case 3: "Wednesday"
        case 4: "Thursday"
        case 5: "Friday"
        default: "Saturday"
        }
    }
}

// MARK: - Parsing

extension HTTPDate {
    /// SWAR: the lanes of `word` in `lanes` that aren't ASCII digits (nonzero if any). A digit XOR 0x30 is 0–9: its high
    /// nibble 0, and adding 6 leaves it 0 too. A carry out of a lane that isn't a digit can only make its neighbour fail.
    @inlinable @inline(__always)
    static func nonDigits(_ word: UInt64, _ lanes: UInt64) -> UInt64 {
        let x = word ^ 0x3030_3030_3030_3030
        return (x | (x &+ 0x0606_0606_0606_0606)) & 0xF0F0_F0F0_F0F0_F0F0 & lanes
    }

    /// The digit in lane `lane` of `word`.
    @inlinable @inline(__always)
    static func digit(_ word: UInt64, _ lane: Int) -> Int { Int(truncatingIfNeeded: word &>> UInt64(8 &* lane)) & 0xF }

    /// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), or `nil`.
    @usableFromInline
    static func imfFixdate(_ value: RawSpan) -> Int64? {
        guard value.byteCount == 29 else { return nil }
        // "Sun, 06 " "Nov 1994" " 08:49:3" and, from byte 21, "9:37 GMT".
        // 8-byte loads at 0, 8, 16, and 21: within the 29 bytes just checked, so the loads' checks fold.
        let first = UInt64(littleEndian: value.load(fromByteOffset: 0, as: UInt64.self))
        let second = UInt64(littleEndian: value.load(fromByteOffset: 8, as: UInt64.self))
        let third = UInt64(littleEndian: value.load(fromByteOffset: 16, as: UInt64.self))
        let fourth = UInt64(littleEndian: value.load(fromByteOffset: 21, as: UInt64.self))
        // The fixed bytes (", " and spaces, ":"s, " GMT"), then the digits, all in one test.
        let fixed = (first & 0xFF00_00FF_FF00_0000 ^ 0x2000_0020_2C00_0000)
            | (second & 0x0000_0000_FF00_0000 ^ 0x0000_0000_2000_0000)
            | (third & 0x00FF_0000_FF00_00FF ^ 0x003A_0000_3A00_0020)
            | (fourth & 0xFFFF_FFFF_0000_0000 ^ 0x544D_4720_0000_0000)
        let digits = nonDigits(first, 0x00FF_FF00_0000_0000) | nonDigits(second, 0xFFFF_FFFF_0000_0000)
            | nonDigits(third, 0xFF00_FFFF_00FF_FF00) | nonDigits(fourth, 0x0000_0000_FF00_0000)
        guard fixed | digits == 0 else { return nil }
        let month = Self.month(UInt32(truncatingIfNeeded: second) & 0xFF_FFFF)
        guard let seconds = Self.seconds(
            year: digit(second, 4) &* 1000 &+ digit(second, 5) &* 100 &+ digit(second, 6) &* 10 &+ digit(second, 7),
            month: month, day: digit(first, 5) &* 10 &+ digit(first, 6),
            hour: digit(third, 1) &* 10 &+ digit(third, 2), minute: digit(third, 4) &* 10 &+ digit(third, 5),
            second: digit(third, 7) &* 10 &+ digit(fourth, 3)
        ) else { return nil }
        // The day name must be the date's.
        let weekday = Self.weekday(days: daysAndTime(seconds &- (digit(third, 7) &* 10 &+ digit(fourth, 3) == 60 ? 1 : 0)).days)
        guard UInt32(truncatingIfNeeded: first) & 0xFF_FFFF == dayNames[weekday] else { return nil }
        return seconds
    }

    /// An RFC 850 date (`Sunday, 06-Nov-94 08:49:37 GMT`) or an asctime date (`Sun Nov  6 08:49:37 1994`), or `nil`.
    /// The rare forms: a byte at a time.
    @usableFromInline
    static func obsoleteDate(_ value: RawSpan, reference: HTTPDate?) -> Int64? {
        let count = value.byteCount
        var bad = false
        func byte(_ offset: Int) -> UInt8 { value.load(fromByteOffset: offset, as: UInt8.self) }
        func number(_ offset: Int, _ length: Int) -> Int {
            var result = 0
            for index in offset..<offset &+ length {
                let digit = byte(index) &- 0x30
                bad = bad || digit > 9
                result = result &* 10 &+ Int(digit)
            }
            return result
        }
        func letters(_ offset: Int) -> UInt32 {
            UInt32(byte(offset)) | UInt32(byte(offset &+ 1)) &<< 8 | UInt32(byte(offset &+ 2)) &<< 16
        }
        func expect(_ offset: Int, _ expected: UInt8) { bad = bad || byte(offset) != expected }
        func time(_ offset: Int) -> (Int, Int, Int) {
            expect(offset &+ 2, 0x3A)
            expect(offset &+ 5, 0x3A)
            return (number(offset, 2), number(offset &+ 3, 2), number(offset &+ 6, 2))
        }

        if count == 24, byte(3) == 0x20 {
            // asctime: "Sun Nov  6 08:49:37 1994" (the day space-padded or two digits).
            expect(7, 0x20)
            expect(10, 0x20)
            expect(19, 0x20)
            let month = Self.month(letters(4))
            let day = byte(8) == 0x20 ? number(9, 1) : number(8, 2)
            let (hour, minute, second) = time(11)
            let year = number(20, 4)
            guard !bad, let seconds = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second),
                  letters(0) == dayNames[weekday(days: daysAndTime(seconds &- (second == 60 ? 1 : 0)).days)] else { return nil }
            return seconds
        }
        // RFC 850: "Sunday, 06-Nov-94 08:49:37 GMT": a full day name of 6–9 letters, then 24 bytes.
        let nameLength = count &- 24
        guard nameLength >= 6, nameLength <= 9 else { return nil }
        let p = nameLength
        expect(p, 0x2C)
        expect(p &+ 1, 0x20)
        expect(p &+ 4, 0x2D)
        expect(p &+ 8, 0x2D)
        expect(p &+ 11, 0x20)
        expect(p &+ 20, 0x20)
        bad = bad || letters(p &+ 21) != 0x544D47 // "GMT"
        let day = number(p &+ 2, 2)
        let month = Self.month(letters(p &+ 5))
        let twoDigitYear = number(p &+ 9, 2)
        let (hour, minute, second) = time(p &+ 12)
        guard !bad else { return nil }
        // The year with those last two digits at most 50 years after the reference date (RFC 9110 §5.6.7).
        let referenceDate = reference ?? .now
        let referenceYear = civil(days: daysAndTime(referenceDate.secondsSince1970).days).year
        // Years from 49 before the reference's to 50 after it; in the 50th, the date and time decide.
        var year = referenceYear &- referenceYear % 100 &+ twoDigitYear
        if year > referenceYear &+ 50 { year &-= 100 } else if year <= referenceYear &- 50 { year &+= 100 }
        guard var seconds = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        if year == referenceYear &+ 50 {
            // The reference moved 50 years on (its month, day, and time of day kept).
            let (referenceDays, referenceTime) = daysAndTime(referenceDate.secondsSince1970)
            let (_, referenceMonth, referenceDay) = civil(days: referenceDays)
            let fiftyYearsOn = Int64(Self.days(year: year, month: referenceMonth, day: referenceDay) &* 86_400 &+ referenceTime)
            if seconds > fiftyYearsOn {
                year &-= 100
                guard let earlier = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
                else { return nil }
                seconds = earlier
            }
        }
        // The full day name must be the date's.
        let name = immortalSpan(longDayName(weekday(days: daysAndTime(seconds &- (second == 60 ? 1 : 0)).days)))
        guard name.byteCount == nameLength else { return nil }
        for index in 0..<nameLength where name.load(fromByteOffset: index, as: UInt8.self) != byte(index) { return nil }
        return seconds
    }
}

// MARK: - Writing

extension HTTPDate {
    /// Two ASCII digits of `value` (0–99), the tens first in memory (little-endian).
    @inlinable @inline(__always)
    static func twoDigits(_ value: Int) -> UInt64 {
        let tens = (value &* 103) &>> 10
        return UInt64(truncatingIfNeeded: 0x3030 | tens | (value &- tens &* 10) &<< 8)
    }

    /// The IMF-fixdate's 29 bytes as three little-endian words and five bytes (the low 40 bits of the last).
    @usableFromInline
    static func imfFixdateWords(_ seconds: Int64) -> (UInt64, UInt64, UInt64, UInt64) {
        // Years 0 to 9999: 0000-01-01T00:00:00 is -62,167,219,200; 9999-12-31T23:59:59 is 253,402,300,799.
        let clamped = Swift.min(Swift.max(seconds, -62_167_219_200), 253_402_300_799)
        let (days, time) = daysAndTime(clamped)
        let (year, month, day) = civil(days: days)
        let hour = time / 3600, minute = time / 60 % 60, second = time % 60
        let first = UInt64(dayNames[weekday(days: days)]) | 0x2C_0000_00 | 0x20_0000_0000
            | twoDigits(day) &<< 40 | 0x2000_0000_0000_0000
        let century = (year &* 5243) &>> 19
        let second8 = UInt64(monthNames[month &- 1]) | 0x2000_0000 | twoDigits(century) &<< 32
            | twoDigits(year &- century &* 100) &<< 48
        let third = 0x20 | twoDigits(hour) &<< 8 | 0x3A00_0000 | twoDigits(minute) &<< 32 | 0x3A_0000_0000_0000
            | UInt64(0x30 | (second &* 103) &>> 10) &<< 56
        let fourth = UInt64(0x30 | second % 10) | 0x20_00 | 0x54_4D47_0000
        return (first, second8, third, fourth)
    }
}
