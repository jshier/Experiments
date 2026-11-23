import HTTP1
import HTTPBytes
import Testing

/// cursed-http's conformance corpus (public/cursed-http, MIT: its conformance/extract.py gathers llhttp's, picohttpparser's,
/// and httparse's request tests with each suite's own verdict, and HTTP Garden's payloads without one), as the
/// cursed-http-cases set has it, run through HTTPBytes: accept, reject, or partial, compared with the suite's verdict.
///
/// picohttpparser and httparse parse heads only, so their cases stop after the head and its framing. llhttp's inputs come
/// out of extract.py truncated (`unjudged` says how) and HTTP Garden's have no verdict: both still run in the split test.
/// Where HTTPBytes decides differently on purpose, the case is in `differences` with why.
@Suite struct CursedHTTPConformanceTests {
    static let cases = ConformanceCase.load(set: "cursed-http-cases")

    /// Sources whose verdicts aren't compared here, with why.
    static let unjudged: [String: String] = [
        // extract.py drops the markdown block's trailing newline with Python's `re.sub(r"\n$", "", …)`, and Python's `$`
        // also matches before a final newline, so it drops two: 40-odd heads lose their last CR LF (and one case runs into
        // the prose after its block) while keeping llhttp's verdict for the whole input. LLHTTPDifferentialTests runs
        // llhttp's suite from its own markdown, made as llhttp's md-test.ts makes it.
        "llhttp": "extract.py truncates llhttp's inputs; LLHTTPDifferentialTests covers them",
        "garden": "no verdict in the suite; HTTPGardenTests gives each payload one",
    ]

    /// Deliberate disagreements, keyed by "source: name".
    static let differences: [String: String] = [
        "pico: pico/test.c: parse multiline": "obsolete line folding is rejected (RFC 9112 §5.2 lets a server reject it with 400)",
        "pico: pico/test.c: accept MSB chars":
            "a request target is ASCII (RFC 9112 §3.2, RFC 3986 §2): bytes 0x80 and above are rejected (in field values they're obs-text, accepted)",
        "pico: pico/test.c: accept multiple spaces between tokens":
            "one SP between the request line's parts (RFC 9112 §3); recipients MAY split on runs of whitespace, HTTPBytes doesn't",
        "httparse: httparse/lib.rs: test_request_newlines": "bare LF line ends need allowsBareLineFeed (RFC 9112 §2.2's MAY; off by default)",
        "httparse: httparse/lib.rs: test_request_empty_lines_prefix_lf_only": "bare LF line ends need allowsBareLineFeed",
        "httparse: httparse/lib.rs: test_request_path_backslash": "bare LF line ends need allowsBareLineFeed (the backslashes are accepted)",
        "httparse: httparse/lib.rs: test_request_with_invalid_but_short_version":
            "the version is judged as one 8-byte word once all 8 bytes are there: `HTTP/1!` (7) waits for one more byte, then is rejected",
    ]

    @Test func agreesWithEachSuitesVerdict() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch cursed-http llhttp-tests http-garden picohttpparser httparse cursed-http-cases")
        var options = Conformance.Options()
        options.headOnly = true
        var report: [String] = []
        var compared = 0
        for testCase in Self.cases where !testCase.verdict.isEmpty && Self.unjudged[testCase.source] == nil {
            compared += 1
            if let line = Conformance.compare(key: testCase.key, input: testCase.input, ours: Conformance.parse(testCase.input, options: options),
                                              expected: testCase.verdict, differences: Self.differences) {
                report.append(line)
            }
        }
        #expect(compared > 50)
        #expect(report.isEmpty, "\(report.count) of \(compared):\n\(report.joined(separator: "\n"))")
    }

    /// Every case, verdict or not, whole and split at every byte: the same outcome either way.
    @Test func splitsDontChangeTheOutcome() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch cursed-http-cases")
        var report: [String] = []
        for testCase in Self.cases {
            let whole = Conformance.parse(testCase.input)
            for split in 1..<max(1, testCase.input.count) {
                let pieces = Conformance.parse(testCase.input, splits: [split])
                if pieces != whole {
                    report.append("\(testCase.key) split at \(split): \(pieces); whole: \(whole)")
                    break
                }
            }
        }
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")
    }
}
