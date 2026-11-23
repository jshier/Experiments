import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// llhttp's test suite again (the llhttp-cases set), judged on whole messages rather than heads: llhttp's verdict is
/// "message complete" before any error (accept), an error first (reject), or neither (partial: the input ended, as a
/// body read until close does without EOF). HTTPBytes reads each message in full: head, framing, then the body through
/// ``HTTP1ChunkedDecoder`` or `Content-Length`. This is what checks chunked bodies (sizes, extensions, chunk ends,
/// trailers) against llhttp; LLHTTPDifferentialTests checks heads. Only llhttp's strict types.
@Suite struct LLHTTPMessageTests {
    static let cases = LLHTTPDifferentialTests.cases.filter { $0.type == "request" || $0.type == "response" }

    /// llhttp-cases' last column: whether llhttp reached "message complete" before an error.
    static let completes: [String: Bool] = {
        guard let url = try? TestData.file(set: "llhttp-cases", name: "cases.tsv"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var completes: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            completes["\(columns[0]): \(columns[1]): \(columns[3])"] = columns[7] == "1"
        }
        return completes
    }()

    static func llhttp(_ testCase: LLHTTPDifferentialTests.Case) -> String {
        let hex = testCase.input.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
        if completes["\(testCase.file): \(testCase.title): \(hex)"] == true { return "accept" }
        return testCase.errorOffset >= 0 ? "reject" : "partial"
    }

    /// Head-level differences carry over from LLHTTPDifferentialTests; these are the body-level ones.
    static let differences: [String: String] = [
        "request/method: CONNECT with body":
            "a CONNECT with a nonzero Content-Length is rejected (RFC 9110 §9.3.6: CONNECT has no content; the bytes would be a body to one reader and the next request to another)",
        // llhttp checks `Content-Length` as its digits arrive; HTTPBytes checks a field once its line has ended. These inputs
        // end inside the line, so llhttp has already failed and HTTPBytes waits for the line end (and then rejects).
        "request/content-length: Error on `Content-Length` overflow": "framing fields are judged once their line ends",
        "request/content-length: Error on duplicate `Content-Length`": "framing fields are judged once their line ends",
        // `skipBody` (dropped by make-cases.pl with the rest of the meta): llhttp was told the message has no body.
        "request/content-length: Content-Length reset when no body is received": "llhttp ran with skipBody",
        "response/content-length: Content-Length reset when no body is received": "llhttp ran with skipBody",
    ]

    /// Where HTTPBytes falls short of RFC 9112.
    static let knownIssues: [String: String] = [
        "request/transfer-encoding: No semicolon before chunk extensions": chunkExtensions,
        "request/transfer-encoding: No extension after semicolon": chunkExtensions,
        "request/transfer-encoding: Unbalanced chunk extensions quoting": chunkExtensions,
        "request/transfer-encoding: Space after chunk header": chunkExtensions,
        "response/transfer-encoding: Trailing space on chunked body": chunkExtensions,
        "response/transfer-encoding: No semicolon before chunk extensions": chunkExtensions,
        "response/transfer-encoding: No extension after semicolon": chunkExtensions,
        "response/transfer-encoding: Unbalanced chunk extensions quoting": chunkExtensions,
    ]

    static let chunkExtensions = """
        chunk extensions aren't parsed: after the size, anything but a control character is skipped to the line end, so \
        `2 erf`, `2;`, `a ` (whitespace with no `;`), and an unclosed quoted string are accepted (RFC 9112 §7.1.1: chunk-ext = \
        *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] ))
        """

    @Test func agreesWithLLHTTPOnWholeMessages() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch llhttp-tests llhttp-cases")
        var options = Conformance.Options()
        options.closesAtEnd = false
        var report: [String] = []
        for testCase in Self.cases {
            let key = "\(testCase.file): \(testCase.title)"
            let kind: Conformance.Kind = testCase.type == "response" ? .response(requestMethod: .get) : .request
            let outcome = Conformance.parse(testCase.input, as: kind, options: options)
            let expected = Self.llhttp(testCase)
            let differences = Self.differences.merging(LLHTTPDifferentialTests.differences) { mine, _ in mine }
            guard let line = Conformance.compare(key: key, input: testCase.input, ours: outcome, expected: expected, differences: differences)
            else { continue }
            if line.contains("listed in differences but agrees now"), Self.differences[key] == nil { continue }
            if let issue = Self.knownIssues[key] {
                withKnownIssue(Comment(rawValue: issue)) { Issue.record(Comment(rawValue: line)) }
            } else {
                report.append(line)
            }
        }
        #expect(report.isEmpty, "\(report.count) of \(Self.cases.count):\n\(report.joined(separator: "\n"))")
    }
}
