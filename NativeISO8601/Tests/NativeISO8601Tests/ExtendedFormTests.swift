import Foundation
import NativeISO8601
import Testing

private func date(_ string: String) throws -> Date { try ISO8601.date(from: string) }

/// 0000-01-01T00:00:00Z, proleptic Gregorian.
private let yearZero = Date(timeIntervalSince1970: -62_167_219_200)
private let day: TimeInterval = 86_400

@Suite("Reduced precision")
struct ReducedPrecisionTests {
    @Test("Each resolves to the start of its period", arguments: [
        ("1985", "1985-01-01"), ("1985-04", "1985-04-01"), ("198", "1980-01-01"), ("19", "1900-01-01"),
        ("00", "0000-01-01"), ("1985-W15", "1985-W15-1"), ("1985W15", "1985-W15-1"), ("2020W53", "2020-12-28"),
    ])
    func startOfPeriod(_ reduced: String, _ complete: String) throws {
        #expect(try date(reduced) == date(complete))
    }

    @Test func hourAndFractions() throws {
        let base = try date("2024-01-15T10:00:00Z")
        #expect(try date("2024-01-15T10") == base)
        #expect(try date("2024-01-15T10Z") == base)
        #expect(try date("20240115T10+01") == base.addingTimeInterval(-3600))
        #expect(try date("2024-01-15T10,5Z") == base.addingTimeInterval(1800))
        #expect(try date("2024-01-15T10.25") == base.addingTimeInterval(900))
        #expect(try date("2024-01-15T10:30,5Z") == base.addingTimeInterval(1830))
        #expect(throws: ISO8601ParseError.valueOutOfRange(.hour, value: 24)) { try date("2024-01-15T24,5") }
    }

    @Test func invalidReducedValues() {
        #expect(throws: ISO8601ParseError.valueOutOfRange(.month, value: 13)) { try date("1985-13") }
        #expect(throws: ISO8601ParseError.valueOutOfRange(.week, value: 53)) { try date("1985-W53") }
        #expect(throws: ISO8601ParseError.valueOutOfRange(.week, value: 0)) { try date("1985W00") }
    }
}

@Suite("Expanded and negative years")
struct ExpandedYearTests {
    @Test("Signed forms match their four-digit equivalents", arguments: [
        ("+001985-04-12", "1985-04-12"), ("+0019850412", "1985-04-12"), ("+001985-102", "1985-102"),
        ("+001985102", "1985-102"), ("+001985-W15-5", "1985-W15-5"), ("+001985W155", "1985-W15-5"),
        ("+001985-W15", "1985-W15"), ("+001985W15", "1985-W15"), ("+001985", "1985"), ("+00198", "198"),
        ("+0019", "19"), ("+1985-04-12T10:30Z", "1985-04-12T10:30Z"), ("-0000-01-01", "0000-01-01"),
    ])
    func equivalents(_ expanded: String, _ plain: String) throws {
        #expect(try date(expanded) == date(plain))
    }

    @Test func anchors() throws {
        // Year −1 (2 BC) isn't a leap year; year 0 is.
        #expect(try date("-0001-01-01") == yearZero.addingTimeInterval(-365 * day))
        #expect(try date("-000001") == yearZero.addingTimeInterval(-365 * day))
        #expect(try date("-0001-12-31") == yearZero.addingTimeInterval(-day))
        // 0000-01-01 was a Saturday, so ISO week 1 of year 0 starts on Monday January 3.
        #expect(try date("0000-W01-1") == yearZero.addingTimeInterval(2 * day))
        // −0001-01-01 was a Friday; week 1 starts Monday January 4.
        #expect(try date("-0001-W01-1") == date("-0001-01-04"))
        #expect(try date("+010000-01-01") == date("9999-12-31").addingTimeInterval(day))
        // Extreme supported years stay finite and ordered.
        let earliest = try date("-999999999-01-01"), latest = try date("+999999999-12-31")
        #expect(earliest.timeIntervalSince1970.isFinite && earliest < yearZero && latest > earliest)
    }

    @Test func negativeLeapYears() throws {
        _ = try date("-0004-02-29")
        _ = try date("-0400-366")
        #expect(throws: ISO8601ParseError.valueOutOfRange(.day, value: 29)) { try date("-0100-02-29") }
        #expect(throws: ISO8601ParseError.valueOutOfRange(.day, value: 29)) { try date("-0001-02-29") }
    }

    @Test("Days are contiguous across year boundaries", arguments: [-1_005, -405, -5, 9_995, 99_995])
    func continuity(startingAt firstYear: Int) throws {
        func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
        func text(_ y: Int, _ m: Int, _ d: Int) -> String {
            let digits = String(abs(y)), padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            return "\(y < 0 ? "-" : "+")\(padded)-\(m < 10 ? "0" : "")\(m)-\(d < 10 ? "0" : "")\(d)"
        }
        var previous = try date(text(firstYear, 1, 1)).addingTimeInterval(-day)
        for year in firstYear..<(firstYear + 10) {
            var ordinal = 0
            for month in 1...12 {
                let length = [31, isLeap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
                for dayOfMonth in 1...length {
                    ordinal += 1
                    let current = try date(text(year, month, dayOfMonth))
                    #expect(current == previous.addingTimeInterval(day), "\(text(year, month, dayOfMonth))")
                    previous = current
                }
            }
            #expect(ordinal == (isLeap(year) ? 366 : 365))
        }
    }
}

@Suite("Timestamp components")
struct TimestampTests {
    @Test func calendarDateTime() throws {
        let stamp = try ISO8601.timestamp(from: "1985-04-12T23:20:50.52+04:00")
        #expect(stamp.dateValue == .calendarDate(year: 1985, month: 4, day: 12))
        #expect(stamp.time == .init(hour: 23, minute: 20, second: 50, fraction: .init(value: 52, digits: 2)))
        #expect(stamp.utcOffset == .init(isNegative: false, hours: 4, minutes: 0))
        #expect(stamp.utcOffset?.seconds == 14_400)
        #expect(stamp.date == (try ISO8601.date(from: "1985-04-12T23:20:50.52+04:00")))
    }

    @Test(arguments: [
        ("19", ISO8601.Timestamp.DateValue.century(19)), ("198", .decade(198)), ("1985", .year(1985)),
        ("-000001", .year(-1)), ("1985-04", .month(year: 1985, month: 4)), ("1985W15", .week(year: 1985, week: 15)),
        ("1985-W15-5", .weekDate(year: 1985, week: 15, weekday: 5)), ("1985102", .ordinalDate(year: 1985, dayOfYear: 102)),
    ])
    func dateValues(_ string: String, _ expected: ISO8601.Timestamp.DateValue) throws {
        let stamp = try ISO8601.timestamp(from: string)
        #expect(stamp.dateValue == expected)
        #expect(stamp.time == nil && stamp.utcOffset == nil)
    }

    @Test func reducedTimesAndOffsets() throws {
        let hour = try ISO8601.timestamp(from: "1985-04-12T23,3Z")
        #expect(hour.time == .init(hour: 23, fraction: .init(value: 3, digits: 1)))
        #expect(hour.utcOffset == .utc)
        let minute = try ISO8601.timestamp(from: "19850412T2320-05")
        #expect(minute.time == .init(hour: 23, minute: 20))
        #expect(minute.utcOffset == .init(isNegative: true, hours: 5, isHoursOnly: true))
        #expect(minute.utcOffset?.seconds == -18_000)
    }
}
