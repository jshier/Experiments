import Bytes
import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// The head parsers' limits and their work on heads that arrive in pieces (a review's findings, 2026-11-23): empty lines
/// before the start line count against the head limit, a line fed a byte at a time is scanned once, and a head's
/// verdict, errors included, doesn't depend on how its bytes were split.
@Suite struct HeadLimitTests {
    /// What a parser made of a head, as text: events, then the end, `needsMore`, or the error.
    static func requestEvents(_ head: [UInt8], cuts: [Int]?, options: HTTP1ParserOptions = HTTP1ParserOptions()) -> [String] {
        var parser = HTTP1RequestParser(options: options)
        var events: [String] = []
        var length = cuts == nil ? head.count : 0
        var cuts = cuts ?? []
        while true {
            let event: HTTP1RequestEvent
            do { event = try parser.next(in: head.span.bytes.extracting(0..<length)) } catch {
                events.append("error \(error)")
                return events
            }
            switch event {
            case .requestLine(let line): events.append("\(string(line.method)) \(string(line.target)) \(line.version)")
            case .field(let field): events.append("\(string(field.name)): \(string(field.value))")
            case .end(let count):
                events.append("end \(count)")
                return events
            case .needsMore:
                if length == head.count {
                    events.append("needsMore")
                    return events
                }
                length = cuts.isEmpty ? head.count : min(head.count, length + cuts.removeFirst())
            }
        }
    }

    static func responseEvents(_ head: [UInt8], cuts: [Int]?, options: HTTP1ParserOptions = HTTP1ParserOptions()) -> [String] {
        var parser = HTTP1ResponseParser(options: options)
        var events: [String] = []
        var length = cuts == nil ? head.count : 0
        var cuts = cuts ?? []
        while true {
            let event: HTTP1ResponseEvent
            do { event = try parser.next(in: head.span.bytes.extracting(0..<length)) } catch {
                events.append("error \(error)")
                return events
            }
            switch event {
            case .statusLine(let line): events.append("\(line.version) \(line.status.code) \(string(line.reasonPhrase))")
            case .field(let field): events.append("\(string(field.name)): \(string(field.value))")
            case .end(let count):
                events.append("end \(count)")
                return events
            case .needsMore:
                if length == head.count {
                    events.append("needsMore")
                    return events
                }
                length = cuts.isEmpty ? head.count : min(head.count, length + cuts.removeFirst())
            }
        }
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - Leading empty lines

    @Test func leadingEmptyLinesCountAgainstTheLimit() {
        // 200 KB of CR LF: the caller must keep them all while the parser says `needsMore`, so they're part of the head.
        let empty = Array(repeating: Self.bytes("\r\n"), count: 100_000).flatMap { $0 }
        #expect(Self.requestEvents(empty, cuts: nil) == ["error headTooLarge"])
        #expect(Self.responseEvents(empty, cuts: nil) == ["error headTooLarge"])
        // In pieces too: two bytes (and an odd byte, a CR waiting for its LF) at a time.
        let pieces = [Int](repeating: 2, count: 40_000)
        #expect(Self.requestEvents(empty, cuts: pieces).last == "error headTooLarge")
        #expect(Self.requestEvents(empty, cuts: [1] + pieces).last == "error headTooLarge")
        #expect(Self.responseEvents(empty, cuts: [1] + pieces).last == "error headTooLarge")
        // Under the limit they're skipped, and the head's length includes them.
        let request = Array(empty.prefix(2_000)) + Self.bytes("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
        #expect(Self.requestEvents(request, cuts: nil) == ["GET / HTTP/1.1", "Host: a", "end \(request.count)"])
        let response = Array(empty.prefix(2_000)) + Self.bytes("HTTP/1.1 200 OK\r\n\r\n")
        #expect(Self.responseEvents(response, cuts: nil) == ["HTTP/1.1 200 OK", "end \(response.count)"])
        // A head that would end past the limit because of them.
        let options = HTTP1ParserOptions(maximumHeadByteCount: 2_010)
        #expect(Self.requestEvents(request, cuts: nil, options: options) == ["error headTooLarge"])
        #expect(Self.responseEvents(Array(empty.prefix(2_000)) + Self.bytes("HTTP/1.1 200 OK\r\n\r\n"), cuts: nil,
                                    options: options) == ["error headTooLarge"])
    }

    // MARK: - Lines in pieces

    /// A head fed a byte at a time: the same events as whole, and in time linear in its size. (Each line was scanned
    /// from its start on every call: a 60 KB value took 60,000 calls and 0.13 s in a release build, and the 200 KB
    /// lines here would take minutes in a debug one.)
    @Test(arguments: [
        "GET / HTTP/1.1\r\nx: VALUE\r\n\r\n",                // the walk's scan
        "GET / HTTP/1.1\r\nx: \tVALUE\r\n\r\n",              // a tab: the exact path's
        "GET / HTTP/1.1\r\nVALUE: x\r\n\r\n",                // a name
        "GET /VALUE HTTP/1.1\r\nx: y\r\n\r\n",               // a target
        "HTTP/1.1 200 VALUE\r\nx: y\r\n\r\n",                // a reason phrase
        "HTTP/1.1 200 \tVALUE\r\nx: y\r\n\r\n",              // a reason phrase with a tab
    ])
    func longLinesInPiecesAreScannedOnce(template: String) {
        let long = String(repeating: "a", count: 200_000)
        let head = Self.bytes(template.replacingOccurrences(of: "VALUE", with: long))
        let options = HTTP1ParserOptions(maximumHeadByteCount: 1 << 20, maximumTargetByteCount: 1 << 20)
        let ones = [Int](repeating: 1, count: head.count)
        let isResponse = template.hasPrefix("HTTP")
        let clock = ContinuousClock()
        var pieces: [String] = []
        let elapsed = clock.measure {
            pieces = isResponse ? Self.responseEvents(head, cuts: ones, options: options)
                : Self.requestEvents(head, cuts: ones, options: options)
        }
        let whole = isResponse ? Self.responseEvents(head, cuts: nil, options: options) : Self.requestEvents(head, cuts: nil, options: options)
        #expect(pieces == whole)
        #expect(whole.last == "end \(head.count)")
        // Linear: well under a second even in a debug build; quadratic: minutes.
        #expect(elapsed < .seconds(20), "\(elapsed)")
    }

    // MARK: - Verdicts by split

    /// The review's case: a malformed byte past the limit was 400 (`invalidFieldValue`) when the bytes came at once and
    /// 431 (`headTooLarge`) when they came in pieces. Bytes past the limit are never looked at now.
    @Test func errorsPastTheLimitDontDependOnTheSplit() {
        let options = HTTP1ParserOptions(maximumHeadByteCount: 120)
        let line = "GET / HTTP/1.1\r\n"
        let cases: [[UInt8]] = [
            // A NUL in a value past the limit.
            Self.bytes(line + "x-long: " + String(repeating: "v", count: 120) + "\0\r\n\r\n"),
            // A CR as the limit's last byte, then not an LF.
            Self.bytes(line + "x: " + String(repeating: "v", count: 120 - line.utf8.count - 3 - 1) + "\rX\r\n\r\n"),
            // A space in a name past the limit.
            Self.bytes(line + String(repeating: "n", count: 120) + " x: y\r\n\r\n"),
            // A bad method or version past the limit (after empty lines).
            Self.bytes(String(repeating: "\r\n", count: 60) + "G(T / HTTP/1.1\r\n\r\n"),
            Self.bytes(String(repeating: "\r\n", count: 54) + "GET / HTTP/9.1\r\n\r\n"),
        ]
        for head in cases {
            let whole = Self.requestEvents(head, cuts: nil, options: options)
            #expect(whole.last == "error headTooLarge", "\(String(decoding: head, as: UTF8.self).debugDescription)")
            for step in [1, 2, 3, 7, 64, 119, 121] {
                #expect(Self.requestEvents(head, cuts: [Int](repeating: step, count: head.count), options: options) == whole)
            }
        }
        let responses: [[UInt8]] = [
            Self.bytes("HTTP/1.1 200 " + String(repeating: "r", count: 120) + "\0\r\n\r\n"),
            Self.bytes("HTTP/1.1 200 " + String(repeating: "r", count: 120 - 13 - 1) + "\rX\r\n\r\n"),
            Self.bytes(String(repeating: "\r\n", count: 55) + "HTTP/1.1 2x0 OK\r\n\r\n"),
        ]
        for head in responses {
            let whole = Self.responseEvents(head, cuts: nil, options: options)
            #expect(whole.last == "error headTooLarge", "\(String(decoding: head, as: UTF8.self).debugDescription)")
            for step in [1, 2, 3, 7, 64, 119, 121] {
                #expect(Self.responseEvents(head, cuts: [Int](repeating: step, count: head.count), options: options) == whole)
            }
        }
    }

    /// The review's fuzzer, smaller: mutated heads parsed whole and in random pieces give the same events and the same
    /// error (not just an error).
    @Test func mutatedHeadsGiveTheSameVerdictInPieces() {
        var generator = SplitMix64(seed: 7)
        func below(_ n: Int) -> Int { Int(generator.next() % UInt64(n)) }
        let alphabet = Array("abcXY:- \t\r\n\r\n\r\n/?=1;,\u{7F}".utf8) + [0x00, 0x0B, 0x80, 0xFF, 0x0D, 0x0A]
        let requests = [
            "GET /index.html?x=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: curl/8\r\nAccept: */*\r\n\r\n",
            "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nX-Long: " + String(repeating: "v", count: 150) + "\r\n\r\nhello",
            "\r\nPATCH / HTTP/1.0\r\nA:b\r\nC:  d \t \r\nE:\r\n\r\n",
            "GET / HTTP/1.1\r\n" + String(repeating: "Name-1: value\r\n", count: 20) + "\r\n",
        ]
        let responses = [
            "HTTP/1.1 200 OK\r\nServer: x\r\nContent-Length: 5\r\n\r\nhello",
            "\r\nHTTP/1.0 404 Not\tFound\r\nX-Long: " + String(repeating: "v", count: 150) + "\r\n\r\n",
            "HTTP/1.1 204\r\nA:b\r\n\r\n",
        ]
        var mismatches: [String] = []
        for trial in 0..<6_000 {
            let isResponse = trial % 3 == 2
            let seeds = isResponse ? responses : requests
            var head = Self.bytes(seeds[(trial / 3) % seeds.count])
            for _ in 0..<below(4) {
                let index = below(head.count)
                switch below(3) {
                case 0: head[index] = alphabet[below(alphabet.count)]
                case 1: head.insert(alphabet[below(alphabet.count)], at: index)
                default: head.remove(at: index)
                }
            }
            for options in [HTTP1ParserOptions(), HTTP1ParserOptions(maximumHeadByteCount: 120, allowsBareLineFeed: true)] {
                let cuts = (0..<64).map { _ in 1 + below(below(2) == 0 ? 3 : 70) }
                let whole = isResponse ? Self.responseEvents(head, cuts: nil, options: options) : Self.requestEvents(head, cuts: nil, options: options)
                let pieces = isResponse ? Self.responseEvents(head, cuts: cuts, options: options) : Self.requestEvents(head, cuts: cuts, options: options)
                if whole != pieces, mismatches.count < 5 {
                    mismatches.append("\(String(decoding: head, as: UTF8.self).debugDescription): \(whole) / \(pieces)")
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }
}
