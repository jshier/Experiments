import Bytes
import HTTP2
import HTTPBytes
import Testing

/// HTTP/2's frame parser, HPACK, and field blocks against a review's findings (2026-11-23): fields that would smuggle an
/// HTTP/1 head, stream errors a caller couldn't skip, HTTP/1 names and connection-specific fields encoded as they came,
/// a decoder reused mid-block, and CONTINUATION floods.
@Suite struct HardeningTests {
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - decode(_:into:) checks fields

    /// The review's block: a value with CR LF (an HTTP/1 field of the sender's choosing once written into a head) and an
    /// uppercase name, both stored by `decode(_:into:)`.
    @Test func decodeIntoRejectsMalformedFields() throws {
        let value = Self.bytes("1\r\nTransfer-Encoding: chunked")
        var block: [UInt8] = [0x82, 0x00, 0x03] + Self.bytes("x-a") + [UInt8(value.count)] + value
        block += [0x00, 0x03] + Self.bytes("X-B") + [0x01] + Self.bytes("v")
        var decoder = HPACKDecoder()
        var store = HTTPFieldStore()
        #expect(throws: HPACKError.malformedField) { try decoder.decode(block.span.bytes, into: &store) }
        #expect(store.count == 1)            // :method, before the malformed field
        #expect(HPACKError.malformedField.http2Error(stream: HTTP2StreamID(1)) == .stream(HTTP2StreamID(1), .protocolError))
        // The block was decoded to its end: the decoder takes the next one.
        var next = HTTPFieldStore()
        let path: [UInt8] = [0x84]
        try decoder.decode(path.span.bytes, into: &next)
        #expect(next.count == 1 && next.field(at: 0).knownName == .pseudoPath)

        let rejected: [[UInt8]] = [
            [0x00, 0x03] + Self.bytes("X-B") + [0x01] + Self.bytes("v"),                  // an uppercase name
            [0x00, 0x04] + Self.bytes(":foo") + [0x01] + Self.bytes("v"),                 // an unknown pseudo-header
            [0x00, 0x01] + Self.bytes("a") + [0x02] + Self.bytes(" v"),                   // a leading space
            [0x0F, 0x2A, 0x07] + Self.bytes("chunked"),                                   // transfer-encoding (static 57)
            [0x00, 0x0A] + Self.bytes("connection") + [0x05] + Self.bytes("close"),
            [0x00, 0x02] + Self.bytes("te") + [0x04] + Self.bytes("gzip"),
        ]
        for block in rejected {
            var decoder = HPACKDecoder()
            var store = HTTPFieldStore()
            #expect(throws: HPACKError.malformedField, "\(block)") { try decoder.decode(block.span.bytes, into: &store) }
            #expect(store.isEmpty)
        }
        // `te: trailers` is allowed, in any case.
        var decoder2 = HPACKDecoder()
        var store2 = HTTPFieldStore()
        try decoder2.decode(([0x00, 0x02] + Self.bytes("te") + [0x08] + Self.bytes("Trailers")).span.bytes, into: &store2)
        #expect(store2.count == 1)
    }

    /// A malformed field inserted into the table still is (the peer's encoder did), and later blocks see it; the next
    /// block refers to it by index and is rejected again.
    @Test func malformedFieldsKeepTheTableInStep() throws {
        var decoder = HPACKDecoder()
        var store = HTTPFieldStore()
        let block = [0x82, 0x40, 0x01] + Self.bytes("a") + [0x03] + Self.bytes("x\ry") + [0x40, 0x01] + Self.bytes("b") + [0x01] + Self.bytes("z")
        #expect(throws: HPACKError.malformedField) { try decoder.decode(block.span.bytes, into: &store) }
        #expect(decoder.tableCount == 2)
        let older: [UInt8] = [0xBF], newer: [UInt8] = [0xBE]
        #expect(throws: HPACKError.malformedField) { try decoder.decode(older.span.bytes, into: &store) }   // 63: a: x\ry
        var later = HTTPFieldStore()
        try decoder.decode(newer.span.bytes, into: &later)                                             // 62: b: z
        #expect(later.count == 1 && text(later.field(at: 0).name) == "b")
    }

    /// `decode(_:into:)` finishes a block that passed the list limit, so the decoder is ready for the next.
    @Test func decodeIntoFinishesATooLargeBlock() throws {
        var decoder = HPACKDecoder(maximumHeaderListSize: 50)
        var store = HTTPFieldStore()
        let block: [UInt8] = [0x82, 0x40, 0x01, 0x61, 0x01, 0x62, 0x84]      // :method GET (42), a: b (34), :path / (38)
        #expect(throws: HPACKError.headerListTooLarge) { try decoder.decode(block.span.bytes, into: &store) }
        #expect(tableEntries(decoder) == fields([("a", "b")]))
        var next = HTTPFieldStore()
        let indexed: [UInt8] = [0xBE]
        try decoder.decode(indexed.span.bytes, into: &next)
        #expect(next.count == 1)
    }

    // MARK: - The decoder's place in a block

    @Test func anotherBlockMidBlockThrows() throws {
        var decoder = HPACKDecoder()
        let first: [UInt8] = [0x82, 0x84, 0x86]
        let second: [UInt8] = [0x40, 0x01, 0x61, 0x01, 0x62]
        let firstSpan = first.span.bytes
        #expect(try decoder.next(in: firstSpan)?.knownName == .pseudoMethod)
        // The caller left its loop: another block would be decoded from the first one's offset (here, in the middle of
        // the literal's name), with no error.
        #expect(throws: HPACKError.unfinishedBlock) { _ = try decoder.next(in: second.span.bytes) }
        #expect(throws: HPACKError.unfinishedBlock) { try decoder.skipRest(of: second.span.bytes) }
        #expect(HPACKError.unfinishedBlock.http2Error(stream: HTTP2StreamID(1)) == .connection(.internalError))
        // The same block goes on.
        #expect(try decoder.next(in: firstSpan)?.knownName == .pseudoPath)
        try decoder.skipRest(of: firstSpan)
        #expect(try decodeAll(&decoder, second) == fields([("a", "b")]))
        // A block abandoned on purpose: reset, then the next.
        #expect(try decoder.next(in: firstSpan) != nil)
        decoder.resetBlock()
        #expect(try decodeAll(&decoder, [0xBE]) == fields([("a", "b")]))
    }

    /// After `headerListTooLarge`, `next(in:)` used to go on to the field after the one that crossed the limit, which
    /// was silently dropped. Now only `skipRest(of:)` (or a reset) goes on.
    @Test func callsAfterAnErrorThrow() throws {
        var decoder = HPACKDecoder(maximumHeaderListSize: 50)
        let block: [UInt8] = [0x82, 0x40, 0x01, 0x61, 0x01, 0x62, 0x84]
        let span = block.span.bytes
        #expect(try decoder.next(in: span)?.knownName == .pseudoMethod)
        #expect(throws: HPACKError.headerListTooLarge) { _ = try decoder.next(in: span) }
        #expect(throws: HPACKError.unfinishedBlock) { _ = try decoder.next(in: span) }
        try decoder.skipRest(of: span)
        #expect(tableEntries(decoder) == fields([("a", "b")]))
        #expect(try decodeAll(&decoder, [0xBE]) == fields([("a", "b")]))

        // A compression error: nothing until a reset (the connection should end).
        var lost = HPACKDecoder()
        let invalid: [UInt8] = [0x80], valid: [UInt8] = [0x82]
        #expect(throws: HPACKError.invalidIndex) { _ = try lost.next(in: invalid.span.bytes) }
        #expect(throws: HPACKError.unfinishedBlock) { _ = try lost.next(in: invalid.span.bytes) }   // the same block again
        #expect(throws: HPACKError.unfinishedBlock) { _ = try lost.next(in: valid.span.bytes) }
        #expect(throws: HPACKError.unfinishedBlock) { try lost.skipRest(of: valid.span.bytes) }
        lost.resetBlock()
        #expect(try decodeAll(&lost, [0x82]).count == 1)
    }

    /// A raw literal name longer than the scratch buffer: the value decodes into the buffer from its start (the name
    /// stays in the block), not from past the buffer's end.
    @Test func longRawNameThenHuffmanValue() throws {
        var decoder = HPACKDecoder(maximumTableSize: 32, maximumHeaderListSize: 50)   // scratch: 50 bytes
        // Incremental indexing, a new name: raw, 128 bytes (127 + 1); the value Huffman-coded "aaaa" ('a' is 00011).
        var block: [UInt8] = [0x40, 0x7F, 0x01] + [UInt8](repeating: 0x6E, count: 128)
        block += [0x83, 0x18, 0xC6, 0x3F]
        #expect(throws: HPACKError.headerListTooLarge) { _ = try decodeAll(&decoder, block) }
        try decoder.skipRest(of: block.span.bytes)
        #expect(decoder.tableCount == 0)            // larger than the table: inserting it emptied it
        #expect(try decodeAll(&decoder, [0x82]).count == 1)
        // With room for it, the same field decodes: the value is right.
        var roomy = HPACKDecoder(maximumTableSize: 32, maximumHeaderListSize: 4_096)
        let decoded = try decodeAll(&roomy, block)
        #expect(decoded.map(\.value) == ["aaaa"])
        #expect(decoded.map(\.name.count) == [128])
    }

    // MARK: - The encoder: HTTP/1 fields to HTTP/2

    /// The review's case: fields from an HTTP/1 head kept their casing (`X-Request-Id`), and connection-specific fields
    /// went through, both malformed in HTTP/2.
    @Test(arguments: [false, true])
    func http1FieldsAreEncodedAsHTTP2Fields(huffman: Bool) throws {
        let longName = "X-" + String(repeating: "Long-Name-", count: 20)     // past the encoder's first scratch size
        // As an HTTP/1 head's fields are stored: names as sent, known names looked up ignoring case.
        let head: [(String, String)] = [
            ("Host", "a"), ("X-Request-Id", "7"), ("Connection", "keep-alive, X-Hop"), ("Transfer-Encoding", "chunked"),
            ("TE", "trailers, deflate"), ("Keep-Alive", "5"), ("Upgrade", "h2c"), ("Proxy-Connection", "x"),
            ("Content-Type", "text/plain"), (longName, "v"), ("User-agent", "u"),
        ]
        var store = HTTPFieldStore()
        for (name, value) in head { try store.append(name: Self.bytes(name).span.bytes, value: Self.bytes(value).span.bytes) }
        var encoder = HPACKEncoder()
        encoder.usesHuffmanCoding = huffman
        let block = try encodeBlock(&encoder, store)
        var decoder = HPACKDecoder()
        var validator = HTTP2FieldValidator(.trailers)
        var names: [String] = []
        while let field = try decoder.next(in: block.span.bytes) {
            names.append(text(field.name))
            try validator.check(field)
        }
        #expect(names == ["host", "x-request-id", "content-type", longName.lowercased(), "user-agent"])
        // A second time: the lowercased names are found in the dynamic table.
        let again = try encodeBlock(&encoder, store)
        #expect(again.count < block.count)
        #expect(try decodeAll(&decoder, again).map(\.name) == names)

        // `te: trailers` is kept.
        var trailers = HTTPFieldStore()
        try trailers.append(.te, value: Self.bytes("trailers").span.bytes)
        #expect(try decodeAll(&decoder, try encodeBlock(&encoder, trailers)).map(\.name) == ["te"])
    }

    // MARK: - Frames

    /// The review's case: stream errors were thrown with `consumed` 0, so a caller resetting the stream couldn't skip
    /// the frame and parsed it again.
    @Test func streamErrorsReportTheFrameSize() throws {
        var parser = HTTP2FrameParser()
        let priority = frame(2, stream: 1, [0, 0, 0, 0, 16, 0])                 // PRIORITY of 6 bytes
        let windowUpdate = frame(8, stream: 5, [0, 0, 0, 0])                    // a stream increment of 0
        let selfPriority = frame(2, stream: 7, [0, 0, 0, 7, 16])                // PRIORITY on itself
        let ping = frame(6, [1, 2, 3, 4, 5, 6, 7, 8])
        let bytes = priority + windowUpdate + selfPriority + ping
        var unread = bytes.span.bytes
        var errors: [HTTP2Error] = []
        var frames: [String] = []
        while unread.byteCount > 0 {
            var consumed = 0
            do {
                if case .ping = try parser.next(in: unread, consumed: &consumed) { frames.append("PING") }
            } catch {
                errors.append(error)
            }
            #expect(consumed > 0)
            unread = unread.extracting(droppingFirst: consumed)
        }
        #expect(errors == [.stream(HTTP2StreamID(1), .frameSizeError), .stream(HTTP2StreamID(5), .protocolError),
                           .stream(HTTP2StreamID(7), .protocolError)])
        #expect(frames == ["PING"])
    }

    /// HEADERS whose priority depends on its own stream: a stream error, but its field block (and CONTINUATION frames)
    /// must still be decoded (RFC 9113 §4.3). It used to be thrown, the block lost, and the CONTINUATION after it
    /// rejected as a connection error.
    @Test func headersDependingOnThemselvesKeepTheirBlock() throws {
        var parser = HTTP2FrameParser()
        var decoder = HPACKDecoder()
        var pending = HTTP2FieldBlockBuffer()
        // HEADERS on stream 3, PRIORITY flag, depends on 3, no END_HEADERS: `:method GET` and a literal inserted into the
        // table; then CONTINUATION with `:path /`.
        let headers = frame(1, flags: 0x20, stream: 3, [0, 0, 0, 3, 16, 0x82, 0x40, 0x01, 0x61, 0x01, 0x62])
        let continuation = frame(9, flags: 0x4, stream: 3, [0x84])
        let bytes = headers + continuation
        var unread = bytes.span.bytes
        var consumed = 0
        switch try parser.next(in: unread, consumed: &consumed) {
        case .rejectedHeaders(let stream, let block, let endHeaders, let error):
            #expect(stream == HTTP2StreamID(3) && !endHeaders && error == .stream(HTTP2StreamID(3), .protocolError))
            #expect(block.byteCount == 6)
            try pending.append(block)
        default:
            Issue.record("not rejected HEADERS")
        }
        #expect(consumed == headers.count)
        unread = unread.extracting(droppingFirst: consumed)
        switch try parser.next(in: unread, consumed: &consumed) {
        case .continuation(let stream, let block, let endHeaders):
            #expect(stream == HTTP2StreamID(3) && endHeaders)
            try pending.append(block)
        default:
            Issue.record("not CONTINUATION")
        }
        // Decoded and discarded: the table has the literal, as the peer's encoder expects.
        var discarded = 0
        while try decoder.next(in: pending.block) != nil { discarded += 1 }
        #expect(discarded == 3)
        #expect(tableEntries(decoder) == fields([("a", "b")]))
        // With END_HEADERS, nothing continues it.
        var single = HTTP2FrameParser()
        #expect(try describe(&single, frame(1, flags: 0x24, stream: 1, [0, 0, 0, 1, 1, 0x82])).0
            == "REJECTED HEADERS 1 1 true stream(stream 1, PROTOCOL_ERROR)")
        #expect(try describe(&single, frame(6, [1, 2, 3, 4, 5, 6, 7, 8])).0 == "PING false 102030405060708")
    }

    // MARK: - CONTINUATION floods

    @Test func fragmentsAreLimited() throws {
        var buffer = HTTP2FieldBlockBuffer()
        #expect(buffer.isEmpty)
        let fragment: [UInt8] = [0x82]
        for _ in 0..<64 { try buffer.append(fragment.span.bytes) }
        #expect(throws: HTTP2Error.connection(.enhanceYourCalm)) { try buffer.append(fragment.span.bytes) }
        buffer.removeAll()
        // Empty fragments count: an endless run of empty CONTINUATION frames is a flood too.
        let empty: [UInt8] = []
        try buffer.append(empty.span.bytes)
        #expect(!buffer.isEmpty && buffer.count == 1)
        for _ in 1..<64 { try buffer.append(empty.span.bytes) }
        #expect(throws: HTTP2Error.connection(.enhanceYourCalm)) { try buffer.append(empty.span.bytes) }
        // A smaller limit.
        var small = HTTP2FieldBlockBuffer(maximumFragmentCount: 2)
        try small.append(fragment.span.bytes)
        try small.append(fragment.span.bytes)
        #expect(throws: HTTP2Error.connection(.enhanceYourCalm)) { try small.append(empty.span.bytes) }
        small.removeAll()
        #expect(small.isEmpty)
        try small.append(fragment.span.bytes)
    }
}
