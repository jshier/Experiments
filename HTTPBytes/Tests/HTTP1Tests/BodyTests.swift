import Bytes
import BytesTestSupport
import HTTP1
import HTTPBytes
import Testing

/// Framing as RFC 9112 §6.3 decides it, and chunked coding both ways.
@Suite struct BodyTests {
    /// The framing a head's fields give.
    func framing(_ fields: [(String, String)]) throws(HTTP1Error) -> HTTP1Framing {
        var framing = HTTP1Framing()
        for (name, value) in fields {
            let nameBytes = Array(name.utf8), valueBytes = Array(value.utf8)
            try framing.observe(HTTPFieldView(name: nameBytes.span.bytes, value: valueBytes.span.bytes,
                                              knownName: HTTPFieldName(caseInsensitive: nameBytes.span.bytes)))
        }
        return framing
    }

    @Test func requestFraming() throws {
        #expect(try framing([]).requestBody(version: .http1_1) == .none)
        #expect(try framing([("Content-Length", "42")]).requestBody(version: .http1_1) == .length(42))
        #expect(try framing([("Content-Length", "0")]).requestBody(version: .http1_1) == .none)
        #expect(try framing([("Content-Length", "42, 42"), ("content-length", "42")]).requestBody(version: .http1_1) == .length(42))
        #expect(try framing([("Transfer-Encoding", "Chunked")]).requestBody(version: .http1_1) == .chunked)
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", "42, 43")]) }
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", "4 2")]) }
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", "-1")]) }
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", "")]) }
        #expect(throws: HTTP1Error.conflictingFraming) {
            _ = try framing([("Content-Length", "5"), ("Transfer-Encoding", "chunked")]).requestBody(version: .http1_1)
        }
        #expect(throws: HTTP1Error.conflictingFraming) { _ = try framing([("Transfer-Encoding", "chunked")]).requestBody(version: .http1_0) }
        #expect(throws: HTTP1Error.invalidTransferEncoding) { _ = try framing([("Transfer-Encoding", "chunked, gzip")]).requestBody(version: .http1_1) }
        #expect(throws: HTTP1Error.invalidTransferEncoding) {
            _ = try framing([("Transfer-Encoding", "chunked"), ("Transfer-Encoding", "chunked")]).requestBody(version: .http1_1)
        }
        #expect(throws: HTTP1Error.unsupportedTransferCoding) { _ = try framing([("Transfer-Encoding", "gzip, chunked")]).requestBody(version: .http1_1) }
        #expect(throws: HTTP1Error.invalidHost) { try framing([]).validateHost(version: .http1_1) }
        #expect(throws: HTTP1Error.invalidHost) { try framing([("Host", "a"), ("host", "b")]).validateHost(version: .http1_1) }
        try framing([]).validateHost(version: .http1_0)
        try framing([("Host", "a")]).validateHost(version: .http1_1)
    }

    @Test func responseFraming() throws {
        let length = try framing([("Content-Length", "10")])
        #expect(try length.responseBody(status: .ok, version: .http1_1, requestMethod: .get) == .length(10))
        #expect(try length.responseBody(status: .ok, version: .http1_1, requestMethod: .head) == .none)
        #expect(try length.responseBody(status: .notModified, version: .http1_1, requestMethod: .get) == .none)
        #expect(try length.responseBody(status: .noContent, version: .http1_1, requestMethod: .get) == .none)
        #expect(try length.responseBody(status: .continue, version: .http1_1, requestMethod: .get) == .none)
        #expect(try length.responseBody(status: .ok, version: .http1_1, requestMethod: .connect) == .none)
        #expect(try framing([]).responseBody(status: .ok, version: .http1_1, requestMethod: .get) == .untilClose)
        let both = try framing([("Content-Length", "10"), ("Transfer-Encoding", "gzip, chunked")])
        #expect(try both.responseBody(status: .ok, version: .http1_1, requestMethod: .get) == .chunked)
        #expect(try framing([("Transfer-Encoding", "gzip")]).responseBody(status: .ok, version: .http1_1, requestMethod: .get) == .untilClose)
        #expect(try framing([("Connection", "close")]).isPersistent(version: .http1_1, body: .none) == false)
        #expect(try framing([]).isPersistent(version: .http1_1, body: .length(3)))
        #expect(try framing([]).isPersistent(version: .http1_0, body: .none) == false)
        #expect(try framing([("Connection", "Keep-Alive")]).isPersistent(version: .http1_0, body: .none))
        #expect(try framing([("Expect", "100-Continue")]).expectsContinue(version: .http1_1))
    }

    /// Body bytes as chunks of the given sizes, with extensions and trailers sometimes.
    static func chunked(_ body: [UInt8], sizes: [Int], extensions: Bool, trailers: [String]) -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        for size in sizes where size > 0 {
            output += Array(String(size, radix: 16, uppercase: size % 2 == 0).utf8)
            if extensions { output += Array(" ;name=\"v a l\" ;x".utf8) }
            output += [0x0D, 0x0A] + body[offset..<offset + size] + [0x0D, 0x0A]
            offset += size
        }
        output += Array("0\r\n".utf8)
        for trailer in trailers {
            output += Array("\(trailer)\r\n".utf8)
        }
        return output + [0x0D, 0x0A]
    }

    /// Decodes `bytes` handed over `step` bytes at a time (as a socket might), dropping consumed bytes as it goes.
    static func decode(_ bytes: [UInt8], step: Int) throws -> (body: [UInt8], trailers: [String], consumed: Int) {
        var decoder = HTTP1ChunkedDecoder()
        var buffer: [UInt8] = []
        var delivered = 0, total = 0
        var body: [UInt8] = [], trailers: [String] = []
        while true {
            var consumed = 0
            var needsMore = false
            // The event borrows `buffer`: handle it in a scope that ends before `buffer` changes.
            do {
                switch try decoder.next(in: buffer.span.bytes, consumed: &consumed) {
                case let .data(data): for offset in 0..<data.byteCount {
                        body.append(data.load(fromByteOffset: offset, as: UInt8.self))
                    }
                case let .trailer(field): trailers.append("\(string(field.name)): \(string(field.value))")
                case .end: return (body, trailers, total + consumed)
                case .needsMore: needsMore = true
                }
            }
            if needsMore {
                guard delivered < bytes.count else { throw HTTP1Error.invalidChunkSize }
                let more = min(step, bytes.count - delivered)
                buffer += bytes[delivered..<delivered + more]
                delivered += more
            }
            buffer.removeFirst(consumed)
            total += consumed
        }
    }

    @Test(arguments: [1, 2, 3, 7, 64, 100_000])
    func chunkedRoundTrips(step: Int) throws {
        var generator = SplitMix64(seed: UInt64(step))
        let body = (0..<5_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        // 5,000 bytes in all.
        let sizes = [1, 2, 15, 16, 255, 256, 4095, 360]
        for (extensions, trailers) in [(false, []), (true, ["Expires: never", "X-Sum: 1"])] {
            let coded = Self.chunked(body, sizes: sizes, extensions: extensions, trailers: trailers)
            let decoded = try Self.decode(coded + Array("NEXT".utf8), step: step)
            #expect(decoded.body == body)
            #expect(decoded.trailers == trailers)
            #expect(decoded.consumed == coded.count)
        }
    }

    @Test func encoderWritesWhatTheDecoderReads() throws {
        var generator = SplitMix64(seed: 3)
        let body = (0..<70_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        var coded = [UInt8]()
        var offset = 0
        for size in [1, 9, 10, 15, 16, 17, 255, 256, 65_536, 4_000] where offset < body.count {
            let take = min(size, body.count - offset)
            try coded.append(alignedByteCapacity: 32) { writer throws(BytesError) in try HTTP1ChunkedEncoder.writeSizeLine(take, to: &writer) }
            coded += body[offset..<offset + take]
            try coded.append(alignedByteCapacity: 2) { writer throws(BytesError) in try HTTP1ChunkedEncoder.writeChunkEnd(to: &writer) }
            offset += take
        }
        try coded.append(alignedByteCapacity: 5) { writer throws(BytesError) in try HTTP1ChunkedEncoder.writeLastChunk(to: &writer) }
        #expect(try Self.decode(coded, step: 1_000).body == Array(body[..<offset]))
        #expect(Array(coded.suffix(5)) == Array("0\r\n\r\n".utf8))
    }

    @Test(arguments: [
        ("x\r\n", HTTP1Error.invalidChunkSize),
        ("\r\n", .invalidChunkSize),
        ("1000000000000000\r\n", .invalidChunkSize),
        ("5\rx", .invalidChunkSize),
        ("5;a\u{01}\r\n", .invalidChunkSize),
        ("3\r\nabcX", .invalidChunkEnd),
        ("3\nabc\r\n", .invalidChunkSize),
        ("0\r\nbad trailer\r\n\r\n", .invalidFieldName),
    ])
    func malformedChunksAreRejected(text: String, error: HTTP1Error) {
        #expect(throws: error) { _ = try Self.decode(Array(text.utf8) + Array("0\r\n\r\n".utf8), step: 100) }
    }

    @Test func extensionsHaveALimit() {
        var decoder = HTTP1ChunkedDecoder(maximumExtensionByteCount: 8)
        var consumed = 0
        let bytes = Array("5;abcdefghijk".utf8)
        #expect(throws: HTTP1Error.chunkExtensionsTooLong) { _ = try decoder.next(in: bytes.span.bytes, consumed: &consumed) }
    }
}

/// Heads written by `HTTP1HeadWriter` parse back to what was written.
@Suite struct HeadWriterTests {
    @Test func requestHeadsRoundTrip() throws {
        var store = HTTPFieldStore()
        try store.append(.host, value: bytes("example.com").span.bytes)
        try store.append(name: bytes("x-custom").span.bytes, value: bytes("a\tb").span.bytes)
        try store.append(.contentLength, value: bytes("5").span.bytes)
        let head = try [UInt8](alignedByteCapacity: 256) { (writer) throws(BytesError) in
            do {
                try HTTP1HeadWriter.writeRequestLine(.post, target: bytes("/upload?x=1").span.bytes, to: &writer)
                try HTTP1HeadWriter.writeFields(store, to: &writer)
                try HTTP1HeadWriter.writeEnd(to: &writer)
            } catch { throw BytesError.insufficientCapacity }
        }
        #expect(String(decoding: head, as: UTF8.self)
            == "POST /upload?x=1 HTTP/1.1\r\nHost: example.com\r\nx-custom: a\tb\r\nContent-Length: 5\r\n\r\n")
        let parsed = try #require(try parse(head))
        #expect(parsed.method == "POST" && parsed.fields == [["Host", "example.com"], ["x-custom", "a\tb"], ["Content-Length", "5"]])
    }

    @Test func statusLines() throws {
        for (status, reason, expected) in [(HTTPStatus.notFound, nil as String?, "HTTP/1.1 404 Not Found\r\n"),
                                           (HTTPStatus(code: 299)!, nil, "HTTP/1.1 299 \r\n"),
                                           (HTTPStatus.ok, "Fine", "HTTP/1.1 200 Fine\r\n")] {
            let reasonBytes = reason.map { Array($0.utf8) }
            let line = try [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in
                do {
                    if let reasonBytes {
                        try HTTP1HeadWriter.writeStatusLine(status, reasonPhrase: reasonBytes.span.bytes, to: &writer)
                    } else {
                        try HTTP1HeadWriter.writeStatusLine(status, to: &writer)
                    }
                } catch { throw BytesError.insufficientCapacity }
            }
            #expect(String(decoding: line, as: UTF8.self) == expected)
        }
    }

    @Test func invalidTargetsAreRefused() {
        for target in ["", "/a b", "/\u{7F}", "/é", "/a\r\n"] {
            var refused = false
            _ = try? [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in
                do throws(HTTP1HeadWriterError) { try HTTP1HeadWriter.writeRequestLine(.get, target: bytes(target).span.bytes, to: &writer) } catch { refused = error == .invalidTarget }
            }
            #expect(refused, "\(target)")
        }
    }
}

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// Regressions from the adversarial review (2026-11-23): each was a confirmed defect.
@Suite struct ReviewRegressionTests {
    func framing(_ fields: [(String, String)]) throws(HTTP1Error) -> HTTP1Framing {
        var framing = HTTP1Framing()
        for (name, value) in fields {
            let nameBytes = Array(name.utf8), valueBytes = Array(value.utf8)
            try framing.observe(HTTPFieldView(name: nameBytes.span.bytes, value: valueBytes.span.bytes,
                                              knownName: HTTPFieldName(caseInsensitive: nameBytes.span.bytes)))
        }
        return framing
    }

    /// `Content-Length: ,` named no length and was ignored, so it slipped past the CL + TE check.
    @Test func contentLengthWithoutANumber() {
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", ",")]) }
        #expect(throws: HTTP1Error.invalidContentLength) { _ = try framing([("Content-Length", " , ,")]) }
    }

    /// CONNECT with a body length: the bytes after the head would be a body to one reader and the next request to another.
    @Test func connectWithContentLength() throws {
        #expect(throws: HTTP1Error.conflictingFraming) {
            _ = try framing([("Content-Length", "5")]).requestBody(version: .http1_1, method: .connect)
        }
        #expect(try framing([("Content-Length", "0")]).requestBody(version: .http1_1, method: .connect) == HTTP1BodyLength.none)
    }

    /// A quoted comma doesn't end a transfer coding (`x;p=", chunked;q="` is one coding, not one ending in chunked).
    @Test func quotedCommasInLists() throws {
        let framing = try framing([("Transfer-Encoding", "x;p=\", chunked;q=\"")])
        #expect(try framing.responseBody(status: .ok, version: .http1_1, requestMethod: .get) == .untilClose)
        var elements: [String] = []
        let value = Array("a, \"b, c\", d;q=\"x\\\"y,z\"".utf8)
        HTTPList.forEachElement(of: value.span.bytes) { element in elements.append(string(element)) }
        #expect(elements == ["a", "\"b, c\"", "d;q=\"x\\\"y,z\""])
    }

    /// The trailer section had no limit: an endless trailer line was buffered forever.
    @Test func trailerSectionLimit() {
        var decoder = HTTP1ChunkedDecoder()
        decoder.maximumTrailerSectionByteCount = 1_000
        var consumed = 0
        let bytes = Array("0\r\nx: ".utf8) + [UInt8](repeating: 0x61, count: 2_000)
        #expect(throws: HTTP1Error.headTooLarge) {
            var unread = bytes.span.bytes
            while true {
                guard case .needsMore = try decoder.next(in: unread, consumed: &consumed) else { break }
                if consumed == 0 { break }
                unread = unread.extracting(droppingFirst: consumed)
            }
        }
    }

    /// Whitespace after an extension name was accepted before the line end but not after a value: neither is in the grammar.
    @Test func extensionWhitespaceIsConsistent() {
        for line in ["5;a \r\n", "5;a=b \r\n", "5 \r\n", "5;a\t\r\n"] {
            var decoder = HTTP1ChunkedDecoder()
            var consumed = 0
            let bytes = Array((line + "xxxxx\r\n0\r\n\r\n").utf8)
            #expect(throws: HTTP1Error.invalidChunkSize, "\(line)") { _ = try decoder.next(in: bytes.span.bytes, consumed: &consumed) }
        }
        for line in ["5;a\r\n", "5 ;a\r\n", "5;a = b\r\n", "5;a=\"b c\";d\r\n"] {
            var decoder = HTTP1ChunkedDecoder()
            var consumed = 0
            let bytes = Array((line + "xxxxx\r\n0\r\n\r\n").utf8)
            #expect(throws: Never.self, "\(line)") { _ = try decoder.next(in: bytes.span.bytes, consumed: &consumed) }
        }
    }

    /// HTTP/2 fields written as HTTP/1: a value with CR LF can't add fields, and pseudo-headers aren't written.
    @Test func headWriterRefusesInjection() throws {
        var store = HTTPFieldStore()
        let injected = Array("1\r\nTransfer-Encoding: chunked".utf8)
        #expect(throws: HTTPFieldError.invalidValue) {
            try store.append(HTTPFieldView(name: Array("x-a".utf8).span.bytes, value: injected.span.bytes, knownName: nil))
        }
        var refused: HTTP1HeadWriterError?
        _ = try? [UInt8](alignedByteCapacity: 128) { (writer) throws(BytesError) in
            do throws(HTTP1HeadWriterError) {
                try HTTP1HeadWriter.writeField(name: Array("x-a".utf8).span.bytes, value: injected.span.bytes, to: &writer)
            } catch { refused = error }
        }
        #expect(refused == .invalidFieldValue)
        try store.append(.pseudoMethod, value: Array("GET".utf8).span.bytes)
        try store.append(.host, value: Array("a".utf8).span.bytes)
        let head = try [UInt8](alignedByteCapacity: 128) { (writer) throws(BytesError) in
            do { try HTTP1HeadWriter.writeFields(store, to: &writer) } catch { throw BytesError.invalidValue }
        }
        #expect(String(decoding: head, as: UTF8.self) == "Host: a\r\n")
    }
}
