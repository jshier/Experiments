import Foundation
import NativeISO8601
import Testing

private func reference(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

@Suite("Parity with Foundation")
struct ParityTests {
    @Test("Matches ISO8601DateFormatter for random internet date-times")
    func randomInternetDateTimes() throws {
        var generator = SystemRandomNumberGenerator()
        let formatter = ISO8601DateFormatter()
        for _ in 0..<20_000 {
            // Foundation switches to the Julian calendar before October 1582; ISO 8601 is proleptic Gregorian.
            let year = Int.random(in: 1583...9999, using: &generator)
            let month = Int.random(in: 1...12, using: &generator)
            let day = Int.random(in: 1...28, using: &generator)
            let hour = Int.random(in: 0...23, using: &generator)
            let minute = Int.random(in: 0...59, using: &generator)
            let second = Int.random(in: 0...59, using: &generator)
            let offset = switch Int.random(in: 0..<3, using: &generator) {
            case 0: "Z"
            case 1: "+" + pad(Int.random(in: 0...23), 2) + ":" + pad(Int.random(in: 0...59), 2)
            default: "-" + pad(Int.random(in: 0...23), 2) + pad(Int.random(in: 0...59), 2)
            }
            let string = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))\(offset)"
            let expected = try #require(formatter.date(from: string), "\(string)")
            #expect(try ISO8601.date(from: string) == expected, "\(string)")
        }
    }

    @Test("Every day 1600–2400 matches Calendar, in calendar, ordinal and week forms")
    func everyDay() throws {
        var components = DateComponents(year: 1600, month: 1, day: 1)
        var date = try #require(utc.date(from: components))
        let end = try #require(utc.date(from: DateComponents(year: 2400, month: 12, day: 31)))
        while date <= end {
            components = utc.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear, .weekday], from: date)
            let year = components.year!
            let ordinal = utc.ordinality(of: .day, in: .year, for: date)!
            let isoWeekday = (components.weekday! + 5) % 7 + 1 // Calendar: Sunday = 1; ISO: Monday = 1.
            let weekYear = pad(components.yearForWeekOfYear!, 4), week = pad(components.weekOfYear!, 2)

            let forms = [
                "\(pad(year, 4))-\(pad(components.month!, 2))-\(pad(components.day!, 2))",
                "\(pad(year, 4))\(pad(components.month!, 2))\(pad(components.day!, 2))",
                "\(pad(year, 4))-\(pad(ordinal, 3))",
                "\(pad(year, 4))\(pad(ordinal, 3))",
                "\(weekYear)-W\(week)-\(isoWeekday)",
                "\(weekYear)W\(week)\(isoWeekday)",
            ]
            for form in forms {
                #expect(try ISO8601.date(from: form) == date, "\(form)")
            }
            date = date.addingTimeInterval(86_400)
        }
    }

    @Test("Fractional seconds match Date.ISO8601FormatStyle", arguments: [
        "2024-01-15T10:30:45.1Z", "2024-01-15T10:30:45.12Z", "2024-01-15T10:30:45.123Z",
        "2024-01-15T10:30:45.999Z", "1970-01-01T00:00:00.001Z", "2000-02-29T23:59:59.5-08:00",
    ])
    func fractionalSeconds(_ string: String) throws {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        #expect(try ISO8601.date(from: string) == style.parse(string))
    }
}

@Suite("Accepted forms")
struct FormTests {
    static let instant = Date(timeIntervalSince1970: 1_705_314_645) // 2024-01-15T10:30:45Z

    @Test(arguments: [
        "2024-01-15T10:30:45Z",
        "2024-01-15t10:30:45z",
        "2024-01-15 10:30:45Z",
        "2024-01-15T10:30:45",
        "20240115T103045Z",
        "2024-01-15T103045Z",
        "2024-015T10:30:45Z",
        "2024015T103045Z",
        "2024-W03-1T10:30:45Z",
        "2024W031T103045Z",
        "2024-01-15T16:00:45+05:30",
        "2024-01-15T16:00:45+0530",
        "2024-01-15T05:30:45-05",
        "2024-01-15T10:30:45+00:00",
        "2024-01-15T10:30:45-00:00",
    ])
    func sameInstant(_ string: String) throws {
        #expect(try ISO8601.date(from: string) == Self.instant)
    }

    @Test func reducedPrecision() throws {
        #expect(try ISO8601.date(from: "2024-01-15") == Date(timeIntervalSince1970: 1_705_276_800))
        #expect(try ISO8601.date(from: "2024-01-15T10:30Z") == Date(timeIntervalSince1970: 1_705_314_600))
    }

    @Test func fractions() throws {
        let base = 1_705_314_645.0 - Date.timeIntervalBetween1970AndReferenceDate
        #expect(try ISO8601.date(from: "2024-01-15T10:30:45,5Z").timeIntervalSinceReferenceDate == base + 0.5)
        #expect(try ISO8601.date(from: "2024-01-15T10:30:45.000000001Z").timeIntervalSinceReferenceDate == base + 1e-9)
        // Digits past nanoseconds are truncated, not rounded.
        #expect(try ISO8601.date(from: "2024-01-15T10:30:45.9999999999999Z").timeIntervalSinceReferenceDate
            == base + 0.999_999_999)
    }

    @Test("A fraction after the minutes is a fraction of a minute")
    func minuteFractions() throws {
        let base = try ISO8601.date(from: "2024-01-15T10:30:00Z")
        #expect(try ISO8601.date(from: "2024-01-15T10:30,5Z") == base.addingTimeInterval(30))
        #expect(try ISO8601.date(from: "2024-01-15T1030.25Z") == base.addingTimeInterval(15))
        #expect(try ISO8601.date(from: "2024-01-15T10:30.999999999Z") == base.addingTimeInterval(59.99999994))
        #expect(throws: ISO8601ParseError.valueOutOfRange(.hour, value: 24)) {
            try ISO8601.date(from: "2024-01-15T24:00,5Z")
        }
    }

    @Test func endOfDayAndLeapSecond() throws {
        let midnight = try ISO8601.date(from: "2024-01-16T00:00:00Z")
        #expect(try ISO8601.date(from: "2024-01-15T24:00:00Z") == midnight)
        #expect(try ISO8601.date(from: "2024-01-15T23:59:60Z") == midnight)
    }

    @Test func extremes() throws {
        // Proleptic Gregorian, independent of Foundation's Julian cutover.
        #expect(try ISO8601.date(from: "0000-01-01T00:00:00Z") == Date(timeIntervalSince1970: -62_167_219_200))
        #expect(try ISO8601.date(from: "0000-03-01T00:00:00Z") == Date(timeIntervalSince1970: -62_162_035_200))
        #expect(try ISO8601.date(from: "9999-12-31T23:59:59Z") == Date(timeIntervalSince1970: 253_402_300_799))
        #expect(try ISO8601.date(from: "2024-01-15T10:30:45Z") == reference("2024-01-15T10:30:45Z"))
    }

    @Test func inputTypes() throws {
        let string = "2024-01-15T10:30:45Z"
        #expect(try ISO8601.date(from: Data(string.utf8)) == FormTests.instant)
        #expect(try ISO8601.date(from: string.utf8Span) == FormTests.instant)
        #expect(try ISO8601.date(from: Array(string.utf8).span) == FormTests.instant)
        #expect(try ISO8601.date(from: Array(string.utf8).span.bytes) == FormTests.instant)
        #expect(Date(iso8601: string) == FormTests.instant)
        #expect(Date(iso8601: "nope") == nil)
    }
}

@Suite("Rejected input")
struct ErrorTests {
    @Test(arguments: [
        ("", ISO8601ParseError.unexpectedEnd(offset: 0)),
        ("198504", .unexpectedEnd(offset: 6)),
        ("1985-04T10", .unexpectedByte(UInt8(ascii: "T"), offset: 7)),
        ("1985T10", .unexpectedByte(UInt8(ascii: "T"), offset: 4)),
        ("12345-01-01", .unexpectedByte(UInt8(ascii: "5"), offset: 4)),
        ("+19850412", .unexpectedEnd(offset: 9)),
        ("+1234567890-01-01", .unexpectedByte(UInt8(ascii: "0"), offset: 10)),
        ("+", .unexpectedEnd(offset: 1)),
        ("2024-01-1", .unexpectedEnd(offset: 9)),
        ("2024/01/15", .unexpectedByte(UInt8(ascii: "/"), offset: 4)),
        ("2024-01-15X10:30:45Z", .unexpectedByte(UInt8(ascii: "X"), offset: 10)),
        ("2024-01-15T1", .unexpectedEnd(offset: 12)),
        ("2024-01-15T10:3", .unexpectedEnd(offset: 15)),
        ("2024-01-15T10:30:45.Z", .unexpectedByte(UInt8(ascii: "Z"), offset: 20)),
        ("2024-01-15T10:30:45+5", .unexpectedEnd(offset: 21)),
        ("2024-01-15T10:30:45ZZ", .unexpectedByte(UInt8(ascii: "Z"), offset: 20)),
        ("2024-01-15T10:30:45 ", .unexpectedByte(UInt8(ascii: " "), offset: 19)),
        ("2024-01-15T10:30:45\u{0}", .unexpectedByte(0, offset: 19)),
        ("２０２４-01-15", .unexpectedByte(0xEF, offset: 0)),
    ])
    func lexical(_ string: String, _ error: ISO8601ParseError) {
        #expect(throws: error) { try ISO8601.date(from: string) }
    }

    @Test(arguments: [
        ("2024-00-10", ISO8601ParseError.valueOutOfRange(.month, value: 0)),
        ("2024-13-10", .valueOutOfRange(.month, value: 13)),
        ("2024-01-00", .valueOutOfRange(.day, value: 0)),
        ("2024-01-32", .valueOutOfRange(.day, value: 32)),
        ("2024-04-31", .valueOutOfRange(.day, value: 31)),
        ("2023-02-29", .valueOutOfRange(.day, value: 29)),
        ("1900-02-29", .valueOutOfRange(.day, value: 29)),
        ("2023-366", .valueOutOfRange(.ordinalDay, value: 366)),
        ("2024-000", .valueOutOfRange(.ordinalDay, value: 0)),
        ("2024-W53-1", .valueOutOfRange(.week, value: 53)),
        ("2024-W00-1", .valueOutOfRange(.week, value: 0)),
        ("2024-W01-8", .valueOutOfRange(.weekday, value: 8)),
        ("2024-W01-0", .valueOutOfRange(.weekday, value: 0)),
        ("2024-01-15T25:00:00Z", .valueOutOfRange(.hour, value: 25)),
        ("2024-01-15T24:00:01Z", .valueOutOfRange(.hour, value: 24)),
        ("2024-01-15T24:00:00.1Z", .valueOutOfRange(.hour, value: 24)),
        ("2024-01-15T10:60:00Z", .valueOutOfRange(.minute, value: 60)),
        ("2024-01-15T10:30:61Z", .valueOutOfRange(.second, value: 61)),
        ("2024-01-15T10:30:45+24:00", .valueOutOfRange(.offsetHour, value: 24)),
        ("2024-01-15T10:30:45+05:60", .valueOutOfRange(.offsetMinute, value: 60)),
    ])
    func semantic(_ string: String, _ error: ISO8601ParseError) {
        #expect(throws: error) { try ISO8601.date(from: string) }
    }

    @Test func leapYearsAccepted() throws {
        _ = try ISO8601.date(from: "2000-02-29")
        _ = try ISO8601.date(from: "2024-366")
        _ = try ISO8601.date(from: "2020-W53-7")
    }
}
