import HTTP1
import HTTPBytes
import Testing

/// nodejs/http-parser's test.c (at ec8b5ee, MIT), as the http-parser-cases set has it: its 77 request and response
/// messages, each read by HTTPBytes in full and compared with what http-parser expects (the body, through
/// ``HTTP1ChunkedDecoder`` or `Content-Length` or to the connection's end; keep-alive; the URL; the field count; where an
/// upgrade's or CONNECT's data starts), and its `test_simple` lines (an expected error: reject; HPE_OK: no error, complete
/// or not). Where HTTPBytes decides differently on purpose, the case is in `differences` with why.
@Suite struct HTTPParserTests {
    static let cases = ConformanceCase.load(set: "http-parser-cases")

    static let differences: [String: String] = [
        "requests: request with no http version": "HTTP/0.9 isn't supported (RFC 9112 has no request line without a version)",
        "requests: line folding in header value": "obsolete line folding is rejected (RFC 9112 §5.2 lets a server reject it)",
        "requests: line folding in header value (2)": "bare LF line ends (allowsBareLineFeed, off by default), and obsolete line folding",
        "requests: multiple connection header values with folding": "obsolete line folding is rejected (RFC 9112 §5.2)",
        "requests: multiple connection header values with folding and lws (2)": "obsolete line folding is rejected (RFC 9112 §5.2)",
        "requests: post - multi line coding transfer-encoding chunked body": "obsolete line folding is rejected (RFC 9112 §5.2)",
        "simple: #6 HPE_OK": "a whitespace-only line after a field is obsolete line folding: rejected (RFC 9112 §5.2)",
        "requests: utf-8 path request": "a request target is ASCII (RFC 9112 §3.2, RFC 3986): raw UTF-8 is rejected",
        "requests: source request (2)": "ICE isn't HTTP",
        "responses: http version 0.9": "HTTP/0.9 isn't HTTP/1 (rejected as unsupported)",
        "requests: post - multi coding transfer-encoding chunked body":
            "501: a coding besides chunked isn't implemented (RFC 9112 §6.1); http-parser leaves it to its user",
        "requests: chunked with content-length set, allow_chunked_length flag is set":
            "both framing fields: rejected (RFC 9112 §6.1); http-parser accepts them only with its allow_chunked_length leniency",
        "responses: no carriage ret": "bare LF line ends need allowsBareLineFeed (RFC 9112 §2.2's MAY; off by default)",
        "responses: proxy connection":
            "Proxy-Connection isn't a standard field (RFC 9110 defines only Connection): it doesn't close the connection",
        "responses: field space": "`en-US Content-Type` isn't a token: a field name with a space is rejected (RFC 9112 §5.1)",
        "responses: HTTP 101 response with Upgrade and Content-Length header":
            "a 1xx response ends at its empty line whatever its fields say (RFC 9112 §6.3 item 1): `body` is the new protocol's data",
        "responses: HTTP 101 response with Upgrade and Transfer-Encoding header":
            "a 1xx response ends at its empty line whatever its fields say (RFC 9112 §6.3 item 1)",
        "requests: connect with body request":
            "a CONNECT with a nonzero Content-Length is rejected (RFC 9110 §9.3.6: CONNECT has no content; http-parser hands the bytes to the tunnel, a front end framing by Content-Length would forward them as a body)",
        "responses: 200 trailing space on chunked body":
            "whitespace after a chunk size without a `;` isn't in RFC 9112 §7.1's grammar: rejected, as llhttp's strict mode does (http-parser and h11 accept it)",
    ]

    /// Where HTTPBytes falls short of RFC 9112.
    static let knownIssues: [String: String] = [:]

    static func kind(_ testCase: ConformanceCase) -> Conformance.Kind {
        testCase.kind == "response" ? .response(requestMethod: .get) : .request
    }

    /// What differs from http-parser's expectations, or nothing.
    static func problems(_ testCase: ConformanceCase) -> [String] {
        var options = Conformance.Options()
        options.closesAtEnd = testCase.extras["eof"] == "1"
        let outcome = Conformance.parse(testCase.input, as: kind(testCase), options: options)
        if testCase.verdict == "noerror" {
            if case .reject = outcome { return ["ours \(outcome); http-parser no error (\(testCase.extras["error"] ?? ""))"] }
            return []
        }
        guard outcome.verdict == testCase.verdict else {
            return ["ours \(outcome); http-parser \(testCase.verdict) \(testCase.extras["error"] ?? "")"]
        }
        guard let message = outcome.message else { return [] }
        var problems: [String] = []
        if let body = testCase.bytes("body"), message.body != body {
            problems.append("body \(Conformance.escaped(message.body)); http-parser \(Conformance.escaped(body))")
        }
        if let size = testCase.int("bodysize"), message.body.count != size {
            problems.append("body \(message.body.count) bytes; http-parser \(size)")
        }
        if let keepAlive = testCase.extras["keepalive"], message.isPersistent != (keepAlive == "1") {
            problems.append("persistent \(message.isPersistent); http-parser \(keepAlive == "1")")
        }
        if let url = testCase.bytes("url"), message.target != url {
            problems.append("target \(Conformance.escaped(message.target)); http-parser \(Conformance.escaped(url))")
        }
        // http-parser counts trailer fields with the head's.
        if let count = testCase.int("headers"), message.fields.count + message.trailers.count != count {
            problems.append("\(message.fields.count) fields and \(message.trailers.count) trailers; http-parser \(count)")
        }
        if let status = testCase.int("status"), message.status != status {
            problems.append("status \(message.status); http-parser \(status)")
        }
        // An upgrade's or CONNECT's data follows the message: it ends where that data starts.
        if let upgrade = testCase.bytes("upgrade"), !upgrade.isEmpty, message.end != testCase.input.count - upgrade.count {
            problems.append("ends at \(message.end); http-parser's upgrade data starts at \(testCase.input.count - upgrade.count)")
        }
        return problems
    }

    @Test func agreesWithHTTPParser() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch http-parser http-parser-cases")
        var report: [String] = []
        for testCase in Self.cases {
            let problems = Self.problems(testCase)
            let line = "\(testCase.key): \(problems.joined(separator: "; ")) [\(Conformance.escaped(testCase.input, limit: 200))]"
            if let issue = Self.knownIssues[testCase.key] {
                withKnownIssue(Comment(rawValue: issue)) { #expect(problems.isEmpty, "\(line)") }
            } else if problems.isEmpty, Self.differences[testCase.key] != nil {
                report.append("\(testCase.key): listed in differences but agrees now")
            } else if !problems.isEmpty, Self.differences[testCase.key] == nil {
                report.append(line)
            }
        }
        #expect(Self.cases.count > 90)
        #expect(report.isEmpty, "\(report.count) of \(Self.cases.count):\n\(report.joined(separator: "\n"))")
    }

    /// Every message, fed in two pieces split at every byte, reads the same as whole.
    @Test func splitsDontChangeTheOutcome() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch http-parser http-parser-cases")
        for testCase in Self.cases {
            let whole = Conformance.parse(testCase.input, as: Self.kind(testCase))
            for split in 1..<max(1, testCase.input.count) {
                let pieces = Conformance.parse(testCase.input, as: Self.kind(testCase), splits: [split])
                guard pieces == whole else {
                    Issue.record("\(testCase.key) split at \(split): \(pieces); whole: \(whole)")
                    break
                }
            }
        }
    }
}
