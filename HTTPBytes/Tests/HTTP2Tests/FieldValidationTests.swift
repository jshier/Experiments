import Bytes
import HTTP2
import HTTPBytes
import Testing

/// RFC 9113 §8.2–8.3: field characters, connection-specific fields, pseudo-header fields; cookie crumbs (§8.2.3); and
/// field blocks split across CONTINUATION frames.
@Suite struct FieldValidationTests {
    /// Checks `pairs` as a section, through the decoder (so names get their known names as they would on the wire).
    func validate(_ pairs: [(String, String)], _ section: HTTP2FieldValidator.Section, extendedConnect: Bool = false) -> HTTP2FieldError? {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        var output = [UInt8](repeating: 0, count: 4_096)
        do {
            let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
                for (name, value) in pairs {
                    try encoder.encode(name: latin1(name).span.bytes, value: latin1(value).span.bytes, indexing: .avoid, into: &span)
                }
                return span.byteCount
            }
            var validator = HTTP2FieldValidator(section, allowsExtendedConnect: extendedConnect)
            let block = Array(output[0..<written])
            let span = block.span.bytes
            do {
                while let field = try decoder.next(in: span) {
                    try validator.check(field)
                }
                _ = try validator.finish()
                return nil
            } catch let error as HTTP2FieldError {
                return error
            }
        } catch {
            Issue.record("encoding: \(error)")
            return nil
        }
    }

    static let request = [(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]

    @Test func validRequestsAndResponses() {
        #expect(validate(Self.request + [("accept", "*/*"), ("te", "trailers"), ("x-custom", "a\tb")], .request) == nil)
        #expect(validate([(":method", "CONNECT"), (":authority", "example.com:443")], .request) == nil)
        #expect(validate([(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/chat"),
                          (":authority", "example.com")], .request, extendedConnect: true) == nil)
        #expect(validate([(":method", "OPTIONS"), (":scheme", "https"), (":authority", "a"), (":path", "*")], .request) == nil)
        #expect(validate([(":status", "200"), ("content-type", "text/html")], .response) == nil)
        #expect(validate([("grpc-status", "0")], .trailers) == nil)
    }

    @Test func names() {
        #expect(validate(Self.request + [("Content-Type", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("x-Custom", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("x custom", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("x-a:b", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("x-\u{7F}", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("x-\u{E9}", "a")], .request) == .invalidName)
        #expect(validate(Self.request + [("", "a")], .request) == .invalidName)
    }

    @Test func values() {
        for bad in ["a\0b", "a\nb", "a\rb", " a", "a ", "\ta", "a\t"] {
            #expect(validate(Self.request + [("x-custom", bad)], .request) == .invalidValue, "\(bad.debugDescription)")
        }
        #expect(validate(Self.request + [("x-custom", "")], .request) == nil)
        #expect(validate(Self.request + [("x-custom", "a b\u{7F}\u{FF}")], .request) == nil) // only NUL, CR, LF are excluded
        // Long values, so the vector scan sees every position.
        for position in [0, 15, 16, 17, 40, 63] {
            var value = Array(repeating: Character("v"), count: 64)
            value[position] = "\r"
            #expect(validate(Self.request + [("x-custom", String(value))], .request) == .invalidValue)
        }
    }

    @Test func connectionSpecificFields() {
        for name in ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"] {
            #expect(validate(Self.request + [(name, "x")], .request) == .connectionSpecificField, "\(name)")
        }
        #expect(validate(Self.request + [("te", "gzip")], .request) == .invalidTE)
        #expect(validate(Self.request + [("te", "Trailers")], .request) == nil)
    }

    @Test func pseudoHeaders() {
        #expect(validate([(":method", "GET"), ("accept", "*/*"), (":scheme", "https"), (":path", "/")], .request) == .pseudoHeaderAfterRegularField)
        #expect(validate(Self.request + [(":method", "GET")], .request) == .duplicatePseudoHeader)
        #expect(validate(Self.request + [(":status", "200")], .request) == .invalidPseudoHeader)
        #expect(validate([(":foo", "bar")] + Self.request, .request) == .invalidPseudoHeader)
        #expect(validate([(":method", "GET"), (":path", "/")], .request) == .missingPseudoHeader)
        #expect(validate([(":method", "GET"), (":scheme", "https"), (":path", "")], .request) == .invalidPseudoHeaderValue)
        #expect(validate([(":method", "CONNECT"), (":authority", "a"), (":path", "/")], .request) == .missingPseudoHeader)
        #expect(validate([(":method", "CONNECT")], .request) == .missingPseudoHeader)
        #expect(validate([(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/"),
                          (":authority", "a")], .request) == .invalidPseudoHeader) // not enabled
        #expect(validate([(":method", "GET"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/"),
                          (":authority", "a")], .request, extendedConnect: true) == .invalidPseudoHeaderValue)
        #expect(validate([(":method", "CONNECT"), (":protocol", "websocket"), (":authority", "a")], .request, extendedConnect: true) == .missingPseudoHeader)
        #expect(validate([("content-type", "x")], .response) == .missingPseudoHeader)
        #expect(validate([(":status", "2000")], .response) == .invalidPseudoHeaderValue)
        #expect(validate([(":status", "2x0")], .response) == .invalidPseudoHeaderValue)
        // Below 100: no status code (`HTTPStatus(code:)` reads 100–999), never an interim response.
        for status in ["000", "099", "010"] {
            #expect(validate([(":status", status)], .response) == .invalidPseudoHeaderValue)
        }
        #expect(validate([(":status", "100")], .response) == nil && validate([(":status", "999")], .response) == nil)
        #expect(validate([(":path", "/")], .response) == .invalidPseudoHeader)
        #expect(validate([(":status", "200")], .trailers) == .invalidPseudoHeader)
        #expect(HTTP2FieldError.invalidName.http2Error(stream: HTTP2StreamID(3)) == .stream(HTTP2StreamID(3), .protocolError))
    }

    /// Values Huffman-coded whatever their length (so CR, LF, and NUL come from the Huffman decoder's flag, not a scan).
    @Test func huffmanVerdicts() throws {
        for (value, valid) in [("ok value", true), ("a\nb", false), ("a\u{0}b", false), ("abc\r", false), (" x", false), ("x\t", false),
                               ("\u{1}\u{7F}\u{FF}", true), ("", true)] {
            var coded = [UInt8](repeating: 0, count: 64)
            let bytes = latin1(value)
            let count = try coded.withOutputRawSpan { span throws(HPACKHuffmanError) -> Int in
                try HPACKHuffman.encode(bytes.span.bytes, into: &span)
                return span.byteCount
            }
            let block = [0x40, 0x01, 0x61, 0x80 | UInt8(count)] + coded[0..<count] // a: value, indexed
            var decoder = HPACKDecoder()
            func first(_ block: [UInt8]) throws(HPACKError) -> (Bool, [UInt8])? {
                let span = block.span.bytes
                var result: (Bool, [UInt8])?
                while let field = try decoder.next(in: span) {
                    if result == nil { result = (field.hasValidCharacters, Array(copying: field.value)) }
                }
                return result
            }
            for block in [block, [0xBE]] {
                let result = try first(block)
                #expect(result?.0 == valid, "\(value.debugDescription)")
                #expect(result?.1 == bytes)
            }
        }
    }

    /// The decoder's verdict, kept in dynamic entries: an indexed field's characters are checked when it was a literal.
    @Test func cachedVerdicts() throws {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        for _ in 0..<2 { // a literal with indexing, then the index
            var output = [UInt8](repeating: 0, count: 256)
            let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
                for (name, value) in [("x-good", "fine"), ("x-bad", "a\rb"), ("X-Upper", "v"), ("accept", " lead")] {
                    try encoder.encode(name: latin1(name).span.bytes, value: latin1(value).span.bytes, indexing: .prefer, into: &span)
                }
                return span.byteCount
            }
            let block = Array(output[0..<written])
            let span = block.span.bytes
            var verdicts: [Bool] = []
            var errors: [HTTP2FieldError?] = []
            while let field = try decoder.next(in: span) {
                verdicts.append(field.hasValidCharacters)
                var validator = HTTP2FieldValidator(.trailers)
                do throws(HTTP2FieldError) { try validator.check(field); errors.append(nil) } catch { errors.append(error) }
            }
            #expect(verdicts == [true, false, false, false])
            #expect(errors == [nil, .invalidValue, .invalidName, .invalidValue])
        }
    }

    @Test func pseudoHeadersSeen() throws {
        var validator = HTTP2FieldValidator(.response)
        try validator.check(name: (":status" as StaticString).bytes, value: ("404" as StaticString).bytes, knownName: .pseudoStatus)
        let seen = try validator.finish()
        #expect(seen.status == 404 && seen.contains(.pseudoStatus) && !seen.contains(.pseudoPath))
    }

    @Test func cookieCrumbs() throws {
        var fields = HTTPFieldStore()
        try fields.append(.pseudoMethod, value: Array("GET".utf8).span.bytes)
        try fields.append(.cookie, value: Array("a=b".utf8).span.bytes)
        try fields.append(.accept, value: Array("*/*".utf8).span.bytes)
        try fields.append(.cookie, value: Array("c=d".utf8).span.bytes, flags: HTTPFieldStore.neverIndexed)
        try fields.append(.cookie, value: Array("e=f".utf8).span.bytes)
        var http1 = HTTPFieldStore()
        var scratch: [UInt8] = []
        try HTTP2Cookies.copyJoiningCookies(fields, into: &http1, scratch: &scratch)
        #expect(http1.count == 2)
        #expect(http1.field(at: 0).knownName == .cookie && text(http1.field(at: 0).value) == "a=b; c=d; e=f")
        #expect(http1.flags(at: 0) == HTTPFieldStore.neverIndexed)
        #expect(http1.field(at: 1).knownName == .accept)
    }

    /// A block split across HEADERS and CONTINUATION, at every point.
    @Test func continuationFragments() throws {
        var encoder = HPACKEncoder()
        var store = HTTPFieldStore()
        try store.append(.userAgent, value: Array("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)".utf8).span.bytes)
        try store.append(.accept, value: Array("text/html,application/xhtml+xml".utf8).span.bytes)
        let block = try encodeBlock(&encoder, store)
        var buffer = HTTP2FieldBlockBuffer()
        for cut in 0...block.count {
            buffer.removeAll()
            try buffer.append(block.span.bytes.extracting(0..<cut))
            try buffer.append(block.span.bytes.extracting(cut..<block.count))
            var decoder = HPACKDecoder()
            var decoded: [String] = []
            let joined = buffer.block
            while let field = try decoder.next(in: joined) {
                decoded.append(text(field.value))
            }
            #expect(decoded == ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "text/html,application/xhtml+xml"])
        }
        var small = HTTP2FieldBlockBuffer(maximumByteCount: 8)
        #expect(throws: HTTP2Error.connection(.enhanceYourCalm)) { try small.append(block.span.bytes) }
    }
}
