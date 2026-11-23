import Bytes
import BytesTestSupport
import BytesTesting
import Foundation
import HTTPBytes
import Testing

/// `HTTPDate`: the three formats, what's refused, writing, and Foundation's `Date.HTTPFormatStyle` as a reference.
@Suite struct HTTPDateTests {
    static func parse(_ text: String, relativeTo reference: HTTPDate? = nil) -> Int64? {
        let bytes = Array(text.utf8)
        if let reference { return try? HTTPDate(parsing: bytes.span.bytes, relativeTo: reference).secondsSince1970 }
        return try? HTTPDate(parsing: bytes.span.bytes).secondsSince1970
    }

    static func written(_ date: HTTPDate) -> String {
        let bytes = try! [UInt8](alignedByteCapacity: 29) { (writer) throws(BytesError) in try date.write(to: &writer) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 2026-11-23, for RFC 850's two-digit years.
    static let reference = HTTPDate(year: 2026, month: 11, day: 23, hour: 12)!

    @Test(arguments: [
        // RFC 9110 §5.6.7's example, in each format.
        ("Sun, 06 Nov 1994 08:49:37 GMT", 784_111_777),
        ("Sunday, 06-Nov-94 08:49:37 GMT", 784_111_777),
        ("Sun Nov  6 08:49:37 1994", 784_111_777),
        ("Sun Nov 06 08:49:37 1994", 784_111_777),
        // Rust's httpdate: the epoch, its last second, and others.
        ("Thu, 01 Jan 1970 00:00:00 GMT", 0),
        ("Fri, 31 Dec 9999 23:59:59 GMT", 253_402_300_799),
        ("Mon, 01 Jan 0001 00:00:00 GMT", -62_135_596_800),
        ("Sat, 01 Jan 0000 00:00:00 GMT", -62_167_219_200),
        ("Tue, 29 Feb 2000 12:00:00 GMT", 951_825_600),
        ("Wed, 31 Dec 1969 23:59:59 GMT", -1),
        ("Thu, 01 Jan 1970 00:00:01 GMT", 1),
        // A leap second is the next minute's first second.
        ("Sat, 31 Dec 2016 23:59:60 GMT", 1_483_228_800),
        ("Saturday, 31-Dec-16 23:59:60 GMT", 1_483_228_800),
        ("Wednesday, 09-Nov-94 08:49:37 GMT", 784_370_977),
    ] as [(String, Int64)])
    func parses(text: String, seconds: Int64) {
        #expect(Self.parse(text, relativeTo: Self.reference) == seconds, "\(text)")
    }

    @Test(arguments: [
        "", "Sun, 06 Nov 1994 08:49:37 GM", "Sun, 06 Nov 1994 08:49:37 GMTX", " Sun, 06 Nov 1994 08:49:37 GMT",
        // Case-sensitive (RFC 9110's grammar; Foundation and Python accept these).
        "sun, 06 Nov 1994 08:49:37 GMT", "Sun, 06 nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 gmt",
        "SUN, 06 NOV 1994 08:49:37 GMT",
        // Not GMT, not the date's weekday, not a date, not a time.
        "Sun, 06 Nov 1994 08:49:37 UTC", "Mon, 06 Nov 1994 08:49:37 GMT", "Sun, 31 Feb 1994 08:49:37 GMT",
        "Thu, 29 Feb 1900 00:00:00 GMT", "Sun, 00 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 08:60:37 GMT", "Sun, 06 Nov 1994 08:49:61 GMT", "Sun, 06 Xyz 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:3a GMT", "Sun, 6 Nov 1994 08:49:37 GMT", "Sun,  6 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 94 08:49:37 GMT", "Sun, 06-Nov-1994 08:49:37 GMT", "Sun, 06 Nov 1994 08-49-37 GMT",
        "Sun, 06 Nov +994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 GMT\r",
        // RFC 850 and asctime, malformed.
        "Sun, 06-Nov-94 08:49:37 GMT", "Sundae, 06-Nov-94 08:49:37 GMT", "Monday, 06-Nov-94 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 UTC", "Sunday, 6-Nov-94 08:49:37 GMT", "sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov 6 08:49:37 1994", "Sun Nov  6 08:49:37 94", "Mon Nov  6 08:49:37 1994", "Sun Nov  6 08:49:37 1994 ",
        "Sun Nov  x 08:49:37 1994",
        // Other formats some parsers take.
        "1994-11-06T08:49:37Z", "784111777", "Sun Nov 06 1994 08:49:37 GMT+0000",
    ])
    func refuses(text: String) {
        #expect(Self.parse(text, relativeTo: Self.reference) == nil, "\(text)")
    }

    @Test func twoDigitYears() {
        // At most 50 years ahead of the reference (2026-11-23 12:00): 76 is 2076, 77 is 1977.
        #expect(Self.parse("Monday, 23-Nov-76 12:00:00 GMT", relativeTo: Self.reference) == HTTPDate(year: 2076, month: 11, day: 23, hour: 12)!.secondsSince1970)
        #expect(Self.parse("Wednesday, 23-Nov-77 12:00:00 GMT", relativeTo: Self.reference) == HTTPDate(year: 1977, month: 11, day: 23, hour: 12)!.secondsSince1970)
        // In 2076, a second past 50 years ahead goes back a century (and must name 1976's weekday); the second itself doesn't.
        #expect(Self.parse("Tuesday, 23-Nov-76 12:00:01 GMT", relativeTo: Self.reference) == HTTPDate(year: 1976, month: 11, day: 23, hour: 12, second: 1)!.secondsSince1970)
        #expect(Self.parse("Monday, 23-Nov-76 12:00:01 GMT", relativeTo: Self.reference) == nil)
        #expect(Self.parse("Saturday, 01-Jan-00 00:00:00 GMT", relativeTo: Self.reference) == HTTPDate(year: 2000, month: 1, day: 1)!.secondsSince1970)
        // Without a reference, the current time is one.
        #expect(Self.parse("Sunday, 06-Nov-94 08:49:37 GMT") == 784_111_777)
    }

    @Test func writes() {
        #expect(Self.written(HTTPDate(secondsSince1970: 784_111_777)) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(Self.written(HTTPDate(secondsSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(Self.written(HTTPDate(secondsSince1970: -1)) == "Wed, 31 Dec 1969 23:59:59 GMT")
        #expect(HTTPDate(secondsSince1970: 1_483_228_800).description == "Sun, 01 Jan 2017 00:00:00 GMT")
        // Clamped to what four digits of year can write.
        #expect(Self.written(HTTPDate(secondsSince1970: .max)) == "Fri, 31 Dec 9999 23:59:59 GMT")
        #expect(Self.written(HTTPDate(secondsSince1970: .min)) == "Sat, 01 Jan 0000 00:00:00 GMT")
    }

    @Test func components() {
        let parts = HTTPDate(secondsSince1970: 784_111_777).components
        #expect(parts == HTTPDate.Components(year: 1994, month: 11, day: 6, hour: 8, minute: 49, second: 37, weekday: 0))
        #expect(HTTPDate(year: 1994, month: 11, day: 6, hour: 8, minute: 49, second: 37)?.secondsSince1970 == 784_111_777)
        #expect(HTTPDate(year: 2023, month: 2, day: 29) == nil)
        #expect(HTTPDate(year: 2024, month: 2, day: 29) != nil)
        #expect(HTTPDate(year: 2024, month: 1, day: 1, second: 60) == nil)
        #expect(HTTPDate(year: 10_000, month: 1, day: 1) == nil)
    }

    @Test func cacheFormatsOncePerSecond() {
        var cache = HTTPDateCache()
        let first = HTTPDate(secondsSince1970: 784_111_777)
        #expect(string(cache.imfFixdate(first)) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(string(cache.imfFixdate(first)) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(string(cache.imfFixdate(HTTPDate(secondsSince1970: 784_111_778))) == "Sun, 06 Nov 1994 08:49:38 GMT")
    }

    func string(_ bytes: RawSpan) -> String {
        String(decoding: (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) }, as: UTF8.self)
    }

    /// Every day from `firstDay` for `count` days, at a time of day from `seed`: written, parsed back (all three formats),
    /// and compared with Foundation's `Date.HTTPFormatStyle` in both directions.
    static func sweep(days firstDay: Int, count: Int, seed: UInt64, foundation: Bool) {
        var generator = SplitMix64(seed: seed)
        let style = Date.HTTPFormatStyle()
        var failures = 0
        for day in firstDay..<firstDay + count where failures < 5 {
            let seconds = Int64(day) * 86_400 + Int64(generator.next() % 86_400)
            let date = HTTPDate(secondsSince1970: seconds)
            let text = written(date)
            let parts = date.components
            var ok = parse(text) == seconds
            // asctime of the same instant.
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let asctime = String(format: "%@ %@ %2d %02d:%02d:%02d %04d", names[parts.weekday], months[parts.month - 1], parts.day,
                                 parts.hour, parts.minute, parts.second, parts.year)
            ok = ok && parse(asctime) == seconds
            if foundation {
                let reference = Date(timeIntervalSince1970: TimeInterval(seconds))
                ok = ok && reference.formatted(style) == text
                ok = ok && (try? style.parseStrategy.parse(text))?.timeIntervalSince1970 == TimeInterval(seconds)
            }
            if !ok {
                failures += 1
                Issue.record("day \(day): \(text) / \(asctime)")
            }
        }
    }

    @Test func everyDayFrom1900To2100() {
        Self.sweep(days: -25_567, count: 73_049, seed: 1, foundation: false)
        // Foundation for a sample (it's slower than the parser by far).
        Self.sweep(days: 0, count: 2_000, seed: 2, foundation: true)
    }
}

@Suite(.bulk) struct HTTPDateBulkTests {
    @Test func everyDayOfYears0To9999() {
        HTTPDateTests.sweep(days: -719_528, count: 3_652_425, seed: 3, foundation: false)
    }

    @Test func foundationAgreesFrom1970To2200() {
        HTTPDateTests.sweep(days: 0, count: 84_000, seed: 4, foundation: true)
    }
}
