import HTTP1
import HTTPBytes
import Testing

/// HTTP Garden's trophies (narfindustries/http-garden's TROPHIES.md at b417e80, GPL-3.0: fetched into TestData by the
/// http-garden set, never checked in): the payload of every parser bug the Garden found in real servers and proxies,
/// mostly request smuggling, as cursed-http's extract.py takes them out (the cursed-http-cases set, source `garden`).
///
/// The Garden gives no verdict, since these are where real implementations disagreed: `expected` gives each payload the
/// verdict RFC 9112 (and RFC 9110 for field syntax) calls for, with the rule. For an accepted payload, `@N` is where the
/// first request must end, so a pipelined request after it starts where a strict reader would start it. Only the bytes'
/// parsing and framing are judged: `Host` isn't required (RFC 9112 §3.2's 400 for a missing `Host` is the server's
/// separate check, `HTTP1Framing.validateHost`, and many payloads leave it out because their targets don't care).
/// Payloads that aren't literal bytes in TROPHIES.md ("any request at all") aren't in the set.
@Suite struct HTTPGardenTests {
    static let cases = ConformanceCase.load(set: "cursed-http-cases").filter { $0.source == "garden" }

    /// "section bug N" from "garden/section bug N: title".
    static func id(_ testCase: ConformanceCase) -> String {
        let name = testCase.name.dropFirst("garden/".count)
        return String(name[..<(name.firstIndex(of: ":") ?? name.endIndex)])
    }

    /// The verdict RFC 9112 calls for, and the rule.
    static let expected: [String: (verdict: String, rule: String)] = [
        "server bug 1": ("reject", "chunk-size = 1*HEXDIG (§7.1): `0_2e` isn't one"),
        "server bug 2": ("reject", "NUL and CR in a field value (RFC 9110 §5.5: reject or replace; §2.2 bare CR)"),
        "server bug 3": ("reject", "whitespace before the colon: a server MUST reject with 400 (§5.1)"),
        "server bug 4": ("reject", "whitespace before the first field line: reject, or drop the line (§2.2)"),
        "server bug 5": ("reject", "HTTP-version = HTTP-name \"/\" DIGIT \".\" DIGIT (§2.3): `1.32` isn't one"),
        "server bug 6": ("reject", "method = token (RFC 9110 §9.1): `\"`, `:`, `<` aren't token characters"),
        "server bug 7": ("reject", "`!` is none of the four request-target forms (§3.2): a server SHOULD respond 400"),
        "server bug 8": ("reject", "field-name = token (RFC 9110 §5.1): 0xEF isn't a token character"),
        "server bug 9": ("reject", "the request line's parts are separated by SP (§3); LF ends a line"),
        "server bug 10": ("reject", "Content-Length = 1*DIGIT (RFC 9110 §8.6); invalid: 400 (§6.3)"),
        "server bug 11": ("reject", "chunked applied twice (§6.1: a sender MUST NOT); framing can't be trusted"),
        "server bug 12": ("reject", "`\\xA0chunked\\xA0` isn't chunked: the final coding isn't chunked, 400 (§6.3)"),
        "server bug 13": ("reject", "a bare CR in a field line (§2.2)"),
        "server bug 14": ("reject", "field-name = token"),
        "server bug 15": ("reject", "HTTP-version syntax (§2.3)"),
        "server bug 16": ("reject", "Content-Length = 1*DIGIT: empty is invalid (§6.3)"),
        "server bug 17": ("reject", "chunk-size = 1*HEXDIG: empty is invalid"),
        "server bug 18": ("reject", "field-name = token: at least one character"),
        "server bug 19": ("reject", "bare LF line ends: a recipient MAY accept them (§2.2); HTTPBytes doesn't by default"),
        "server bug 20": ("reject", "field-name = token: 0x85 isn't a token character"),
        "server bug 21": ("reject", "Transfer-Encoding and Content-Length together in a request: rejected (§6.1, §6.3)"),
        "server bug 22": ("reject", "chunk-size = 1*HEXDIG"),
        "server bug 23": ("reject", "differing Content-Length values: invalid, 400 (§6.3)"),
        "server bug 24": ("reject", "HTTP-version syntax"),
        "server bug 25": ("partial", "a chunked request whose chunks haven't arrived"),
        "server bug 26": ("reject", "Content-Length = 1*DIGIT: no sign"),
        "server bug 27": ("reject", "field-name = token: at least one character"),
        "server bug 28": ("reject", "a field line without a colon (§5)"),
        "server bug 29": ("reject", "Content-Length = 1*DIGIT"),
        "server bug 30": ("reject", "a bare CR (§2.2): `\\r\\n\\rZ` doesn't end the head"),
        "server bug 31": ("reject", "a bare CR in a chunk-size line"),
        "server bug 32": ("partial", "`010` is 1*DIGIT, ten (leading zeros are digits): 8 of 10 body bytes have arrived"),
        "server bug 33": ("reject", "differing Content-Length values (§6.3)"),
        "server bug 34": ("reject", "a bare CR in a field value"),
        "server bug 35": ("reject", "NUL in a field value (RFC 9110 §5.5)"),
        "server bug 36": ("reject", "a bare CR in chunk extensions"),
        "server bug 37": ("reject", "`Transfer-` is a field line without a colon"),
        "server bug 38": ("reject", "Content-Length = 1*DIGIT: empty is invalid"),
        "server bug 39": ("accept@70", "`X:POST / HTTP/1.1` after the last chunk is a trailer field (§7.1.2): the message ends after it"),
        "server bug 40": ("reject", "method = token; HTTP-version syntax"),
        "server bug 41": ("accept@47", "0x85 and 0xA0 are obs-text, allowed in field values (RFC 9110 §5.5) and kept"),
        "server bug 42": ("reject", "an empty Content-Length is invalid, and the values differ"),
        "server bug 43": ("reject", "NUL in a field value"),
        "server bug 44": ("reject", "`blegh` isn't chunked: the final coding isn't chunked, 400 (§6.3)"),
        "server bug 45": ("accept@37", "the first request ends at its head; `Invalid` is the next message's problem"),
        "server bug 46": ("reject", "`\\xFFchunked\\xFF` isn't chunked (§6.3); `\\xFFa\\xFF` in Host is obs-text, fine"),
        "server bug 47": ("reject", "chunk-size = 1*HEXDIG"),
        "server bug 48": ("accept@77", "Content-Length: 0: the pipelined POST is the next request, not a body"),
        "transducer bug 1": ("reject", "Content-Length = 1*DIGIT: no `0x`"),
        "transducer bug 2": ("reject", "chunk-size = 1*HEXDIG: `Z` isn't one"),
        "transducer bug 3": ("reject", "a bare CR before chunk extensions"),
        "transducer bug 4": ("reject", "two spaces before the version (§3: one SP)"),
        "transducer bug 5": ("reject", "Content-Length = 1*DIGIT: empty is invalid"),
        "transducer bug 6": ("reject", "field-name = token"),
        "transducer bug 7": ("reject", "chunk-size then `these-bytes…`: neither extensions nor the line end"),
        "transducer bug 9": ("accept@62", "empty list elements are ignored (RFC 9110 §5.6.1): `,chunked` is chunked"),
        "transducer bug 10": ("reject", "bare CRs in a field value"),
        "transducer bug 11": ("reject", "an empty Content-Length is invalid, and the values differ"),
        "transducer bug 12": ("reject", "NUL in a field value"),
        "transducer bug 13": ("reject", "chunk-data is followed by CRLF (§7.1); HTTPBytes takes no bare LF there by default"),
        "transducer bug 14": ("reject", "a field line without a colon"),
        "transducer bug 15": ("reject", "Transfer-Encoding and Content-Length together in a request"),
        "transducer bug 16": ("reject", "bare LF line ends: a recipient MAY accept them; HTTPBytes doesn't by default"),
        "transducer bug 17": ("reject", "after a 0x17-byte chunk and its CRLF, an empty chunk-size line"),
        "transducer bug 18": ("reject", "Transfer-Encoding and Content-Length together in a request"),
        "transducer bug 19": ("reject", "chunk-size = 1*HEXDIG: no sign or `0x`"),
        "transducer bug 20": ("reject", "field-name = token: `c\\x00` with no colon"),
        "transducer bug 21": ("accept@48", "a GET with a Content-Length has that body (§6.3)"),
        "transducer bug 22": ("reject", "differing Content-Length values"),
        "transducer bug 23": ("reject", "Transfer-Encoding and Content-Length together in a request"),
        "transducer bug 24": ("reject", "chunk-size = 1*HEXDIG: no leading whitespace"),
        "transducer bug 25": ("reject", "chunked applied twice"),
        "bonus bug 1": ("accept@67", "the chunked body ends at its empty trailer section; the NUL after it starts the next message"),
        "bonus bug 4": ("accept@74", "a well-formed chunked request"),
        "bonus bug 5": ("reject", "HTTP/2.0's preface isn't an HTTP/1 request: a version HTTP/1 doesn't speak (505)"),
        "bonus-bonus bug 2": ("reject", "HTTP/2.0's preface isn't an HTTP/1 request (505)"),
    ]

    /// Payloads where HTTPBytes doesn't do what RFC 9112 calls for: gaps, reported rather than fixed here.
    static let knownIssues: [String: String] = [
        "server bug 7": "the request target's form isn't checked: any 0x21–0x7E bytes are accepted (RFC 9112 §3.2)",
    ]

    static func verdict(_ outcome: Conformance.Outcome) -> String {
        if case let .accept(message) = outcome { return "accept@\(message.end)" }
        return outcome.verdict
    }

    @Test func everyPayloadGetsTheRFCsVerdict() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch cursed-http llhttp-tests http-garden picohttpparser httparse cursed-http-cases")
        var report: [String] = []
        for testCase in Self.cases {
            let id = Self.id(testCase)
            guard let (expected, rule) = Self.expected[id] else {
                report.append("\(id): no verdict recorded")
                continue
            }
            let outcome = Conformance.parse(testCase.input)
            let ours = Self.verdict(outcome)
            if let issue = Self.knownIssues[id] {
                withKnownIssue(Comment(rawValue: issue)) {
                    #expect(ours == expected, "\(id): \(outcome) [\(Conformance.escaped(testCase.input))]")
                }
            } else if ours != expected {
                report.append("\(id): ours \(outcome); expected \(expected) (\(rule)) [\(Conformance.escaped(testCase.input))]")
            }
        }
        #expect(Self.cases.count == Self.expected.count)
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")
    }

    /// The field values of payload 41 come through as sent: obs-text isn't stripped (the bug was stripping it).
    @Test func obsTextIsKept() throws {
        let payload = try #require(Self.cases.first { Self.id($0) == "server bug 41" })
        let message = try #require(Conformance.parse(payload.input).message)
        #expect(message.field("User") == [0x85] + Conformance.bytes("admin") + [0xA0])
    }
}
