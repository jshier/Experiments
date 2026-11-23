import HTTP1
import HTTPBytes
import Testing

/// picohttpparser's test.c (h2o/picohttpparser at dd573d8, MIT), as the picohttpparser-cases set has it: its request,
/// response, and header-block tests (heads only, as picohttpparser parses them: each case stops after the head and its
/// framing) and its chunked-decoder tests (each body after a chunked request head, through ``HTTP1ChunkedDecoder``,
/// compared with the data picohttpparser decodes). Where HTTPBytes decides differently on purpose, the case is in
/// `differences` with why.
@Suite struct PicoHTTPParserTests {
    static let cases = ConformanceCase.load(set: "picohttpparser-cases")

    static let differences: [String: String] = [
        "request: parse multiline": "obsolete line folding is rejected (RFC 9112 §5.2 lets a server reject it with 400)",
        "response: parse multiline": "obsolete line folding is rejected (RFC 9112 §5.2)",
        "request: accept MSB chars":
            "a request target is ASCII (RFC 9112 §3.2, RFC 3986): bytes 0x80 and above are rejected (in a field value they're obs-text, accepted)",
        "request: accept multiple spaces between tokens":
            "one SP between the request line's parts (RFC 9112 §3); recipients MAY split on runs of whitespace, HTTPBytes doesn't",
        "response: accept multiple spaces between tokens": "one SP between the status line's parts (RFC 9112 §4)",
        "response: status code above 599":
            "600–999 are three digits, accepted: RFC 9110 §15 says a client SHOULD process an out-of-range code as a 5xx, not reject the response",
        "response: incomplete 11": "bare LF line ends need allowsBareLineFeed (RFC 9112 §2.2's MAY; off by default)",
        "chunked: consume_trailer=1 b\\x0D\\x0Ahello world\\x0D\\x0A0\\x0D\\x0A\\x0A":
            "bare LF ends the trailer section only with allowsBareLineFeed",
        "chunked: consume_trailer=1 6\\x0D\\x0Ahello \\x0D\\x0A5\\x0D\\x0Aworld\\x0D\\x0A0\\x0D\\x0Aa: b\\x0Ac: d\\x0A\\x0A":
            "bare LF in trailers only with allowsBareLineFeed",
        "chunked: failure 6\\x0D\\x0Ahello \\x0D\\x0Affffffffffffffff\\x0D\\x0Aabcdefg":
            "16 hexadecimal digits are rejected (at most 15: no chunk is larger); picohttpparser takes 2⁶⁴−1 and waits for it",
    ]

    static let head = Array("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)

    static func outcome(_ testCase: ConformanceCase) -> Conformance.Outcome {
        var options = Conformance.Options()
        switch testCase.kind {
        case "chunked":
            return Conformance.parse(head + testCase.input)
        case "headers":
            options.headOnly = true
            return Conformance.parse(Array("GET / HTTP/1.1\r\n".utf8) + testCase.input, options: options)
        case "response":
            options.headOnly = true
            return Conformance.parse(testCase.input, as: .response(requestMethod: .get), options: options)
        default:
            options.headOnly = true
            return Conformance.parse(testCase.input, options: options)
        }
    }

    @Test func agreesWithPicoHTTPParser() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch picohttpparser picohttpparser-cases")
        var report: [String] = []
        for testCase in Self.cases {
            let outcome = Self.outcome(testCase)
            var line = Conformance.compare(key: testCase.key, input: testCase.input, ours: outcome, expected: testCase.verdict,
                                           differences: Self.differences)
            if line == nil, Self.differences[testCase.key] == nil, let decoded = testCase.bytes("decoded"), let message = outcome.message,
               message.body != decoded {
                line = "\(testCase.key): body \(Conformance.escaped(message.body)); picohttpparser \(Conformance.escaped(decoded))"
            }
            if let line { report.append(line) }
        }
        #expect(Self.cases.count > 90)
        #expect(report.isEmpty, "\(report.count) of \(Self.cases.count):\n\(report.joined(separator: "\n"))")
    }
}
