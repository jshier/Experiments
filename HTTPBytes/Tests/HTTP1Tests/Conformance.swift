import Bytes
import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// A case from another implementation's test suite, as the generators in HTTPBytes/Fixtures write them: one TSV line,
/// `source name kind verdict input-hex`, then `key=value` columns with whatever else the suite expects.
struct ConformanceCase: CustomStringConvertible {
    let source: String, name: String, kind: String, verdict: String
    let input: [UInt8]
    let extras: [String: String]

    /// "source: name", the key of a `differences` table.
    var key: String { "\(source): \(name)" }
    var description: String { "\(key) [\(Conformance.escaped(input))]" }

    /// The extra column `key`, decoded from hexadecimal.
    func bytes(_ key: String) -> [UInt8]? { extras[key].map(Conformance.unhex) }
    func int(_ key: String) -> Int? { extras[key].flatMap { Int($0) } }

    /// Every case in a generated set's TSV file, or none if the set hasn't been fetched.
    static func load(set: String, name: String = "cases.tsv") -> [ConformanceCase] {
        guard let url = try? TestData.file(set: set, name: name), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").map { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var extras: [String: String] = [:]
            for column in columns.dropFirst(5) {
                guard let equals = column.firstIndex(of: "=") else { continue }
                extras[String(column[..<equals])] = String(column[column.index(after: equals)...])
            }
            return ConformanceCase(source: columns[0], name: columns[1], kind: columns[2], verdict: columns[3],
                                   input: Conformance.unhex(columns[4]), extras: extras)
        }
    }
}

/// Whole HTTP/1 messages through HTTPBytes' parsers, as a server or client would read them: the head
/// (``HTTP1RequestParser``/``HTTP1ResponseParser``), its framing (``HTTP1Framing``), then the body
/// (``HTTP1ChunkedDecoder``, a `Content-Length`, or the rest of the input). The differential suites compare the outcome
/// with other implementations' verdicts.
enum Conformance {
    /// Which message is read: a request, or a response to a request with `requestMethod`.
    enum Kind: Equatable, Sendable { case request, response(requestMethod: HTTPMethod) }

    /// Where a message was rejected or ran out of bytes.
    enum Stage: String, Sendable { case head, framing, body }

    struct Field: Equatable, CustomStringConvertible {
        var name: [UInt8], value: [UInt8]
        var description: String { "\(Conformance.escaped(name)): \(Conformance.escaped(value))" }
    }

    /// A message read in full.
    struct Message: Equatable, CustomStringConvertible {
        var method: [UInt8] = [], target: [UInt8] = []
        var version: HTTPVersion = .http1_1
        var status = 0
        var reason: [UInt8] = []
        var fields: [Field] = []
        var headByteCount = 0
        var framing: HTTP1BodyLength = .none
        var body: [UInt8] = []
        var trailers: [Field] = []
        /// The offset just past the message: where a pipelined next message would start.
        var end = 0
        /// Exactly one `Host` in HTTP/1.1, at most one in HTTP/1.0 (RFC 9112 §3.2).
        var hostIsValid = true
        var isPersistent = false
        var description: String {
            let line = status == 0 ? "\(escaped(method)) \(escaped(target)) \(version)" : "\(version) \(status) \(escaped(reason))"
            return "\(line), \(fields.count) fields, \(framing), body \(body.count) bytes, ends at \(end)"
        }

        func field(_ name: String) -> [UInt8]? {
            fields.first { String(decoding: $0.name, as: UTF8.self).lowercased() == name.lowercased() }?.value
        }
    }

    enum Outcome: Equatable, CustomStringConvertible {
        case accept(Message)
        case reject(HTTP1Error, Stage)
        case partial(Stage)

        /// accept, reject, or partial: the other suites' terms.
        var verdict: String {
            switch self {
            case .accept: "accept"
            case .reject: "reject"
            case .partial: "partial"
            }
        }

        var message: Message? { if case let .accept(message) = self { message } else { nil } }
        var description: String {
            switch self {
            case let .accept(message): "accept (\(message))"
            case let .reject(error, stage): "reject (\(stage.rawValue): \(error))"
            case let .partial(stage): "partial (\(stage.rawValue))"
            }
        }
    }

    struct Options {
        var head = HTTP1ParserOptions()
        var chunked = HTTP1ChunkedDecoder()
        /// Reject a request whose `Host` isn't valid (RFC 9112 §3.2's 400).
        var validatesHost = false
        /// Stop after the head and its framing: for suites that only parse heads (picohttpparser, httparse).
        var headOnly = false
        /// The input ends with the connection: a body read until close ends there (otherwise it's partial).
        var closesAtEnd = true
    }

    /// Reads the first message in `input`. With `splits`, the bytes arrive in pieces ending at those offsets (then the
    /// rest), as a socket might hand them over: the outcome must be the same as for the whole input.
    static func parse(_ input: [UInt8], as kind: Kind = .request, options: Options = Options(), splits: [Int] = []) -> Outcome {
        let limits = splits.filter { $0 > 0 && $0 < input.count }.sorted() + [input.count]
        var limitIndex = 0
        var limit: Int { limits[limitIndex] }
        /// Whether more bytes can arrive: the next piece.
        func more() -> Bool {
            guard limitIndex + 1 < limits.count else { return false }
            limitIndex += 1
            return true
        }
        let all = input.span.bytes
        var message = Message()
        var framing = HTTP1Framing()
        var observeError: HTTP1Error?

        // The head.
        do throws(HTTP1Error) {
            switch kind {
            case .request:
                var parser = HTTP1RequestParser(options: options.head)
                head: while true {
                    let bytes = all.extracting(0..<limit)
                    switch try parser.next(in: bytes) {
                    case let .requestLine(line):
                        message.method = array(line.method)
                        message.target = array(line.target)
                        message.version = line.version
                    case let .field(field):
                        message.fields.append(Field(name: array(field.name), value: array(field.value)))
                        if observeError == nil { do throws(HTTP1Error) { try framing.observe(field) } catch { observeError = error } }
                    case let .end(length):
                        message.headByteCount = length
                        break head
                    case .needsMore:
                        guard more() else { return .partial(.head) }
                    }
                }
            case .response:
                var parser = HTTP1ResponseParser(options: options.head)
                head: while true {
                    let bytes = all.extracting(0..<limit)
                    switch try parser.next(in: bytes) {
                    case let .statusLine(line):
                        message.version = line.version
                        message.status = line.status.code
                        message.reason = array(line.reasonPhrase)
                    case let .field(field):
                        message.fields.append(Field(name: array(field.name), value: array(field.value)))
                        if observeError == nil { do throws(HTTP1Error) { try framing.observe(field) } catch { observeError = error } }
                    case let .end(length):
                        message.headByteCount = length
                        break head
                    case .needsMore:
                        guard more() else { return .partial(.head) }
                    }
                }
            }
        } catch {
            return .reject(error, .head)
        }

        // Its framing.
        if let observeError { return .reject(observeError, .framing) }
        do throws(HTTP1Error) {
            switch kind {
            case .request:
                message.framing = try framing.requestBody(version: message.version, method: HTTPMethod(message.method.span.bytes))
                if options.validatesHost { try framing.validateHost(version: message.version) }
            case let .response(method):
                message.framing = try framing.responseBody(status: HTTPStatus(uncheckedCode: message.status), version: message.version,
                                                           requestMethod: method)
            }
        } catch {
            return .reject(error, .framing)
        }
        message.hostIsValid = (try? framing.validateHost(version: message.version)) != nil
        message.isPersistent = framing.isPersistent(version: message.version, body: message.framing)
        message.end = message.headByteCount
        if options.headOnly { return .accept(message) }

        // The body.
        switch message.framing {
        case .none:
            break
        case let .length(length):
            while message.headByteCount + length > limit {
                guard more() else { return .partial(.body) }
            }
            message.body = Array(input[message.headByteCount..<message.headByteCount + length])
            message.end = message.headByteCount + length
        case .untilClose:
            guard options.closesAtEnd else { return .partial(.body) }
            message.body = Array(input[message.headByteCount...])
            message.end = input.count
        case .chunked:
            var decoder = options.chunked
            var position = message.headByteCount
            do throws(HTTP1Error) {
                body: while true {
                    var consumed = 0
                    let bytes = all.extracting(position..<limit)
                    switch try decoder.next(in: bytes, consumed: &consumed) {
                    case let .data(data): message.body += array(data)
                    case let .trailer(field): message.trailers.append(Field(name: array(field.name), value: array(field.value)))
                    case .end:
                        position += consumed
                        break body
                    case .needsMore:
                        position += consumed
                        guard more() else { return .partial(.body) }
                        continue body
                    }
                    position += consumed
                }
            } catch {
                return .reject(error, .body)
            }
            message.end = position
        }
        return .accept(message)
    }

    static func array(_ bytes: RawSpan) -> [UInt8] {
        (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) }
    }

    static func unhex(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let nibble: UInt8 = character <= 0x39 ? character - 0x30 : (character | 0x20) - 0x61 + 10
            if let value = high { bytes.append(value << 4 | nibble); high = nil } else { high = nibble }
        }
        return bytes
    }

    static func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    /// Bytes as readable text: printable ASCII as is, the rest escaped.
    static func escaped(_ bytes: [UInt8], limit: Int = 160) -> String {
        var text = ""
        for byte in bytes.prefix(limit) {
            switch byte {
            case 0x0D: text += "\\r"
            case 0x0A: text += "\\n"
            case 0x09: text += "\\t"
            case 0x5C: text += "\\\\"
            case 0x20...0x7E: text.unicodeScalars.append(Unicode.Scalar(byte))
            default: text += String(format: "\\x%02X", byte)
            }
        }
        return bytes.count > limit ? text + "…" : text
    }

    /// Checks `outcome` against `expected`, unless `differences` explains why they differ; returns a line for the
    /// report when they differ unexplained. Also returns a line when a listed difference no longer occurs (the table
    /// is kept exact).
    static func compare(key: String, input: [UInt8], ours outcome: Outcome, expected: String,
                        differences: [String: String]) -> String? {
        let agrees = outcome.verdict == expected
        if agrees, differences[key] != nil { return "\(key): listed in differences but agrees now (\(outcome))" }
        if !agrees, differences[key] == nil { return "\(key): ours \(outcome); expected \(expected) [\(escaped(input))]" }
        return nil
    }
}

/// A case transcribed by hand from another implementation's tests (Go's, h11's): the bytes, and what that implementation
/// does with them.
struct TranscribedCase {
    let name: String
    let input: [UInt8]
    var kind: Conformance.Kind = .request
    /// The implementation's verdict: accept, reject, or partial.
    let verdict: String
    /// The body it reads, if the test says.
    var body: [UInt8]?
    /// Whether it keeps the connection open after the message, if the test says.
    var persistent: Bool?
    /// Field values it reports (name, value), if the test says.
    var fields: [(String, String)]?
    /// Whether the input ends with the connection (for a body read until close).
    var closesAtEnd = true
    /// Why HTTPBytes decides differently, on purpose.
    var difference: String?
    /// Where HTTPBytes falls short of the RFCs: checked as a known issue.
    var issue: String?

    init(name: String, input: [UInt8], kind: Conformance.Kind = .request, verdict: String, body: [UInt8]? = nil,
         persistent: Bool? = nil, fields: [(String, String)]? = nil, closesAtEnd: Bool = true, difference: String? = nil,
         issue: String? = nil) {
        self.name = name
        self.input = input
        self.kind = kind
        self.verdict = verdict
        self.body = body
        self.persistent = persistent
        self.fields = fields
        self.closesAtEnd = closesAtEnd
        self.difference = difference
        self.issue = issue
    }
}

extension Conformance {
    /// Runs each case and compares; returns the report of unexplained disagreements (and of listed differences that no
    /// longer differ). Cases with an `issue` are checked inside `withKnownIssue`.
    static func check(_ cases: [TranscribedCase], suite: String) -> [String] {
        var report: [String] = []
        for testCase in cases {
            var options = Options()
            options.closesAtEnd = testCase.closesAtEnd
            let outcome = parse(testCase.input, as: testCase.kind, options: options)
            var problems: [String] = []
            if outcome.verdict != testCase.verdict { problems.append("ours \(outcome); \(suite) \(testCase.verdict)") }
            if let message = outcome.message, testCase.verdict == "accept" {
                if let body = testCase.body, message.body != body {
                    problems.append("body \(escaped(message.body)); \(suite) \(escaped(body))")
                }
                if let persistent = testCase.persistent, message.isPersistent != persistent {
                    problems.append("persistent \(message.isPersistent); \(suite) \(persistent)")
                }
                for (name, value) in testCase.fields ?? [] where message.field(name) != Array(value.utf8) {
                    problems.append("\(name): \(message.field(name).map { escaped($0) } ?? "missing"); \(suite) \(value)")
                }
            }
            let line = "\(testCase.name): " + problems.joined(separator: "; ") + " [\(escaped(testCase.input, limit: 120))]"
            if let issue = testCase.issue {
                withKnownIssue(Comment(rawValue: issue)) { #expect(problems.isEmpty, "\(line)") }
            } else if problems.isEmpty, testCase.difference != nil {
                report.append("\(testCase.name): listed as a difference but agrees now")
            } else if !problems.isEmpty, testCase.difference == nil {
                report.append(line)
            }
        }
        return report
    }
}
