import Bytes
import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// llhttp's own test suite (its markdown cases, as the llhttp-cases set has them, with llhttp's verdict on each), run
/// through HTTPBytes' parsers: whether each head is accepted, and whether its framing (`Content-Length`,
/// `Transfer-Encoding`) is. Only llhttp's strict types (`request`, `response`); its lenient modes test leniencies
/// HTTPBytes doesn't offer. Where HTTPBytes decides differently on purpose, the case is listed in `differences` with why.
@Suite struct LLHTTPDifferentialTests {
    struct Case {
        let file: String, title: String, type: String
        let input: [UInt8]
        let headersOffset: Int, errorOffset: Int, reason: String
    }

    static let cases: [Case] = {
        guard let url = try? TestData.file(set: "llhttp-cases", name: "cases.tsv"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").map { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var input: [UInt8] = []
            var hex = columns[3][...]
            while hex.count >= 2 {
                input.append(UInt8(hex.prefix(2), radix: 16)!); hex = hex.dropFirst(2)
            }
            return Case(file: columns[0], title: columns[1], type: columns[2], input: input,
                        headersOffset: Int(columns[4])!, errorOffset: Int(columns[5])!, reason: columns[6])
        }
    }()

    /// What a parser concluded about the first message's head: its length, or an error, or that it isn't complete.
    enum Verdict: Equatable, CustomStringConvertible {
        case head(Int), framingError(HTTP1Error), headError(HTTP1Error), incomplete
        var description: String {
            switch self {
            case let .head(length): "head of \(length) bytes"
            case let .framingError(error): "framing error \(error)"
            case let .headError(error): "head error \(error)"
            case .incomplete: "incomplete"
            }
        }
    }

    static func ours(_ testCase: Case) -> Verdict {
        var framing = HTTP1Framing()
        let bytes = testCase.input.span.bytes
        do {
            if testCase.type == "request" {
                var parser = HTTP1RequestParser()
                var version = HTTPVersion.http1_1
                while true {
                    switch try parser.next(in: bytes) {
                    case let .requestLine(line): version = line.version
                    case let .field(field): try framing.observe(field)
                    case let .end(length):
                        do { _ = try framing.requestBody(version: version) } catch { return .framingError(error) }
                        return .head(length)
                    case .needsMore: return .incomplete
                    }
                }
            } else {
                var parser = HTTP1ResponseParser()
                var status = HTTPStatus.ok, version = HTTPVersion.http1_1
                while true {
                    switch try parser.next(in: bytes) {
                    case let .statusLine(line): (status, version) = (line.status, line.version)
                    case let .field(field): try framing.observe(field)
                    case let .end(length):
                        do { _ = try framing.responseBody(status: status, version: version, requestMethod: .get) } catch {
                            return .framingError(error)
                        }
                        return .head(length)
                    case .needsMore: return .incomplete
                    }
                }
            }
        } catch {
            return [.invalidContentLength].contains(error) ? .framingError(error) : .headError(error)
        }
    }

    /// llhttp's verdict, in the same terms: an error before the head ended rejects the head; an error at the head's end
    /// about `Content-Length` or `Transfer-Encoding` rejects its framing.
    static func llhttp(_ testCase: Case) -> String {
        if testCase.errorOffset >= 0, testCase.headersOffset < 0 || testCase.errorOffset < testCase.headersOffset {
            // llhttp checks `Content-Length` and `Transfer-Encoding` as it reads them; HTTPBytes checks them as framing,
            // once the head has ended (`HTTP1Framing`). The same rejection, at a different point.
            if testCase.reason.contains("Content-Length") || testCase.reason.contains("Transfer-Encoding") { return "framing error" }
            return "head error"
        }
        if testCase.headersOffset >= 0 {
            if testCase.errorOffset == testCase.headersOffset { return "framing error" }
            return "head"
        }
        return "incomplete"
    }

    /// Cases where HTTPBytes decides differently, deliberately: keyed by "file: title", with the reason.
    static let differences: [String: String] = [
        // Methods: any token (RFC 9110 §9: methods are extensible); llhttp knows a fixed list, and treats PRI as HTTP/2.
        "request/invalid: HTTP protocol and ANNOUNCE method": "ANNOUNCE is a token: an extension method",
        "request/invalid: Invalid method": "MKCOLA is a token: an extension method",
        "request/method: PRI request HTTP2": "PRI with HTTP/1.1 is a token method; HTTP/2's preface is checked by HTTP2ConnectionPreface",
        // Protocols: HTTP/1.0 and 1.1 only; llhttp also parses RTSP and ICE (SHOUTcast), and HTTP/0.9's version-less lines.
        "request/method: SOURCE request with ICE": "ICE isn't HTTP",
        "request/method: OPTIONS request with RTSP": "RTSP isn't HTTP",
        "request/method: ANNOUNCE request with RTSP": "RTSP isn't HTTP",
        "request/sample: No HTTP version": "HTTP/0.9 isn't supported (RFC 9112 has no request line without a version)",
        "response/sample: RTSP response": "RTSP isn't HTTP",
        "response/sample: ICE response": "ICE isn't HTTP",
        "response/sample: HTTP version 0.9": "a response claiming HTTP/0.9 is rejected (505's counterpart for responses)",
        // Codings: a request whose `Transfer-Encoding` names a coding besides chunked gets 501 (RFC 9112 §6.1: a server
        // that doesn't understand a coding should respond 501); llhttp accepts it and leaves the coding to its user.
        "request/transfer-encoding: POST with `chunked` as last transfer-encoding": "501: unsupported coding",
        "request/transfer-encoding: POST with `chunked` as last transfer-encoding (multiple headers)": "501: unsupported coding",
    ]

    @Test func agreesWithLLHTTP() throws {
        try #require(!Self.cases.isEmpty, "run Tools/test-data fetch llhttp-tests llhttp-cases")
        var disagreements: [String] = []
        var compared = 0
        for testCase in Self.cases where testCase.type == "request" || testCase.type == "response" {
            compared += 1
            let ours = Self.ours(testCase), theirs = Self.llhttp(testCase)
            let agrees = switch (ours, theirs) {
            case (.head, "head"), (.headError, "head error"), (.framingError, "framing error"), (.incomplete, "incomplete"): true
            default: false
            }
            let key = "\(testCase.file): \(testCase.title)"
            if !agrees, Self.differences[key] == nil {
                disagreements.append("\(key) — ours: \(ours); llhttp: \(theirs) \(testCase.reason)")
            }
        }
        #expect(compared > 200)
        let report = "\(disagreements.count) of \(compared):\n" + disagreements.joined(separator: "\n")
        #expect(disagreements.isEmpty, "\(report)")
    }
}
