import HTTP1
import HTTPBytes
import Testing

// Test vectors transcribed from Go's net/http (golang/go at 4f55df0: src/net/http/readrequest_test.go, response_test.go,
// transfer_test.go, internal/chunked_test.go). Copyright 2010–2011 The Go Authors; BSD-style license
// (https://go.dev/LICENSE): "Redistribution and use in source and binary forms, with or without modification, are
// permitted provided that … redistributions of source code must retain the above copyright notice, this list of
// conditions and the following disclaimer."

/// Go's net/http request, response, Content-Length, and chunked-coding tests, transcribed: each message read in full by
/// HTTPBytes (head, framing, body) and compared with what Go's reader does: accept (with the body, and whether the
/// connection stays open) or reject. Where HTTPBytes decides differently on purpose, `difference` says why; where it
/// falls short of RFC 9112, `issue` does.
@Suite struct GoNetHTTPTests {
    typealias Case = TranscribedCase

    static func b(_ string: String) -> [UInt8] { Array(string.utf8) }

    // MARK: readrequest_test.go: reqTests and badRequestTests

    static let requests: [Case] = [
        Case(name: "baseline (absolute-form, Content-Length 7)",
             input: b("GET http://www.techcrunch.com/ HTTP/1.1\r\nHost: www.techcrunch.com\r\nUser-Agent: Fake\r\n"
                 + "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nAccept-Language: en-us,en;q=0.5\r\n"
                 + "Accept-Encoding: gzip,deflate\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\nKeep-Alive: 300\r\n"
                 + "Content-Length: 7\r\nProxy-Connection: keep-alive\r\n\r\nabcdef\n???"),
             verdict: "accept", body: b("abcdef\n"), persistent: true),
        Case(name: "GET with no body", input: b("GET / HTTP/1.1\r\nHost: foo.com\r\n\r\n"), verdict: "accept", body: [], persistent: true),
        Case(name: "path that looks scheme-relative", input: b("GET //user@host/is/actually/a/path/ HTTP/1.1\r\nHost: test\r\n\r\n"),
             verdict: "accept", body: []),
        Case(name: "bogus absolute-path", input: b("GET ../../../../etc/passwd HTTP/1.1\r\nHost: test\r\n\r\n"), verdict: "reject",
             issue: "the request target's form isn't checked: `../../../../etc/passwd` is no request-target form (RFC 9112 §3.2)"),
        Case(name: "missing URL", input: b("GET  HTTP/1.1\r\nHost: test\r\n\r\n"), verdict: "reject"),
        Case(name: "chunked body with trailer",
             input: b("POST / HTTP/1.1\r\nHost: foo.com\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nfoo\r\n3\r\nbar\r\n0\r\nTrailer-Key: Trailer-Value\r\n\r\n"),
             verdict: "accept", body: b("foobar"), persistent: true),
        Case(name: "chunked body and a bogus Content-Length",
             input: b("POST / HTTP/1.1\r\nHost: foo.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 9999\r\n\r\n3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n"),
             verdict: "accept", body: b("foobar"), persistent: false,
             difference: "both framing fields: rejected (RFC 9112 §6.3 lets a server reject; Go drops Content-Length and closes after)"),
        Case(name: "chunked body and an invalid Content-Length",
             input: b("POST / HTTP/1.1\r\nHost: foo.com\r\nTransfer-Encoding: chunked\r\nContent-Length: notdigits\r\n\r\n3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n"),
             verdict: "reject"),
        Case(name: "CONNECT with a domain name", input: b("CONNECT www.google.com:443 HTTP/1.1\r\n\r\n"), verdict: "accept", body: [], persistent: true),
        Case(name: "CONNECT with an IP address", input: b("CONNECT 127.0.0.1:6060 HTTP/1.1\r\n\r\n"), verdict: "accept", body: [], persistent: true),
        Case(name: "CONNECT for RPC", input: b("CONNECT /_goRPC_ HTTP/1.1\r\n\r\n"), verdict: "accept", body: []), // Neither checks that CONNECT's target is authority-form (RFC 9112 §3.2.3).

        Case(name: "SSDP NOTIFY *", input: b("NOTIFY * HTTP/1.1\r\nServer: foo\r\n\r\n"), verdict: "accept", body: [], persistent: true),
        Case(name: "OPTIONS *", input: b("OPTIONS * HTTP/1.1\r\nServer: foo\r\n\r\n"), verdict: "accept", body: [], persistent: true),
        Case(name: "Connection: close", input: b("GET / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\n\r\n"),
             verdict: "accept", body: [], persistent: false),
        Case(name: "HEAD with Content-Length 0", input: b("HEAD / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"),
             verdict: "accept", body: [], persistent: false),
        Case(name: "HTTP/2 client preface", input: b("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), verdict: "accept",
             difference: "HTTP/2.0 isn't HTTP/1 (505); the preface is HTTP2's to recognize"),
        // badRequestTests (reqBytes: lines joined with CR LF, then an empty line).
        Case(name: "bad_connect_host",
             input: b("CONNECT []%20%48%54%54%50%2f%31%2e%31%0a%4d%79%48%65%61%64%65%72%3a%20%31%32%33%0a%0a HTTP/1.0\r\n\r\n"),
             verdict: "reject", issue: "the request target's form isn't checked: `[]…` isn't an authority (RFC 9112 §3.2.3)"),
        Case(name: "smuggle_two_contentlen", input: b("POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc\r\n\r\n"), verdict: "reject"),
        Case(name: "smuggle_two_content_len_head",
             input: b("HEAD / HTTP/1.1\r\nHost: foo\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n1234\r\n\r\n"), verdict: "reject"),
        Case(name: "leading_space_in_header", input: b("GET / HTTP/1.1\r\n Host: foo\r\n\r\n"), verdict: "reject"),
        Case(name: "leading_tab_in_header", input: b("GET / HTTP/1.1\r\n\tHost: foo\r\n\r\n"), verdict: "reject"),
    ]

    // MARK: transfer_test.go: TestParseContentLength

    static let contentLengths: [Case] = [("", false), ("3", true), ("+3", false), ("-3", false), ("9223372036854775807", true),
                                         ("9223372036854775808", false)].map { value, valid in
        Case(name: "Content-Length \"\(value)\"", input: b("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: \(value)\r\n\r\nabc"),
             verdict: valid ? "accept" : "reject",
             difference: value == "9223372036854775807" ? "Int.max bytes: accepted, and the body is incomplete (3 bytes here)" : nil)
    }

    // MARK: response_test.go: respTests and TestReadResponseErrors

    static func response(_ name: String, _ input: String, method: HTTPMethod = .get, verdict: String = "accept", body: String? = nil,
                         persistent: Bool? = nil, difference: String? = nil, issue: String? = nil) -> Case {
        Case(name: name, input: b(input), kind: .response(requestMethod: method), verdict: verdict, body: body.map(b),
             persistent: persistent, difference: difference, issue: issue)
    }

    /// `"\x1f\x8b\b\x00\x00\x00\x00\x00\x00\x00s\xf3\xf7\a\x00\xab'\xd4\x1a\x03\x00\x00\x00"`: 23 bytes of gzip.
    static let gzipBody: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0, 0x73, 0xF3, 0xF7, 0x07, 0, 0xAB, 0x27, 0xD4, 0x1A, 0x03, 0, 0, 0]

    static let responses: [Case] = [
        response("Unchunked response without Content-Length", "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nBody here\n",
                 body: "Body here\n", persistent: false),
        response("Unchunked HTTP/1.1 response without Content-Length or Connection", "HTTP/1.1 200 OK\r\n\r\nBody here\n",
                 body: "Body here\n", persistent: false),
        response("Unchunked HTTP/1.1 204 response without Content-Length", "HTTP/1.1 204 No Content\r\n\r\nBody should not be read!\n",
                 body: "", persistent: true),
        response("Unchunked response with Content-Length", "HTTP/1.0 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nBody here\n",
                 body: "Body here\n", persistent: false),
        response("Chunked response without Content-Length",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0a\r\nBody here\n\r\n09\r\ncontinued\r\n0\r\n\r\n",
                 body: "Body here\ncontinued", persistent: true),
        response("Trailer header but no TransferEncoding",
                 "HTTP/1.0 200 OK\r\nTrailer: Content-MD5, Content-Sources\r\nContent-Length: 10\r\nConnection: close\r\n\r\nBody here\n",
                 body: "Body here\n", persistent: false),
        response("Chunked response with Content-Length",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 10\r\n\r\n0a\r\nBody here\n\r\n0\r\n\r\n",
                 body: "Body here\n", persistent: false),
        response("Chunked response in response to a HEAD request", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
                 method: .head, body: "", persistent: true),
        response("Content-Length in response to a HEAD request", "HTTP/1.0 200 OK\r\nContent-Length: 256\r\n\r\n", method: .head,
                 body: "", persistent: false),
        response("Content-Length in response to a HEAD request with HTTP/1.1", "HTTP/1.1 200 OK\r\nContent-Length: 256\r\n\r\n",
                 method: .head, body: "", persistent: true),
        response("No Content-Length or Chunked in response to a HEAD request", "HTTP/1.0 200 OK\r\n\r\n", method: .head, body: "",
                 persistent: false),
        response("explicit Content-Length of 0", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", body: "", persistent: true),
        response("Status line without a Reason-Phrase, but trailing space", "HTTP/1.0 303 \r\n\r\n", body: "", persistent: false),
        response("Status line without a Reason-Phrase, and no trailing space", "HTTP/1.0 303\r\n\r\n", body: "", persistent: false),
        response("Issue 4767", "HTTP/1.1 206 Partial Content\r\nConnection: close\r\nContent-Type: multipart/byteranges; boundary=18a75608c8f47cef\r\n\r\nsome body",
                 body: "some body", persistent: false),
        response("206 Partial Content", "HTTP/1.1 206 Partial Content\r\nContent-Type: text/plain; charset=utf-8\r\nAccept-Ranges: bytes\r\n"
            + "Content-Range: bytes 0-5/1862\r\nContent-Length: 6\r\n\r\nfoobar", body: "foobar", persistent: true),
        response("Both keep-alive and close, on the same Connection line",
                 "HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: keep-alive, close\r\n\r\n", method: .head, body: "", persistent: false),
        response("Both keep-alive and close, on different Connection lines",
                 "HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: keep-alive\r\nConnection: close\r\n\r\n", method: .head, body: "",
                 persistent: false),
        response("HTTP1.0 bogus T-E no C-L", "HTTP/1.0 200 OK\r\nTransfer-Encoding: bogus\r\n\r\nBody here\n", body: "Body here\n",
                 persistent: false),
        response("HTTP1.0 bogus T-E with C-L", "HTTP/1.0 200 OK\r\nTransfer-Encoding: bogus\r\nContent-Length: 10\r\n\r\nBody here\n",
                 // Transfer-Encoding wins over Content-Length (RFC 9112 §6.3), and a coding that isn't chunked reads until close:
                 // the same bytes here (Go ignores Transfer-Encoding in HTTP/1.0 and reads 10).
                 body: "Body here\n", persistent: false),
        Case(name: "keep-alive timeout",
             input: b("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 23\r\nConnection: keep-alive\r\nKeep-Alive: timeout=7200\r\n\r\n")
                 + gzipBody,
             kind: .response(requestMethod: .get), verdict: "accept", body: gzipBody, persistent: true),
        response("Two spaces between HTTP version and status",
                 "HTTP/1.0  401 Unauthorized\r\nContent-type: text/html\r\nWWW-Authenticate: Basic realm=\"\"\r\n\r\nYour Authentication failed.\r\n",
                 body: "Your Authentication failed.\r\n", persistent: false,
                 difference: "one SP between the status line's parts (RFC 9112 §4); Go skips extra spaces"),
        // TestReadResponseErrors
        response("empty", "", verdict: "reject", difference: "no bytes yet: partial (Go's reader is at EOF: unexpected EOF)"),
        response("truncated head", "HTTP/1.1 301 Moved Permanently\r\nFoo: bar", verdict: "reject",
                 difference: "partial: more bytes may come (Go: unexpected EOF)"),
        response("HTTP/1.1 alone", "HTTP/1.1", verdict: "reject", difference: "partial: more bytes may come (Go: EOF, malformed)"),
        response("HTTP/2.0 alone", "HTTP/2.0", verdict: "reject", difference: "partial: more bytes may come (Go: EOF, malformed)"),
    ] + [("20X Unknown", false), ("abcd Unknown", false), ("二百/两百 OK", false), (" Unknown", false), ("c8 OK", false),
         ("0x12d Moved Permanently", false), ("200 OK", true), ("000 OK", true), ("001 OK", true), ("404 NOTFOUND", true),
         ("20 OK", false), ("00 OK", false), ("-10 OK", false), ("1000 OK", false), ("999 Done", true), ("-1 OK", false),
         ("-200 OK", false)].map { status, valid in
        response("status \"\(status)\"", "HTTP/1.1 \(status)\r\nFoo: bar\r\n\r\n", verdict: valid ? "accept" : "reject",
                 difference: status.hasPrefix("00") && valid ? "a status code is 100–599 (RFC 9110 §15): 0xx is rejected" : nil)
    } + [("HTTP/1.2", true), ("HTTP/2.0", true), ("HTTP/1.100000000002", false), ("HTTP/1.-1", false), ("HTTP/A.B", false),
         ("HTTP/1", false), ("http/1.1", false)].map { version, valid in
        response("version \"\(version)\"", "\(version) 200 OK\r\n\r\n", verdict: valid ? "accept" : "reject",
                 difference: version == "HTTP/2.0" ? "HTTP/2.0 isn't HTTP/1's framing: rejected" : nil)
    } + [
        response("two different Content-Lengths", "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nContent-Length: 7\r\n\r\nGopher hey\r\n", verdict: "reject"),
        response("two equal Content-Lengths", "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Length: 7\r\n\r\nGophers\r\n", body: "Gophers"),
        response("201 with 0 and 7", "HTTP/1.1 201 OK\r\nContent-Length: 0\r\nContent-Length: 7\r\n\r\nGophers\r\n", verdict: "reject"),
        response("300 with 0 and `0 `", "HTTP/1.1 300 OK\r\nContent-Length: 0\r\nContent-Length: 0 \r\n\r\nGophers\r\n", body: ""),
        response("two empty Content-Lengths", "HTTP/1.1 200 OK\r\nContent-Length:\r\nContent-Length:\r\n\r\nGophers\r\n", verdict: "reject"),
        response("206 with empty and `0 `", "HTTP/1.1 206 OK\r\nContent-Length:\r\nContent-Length: 0 \r\nConnection: close\r\n\r\nGophers\r\n",
                 verdict: "reject"),
        response("204 with 7 and 8", "HTTP/1.1 204 OK\r\nContent-Length: 7\r\nContent-Length: 8\r\n\r\n", verdict: "reject"),
        response("204 with 3 and 3", "HTTP/1.1 204 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n", body: ""),
        response("304 with 880 and 1", "HTTP/1.1 304 OK\r\nContent-Length: 880\r\nContent-Length: 1\r\n\r\n", verdict: "reject"),
        response("304 with 961 and 961", "HTTP/1.1 304 OK\r\nContent-Length: 961\r\nContent-Length: 961\r\n\r\n", body: ""),
        response("leading space in header", "HTTP/1.1 200 OK\r\n Content-type: text/html\r\nFoo: bar\r\n\r\n", verdict: "reject"),
        response("leading tab in header", "HTTP/1.1 200 OK\r\n\tContent-type: text/html\r\nFoo: bar\r\n\r\n", verdict: "reject"),
    ]

    // MARK: internal/chunked_test.go

    static func chunked(_ name: String, _ body: [UInt8], verdict: String, decoded: String? = nil, difference: String? = nil,
                        issue: String? = nil) -> Case {
        Case(name: name, input: b("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n") + body, verdict: verdict,
             body: decoded.map(b), difference: difference, issue: issue)
    }

    /// Go's `parseHexUint` table, as chunk-size lines (Go's reader returns after the last chunk's line; the empty
    /// trailer section is added so the body ends).
    static let chunkSizes: [Case] = [
        ("x", false, nil), ("0000000000000000", true, "16 hexadecimal digits are rejected (at most 15: no chunk is larger, no overflow), even zeros"),
        ("0000000000000001", true, "16 hexadecimal digits are rejected, even with leading zeros"),
        ("ffffffffffffffff", true, "2⁶⁴−1 is rejected: at most 15 hexadecimal digits"),
        ("000000000000bogus", false, nil), ("00000000000000000", false, nil), ("10000000000000000", false, nil),
        ("00000000000000001", false, nil), ("", false, nil),
    ].map { size, valid, difference in
        // Accepted sizes wait for their data (partial); zero ends the body.
        chunked("chunk size \"\(size)\"", b("\(size)\r\n"), verdict: valid ? (size.allSatisfy { $0 == "0" } ? "partial" : "partial") : "reject",
                difference: difference)
    } + (0..<1024).map { value in
        chunked("chunk size \(String(value, radix: 16))", b("\(String(value, radix: 16))\r\n"), verdict: "partial")
    }

    static let chunkedBodies: [Case] = [
        chunked("TestChunkReadMultiple: foo, bar", b("3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n"), verdict: "accept", decoded: "foobar"),
        chunked("TestChunkReadMultiple: 11 then 3", b("b\r\n0123456789a\r\n3\r\nfoo\r\n0\r\n\r\n"), verdict: "accept", decoded: "0123456789afoo"),
        chunked("TestChunkReadingIgnoresExtensions",
                b("7;ext=\"some quoted string\"\r\nhello, \r\n17;someext\r\nworld! 0123456789abcdef\r\n0;someextension=sometoken\r\n\r\n"),
                verdict: "accept", decoded: "hello, world! 0123456789abcdef"),
        chunked("TestChunkReadPartial", b("7\r\n1234567xx"), verdict: "reject"),
        chunked("TestIncompleteChunk: whole", b("4\r\nabcd\r\n5\r\nabc\r\n\r\n0\r\n\r\n"), verdict: "accept", decoded: "abcdabc\r\n"),
        chunked("TestChunkInvalidInputs: bare LF in chunk size", b("1\na\r\n0\r\n\r\n"), verdict: "reject"),
        chunked("TestChunkInvalidInputs: extra LF in chunk size", b("1\r\r\na\r\n0\r\n\r\n"), verdict: "reject"),
        chunked("TestChunkInvalidInputs: bare LF in chunk data", b("1\r\na\n0\r\n\r\n"), verdict: "reject"),
        chunked("TestChunkInvalidInputs: bare LF in chunk extension", b("1;\na\r\n0\r\n\r\n"), verdict: "reject"),
        // TestChunkReaderByteAtATime, at 100,000 one-byte chunks rather than 2²⁰.
        chunked("TestChunkReaderByteAtATime", Array(repeating: b("1\r\nX\r\n"), count: 100_000).flatMap(\.self) + b("0\r\n\r\n"),
                verdict: "accept", decoded: String(repeating: "X", count: 100_000)),
        // TestChunkReaderTooMuchOverhead, at 1,000 chunks (Go's limit, 16 KiB of overhead beyond 16 bytes a chunk, trips at
        // about 190).
        chunked("TestChunkReaderTooMuchOverhead", Array(repeating: b("1;" + String(repeating: "a", count: 100) + "\r\nX\r\n"), count: 1_000)
            .flatMap(\.self) + b("0\r\n\r\n"), verdict: "reject"),
    ]

    /// TestIncompleteChunk: every prefix of a valid body is incomplete.
    @Test func everyPrefixOfAChunkedBodyIsIncomplete() {
        let valid = Self.b("4\r\nabcd\r\n5\r\nabc\r\n\r\n0\r\n\r\n")
        let head = Self.b("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n")
        for length in 0..<valid.count {
            #expect(Conformance.parse(head + valid[..<length]) == .partial(.body), "\(Conformance.escaped(Array(valid[..<length])))")
        }
    }

    static var all: [Case] { requests + contentLengths + responses + chunkSizes + chunkedBodies }

    @Test func agreesWithGo() {
        let report = Conformance.check(Self.all, suite: "Go")
        #expect(report.isEmpty, "\(report.count):\n\(report.joined(separator: "\n"))")
    }
}
