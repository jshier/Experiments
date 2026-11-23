import Bytes
import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// A head as plain values, for comparing.
struct ParsedHead: Equatable, CustomStringConvertible {
    var method = "", target = "", version = ""
    var fields: [[String]] = []
    var known: [String] = []
    var byteCount = 0
    var description: String { "\(method) \(target) \(version) \(fields) (\(byteCount) bytes)" }
}

func string(_ bytes: RawSpan) -> String {
    String(decoding: (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) }, as: UTF8.self)
}

/// Runs `parser` over `bytes` until the head ends or the bytes do, appending what it finds to `head`. Returns whether
/// the head ended.
func parse(_ parser: inout HTTP1RequestParser, _ bytes: RawSpan, into head: inout ParsedHead) throws(HTTP1Error) -> Bool {
    while true {
        switch try parser.next(in: bytes) {
        case .requestLine(let line):
            head.method = string(line.method)
            head.target = string(line.target)
            head.version = "\(line.version)"
        case .field(let field):
            head.fields.append([string(field.name), string(field.value)])
            head.known.append(field.knownName.map { "\($0)" } ?? "-")
        case .end(let headByteCount):
            head.byteCount = headByteCount
            return true
        case .needsMore:
            return false
        }
    }
}

func parse(_ bytes: [UInt8], options: HTTP1ParserOptions = HTTP1ParserOptions()) throws(HTTP1Error) -> ParsedHead? {
    var parser = HTTP1RequestParser(options: options)
    var head = ParsedHead()
    return try parse(&parser, bytes.span.bytes, into: &head) ? head : nil
}

/// A plain parser for well-formed heads, to check the real one against: lines split at CR LF, the request line at
/// spaces, fields at their first colon, values trimmed.
func referenceParse(_ bytes: [UInt8]) -> ParsedHead {
    let text = String(decoding: bytes, as: UTF8.self)
    let headText = text.components(separatedBy: "\r\n\r\n")[0]
    var lines = headText.components(separatedBy: "\r\n")
    let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var head = ParsedHead(method: parts[0], target: parts[1], version: parts[2])
    for line in lines {
        let colon = line.firstIndex(of: ":")!
        head.fields.append([String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))])
        head.known.append(HTTPFieldName(caseInsensitive: Array(line[..<colon].utf8).span.bytes).map { "\($0)" } ?? "-")
    }
    head.byteCount = headText.utf8.count + 4
    return head
}

/// The http-corpus requests: each head, split from the file by the reference.
let corpusHeads: [[UInt8]] = {
    guard let url = try? TestData.file(set: "http-corpus", name: "requests.http1"), let data = try? Data(contentsOf: url) else { return [] }
    let bytes = [UInt8](data)
    var heads: [[UInt8]] = []
    var start = 0
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    var index = 0
    while index + 4 <= bytes.count {
        if Array(bytes[index..<index + 4]) == separator {
            heads.append(Array(bytes[start..<index + 4]))
            start = index + 4
            index += 4
        } else {
            index += 1
        }
    }
    return heads
}()

@Suite struct RequestParserTests {
    @Test func corpusHeadsMatchTheReference() throws {
        try #require(!corpusHeads.isEmpty, "run Tools/test-data fetch qifs http-corpus")
        for head in corpusHeads {
            // With the next head's bytes after it, as a connection's buffer would have.
            let parsed = try parse(head + Array("GET / HTTP/1.1\r\n".utf8))
            #expect(parsed == referenceParse(head))
        }
    }

    /// Every head of the first 40, cut at every byte: the parser says it needs more, then finishes with the rest, with
    /// the same result.
    @Test func everyCutResumes() throws {
        for head in corpusHeads.prefix(40) + [Array("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)] {
            let whole = try #require(try parse(head))
            for cut in 0..<head.count {
                var parser = HTTP1RequestParser()
                var parsed = ParsedHead()
                let ended = try parse(&parser, Array(head[..<cut]).span.bytes, into: &parsed)
                #expect(!ended, "cut \(cut)")
                #expect(try parse(&parser, head.span.bytes, into: &parsed))
                #expect(parsed == whole, "cut \(cut)")
            }
        }
    }

    @Test func smallHead() throws {
        let head = try #require(try parse(Array("GET /index.html?q=1 HTTP/1.0\r\nHost: example.com\r\nX-Empty:\r\nX-Space:  a b \t\r\n\r\nbody".utf8)))
        #expect(head == ParsedHead(method: "GET", target: "/index.html?q=1", version: "HTTP/1.0",
                                   fields: [["Host", "example.com"], ["X-Empty", ""], ["X-Space", "a b"]],
                                   known: ["Host", "-", "-"], byteCount: 78))
    }

    @Test func leadingEmptyLinesAreSkipped() throws {
        let head = try #require(try parse(Array("\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)))
        // The empty lines count toward the head's length: its offsets are from the bytes' start.
        #expect(head.method == "GET" && head.byteCount == 22)
        #expect(throws: HTTP1Error.invalidMethod) {
            _ = try parse(Array("\r\nGET / HTTP/1.1\r\n\r\n".utf8), options: HTTP1ParserOptions(skipsLeadingEmptyLines: false))
        }
    }

    @Test func obsTextAndTabsAreValueBytes() throws {
        // "a", tab, "b", then é in UTF-8 (two bytes of obs-text).
        let head = try #require(try parse(Array("GET / HTTP/1.1\r\nX: a\tb".utf8) + [0xC3, 0xA9] + Array("\r\n\r\n".utf8)))
        #expect(head.fields[0][1].utf8.count == 5)
    }

    @Test func bareLineFeeds() throws {
        let bytes = Array("GET / HTTP/1.1\nHost: a\n\n".utf8)
        #expect(throws: HTTP1Error.invalidLineEnding) { _ = try parse(bytes) }
        let head = try #require(try parse(bytes, options: HTTP1ParserOptions(allowsBareLineFeed: true)))
        #expect(head.fields == [["Host", "a"]] && head.byteCount == bytes.count)
    }

    @Test(arguments: [
        ("GET  / HTTP/1.1\r\n\r\n", HTTP1Error.invalidTarget),
        ("GET /  HTTP/1.1\r\n\r\n", .invalidVersion),
        (" GET / HTTP/1.1\r\n\r\n", .invalidMethod),
        ("G(T / HTTP/1.1\r\n\r\n", .invalidMethod),
        ("GET\t/ HTTP/1.1\r\n\r\n", .invalidMethod),
        ("GET / HTTP/1.1 \r\n\r\n", .invalidVersion),
        ("GET / http/1.1\r\n\r\n", .invalidVersion),
        ("GET / HTTP/2.0\r\n\r\n", .unsupportedVersion),
        ("GET / HTTP/1.1\r\r\n\r\n", .invalidLineEnding),
        ("GET /\u{7F} HTTP/1.1\r\n\r\n", .invalidTarget),
        ("GET / HTTP/1.1\r\nHost : a\r\n\r\n", .invalidFieldName),
        ("GET / HTTP/1.1\r\n: a\r\n\r\n", .invalidFieldName),
        ("GET / HTTP/1.1\r\nHo\"st: a\r\n\r\n", .invalidFieldName),
        ("GET / HTTP/1.1\r\nA: b\r\n c\r\n\r\n", .obsoleteLineFolding),
        ("GET / HTTP/1.1\r\nA: b\u{01}c\r\n\r\n", .invalidFieldValue),
        ("GET / HTTP/1.1\r\nA: b\u{7F}\r\n\r\n", .invalidFieldValue),
        ("GET / HTTP/1.1\r\nA: b\rc\r\n\r\n", .invalidLineEnding),
        ("GET / HTTP/1.1\r\nA: b\r\n\rx", .invalidLineEnding),
        ("GET / HTTP/1.1\r\nA\r\n\r\n", .invalidFieldName),
    ])
    func malformedHeadsAreRejected(text: String, error: HTTP1Error) {
        #expect(throws: error) { _ = try parse(Array(text.utf8)) }
    }

    /// `validatesTargets` checks the target's form (RFC 9112 §3.2), on the word-compare path (GET) and the exact one
    /// (other methods); off, any visible ASCII is a target.
    @Test func targetValidationIsAnOption() throws {
        let checked = HTTP1ParserOptions(validatesTargets: true)
        for head in ["GET ! HTTP/1.1\r\n\r\n", "DELETE ! HTTP/1.1\r\n\r\n", "GET /a%zz HTTP/1.1\r\nHost: a\r\n\r\n"] {
            #expect(throws: HTTP1Error.invalidTarget, "\(head)") { _ = try parse(Array(head.utf8), options: checked) }
            #expect(try parse(Array(head.utf8)) != nil, "\(head)")
        }
        #expect(try parse(Array("GET /a?b=c HTTP/1.1\r\nHost: a\r\n\r\n".utf8), options: checked) != nil)
        #expect(try parse(Array("CONNECT a.example:443 HTTP/1.1\r\nHost: a\r\n\r\n".utf8), options: checked) != nil)
    }

    @Test func limits() throws {
        let long = Array("GET /\(String(repeating: "a", count: 100)) HTTP/1.1\r\n\r\n".utf8)
        #expect(throws: HTTP1Error.targetTooLong) { _ = try parse(long, options: HTTP1ParserOptions(maximumTargetByteCount: 50)) }
        #expect(throws: HTTP1Error.targetTooLong) { _ = try parse(Array(long[..<80]), options: HTTP1ParserOptions(maximumTargetByteCount: 50)) }
        let fields = Array(("GET / HTTP/1.1\r\n" + String(repeating: "A: b\r\n", count: 10) + "\r\n").utf8)
        #expect(throws: HTTP1Error.tooManyFields) { _ = try parse(fields, options: HTTP1ParserOptions(maximumFieldCount: 9)) }
        #expect(try parse(fields, options: HTTP1ParserOptions(maximumFieldCount: 10)) != nil)
        #expect(throws: HTTP1Error.headTooLarge) { _ = try parse(fields, options: HTTP1ParserOptions(maximumHeadByteCount: 40)) }
        #expect(throws: HTTP1Error.headTooLarge) { _ = try parse(Array(fields[..<45]), options: HTTP1ParserOptions(maximumHeadByteCount: 40)) }
        #expect(HTTP1Error.targetTooLong.status == .uriTooLong && HTTP1Error.tooManyFields.status == .requestHeaderFieldsTooLarge)
    }

    /// The head limit is the head's, not the buffer's: more than the limit after a small head (pipelined requests, a
    /// body) parses.
    @Test func bytesAfterTheHeadDontCountTowardItsLimit() throws {
        let head = Array("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)
        let parsed = try parse(head + [UInt8](repeating: 0x41, count: 100_000), options: HTTP1ParserOptions(maximumHeadByteCount: 1_000))
        #expect(parsed?.byteCount == head.count)
        var response = HTTP1ResponseParser(options: HTTP1ParserOptions(maximumHeadByteCount: 1_000))
        var parsedResponse = ParsedResponse()
        let bytes = Array("HTTP/1.1 200 OK\r\nA: b\r\n\r\n".utf8) + [UInt8](repeating: 0x41, count: 100_000)
        #expect(try parseResponse(&response, bytes.span.bytes, into: &parsedResponse))
    }

    @Test func endRepeatsUntilReset() throws {
        var parser = HTTP1RequestParser()
        let bytes = Array("GET / HTTP/1.1\r\n\r\nPOST /a HTTP/1.1\r\n\r\n".utf8)
        var head = ParsedHead()
        #expect(try parse(&parser, bytes.span.bytes, into: &head))
        guard case .end(18) = try parser.next(in: bytes.span.bytes) else { Issue.record("not the end again"); return }
        parser.reset()
        head = ParsedHead()
        #expect(try parse(&parser, bytes.span.bytes.extracting(droppingFirst: 18), into: &head))
        #expect(head.method == "POST" && head.target == "/a")
    }
}
