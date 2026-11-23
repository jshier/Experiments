import Bytes
import BytesTestSupport
import HTTPBytes
import Testing

// Field-value parsers. Vectors marked "Go" are transcribed from Go's net/http and mime (golang/go master, 2026-11:
// src/net/http/range_test.go, src/mime/mediatype_test.go; BSD-style license, https://go.dev/LICENSE: "Redistribution
// and use in source and binary forms, with or without modification, are permitted provided that … redistributions of
// source code must retain the above copyright notice"); "negotiator" and "fresh" from jshttp's negotiator and fresh
// (MIT); "cache-tests" from http-tests/cache-tests (BSD-3-Clause). Deliberate differences say why.

func b(_ text: String) -> [UInt8] { Array(text.utf8) }

/// `Optional.map` doesn't take `~Escapable` values.
func optionalText(_ span: RawSpan?) -> String? {
    if let span { return text(span) }
    return nil
}

/// What a writer received from `body`, or `nil` if it threw.
func written(_ body: (inout AlignedBytesWriter) throws(HTTPFieldValueError) -> Void) -> String? {
    let bytes = try? [UInt8](alignedByteCapacity: 1_024) { (writer) throws(BytesError) in
        do throws(HTTPFieldValueError) { try body(&writer) } catch { throw .invalidValue }
    }
    return bytes.map { String(decoding: $0, as: UTF8.self) }
}

@Suite struct GrammarTests {
    static func elements(_ value: String) -> [String]? {
        let bytes = b(value)
        var list = HTTPListElements(bytes.span.bytes)
        var result: [String] = []
        do throws(HTTPFieldValueError) {
            while let element = try list.next() { result.append(text(element)) }
        } catch { return nil }
        return result
    }

    @Test func lists() {
        #expect(Self.elements("a, b,c") == ["a", "b", "c"])
        // RFC 9110 §5.6.1.2: empty elements are accepted and don't count.
        #expect(Self.elements(" , ,a,,  b ,") == ["a", "b"])
        #expect(Self.elements("") == [])
        #expect(Self.elements("x;p=\"a, b\", y") == ["x;p=\"a, b\"", "y"])
        #expect(Self.elements("x;p=\"a\\\", b\", y") == ["x;p=\"a\\\", b\"", "y"])
        #expect(Self.elements("x;p=\"unclosed, y") == nil)
        // Elements longer than a vector's 16 bytes, commas past them.
        #expect(Self.elements("abcdefghijklmnopqrstuvwxyz, 0123456789012345678901234567890123") == ["abcdefghijklmnopqrstuvwxyz", "0123456789012345678901234567890123"])
    }

    static func parameters(_ value: String) -> [String]? {
        let bytes = b(value)
        var parameters = HTTPParameters(bytes.span.bytes)
        var result: [String] = []
        do throws(HTTPFieldValueError) {
            while let parameter = try parameters.next() {
                let value = written { (writer) throws(HTTPFieldValueError) in
                    do throws(BytesError) { try parameter.value.write(to: &writer) } catch { throw .outputTooSmall }
                }
                result.append("\(text(parameter.name))=\(value ?? "?")")
            }
        } catch { return nil }
        return result
    }

    @Test func parameters() {
        #expect(Self.parameters("; a=1 ;b=\"two\";  c=\"x\\\"y\"") == ["a=1", "b=two", "c=x\"y"])
        #expect(Self.parameters(";;a=1;") == ["a=1"])
        #expect(Self.parameters("") == [])
        // No whitespace around `=` (RFC 9110 §5.6.6), a value, a `;` between parameters.
        #expect(Self.parameters("; a =1") == nil)
        #expect(Self.parameters("; a= 1") == nil)
        #expect(Self.parameters("; a=") == nil)
        #expect(Self.parameters("; a") == nil)
        #expect(Self.parameters("; a=1 b=2") == nil)
        #expect(Self.parameters("a=1") == nil)
        #expect(Self.parameters("; a=\"\u{7F}\"") == nil)
        #expect(Self.parameters("; a=\"tab\there\"") == ["a=tab\there"])
        #expect(Self.parameters("; a=\"é\"") == ["a=é"], "obs-text")
    }

    @Test func weights() {
        let cases: [(String, Int?)] = [("1", 1000), ("1.", 1000), ("1.000", 1000), ("0", 0), ("0.5", 500), ("0.25", 250),
                                       ("0.125", 125), ("0.001", 1), ("1.001", nil), ("2", nil), (".5", nil), ("0.1234", nil),
                                       ("", nil), ("0.a", nil), ("01", nil)]
        for (value, expected) in cases {
            let bytes = b(value)
            #expect(HTTPWeight.thousandths(bytes.span.bytes) == expected, "\(value)")
        }
    }
}

@Suite struct MediaTypeTests {
    static func parse(_ value: String) -> (String, String, String?)? {
        let bytes = b(value)
        guard let type = try? HTTPMediaType(parsing: bytes.span.bytes) else { return nil }
        var charset: String? = nil
        if let value = type.charset {
            charset = written { (writer) throws(HTTPFieldValueError) in
                do throws(BytesError) { try value.write(to: &writer) } catch { throw .outputTooSmall }
            }
        }
        return (text(type.type), text(type.subtype), charset)
    }

    @Test func contentTypes() {
        #expect(Self.parse("text/html; charset=utf-8")! == ("text", "html", "utf-8"))
        #expect(Self.parse(" Text/HTML ;Charset=\"UTF-8\" ")! == ("Text", "HTML", "UTF-8"))
        #expect(Self.parse("application/json")! == ("application", "json", nil))
        #expect(Self.parse("multipart/form-data; boundary=----x; charset=utf-8")! == ("multipart", "form-data", "utf-8"))
        for invalid in ["text", "text/", "/html", "text /html", "text/ html", "text/html;", "text/html; charset", "text/html charset=x",
                        "text/html; charset=\"x", "te(t/html", ""] where invalid != "text/html;" {
            #expect(Self.parse(invalid) == nil, "\(invalid)")
        }
        // A trailing `;` is an empty parameter: allowed.
        #expect(Self.parse("text/html;") != nil)
        let bytes = b("APPLICATION/Json")
        let matches = (try? HTTPMediaType(parsing: bytes.span.bytes).matches("application", "json")) ?? false
        #expect(matches)
    }

    static func weight(_ type: String, _ accept: String) -> Int {
        let parts = type.split(separator: "/").map { b(String($0)) }
        let mainType = parts[0], subtype = parts[1]
        let value = b(accept)
        return (try? HTTPAcceptList.weight(ofMediaType: mainType.span.bytes, subtype.span.bytes, in: value.span.bytes)) ?? -1
    }

    @Test func mediaTypeNegotiation() {
        // RFC 9110 §12.5.1's example.
        let accept = "text/*;q=0.3, text/plain;q=0.7, text/plain;format=flowed, text/plain;format=fixed;q=0.4, */*;q=0.5"
        #expect(Self.weight("text/plain", accept) == 700)
        #expect(Self.weight("text/html", accept) == 300)
        #expect(Self.weight("image/jpeg", accept) == 500)
        #expect(Self.weight("text/plain", "text/*, text/plain;q=0") == 0, "the most specific range wins")
        #expect(Self.weight("application/json", "text/html") == 0)
        #expect(Self.weight("application/json", "application/*;q=0.2") == 200)
        // negotiator: `*/*;q=0.8, text/html` prefers text/html; ranges match without case.
        #expect(Self.weight("text/html", "*/*;q=0.8, Text/HTML") == 1000)
        #expect(Self.weight("text/html", "*/*;q=0.8, text/html;q=0") == 0)
        #expect(Self.weight("text/html", "text/html;q=invalid") == -1)
    }

    static func language(_ tag: String, _ accept: String) -> Int {
        let tagBytes = b(tag), value = b(accept)
        return (try? HTTPAcceptList.weight(ofLanguage: tagBytes.span.bytes, in: value.span.bytes)) ?? -1
    }

    @Test func languages() {
        let accept = "da, en-gb;q=0.8, en;q=0.7"
        #expect(Self.language("da", accept) == 1000)
        #expect(Self.language("en-GB", accept) == 800)
        #expect(Self.language("en-US", accept) == 700, "the range `en` matches `en-US`")
        #expect(Self.language("fr", accept) == 0)
        #expect(Self.language("fr", "*;q=0.1") == 100)
        #expect(Self.language("english", "en") == 0, "a prefix must end at a `-`")
    }

    static func coding(_ token: String, _ accept: String) -> Int {
        let tokenBytes = b(token), value = b(accept)
        return (try? HTTPAcceptList.weight(ofToken: tokenBytes.span.bytes, in: value.span.bytes)) ?? -1
    }

    /// negotiator's encoding tests, as weights.
    @Test func codings() {
        #expect(Self.coding("gzip", "*") == 1000)
        #expect(Self.coding("gzip", "*, gzip;q=0") == 0)
        #expect(Self.coding("compress", "*, gzip;q=0") == 1000)
        #expect(Self.coding("identity", "*;q=0") == 0)
        #expect(Self.coding("identity", "*;q=0, identity;q=1") == 1000)
        #expect(Self.coding("identity", "identity;q=0") == 0)
        #expect(Self.coding("identity", "gzip") == 1000, "identity is acceptable unless refused")
        #expect(Self.coding("identity", "") == 1000)
        #expect(Self.coding("gzip", "") == 0)
        #expect(Self.coding("gzip", "gzip;q=0.8, deflate") == 800)
        #expect(Self.coding("GZIP", "gzip") == 1000)
        #expect(Self.coding("br", "gzip, deflate, br, zstd") == 1000)
        #expect(Self.coding("br", "gzip;q=1.5") == -1)
    }
}

@Suite struct RangeTests {
    static func resolve(_ value: String, _ length: Int, storage size: Int = 4) -> String {
        let bytes = b(value)
        var storage = [Range<Int>](repeating: 0..<0, count: size)
        var span = storage.mutableSpan
        switch HTTPRangeSet.resolve(bytes.span.bytes, length: length, into: &span) {
        case .ignore: return "ignore"
        case .unsatisfiable: return "416"
        case .ranges(let count): return storage[..<count].map { "\($0.lowerBound)-\($0.upperBound - 1)" }.joined(separator: ",")
        }
    }

    /// Review: merging must happen before the storage limit is checked. Random sets against a plain sort-and-merge, for
    /// every storage size 0–4.
    @Test func mergingAgainstAReference() {
        #expect(Self.resolve("bytes=0-0,5-6,2-4", 10, storage: 2) == "0-0,2-6")
        #expect(Self.resolve("bytes=0-5,0-", 100, storage: 1) == "0-99")
        #expect(Self.resolve("bytes=0-,10-,-20", 10, storage: 1) == "0-9")
        var generator = SplitMix64(seed: 9)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 40)
            var parts: [String] = [], resolved: [Range<Int>] = []
            for _ in 0..<(1 + Int(generator.next() % 5)) {
                let a = Int(generator.next() % 45), b = Int(generator.next() % 45)
                switch generator.next() % 3 {
                case 0:
                    parts.append("\(min(a, b))-\(max(a, b))")
                    if min(a, b) < length { resolved.append(min(a, b)..<min(max(a, b), length - 1) + 1) }
                case 1:
                    parts.append("\(a)-")
                    if a < length { resolved.append(a..<length) }
                default:
                    parts.append("-\(a)")
                    if a > 0, length > 0 { resolved.append(max(0, length - a)..<length) }
                }
            }
            var merged: [Range<Int>] = []
            for range in resolved.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, last.upperBound >= range.lowerBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            let value = "bytes=" + parts.joined(separator: ",")
            for size in 0...4 {
                let expected = merged.isEmpty ? "416" : merged.count > size ? "ignore"
                    : merged.map { "\($0.lowerBound)-\($0.upperBound - 1)" }.joined(separator: ",")
                let got = Self.resolve(value, length, storage: size)
                if got != expected { Issue.record("\(value) length \(length) storage \(size): \(got), expected \(expected)"); return }
            }
        }
    }

    /// Go's ParseRangeTests. Go keeps ranges in request order unmerged and reports an unsatisfiable set as an error;
    /// here they're sorted and merged (overlapping or adjacent), and all-unsatisfiable is 416.
    @Test(arguments: [
        ("", 0, "ignore"), ("", 1000, "ignore"), ("foo", 0, "ignore"), ("bytes=", 0, "ignore"), ("bytes=7", 10, "ignore"),
        ("bytes= 7 ", 10, "ignore"), ("bytes=1-", 0, "416"), ("bytes=5-4", 10, "ignore"), ("bytes=0-2,5-4", 10, "ignore"),
        ("bytes=2-5,4-3", 10, "ignore"), ("bytes=--5,4--3", 10, "ignore"), ("bytes=A-", 10, "ignore"), ("bytes=A- ", 10, "ignore"),
        ("bytes=A-Z", 10, "ignore"), ("bytes= -Z", 10, "ignore"), ("bytes=5-Z", 10, "ignore"), ("bytes=Ran-dom, garbage", 10, "ignore"),
        ("bytes=0x01-0x02", 10, "ignore"), ("bytes=         ", 10, "ignore"), ("bytes= , , ,   ", 10, "ignore"),
        ("bytes=0-9", 10, "0-9"), ("Bytes=0-9", 10, "0-9"), ("BYTES=0-9", 10, "0-9"), ("bYtEs=0-9", 10, "0-9"), ("bytes=0-", 10, "0-9"),
        ("bytes=5-", 10, "5-9"), ("bytes=0-20", 10, "0-9"), ("bytes=15-,0-5", 10, "0-5"), ("bytes=1-2,5-", 10, "1-2,5-9"),
        ("bytes=-2 , 7-", 11, "7-10"), ("bytes=0-0 ,2-2, 7-", 11, "0-0,2-2,7-10"), ("bytes=-5", 10, "5-9"), ("bytes=-15", 10, "0-9"),
        ("bytes=0-499", 10_000, "0-499"), ("bytes=500-999", 10_000, "500-999"), ("bytes=-500", 10_000, "9500-9999"),
        ("bytes=9500-", 10_000, "9500-9999"), ("bytes=0-0,-1", 10_000, "0-0,9999-9999"), ("bytes=500-600,601-999", 10_000, "500-999"),
        ("bytes=500-700,601-999", 10_000, "500-999"),
        // Go accepts Apache's laxity, whitespace inside ranges; RFC 9110's grammar doesn't.
        ("bytes=   1 -2   ,  4- 5, 7 - 8 , ,,", 11, "ignore"),
        // More: suffix 0 is unsatisfiable; huge numbers saturate; more ranges than the storage holds, after merging.
        ("bytes=-0", 10, "416"), ("bytes=0-99999999999999999999999", 10, "0-9"), ("bytes=99999999999999999999-", 10, "416"),
        ("bytes=0-0,2-2,4-4,6-6,8-8", 10, "ignore"), ("bytes=0-0,1-1,2-2,3-3,4-4,5-5", 10, "0-5"), ("bytes=5-6,0-1,3-3", 10, "0-1,3-3,5-6"),
        ("bytes=0-1,4-5,1-4", 10, "0-5"), ("bytes=-3,-2", 10, "7-9"), ("items=0-1", 10, "ignore"),
    ] as [(String, Int, String)])
    func ranges(value: String, length: Int, expected: String) {
        #expect(Self.resolve(value, length) == expected, "\(value)")
    }

    @Test func contentRanges() throws {
        func parse(_ value: String) -> HTTPContentRange? { try? HTTPContentRange(parsing: b(value).span.bytes) }
        #expect(parse("bytes 0-499/1234") == HTTPContentRange(range: 0...499, completeLength: 1234))
        #expect(parse("bytes */1234") == HTTPContentRange(range: nil, completeLength: 1234))
        #expect(parse("bytes 42-1233/*") == HTTPContentRange(range: 42...1233, completeLength: nil))
        for invalid in ["bytes 0-1234/1234", "bytes 5-4/10", "bytes */*", "bytes 0-1/", "bytes 0-/10", "items 0-1/2", "bytes  0-1/2", "bytes 0-1/2x"] {
            #expect(parse(invalid) == nil, "\(invalid)")
        }
        let range = HTTPContentRange(range: 0...499, completeLength: 1234)
        #expect(written { (writer) throws(HTTPFieldValueError) in
            do throws(BytesError) { try range.write(to: &writer) } catch { throw .outputTooSmall }
        } == "bytes 0-499/1234")
        let unsatisfied = HTTPContentRange(range: nil, completeLength: 0)
        #expect(written { (writer) throws(HTTPFieldValueError) in
            do throws(BytesError) { try unsatisfied.write(to: &writer) } catch { throw .outputTooSmall }
        } == "bytes */0")
    }
}

@Suite struct ConditionalTests {
    static func tags(_ value: String) -> [String]? {
        let bytes = b(value)
        var list = HTTPEntityTagList(bytes.span.bytes)
        if list.isAny { return ["*"] }
        var result: [String] = []
        do throws(HTTPFieldValueError) {
            while let tag = try list.next() { result.append((tag.isWeak ? "W/" : "") + text(tag.opaque)) }
        } catch { return nil }
        return result
    }

    @Test func entityTags() {
        #expect(Self.tags("\"xyzzy\", W/\"r2d2xxxx\", \"c3piozzzz\"") == ["xyzzy", "W/r2d2xxxx", "c3piozzzz"])
        #expect(Self.tags("*") == ["*"])
        #expect(Self.tags("\"a,b\", \"c\"") == ["a,b", "c"], "commas are entity-tag characters")
        #expect(Self.tags("\"a\\\"") == ["a\\"], "no escapes: a backslash is an ordinary character")
        #expect(Self.tags("\"\"") == [""])
        #expect(Self.tags("w/\"a\"") == nil, "W/ is case-sensitive")
        #expect(Self.tags("\"a\" \"b\"") == nil)
        #expect(Self.tags("xyzzy") == nil)
        #expect(Self.tags("\"a") == nil)
        #expect(Self.tags("\"a b\"") == nil)
    }

    static func evaluate(_ method: HTTPMethod, ifMatch: String? = nil, ifUnmodifiedSince: String? = nil, ifNoneMatch: String? = nil,
                         ifModifiedSince: String? = nil, etag: String? = "\"abc\"", lastModified: Int64? = 1_000) -> HTTPPreconditionResult {
        let a = ifMatch.map(b), c = ifUnmodifiedSince.map(b), d = ifNoneMatch.map(b), e = ifModifiedSince.map(b), tag = etag.map(b)
        let preconditions = HTTPPreconditions(ifMatch: a?.span.bytes, ifUnmodifiedSince: c?.span.bytes, ifNoneMatch: d?.span.bytes,
                                              ifModifiedSince: e?.span.bytes)
        let modified = lastModified.map { HTTPDate(secondsSince1970: $0) }
        if let tag {
            let current = try! HTTPEntityTag(parsing: tag.span.bytes)
            return preconditions.evaluate(method: method, entityTag: current, lastModified: modified)
        }
        return preconditions.evaluate(method: method, entityTag: nil, lastModified: modified)
    }

    static let before = "Thu, 01 Jan 1970 00:00:00 GMT", after = "Fri, 02 Jan 1970 00:00:00 GMT"

    /// Review: a malformed list fails its condition wherever the bad element is; `*` on a missing representation.
    @Test func malformedListsAndMissingRepresentations() {
        #expect(Self.evaluate(.put, ifMatch: "\"abc\", garbage") == .preconditionFailed)
        #expect(Self.evaluate(.put, ifMatch: "garbage, \"abc\"") == .preconditionFailed)
        #expect(Self.evaluate(.get, ifNoneMatch: "\"abc\", garbage") == .proceed)
        #expect(Self.evaluate(.put, ifNoneMatch: "*", etag: nil, lastModified: nil) == .proceed, "nothing there to match")
        let tokens = b("close, @@"), reversed = b("@@, close")
        let first = HTTPTokenList.contains(tokens.span.bytes, "close"), second = HTTPTokenList.contains(reversed.span.bytes, "close")
        #expect(!first && !second)
    }

    /// RFC 9110 §13.2.2's order, and jshttp's fresh tests (GET: 304 when fresh).
    @Test func preconditions() {
        #expect(Self.evaluate(.get) == .proceed)
        // fresh: etags.
        #expect(Self.evaluate(.get, ifNoneMatch: "\"abc\"") == .notModified)
        #expect(Self.evaluate(.get, ifNoneMatch: "\"xyz\"") == .proceed)
        #expect(Self.evaluate(.get, ifNoneMatch: "\"xyz\", \"abc\"") == .notModified)
        #expect(Self.evaluate(.get, ifNoneMatch: "W/\"abc\"") == .notModified, "weak comparison")
        #expect(Self.evaluate(.get, ifNoneMatch: "*") == .notModified)
        #expect(Self.evaluate(.get, ifNoneMatch: "*", etag: nil, lastModified: nil) == .proceed, "* needs a current representation")
        #expect(Self.evaluate(.post, ifNoneMatch: "\"abc\"") == .preconditionFailed)
        // fresh: dates; If-Modified-Since is ignored when If-None-Match is present.
        #expect(Self.evaluate(.get, ifModifiedSince: Self.after) == .notModified)
        #expect(Self.evaluate(.get, ifModifiedSince: Self.before) == .proceed)
        #expect(Self.evaluate(.get, ifNoneMatch: "\"xyz\"", ifModifiedSince: Self.after) == .proceed)
        #expect(Self.evaluate(.get, ifModifiedSince: "foo") == .proceed, "an invalid date is ignored")
        #expect(Self.evaluate(.post, ifModifiedSince: Self.after) == .proceed, "only GET and HEAD")
        // If-Match: strong comparison; then If-Unmodified-Since only without it.
        #expect(Self.evaluate(.put, ifMatch: "\"abc\"") == .proceed)
        #expect(Self.evaluate(.put, ifMatch: "W/\"abc\"") == .preconditionFailed)
        #expect(Self.evaluate(.put, ifMatch: "*") == .proceed)
        #expect(Self.evaluate(.put, ifMatch: "*", etag: nil, lastModified: nil) == .preconditionFailed)
        #expect(Self.evaluate(.put, ifUnmodifiedSince: Self.before) == .preconditionFailed)
        #expect(Self.evaluate(.put, ifUnmodifiedSince: Self.after) == .proceed)
        #expect(Self.evaluate(.put, ifMatch: "\"abc\"", ifUnmodifiedSince: Self.before) == .proceed)
        #expect(Self.evaluate(.put, ifMatch: "\"abc\"", ifNoneMatch: "\"abc\"") == .preconditionFailed)
    }

    @Test func ifRange() throws {
        let tag = b("\"abc\""), weak = b("W/\"abc\""), date = b("Thu, 01 Jan 1970 00:16:40 GMT")
        let current = try HTTPEntityTag(parsing: tag.span.bytes)
        #expect(try HTTPIfRange(parsing: tag.span.bytes).matches(entityTag: current, lastModified: nil))
        #expect(try !HTTPIfRange(parsing: weak.span.bytes).matches(entityTag: current, lastModified: nil))
        #expect(try HTTPIfRange(parsing: date.span.bytes).matches(entityTag: nil, lastModified: HTTPDate(secondsSince1970: 1_000)))
        #expect(try !HTTPIfRange(parsing: date.span.bytes).matches(entityTag: nil, lastModified: HTTPDate(secondsSince1970: 1_001)))
    }
}

@Suite struct CacheControlTests {
    static func parse(_ lines: String...) -> HTTPCacheControl? {
        var control = HTTPCacheControl()
        for line in lines {
            let bytes = b(line)
            control.update(parsing: bytes.span.bytes)
        }
        return control
    }

    /// Review: a malformed element doesn't throw the field away (a cache would store what `no-store` forbids).
    @Test func malformedElementsKeepTheRest() {
        #expect(Self.parse("max-age = 0, no-store")?.noStore == true)
        #expect(Self.parse("no-store, max-age=1 2")?.noStore == true)
        #expect(Self.parse("no-store, private=\"a")?.noStore == true, "an unclosed quote ends the field there")
        #expect(Self.parse("no-cache=\"\"")?.noCacheHasFields == false)
    }

    /// cache-tests' cc-parse.mjs (the "must" ones exactly; the "check" ones as RFC 9111 §4.2.1 and §5.2 decide).
    @Test func directives() {
        #expect(Self.parse("max-age=1800, max-age=1")?.maxAge == 1800, "the first occurrence")
        #expect(Self.parse("max-age=1800", "max-age=1")?.maxAge == 1800)
        #expect(Self.parse("max-age=1, max-age=1800")?.maxAge == 1)
        #expect(Self.parse("max-age=\"3600\"")?.maxAge == 3600, "the quoted form")
        #expect(Self.parse("extension=\"max-age=3600\", max-age=1")?.maxAge == 1, "must: not inside another's quoted string")
        #expect(Self.parse("max-age=1, extension=\"max-age=3600\"")?.maxAge == 1)
        #expect(Self.parse("max-age =3600")?.maxAge == nil)
        #expect(Self.parse("max-age= 3600")?.maxAge == nil)
        #expect(Self.parse("max-age=003600")?.maxAge == 3600)
        #expect(Self.parse("max-age='3600'")?.maxAge == nil, "must: not single quotes")
        #expect(Self.parse("max-age=3600.0")?.maxAge == nil)
        #expect(Self.parse("max-age=a3600")?.maxAge == nil)
        #expect(Self.parse("max-age=3600a")?.maxAge == nil)
        // An invalid max-age doesn't lose the other directives.
        #expect(Self.parse("max-age=x, no-store")?.noStore == true)
        #expect(Self.parse("max-age=99999999999999999999")?.maxAge == 1 << 31, "2^31 at most")
        let all = Self.parse("Public, PRIVATE=\"Set-Cookie\", no-cache=\"a, b\", no-store, no-transform, must-revalidate, proxy-revalidate, "
            + "must-understand, immutable, s-maxage=5, stale-while-revalidate=6, stale-if-error=7, max-stale, min-fresh=8, only-if-cached")!
        #expect(all.isPublic && all.isPrivate && all.noCache && all.noCacheHasFields && all.noStore && all.noTransform)
        #expect(all.mustRevalidate && all.proxyRevalidate && all.mustUnderstand && all.isImmutable && all.onlyIfCached)
        #expect(all.sharedMaxAge == 5 && all.staleWhileRevalidate == 6 && all.staleIfError == 7 && all.maxStale == .max && all.minFresh == 8)
        #expect(Self.parse("max-stale=10")?.maxStale == 10)
    }

    @Test func retryAfterSaturates() throws {
        let huge = try HTTPRetryAfter(parsing: b("99999999999999999999").span.bytes)
        #expect(huge.date(after: HTTPDate(secondsSince1970: 1_700_000_000)) == HTTPDate(secondsSince1970: .max))
        #expect(HTTPDate(secondsSince1970: .min).components.year == 0, "the expired sentinel reads as year 0")
    }

    @Test func ageExpiresRetryAfter() throws {
        #expect(HTTPCacheFields.age(b("60").span.bytes) == 60)
        #expect(HTTPCacheFields.age(b(" 60 ").span.bytes) == 60)
        #expect(HTTPCacheFields.age(b("-1").span.bytes) == nil)
        #expect(HTTPCacheFields.age(b("1.5").span.bytes) == nil)
        #expect(HTTPCacheFields.expires(b("0").span.bytes) == HTTPDate(secondsSince1970: .min), "already expired")
        #expect(HTTPCacheFields.expires(b("Thu, 01 Jan 1970 00:00:10 GMT").span.bytes) == HTTPDate(secondsSince1970: 10))
        #expect(try HTTPRetryAfter(parsing: b("120").span.bytes) == .seconds(120))
        #expect(try HTTPRetryAfter(parsing: b("Fri, 31 Dec 1999 23:59:59 GMT").span.bytes) == .date(HTTPDate(secondsSince1970: 946_684_799)))
        #expect(throws: HTTPFieldValueError.invalidDate) { try HTTPRetryAfter(parsing: b("soon").span.bytes) }
    }
}

@Suite struct HostAndListTests {
    static func host(_ value: String) -> String? {
        let bytes = b(value)
        guard let host = try? HTTPHost(parsing: bytes.span.bytes) else { return nil }
        return "\(host.kind) \(text(host.host)) \(host.port.map(String.init) ?? "-")"
    }

    @Test func hosts() {
        #expect(Self.host("example.com") == "registeredName example.com -")
        #expect(Self.host("example.com:8080") == "registeredName example.com 8080")
        #expect(Self.host("example.com:") == "registeredName example.com -")
        #expect(Self.host("") == "registeredName  -", "an empty host (RFC 9112 §3.2)")
        #expect(Self.host("192.168.0.1:80") == "ipv4 192.168.0.1 80")
        #expect(Self.host("256.1.1.1") == "registeredName 256.1.1.1 -", "not a dec-octet: a reg-name, as RFC 3986 reads it")
        #expect(Self.host("01.1.1.1") == "registeredName 01.1.1.1 -")
        #expect(Self.host("[::1]:443") == "ipv6 ::1 443")
        #expect(Self.host("[2001:db8::7]") == "ipv6 2001:db8::7 -")
        #expect(Self.host("[::ffff:192.0.2.1]") == "ipv6 ::ffff:192.0.2.1 -")
        #expect(Self.host("[1:2:3:4:5:6:7:8]") == "ipv6 1:2:3:4:5:6:7:8 -")
        #expect(Self.host("[v1.fe80::a+en1]") == "ipFuture v1.fe80::a+en1 -")
        #expect(Self.host("ex%41mple.com") == "registeredName ex%41mple.com -")
        for invalid in ["[fe80::1%25en0]", "[1:2:3:4:5:6:7:8:9]", "[1::2::3]", "[12345::]", "[::1", "exa mple.com", "example.com:65536",
                        "example.com:80:80", "example.com:x", "ex%4mple.com", "user@example.com", "[::1]x", "[1:2:3:4:5:6:7]"] {
            #expect(Self.host(invalid) == nil, "\(invalid)")
        }
    }

    static func tokens(_ value: String) -> [String]? {
        let bytes = b(value)
        var list = HTTPTokenList(bytes.span.bytes)
        if list.isAny { return ["*"] }
        var result: [String] = []
        do throws(HTTPFieldValueError) {
            while let token = try list.next() { result.append(text(token)) }
        } catch { return nil }
        return result
    }

    @Test func tokenLists() {
        #expect(Self.tokens("Accept-Encoding, User-Agent") == ["Accept-Encoding", "User-Agent"])
        #expect(Self.tokens(" * ") == ["*"])
        #expect(Self.tokens("a b") == nil)
        let connection = b("keep-alive, Upgrade")
        let hasUpgrade = HTTPTokenList.contains(connection.span.bytes, "upgrade")
        #expect(hasUpgrade)
        let upgrade = b("HTTP/2.0, SHTTP/1.3, IRC/6.9, RTA/x11, websocket")
        var protocols = HTTPUpgradeList(upgrade.span.bytes)
        var names: [String] = []
        while let next = try? protocols.next() { names.append(text(next.name) + (optionalText(next.version).map { "/" + $0 } ?? "")) }
        #expect(names == ["HTTP/2.0", "SHTTP/1.3", "IRC/6.9", "RTA/x11", "websocket"])
    }

    @Test func forwarded() throws {
        // RFC 7239 §4's examples.
        let value = b("for=\"_gazonk\", For=\"[2001:db8:cafe::17]:4711\", for=192.0.2.60;proto=http;by=203.0.113.43, for=192.0.2.43")
        var hops = HTTPForwardedElements(value.span.bytes)
        var seen: [String] = []
        while var pairs = try hops.next() {
            var hop: [String] = []
            while let pair = try pairs.next() {
                let value = written { (writer) throws(HTTPFieldValueError) in
                    do throws(BytesError) { try pair.value.write(to: &writer) } catch { throw .outputTooSmall }
                }
                hop.append("\(text(pair.name).lowercased())=\(value ?? "?")")
            }
            seen.append(hop.joined(separator: ";"))
        }
        #expect(seen == ["for=_gazonk", "for=[2001:db8:cafe::17]:4711", "for=192.0.2.60;proto=http;by=203.0.113.43", "for=192.0.2.43"])
    }
}

@Suite struct CredentialsTests {
    static func describe(_ credentials: borrowing HTTPCredentials) -> String {
        var parts = [text(credentials.scheme)]
        if let token68 = credentials.token68 { parts.append(text(token68)) }
        var parameters = credentials.parameters
        while let parameter = parameters.next() {
            let value = written { (writer) throws(HTTPFieldValueError) in
                do throws(BytesError) { try parameter.value.write(to: &writer) } catch { throw .outputTooSmall }
            }
            parts.append("\(text(parameter.name))=\(value ?? "?")")
        }
        return parts.joined(separator: " ")
    }

    static func authorization(_ value: String) -> String? {
        let bytes = b(value)
        guard let credentials = try? HTTPCredentials(parsing: bytes.span.bytes) else { return nil }
        return describe(credentials)
    }

    static func challenges(_ value: String) -> [String]? {
        let bytes = b(value)
        var challenges = HTTPChallenges(bytes.span.bytes)
        var result: [String] = []
        do throws(HTTPFieldValueError) {
            while let challenge = try challenges.next() { result.append(describe(challenge)) }
        } catch { return nil }
        return result
    }

    @Test func authorization() throws {
        #expect(Self.authorization("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==") == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
        #expect(Self.authorization("Bearer mF_9.B5f-4.1JqM") == "Bearer mF_9.B5f-4.1JqM")
        #expect(Self.authorization("Digest username=\"Mufasa\", realm=\"http-auth@example.org\", nc=00000001")
            == "Digest username=Mufasa realm=http-auth@example.org nc=00000001")
        #expect(Self.authorization("Custom a = 1 , b=\"x\"") == "Custom a=1 b=x", "BWS around `=` in auth-params")
        #expect(Self.authorization("Basic") == "Basic")
        #expect(Self.authorization("Basic a b") == nil)
        #expect(Self.authorization("Digest a=1, Basic") == nil, "one set of credentials")
        let basic = b("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
        let credentials = try HTTPCredentials(parsing: basic.span.bytes)
        #expect(written { (writer) throws(HTTPFieldValueError) in try credentials.writeBasicUserPass(to: &writer) } == "Aladdin:open sesame")
    }

    @Test func challenges() {
        // RFC 9110 §11.6.1's example, and a list's ambiguous commas.
        #expect(Self.challenges("Basic realm=\"simple\", Newauth realm=\"apps\", type=1, title=\"Login to \\\"apps\\\"\"")
            == ["Basic realm=simple", "Newauth realm=apps type=1 title=Login to \"apps\""])
        #expect(Self.challenges("Bearer, Basic realm=\"x\"") == ["Bearer", "Basic realm=x"])
        #expect(Self.challenges("Negotiate a87421000492aa874209af8bc028, Basic realm=\"x\"") == ["Negotiate a87421000492aa874209af8bc028", "Basic realm=x"])
        #expect(Self.challenges("Basic realm=\"x\", charset=\"UTF-8\"") == ["Basic realm=x charset=UTF-8"])
        #expect(Self.challenges("Basic realm=\"x\",, Bearer realm=\"y\"") == ["Basic realm=x", "Bearer realm=y"])
        #expect(Self.challenges("Negotiate , Basic realm=\"x\"") == ["Negotiate", "Basic realm=x"])
        #expect(Self.challenges("Basic realm=") == ["Basic realm="], "a token68 with its padding")
        #expect(Self.challenges("Basic realm=\"x") == nil)
        #expect(Self.challenges("Basic realm=x y") == nil)
    }
}

@Suite struct DispositionCookieTargetTests {
    static func fileName(_ value: String) -> String?? {
        let bytes = b(value)
        guard let disposition = try? HTTPContentDisposition(parsing: bytes.span.bytes) else { return .none }
        var found = false
        let name = written { (writer) throws(HTTPFieldValueError) in found = try disposition.writeFileName(to: &writer) }
        return .some(found ? name : nil)
    }

    /// Go's mime tests for Content-Disposition. Differences: an escaped byte in a quoted string is the byte (RFC 9110's
    /// quoted-pair; Go keeps the backslash before other than `"` and `\`, as browsers do); no whitespace before `=`
    /// (RFC 9110 §5.6.6); RFC 2231 continuations (`title*0=`) aren't HTTP's (RFC 8187 dropped them).
    @Test func contentDisposition() {
        #expect(Self.fileName("attachment; filename=\"foo.html\"") == "foo.html")
        #expect(Self.fileName("attachment; filename=foo.html") == "foo.html")
        #expect(Self.fileName("attachment; filename=foo.html ;") == "foo.html")
        #expect(Self.fileName("attachment; FILENAME=\"foo.html\"") == "foo.html")
        #expect(Self.fileName("attachment; foo=\"bar\"; filename=\"foo.html\"") == "foo.html")
        #expect(Self.fileName("attachment; filename=\"\\\"quoting\\\" tested.html\"") == "\"quoting\" tested.html")
        #expect(Self.fileName("attachment; filename=\"Here's a semicolon;.html\"") == "Here's a semicolon;.html")
        #expect(Self.fileName("attachment; filename=\"foo-ä.html\"") == "foo-ä.html")
        #expect(Self.fileName("attachment; filename=\"foo-%41.html\"") == "foo-%41.html")
        #expect(Self.fileName("attachment; filename=\"f\\oo.html\"") == "foo.html")
        #expect(Self.fileName("attachment; filename*=UTF-8''foo-%c3%a4-%e2%82%ac.html") == "foo-ä-€.html")
        #expect(Self.fileName("attachment; filename*=iso-8859-1'en'%A3%20rates") == "£ rates")
        #expect(Self.fileName("attachment; filename=\"EURO rates\"; filename*=utf-8''%e2%82%ac%20rates") == "€ rates", "RFC 6266's example")
        #expect(Self.fileName("attachment; filename=\"plain\"; filename*=koi8-r''x") == "plain", "an unknown charset falls back")
        // Review: duplicate parameters are invalid (RFC 6266 §4.1); decoded names are UTF-8 without controls.
        #expect(Self.fileName("attachment; filename=\"a.txt\"; filename=\"evil.exe\"") == .none)
        #expect(Self.fileName("attachment; filename*=UTF-8''a; FILENAME*=UTF-8''b") == .none)
        #expect(Self.fileName("attachment; filename=\"ok\"; filename*=UTF-8''%00%2F..%2Fx%0D%0A") == "ok")
        #expect(Self.fileName("attachment; filename=\"ok\"; filename*=UTF-8''%FF%FE") == "ok")
        #expect(Self.fileName("attachment; filename=\"ok\"; filename*=UTF-8''%E2%82") == "ok", "a cut sequence")
        #expect(Self.fileName("attachment; filename=\"ok\"; filename*=UTF-8''%C2%85") == "ok", "a C1 control")
        #expect(Self.fileName("attachment; filename=\"ok\"; filename*=ISO-8859-1''%85") == "ok")
        #expect(Self.fileName("attachment; filename=\"tab\there\"") == .some(nil), "a plain name with a control is refused")
        #expect(Self.fileName("attachment") == .some(nil))
        #expect(Self.fileName("ATTACHMENT") == .some(nil))
        for invalid in ["filename=foo.html", "x=y; filename=foo.html", "; filename=foo.html", "inline; attachment; filename=foo.html",
                        "attachment; filename=\"foo.html\".txt", "attachment; filename=\"bar", "attachment; filename=foo\"bar;baz\"qux",
                        "attachment; filename=foo.html, attachment; filename=bar.html", "attachment; foo=foo filename=bar",
                        "attachment filename=bar", "attachment; filename =\"foo.html\""] {
            #expect(Self.fileName(invalid) == .none, "\(invalid)")
        }
    }

    @Test func cookies() throws {
        let value = b("SID=31d4d96e407aad42; lang=en-US;  quoted=\"a b\" ; novalue; =x; empty=")
        var cookies = HTTPCookies(value.span.bytes)
        var seen: [String] = []
        while let cookie = cookies.next() { seen.append("\(text(cookie.name))=\(text(cookie.value))") }
        #expect(seen == ["SID=31d4d96e407aad42", "lang=en-US", "quoted=a b", "empty="])
        let langName = b("lang")
        let lang = optionalText(HTTPCookies.value(named: langName.span.bytes, in: value.span.bytes))
        #expect(lang == "en-US")

        let name = b("SID"), token = b("31d4d96e407aad42"), path = b("/"), domain = b("example.com")
        var cookie = HTTPSetCookie(name: name.span.bytes, value: token.span.bytes)
        cookie.path = path.span.bytes
        cookie.domain = domain.span.bytes
        cookie.maxAge = 3600
        cookie.expires = HTTPDate(secondsSince1970: 1_294_706_642)
        cookie.isSecure = true
        cookie.isHTTPOnly = true
        cookie.sameSite = .lax
        #expect(written { (writer) throws(HTTPFieldValueError) in try cookie.write(to: &writer) }
            == "SID=31d4d96e407aad42; Expires=Tue, 11 Jan 2011 00:44:02 GMT; Max-Age=3600; Domain=example.com; Path=/; Secure; HttpOnly; SameSite=Lax")
        for (badName, badValue) in [("a b", "x"), ("a", "x y"), ("a", "x;y"), ("a", "x,y"), ("a", "\"x"), ("", "x")] {
            let n = b(badName), v = b(badValue)
            let bad = HTTPSetCookie(name: n.span.bytes, value: v.span.bytes)
            #expect(written { (writer) throws(HTTPFieldValueError) in try bad.write(to: &writer) } == nil, "\(badName)=\(badValue)")
        }
        var noneInsecure = HTTPSetCookie(name: name.span.bytes, value: token.span.bytes)
        noneInsecure.sameSite = HTTPSetCookie.SameSite.none
        #expect(written { (writer) throws(HTTPFieldValueError) in try noneInsecure.write(to: &writer) } == nil)
    }

    static func components(_ target: String) -> String {
        let bytes = b(target)
        let parts = HTTPTargetComponents(bytes.span.bytes)
        var segments = parts.pathSegments
        var path: [String] = []
        while let segment = segments.next() { path.append(text(segment)) }
        var items = parts.queryItems
        var query: [String] = []
        while let item = items.next() { query.append(text(item.name) + (optionalText(item.value).map { "=" + $0 } ?? "")) }
        return "\(parts.form) \(optionalText(parts.scheme) ?? "-") \(optionalText(parts.authority) ?? "-") [\(path.joined(separator: "|"))] "
            + "\(parts.query == nil ? "-" : "[" + query.joined(separator: "|") + "]")"
    }

    @Test func targets() throws {
        #expect(Self.components("/where?q=now&x") == "origin - - [where] [q=now|x]")
        #expect(Self.components("/a//b/") == "origin - - [a||b|] -")
        #expect(Self.components("/") == "origin - - [] -")
        #expect(Self.components("/?") == "origin - - [] []")
        #expect(Self.components("http://www.example.org/pub/WWW/TheProject.html") == "absolute http www.example.org [pub|WWW|TheProject.html] -")
        #expect(Self.components("http://example.org?a=1&&b=") == "absolute http example.org [] [a=1|b=]")
        #expect(Self.components("www.example.com:80") == "absolute www.example.com - [80] -", "authority-form only for CONNECT")
        #expect(Self.components("*") == "asterisk - - [] -")
        // Review: the same form as `HTTPRequestTarget.validate` gives (authority-form is CONNECT's).
        for (target, expected) in [("http:foo", "absolute http - [foo] -"), ("urn:isbn:123", "absolute urn - [isbn:123] -"),
                                   ("example.com:443", "absolute example.com - [443] -"), ("http:/path?x", "absolute http - [path] [x]")] {
            #expect(Self.components(target) == expected)
            let bytes = b(target)
            let form = try? HTTPRequestTarget.validate(bytes.span.bytes, method: nil)
            #expect(form == .absolute, "\(target)")
        }
        let connect = b("www.example.com:443")
        let parts = HTTPTargetComponents(connect.span.bytes, method: .connect)
        #expect(parts.form == .authority)
        #expect(optionalText(parts.authority) == "www.example.com:443")
        #expect(Self.components("/path#fragment") == "origin - - [path] -")

        let encoded = b("/caf%C3%A9%20menu%2Fx+y")
        #expect(written { (writer) throws(HTTPFieldValueError) in try HTTPPercentEncoding.decode(encoded.span.bytes, to: &writer) } == "/café menu/x+y")
        let decodedCount = try HTTPPercentEncoding.decodedByteCount(encoded.span.bytes)
        #expect(decodedCount == 15)
        for invalid in ["%", "%4", "%G0", "a%0g"] {
            let bytes = b(invalid)
            #expect(written { (writer) throws(HTTPFieldValueError) in try HTTPPercentEncoding.decode(bytes.span.bytes, to: &writer) } == nil, "\(invalid)")
        }
    }
}
