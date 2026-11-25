import HTTP1
import HTTPBytes
import Testing

// Test vectors transcribed from python-hyper/h11 at 62c5068 (h11/tests/test_io.py, test_connection.py, test_headers.py).
// Copyright (c) 2016 Nathaniel J. Smith and other contributors; MIT license: "Permission is hereby granted, free of
// charge, to any person obtaining a copy of this software … The above copyright notice and this permission notice shall
// be included in all copies or substantial portions of the Software."

/// h11's reader tests, transcribed: requests and responses read by HTTPBytes in full (head, framing, body) and compared
/// with what h11 reads: accept (with body, fields, and keep-alive where the test says), reject, or still waiting. h11's
/// header-validation tests (`normalize_and_validate`) become field lines in a request. Where HTTPBytes decides
/// differently on purpose, `difference` says why; where it falls short of the RFCs, `issue` does.
@Suite struct H11Tests {
    typealias Case = TranscribedCase

    static func b(_ string: String) -> [UInt8] { Array(string.utf8) }

    // MARK: test_io.py

    static let readers: [Case] = [
        // SIMPLE_CASES
        Case(name: "simple request", input: b("GET /a HTTP/1.1\r\nHost: foo\r\nConnection: close\r\n\r\n"), verdict: "accept", body: [],
             persistent: false, fields: [("Host", "foo"), ("Connection", "close")]),
        Case(name: "simple response, Connection: close", input: b("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"),
             kind: .response(requestMethod: .get), verdict: "accept", body: [], persistent: false),
        Case(name: "simple response, no fields", input: b("HTTP/1.1 200 OK\r\n\r\n"), kind: .response(requestMethod: .get), verdict: "accept", body: []),
        Case(name: "101 with Upgrade", input: b("HTTP/1.1 101 Upgrade\r\nUpgrade: websocket\r\n\r\n"), kind: .response(requestMethod: .get),
             verdict: "accept", body: [], fields: [("Upgrade", "websocket")]),
        Case(name: "101", input: b("HTTP/1.1 101 Upgrade\r\n\r\n"), kind: .response(requestMethod: .get), verdict: "accept", body: []),
        // test_readers_unusual
        Case(name: "HTTP/1.0 HEAD", input: b("HEAD /foo HTTP/1.0\r\nSome: header\r\n\r\n"), verdict: "accept", body: [], persistent: false,
             fields: [("Some", "header")]),
        Case(name: "HTTP/1.0 with no fields", input: b("HEAD /foo HTTP/1.0\r\n\r\n"), verdict: "accept", body: []),
        Case(name: "HTTP/1.0 response", input: b("HTTP/1.0 200 OK\r\nSome: header\r\n\r\n"), kind: .response(requestMethod: .head),
             verdict: "accept", fields: [("Some", "header")]),
        Case(name: "value with inner spaces", input: b("HTTP/1.0 200 OK\r\nFoo: a a a a a \r\n\r\n"), kind: .response(requestMethod: .head),
             verdict: "accept", fields: [("Foo", "a a a a a")]),
        Case(name: "empty value", input: b("HTTP/1.0 200 OK\r\nFoo:\r\n\r\n"), kind: .response(requestMethod: .head), verdict: "accept",
             fields: [("Foo", "")]),
        Case(name: "whitespace-only value", input: b("HTTP/1.0 200 OK\r\nFoo: \t \t \r\n\r\n"), kind: .response(requestMethod: .head),
             verdict: "accept", fields: [("Foo", "")]),
        Case(name: "no reason phrase", input: b("HTTP/1.0 200\r\nFoo: bar\r\n\r\n"), kind: .response(requestMethod: .head), verdict: "accept",
             fields: [("Foo", "bar")]),
        Case(name: "LF then CR LF", input: b("HTTP/1.1 200 OK\r\nSomeHeader: val\n\r\n"), kind: .response(requestMethod: .head),
             verdict: "accept", difference: "bare LF line ends need allowsBareLineFeed (RFC 9112 §2.2's MAY; off by default)"),
        Case(name: "LF only", input: b("HTTP/1.1 200 OK\nSomeHeader1: val1\nSomeHeader2: val2\n\n"), kind: .response(requestMethod: .head),
             verdict: "accept", difference: "bare LF line ends need allowsBareLineFeed"),
        Case(name: "mixed CR LF and LF", input: b("HTTP/1.1 200 OK\r\nSomeHeader1: val1\nSomeHeader2: val2\n\r\n"),
             kind: .response(requestMethod: .head), verdict: "accept", difference: "bare LF line ends need allowsBareLineFeed"),
        Case(name: "obsolete line folding",
             input: b("HEAD /foo HTTP/1.1\r\nHost: example.com\r\nSome: multi-line\r\n header\r\n\tnonsense\r\n    \t   \t\tI guess\r\n"
                 + "Connection: close\r\nMore-nonsense: in the\r\n    last header  \r\n\r\n"),
             verdict: "accept", difference: "obsolete line folding is rejected (RFC 9112 §5.2 lets a server reject it with 400; h11 unfolds)"),
        Case(name: "folded first line", input: b("HEAD /foo HTTP/1.1\r\n  folded: line\r\n\r\n"), verdict: "reject"),
        Case(name: "spaces before the colon", input: b("HEAD /foo HTTP/1.1\r\nfoo  : line\r\n\r\n"), verdict: "reject"),
        Case(name: "tab before the colon", input: b("HEAD /foo HTTP/1.1\r\nfoo\t: line\r\n\r\n"), verdict: "reject"),
        Case(name: "empty name", input: b("HEAD /foo HTTP/1.1\r\n: line\r\n\r\n"), verdict: "reject"),
        // test_ContentLengthReader, test_Http10Reader, test_ChunkedReader: bodies after a head.
        Case(name: "Content-Length 0", input: b("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n"), verdict: "accept", body: []),
        Case(name: "Content-Length 10", input: b("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\n0123456789"), verdict: "accept",
             body: b("0123456789")),
        Case(name: "until close, empty, at EOF", input: b("HTTP/1.0 200 OK\r\n\r\n"), kind: .response(requestMethod: .get), verdict: "accept",
             body: []),
        Case(name: "until close, no EOF yet", input: b("HTTP/1.0 200 OK\r\n\r\nasdf"), kind: .response(requestMethod: .get), verdict: "partial",
             closesAtEnd: false),
        Case(name: "until close, at EOF", input: b("HTTP/1.0 200 OK\r\n\r\nasdf"), kind: .response(requestMethod: .get), verdict: "accept",
             body: b("asdf")),
    ] + [
        ("empty chunked body", "0\r\n\r\n", "accept", ""),
        ("trailer", "0\r\nSome: header\r\n\r\n", "accept", ""),
        ("two chunks and a trailer", "5\r\n01234\r\n10\r\n0123456789abcdef\r\n0\r\nSome: header\r\n\r\n", "accept", "012340123456789abcdef"),
        ("two chunks", "5\r\n01234\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n", "accept", "012340123456789abcdef"),
        ("mixed-case hexadecimal", "aA\r\n" + String(repeating: "x", count: 0xAA) + "\r\n0\r\n\r\n", "accept", String(repeating: "x", count: 0xAA)),
        ("100-digit size", String(repeating: "9", count: 100) + "\r\nxxx", "reject", nil),
        ("NUL in the size line", "10\0\r\nxxx", "reject", nil),
        ("extensions", "5; hello=there\r\nxxxxx\r\n0; random=\"junk\"; some=more; canbe=lonnnnngg\r\n\r\n", "accept", "xxxxx"),
        // h11 accepts this; HTTPBytes follows RFC 9112 §7.1's grammar (whitespace only before a `;`), as llhttp's strict
        // mode does: a deliberate difference.
        ("whitespace after the size", "5   \t \r\n01234\r\n0\r\n\r\n", "reject", nil),
        ("bad chunk end", "3\r\nxxx__1a\r\n", "reject", nil),
        ("bad chunk end: CR then _", "3\r\nxxx\r_1a\r\n", "reject", nil),
        ("bad chunk end: _ then LF", "3\r\nxxx_\n1a\r\n", "reject", nil),
    ].map { name, body, verdict, decoded in
        Case(name: "chunked: \(name)", input: b("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n" + body), verdict: verdict,
             body: decoded.map(b))
    } + [
        Case(name: "garbage after the status line", input: b("HTTP/1.0 200 OK\0xxxx\r\n\r\n"), kind: .response(requestMethod: .get),
             verdict: "reject"),
        Case(name: "garbage after the request line", input: b("HEAD /foo HTTP/1.1 xxxxxx\r\nHost: a\r\n\r\n"), verdict: "reject"),
        Case(name: "NUL in a field value", input: b("HEAD /foo HTTP/1.1\r\nHost: foo\0bar\r\n\r\n"), verdict: "reject"),
    ] + [UInt8]([0x00, 0x20, 0x7F, 0xEE]).map { byte in
        Case(name: "non-VCHAR \(byte) in the path", input: b("HEAD /") + [byte] + b(" HTTP/1.1\r\nHost: foobar\r\n\r\n"), verdict: "reject")
    } + [
        Case(name: "some garbage in cookies", input: b("HEAD /foo HTTP/1.1\r\nHost: foo\r\nSet-Cookie: ___utmvafIumyLc=kUd\u{1}UpAt; path=/; Max-Age=900\r\n\r\n"),
             verdict: "accept",
             difference: "a control character in a field value is rejected (RFC 9110 §5.5: CTLs are invalid; a recipient MAY retain them, h11 does for cookies)"),
    ]

    // MARK: test_connection.py

    static let connection: [Case] = [
        // test__keep_alive
        Case(name: "keep-alive: HTTP/1.1", input: b("GET / HTTP/1.1\r\nHost: Example.com\r\n\r\n"), verdict: "accept", persistent: true),
        Case(name: "keep-alive: close", input: b("GET / HTTP/1.1\r\nHost: Example.com\r\nConnection: close\r\n\r\n"), verdict: "accept", persistent: false),
        Case(name: "keep-alive: close in a list", input: b("GET / HTTP/1.1\r\nHost: Example.com\r\nConnection: a, b, cLOse, foo\r\n\r\n"),
             verdict: "accept", persistent: false),
        Case(name: "keep-alive: HTTP/1.0", input: b("GET / HTTP/1.0\r\n\r\n"), verdict: "accept", persistent: false),
        Case(name: "keep-alive: response", input: b("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"), kind: .response(requestMethod: .get),
             verdict: "accept", persistent: true),
        Case(name: "keep-alive: response, close in a list", input: b("HTTP/1.1 200 OK\r\nConnection: a, b, cLOse, foo\r\nContent-Length: 0\r\n\r\n"),
             kind: .response(requestMethod: .get), verdict: "accept", persistent: false),
        Case(name: "keep-alive: HTTP/1.0 response", input: b("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"), kind: .response(requestMethod: .get),
             verdict: "accept", persistent: false),
        // test__body_framing: HEAD, 204, 304 have no body whatever the fields say.
    ] + [("", ""), ("Content-Length: 100\r\n", ""), ("Transfer-Encoding: chunked\r\n", ""),
         ("Content-Length: 100\r\nTransfer-Encoding: chunked\r\n", "")].flatMap { fields, _ in
        [(HTTPMethod.head, "200"), (.get, "204"), (.get, "304")].map { method, status in
            Case(name: "no body: \(method) \(status) \(fields.replacing("\r\n", with: " "))", input: b("HTTP/1.1 \(status) X\r\n\(fields)\r\nNEXT"),
                 kind: .response(requestMethod: method), verdict: "accept", body: [])
        }
    } + [
        Case(name: "framing: request, chunked", input: b("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nHost: example.com\r\n\r\n0\r\n\r\n"),
             verdict: "accept", body: []),
        Case(name: "framing: request, chunked and Content-Length",
             input: b("GET / HTTP/1.1\r\nContent-Length: 100\r\nTransfer-Encoding: chunked\r\nHost: example.com\r\n\r\n0\r\n\r\n"),
             verdict: "accept", body: [],
             difference: "a request with both framing fields is rejected (RFC 9112 §6.1 lets a server reject it; h11 frames it as chunked)"),
        Case(name: "framing: response, chunked and Content-Length",
             input: b("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"), kind: .response(requestMethod: .get),
             verdict: "accept", body: []),
        Case(name: "framing: request, no fields", input: b("GET / HTTP/1.1\r\nHost: example.com\r\n\r\nNEXT"), verdict: "accept", body: []),
        Case(name: "framing: response, no fields", input: b("HTTP/1.1 200 OK\r\n\r\nuntil close"), kind: .response(requestMethod: .get),
             verdict: "accept", body: b("until close")),
        // test_server_talking_to_http10_client
        Case(name: "HTTP/1.0 POST, body arriving", input: b("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\n1"), verdict: "partial"),
        // test_chunk_boundaries
        Case(name: "chunk boundaries", input: b("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nhello\r\n0\r\n\r\n"),
             verdict: "accept", body: b("hellohello")),
        // test_pipelining: the first request's end
        Case(name: "pipelining", input: b("GET /1 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n12345GET /2 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n67890"),
             verdict: "accept", body: b("12345")),
        // test_empty_request, test_empty_response, test_errors
        Case(name: "empty request line", input: b("\r\n"), verdict: "reject",
             difference: "empty lines before a request line are skipped (RFC 9112 §2.2: a server SHOULD ignore at least one), so CR LF alone waits for more"),
        Case(name: "empty response line", input: b("\r\n"), kind: .response(requestMethod: .get), verdict: "reject",
             difference: "empty lines before a status line are skipped (as llhttp does), so CR LF alone waits for more"),
        Case(name: "gibberish request", input: b("gibberish\r\n\r\n"), verdict: "reject"),
        Case(name: "gibberish response", input: b("gibberish\r\n\r\n"), kind: .response(requestMethod: .get), verdict: "reject"),
        // test_early_detection_of_invalid_request/response
        Case(name: "early: NUL request", input: [0x00], verdict: "reject"),
        Case(name: "early: SP request", input: [0x20], verdict: "reject"),
        Case(name: "early: TLS ClientHello", input: [0x16, 0x03, 0x01, 0x00, 0xA5], verdict: "reject"),
        Case(name: "early: NUL response", input: [0x00], kind: .response(requestMethod: .get), verdict: "reject",
             difference: "a status line is judged once its first 13 bytes are there: one byte waits"),
        Case(name: "early: SP response", input: [0x20], kind: .response(requestMethod: .get), verdict: "reject",
             difference: "a status line is judged once its first 13 bytes are there"),
        Case(name: "early: TLS ServerHello", input: [0x16, 0x03, 0x03, 0x00, 0x31], kind: .response(requestMethod: .get), verdict: "reject",
             difference: "a status line is judged once its first 13 bytes are there"),
        // test_special_exceptions_for_lost_connection_in_message_body
        Case(name: "Content-Length body cut short", input: b("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 100\r\n\r\n12345"),
             verdict: "partial"),
        Case(name: "chunked body cut short", input: b("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n012345"),
             verdict: "partial"),
    ]

    // MARK: test_headers.py: normalize_and_validate, as field lines

    static func field(_ name: String, _ lines: String, verdict: String, fields: [(String, String)]? = nil, difference: String? = nil,
                      issue: String? = nil) -> Case {
        Case(name: name, input: b("POST / HTTP/1.1\r\nHost: a\r\n\(lines)\r\n"), verdict: verdict, fields: fields, difference: difference,
             issue: issue)
    }

    static let headers: [Case] = [
        field("name with trailing space", "foo : bar\r\n", verdict: "reject"),
        field("name with leading space", " foo: bar\r\n", verdict: "reject"),
        field("space in name", "foo bar: baz\r\n", verdict: "reject"),
        field("NUL in name", "foo\0bar: baz\r\n", verdict: "reject"),
        field("0xFF in name", "foo\u{FF}bar: baz\r\n", verdict: "reject"),
        field("0x01 in name", "foo\u{1}bar: baz\r\n", verdict: "reject"),
        field("CR in value", "foo: bar\rbaz\r\n", verdict: "reject"),
        field("LF in value", "foo: bar\nbaz\r\n", verdict: "reject"),
        field("NUL in value", "foo: bar\0baz\r\n", verdict: "reject"),
        // h11 rejects these when *sending*; when reading, OWS around a value is removed (RFC 9112 §5.1).
        field("trailing spaces", "foo: barbaz  \r\n", verdict: "accept", fields: [("foo", "barbaz")]),
        field("leading tab", "foo:\tbarbaz\r\n", verdict: "accept", fields: [("foo", "barbaz")]),
        field("Content-Length 1", "Content-Length: 1\r\n", verdict: "partial"),
        field("Content-Length asdf", "Content-Length: asdf\r\n", verdict: "reject"),
        field("Content-Length 1x", "Content-Length: 1x\r\n", verdict: "reject"),
        field("Content-Length 1 and 2", "Content-Length: 1\r\nContent-Length: 2\r\n", verdict: "reject"),
        field("Content-Length 0 and 0", "Content-Length: 0\r\nContent-Length: 0\r\n", verdict: "accept"),
        field("Content-Length `0 , 0`", "Content-Length: 0 , 0\r\n", verdict: "accept"),
        field("Content-Length 1, 1, 2", "Content-Length: 1\r\nContent-Length: 1\r\nContent-Length: 2\r\n", verdict: "reject"),
        field("Content-Length `1 , 1,2`", "Content-Length: 1 , 1,2\r\n", verdict: "reject"),
        field("Content-Length of 21 ones", "Content-Length: \(String(repeating: "1", count: 21))\r\n", verdict: "reject"),
        field("Transfer-Encoding chunked", "Transfer-Encoding: chunked\r\n", verdict: "partial"),
        field("Transfer-Encoding cHuNkEd", "Transfer-Encoding: cHuNkEd\r\n", verdict: "partial"),
        field("Transfer-Encoding gzip", "Transfer-Encoding: gzip\r\n", verdict: "reject"),
        field("Transfer-Encoding chunked, then gzip", "Transfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n", verdict: "reject"),
    ]

    @Test func agreesWithH11() {
        let report = Conformance.check(Self.readers + Self.connection + Self.headers, suite: "h11")
        #expect(report.isEmpty, "\(report.count):\n\(report.joined(separator: "\n"))")
    }

    /// test_has_100_continue: `Expect: 100-continue`, any case, but not in HTTP/1.0 (RFC 9110 §10.1.1: a server MUST
    /// ignore it there).
    @Test func expectsContinue() throws {
        func framing(_ head: String) throws -> (HTTP1Framing, HTTPVersion) {
            let bytes = Array(head.utf8)
            var parser = HTTP1RequestParser()
            var framing = HTTP1Framing()
            var version = HTTPVersion.http1_1
            while true {
                switch try parser.next(in: bytes.span.bytes) {
                case let .requestLine(line): version = line.version
                case let .field(field): try framing.observe(field)
                case .end, .needsMore: return (framing, version)
                }
            }
        }
        #expect(try framing("GET / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n").0.expectsContinue(version: .http1_1))
        #expect(try !framing("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n").0.expectsContinue(version: .http1_1))
        #expect(try framing("GET / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-Continue\r\n\r\n").0.expectsContinue(version: .http1_1))
        let (http10, version) = try framing("GET / HTTP/1.0\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n")
        #expect(version == .http1_0)
        #expect(!http10.expectsContinue(version: version))
    }
}
