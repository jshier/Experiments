import HTTP1
import HTTPBytes
import Testing

/// httparse's tests (seanmonstar/httparse at a0fa552, MIT/Apache-2.0): its `req!` and `res!` tests from src/lib.rs, and
/// tests/uri.rs, 263 request lines whose targets come from the WHATWG URL tests, as the httparse-cases set has them.
/// httparse parses heads only, so each case stops after the head and its framing; accepted requests also compare the
/// target with the path httparse asserts. Where HTTPBytes decides differently on purpose, the case is in `differences`
/// with why; where it falls short of RFC 9112, in `knownIssues`.
@Suite struct HTTParseTests {
    static let cases = ConformanceCase.load(set: "httparse-cases")

    static let differences: [String: String] = [
        // Bare LF line ends: RFC 9112 §2.2 lets a recipient accept them; HTTPBytes doesn't unless `allowsBareLineFeed`.
        "lib.rs: test_request_newlines": "bare LF line ends (allowsBareLineFeed, off by default)",
        "lib.rs: test_request_empty_lines_prefix_lf_only": "bare LF line ends",
        "lib.rs: test_request_path_backslash": "bare LF line ends (the backslashes are fine)",
        "lib.rs: test_response_newlines": "bare LF line ends",
        "lib.rs: test_response_empty_lines_prefix_lf_only": "bare LF line ends",
        "lib.rs: test_response_no_cr": "bare LF line ends",
        "lib.rs: test_request_with_invalid_but_short_version":
            "the version is judged once its 8 bytes are there: `HTTP/1!` (7 bytes) waits for one more, then is rejected",
    ]

    /// Where HTTPBytes doesn't do what RFC 9112 calls for.
    static let knownIssues: [String: String] = [:]

    static func outcome(_ testCase: ConformanceCase) -> Conformance.Outcome {
        var options = Conformance.Options()
        options.headOnly = true
        return Conformance.parse(testCase.input, as: testCase.kind == "response" ? .response(requestMethod: .get) : .request, options: options)
    }

    @Test func agreesWithHTTParse() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch httparse httparse-cases")
        var report: [String] = []
        for testCase in Self.cases {
            let outcome = Self.outcome(testCase)
            var line = Conformance.compare(key: testCase.key, input: testCase.input, ours: outcome, expected: testCase.verdict,
                                           differences: Self.differences)
            if line == nil, let path = testCase.bytes("path"), let message = outcome.message, message.target != path {
                line = "\(testCase.key): target \(Conformance.escaped(message.target)); httparse's path \(Conformance.escaped(path))"
            }
            guard let line else { continue }
            if let issue = Self.knownIssues[testCase.key] {
                withKnownIssue(Comment(rawValue: issue)) { Issue.record(Comment(rawValue: line)) }
            } else {
                report.append(line)
            }
        }
        #expect(Self.cases.count > 300)
        #expect(report.isEmpty, "\(report.count) of \(Self.cases.count):\n\(report.joined(separator: "\n"))")
    }

    /// Whether `target` is one of RFC 9112 §3.2's request-target forms for a request with `method`: origin-form
    /// (`/` path, then `?` query), absolute-form (scheme `:` …), authority-form (`host:port`, CONNECT only), or `*`
    /// (OPTIONS only), with RFC 3986's characters and percent-encoding. A reference for the URI cases, not a URI parser.
    static func isRequestTarget(_ target: [UInt8], method: [UInt8]) -> Bool {
        func isAlpha(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        func isHex(_ byte: UInt8) -> Bool { isDigit(byte) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66) }
        /// unreserved, sub-delims, `:`, `@`, and the extra characters given; `%` only before two hex digits.
        func valid(_ bytes: ArraySlice<UInt8>, extra: String) -> Bool {
            var index = bytes.startIndex
            while index < bytes.endIndex {
                let byte = bytes[index]
                if byte == 0x25 {
                    guard index + 2 < bytes.endIndex, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                    index += 3
                    continue
                }
                guard isAlpha(byte) || isDigit(byte) || "-._~!$&'()*+,;=:@".utf8.contains(byte) || extra.utf8.contains(byte) else {
                    return false
                }
                index += 1
            }
            return true
        }
        if target == [0x2A] { return method == Array("OPTIONS".utf8) }
        if target.first == 0x2F { return valid(target[...], extra: "/?") && target.firstIndex(of: 0x3F).map { valid(target[$0...], extra: "/?") } ?? true }
        if method == Array("CONNECT".utf8) {
            guard let colon = target.lastIndex(of: 0x3A), colon > 0, target[(colon + 1)...].allSatisfy(isDigit) else { return false }
            return valid(target[..<colon], extra: "[]") && !target[..<colon].contains(0x40)
        }
        guard let colon = target.firstIndex(of: 0x3A), colon > 0, isAlpha(target[0]),
              target[..<colon].allSatisfy({ isAlpha($0) || isDigit($0) || "+-.".utf8.contains($0) }) else { return false }
        return valid(target[(colon + 1)...], extra: "/?[]")
    }

    /// httparse accepts any visible ASCII as a target, and so does HTTPBytes' parser by default (`validatesTargets` is off).
    /// These are the uri.rs targets both accept that aren't any of RFC 9112's forms (a gap: RFC 9112 §3.2 says a server
    /// SHOULD respond 400 to an invalid request-target).
    @Test func acceptedTargetsAreRequestTargets() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch httparse httparse-cases")
        var invalid: [String] = []
        var accepted = 0
        for testCase in Self.cases where testCase.source == "uri.rs" {
            guard let message = Self.outcome(testCase).message else { continue }
            accepted += 1
            if !Self.isRequestTarget(message.target, method: message.method) {
                invalid.append("\(testCase.name): \(Conformance.escaped(message.target))")
            }
        }
        #expect(accepted > 250)
        // The reference itself: forms it must accept and reject.
        #expect(Self.isRequestTarget(Array("/a/b%20c?d=e/f?".utf8), method: Array("GET".utf8)))
        #expect(Self.isRequestTarget(Array("https://example.com:443/".utf8), method: Array("GET".utf8)))
        #expect(Self.isRequestTarget(Array("example.com:443".utf8), method: Array("CONNECT".utf8)))
        #expect(!Self.isRequestTarget(Array("/a%2z".utf8), method: Array("GET".utf8)))
        #expect(!Self.isRequestTarget(Array("x@x.com".utf8), method: Array("GET".utf8)))
        withKnownIssue("the request target's form isn't checked (RFC 9112 §3.2)") {
            #expect(invalid.isEmpty, "\(invalid.count) of \(accepted) accepted targets aren't request-targets:\n\(invalid.joined(separator: "\n"))")
        }
    }
}
