import Bytes
import BytesTestSupport
import HTTP3
import Testing

func varint(_ value: UInt64) -> [UInt8] {
    (try? [UInt8](byteCapacity: 8, mode: BigEndianBytes.self) { (writer) throws(BytesError) in
        try QUICVariableLengthInteger.write(value, to: &writer)
    }) ?? []
}

func h3frame(_ type: UInt64, _ payload: [UInt8]) -> [UInt8] { varint(type) + varint(UInt64(payload.count)) + payload }

/// Parses every frame in `bytes` handed over `step` bytes at a time; describes each.
func describeAll(_ bytes: [UInt8], kind: HTTP3StreamKind, role: HTTP3Role? = nil, step: Int = .max) throws(HTTP3Error) -> [String] {
    var parser = HTTP3FrameParser(streamKind: kind, role: role)
    var buffer: [UInt8] = [], delivered = 0
    var described: [String] = []
    while true {
        var consumed = 0
        var needsMore = false
        do {
            switch try parser.next(in: buffer.span.bytes, consumed: &consumed) {
            case let .data(payload): described.append("DATA \(payload.byteCount)")
            case let .headers(section): described.append("HEADERS \(section.byteCount)")
            case let .cancelPush(id): described.append("CANCEL_PUSH \(id)")
            case let .settings(settings):
                var pairs: [String] = []
                try settings.forEach { id, value in pairs.append("\(id.rawValue)=\(value)") }
                described.append("SETTINGS \(pairs.joined(separator: ","))")
            case let .pushPromise(id, section): described.append("PUSH_PROMISE \(id) \(section.byteCount)")
            case let .goaway(id): described.append("GOAWAY \(id)")
            case let .maxPushID(id): described.append("MAX_PUSH_ID \(id)")
            case let .priorityUpdate(push, id, value): described.append("PRIORITY_UPDATE \(push) \(id) \(value.byteCount)")
            case let .unknown(type, payload, _): described.append("UNKNOWN \(type.rawValue) \(payload.byteCount)")
            case .needsMore:
                // Nothing consumed, nothing changed: the same bytes come again with more.
                #expect(consumed == 0)
                needsMore = true
            }
        }
        buffer.removeFirst(consumed)
        if needsMore {
            if delivered == bytes.count { return described }
            let more = min(step, bytes.count - delivered)
            buffer += bytes[delivered..<delivered + more]
            delivered += more
        }
    }
}

/// DATA parts merged, and unknown frames' parts, to compare runs fed in different steps.
func merged(_ frames: [String]) -> [String] {
    var result: [String] = []
    for frame in frames {
        // "DATA n" or "UNKNOWN type n": the same words but the last, which is a count.
        let words = frame.split(separator: " "), lastWords = result.last?.split(separator: " ") ?? []
        if words.first == "DATA" || words.first == "UNKNOWN", words.dropLast() == lastWords.dropLast(),
           let a = Int(lastWords.last ?? ""), let b = Int(words.last ?? "") {
            result[result.count - 1] = (words.dropLast().map(String.init) + ["\(a + b)"]).joined(separator: " ")
        } else {
            result.append(frame)
        }
    }
    return result
}

@Suite struct HTTP3FrameTests {
    @Test func variableLengthIntegers() {
        // RFC 9000 Appendix A.1's examples.
        let examples: [([UInt8], UInt64)] = [
            ([0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C], 151_288_809_941_952_652),
            ([0x9D, 0x7F, 0x3E, 0x7D], 494_878_333), ([0x7B, 0xBD], 15_293), ([0x25], 37), ([0x40, 0x25], 37),
        ]
        for (bytes, value) in examples {
            for padding in [0, 10] {
                let read = QUICVariableLengthInteger.read((bytes + [UInt8](repeating: 0xFF, count: padding)).span.bytes, at: 0)
                #expect(read?.value == value && read?.length == bytes.count)
            }
            #expect(QUICVariableLengthInteger.read(Array(bytes.dropLast()).span.bytes, at: 0) == nil)
        }
        var generator = SplitMix64(seed: 5)
        for _ in 0..<10_000 {
            let value = generator.next() >> (generator.next() % 64) & QUICVariableLengthInteger.maximum
            let encoded = varint(value)
            #expect(encoded.count == QUICVariableLengthInteger.length(of: value))
            #expect(QUICVariableLengthInteger.read(encoded.span.bytes, at: 0)?.value == value)
        }
    }

    @Test func requestStreamFrames() throws {
        let stream = h3frame(1, [1, 2, 3]) + h3frame(0, [UInt8](repeating: 7, count: 300)) + h3frame(0x21, [9])
            + h3frame(5, varint(4) + [8, 8]) + h3frame(0, [])
        let whole = try describeAll(stream, kind: .request)
        #expect(whole == ["HEADERS 3", "DATA 300", "UNKNOWN 33 1", "PUSH_PROMISE 4 2", "DATA 0"])
        for step in [1, 2, 7, 64] {
            #expect(try merged(describeAll(stream, kind: .request, step: step)) == whole, "step \(step)")
        }
    }

    @Test func controlStream() throws {
        let settings = h3frame(4, varint(1) + varint(4096) + varint(7) + varint(16) + varint(0x1F * 3 + 0x21) + varint(1))
        let stream = settings + h3frame(7, varint(8)) + h3frame(0xD, varint(10)) + h3frame(0xF0700, varint(4) + Array("u=1".utf8))
        #expect(try describeAll(stream, kind: .control) == ["SETTINGS 1=4096,7=16,126=1", "GOAWAY 8", "MAX_PUSH_ID 10", "PRIORITY_UPDATE false 4 3"])
    }

    @Test(arguments: [
        (h3frame(7, varint(0)), HTTP3StreamKind.control, HTTP3Error.connection(.missingSettings)),
        (h3frame(4, []) + h3frame(4, []), .control, .connection(.frameUnexpected)),
        (h3frame(4, []) + h3frame(0, [1]), .control, .connection(.frameUnexpected)),
        (h3frame(4, []), .request, .connection(.frameUnexpected)),
        (h3frame(7, varint(0)), .request, .connection(.frameUnexpected)),
        (h3frame(5, varint(1)), .push, .connection(.frameUnexpected)),
        (h3frame(0x9, [1]), .request, .connection(.frameUnexpected)), // HTTP/2's CONTINUATION
        (h3frame(4, []) + h3frame(7, varint(8) + [0]), .control, .connection(.frameError)), // GOAWAY with extra bytes
        (h3frame(4, [0x41]), .control, .connection(.frameError)), // a cut-short setting
    ])
    func malformedFramesAreRejected(bytes: [UInt8], kind: HTTP3StreamKind, error: HTTP3Error) {
        #expect(throws: error) { _ = try describeAll(bytes, kind: kind) }
    }

    @Test func dataHeaderAloneNeedsMore() throws {
        // A DATA frame's type and length with none of its payload yet: nothing consumed, so the caller keeps the two
        // bytes, and the payload that follows them is the body (the header bytes were once handed out as body).
        var parser = HTTP3FrameParser(streamKind: .request)
        var consumed = -1
        let headers = h3frame(1, [0xC0])
        guard case .headers = try parser.next(in: headers.span.bytes, consumed: &consumed) else { Issue.record("HEADERS"); return }
        let header: [UInt8] = [0x00, 0x05]
        guard case .needsMore = try parser.next(in: header.span.bytes, consumed: &consumed) else { Issue.record("needsMore"); return }
        #expect(consumed == 0)
        let more = header + Array("hello".utf8)
        guard case let .data(body) = try parser.next(in: more.span.bytes, consumed: &consumed) else { Issue.record("DATA"); return }
        #expect(Array(copying: body) == Array("hello".utf8))
        #expect(consumed == 7)
        // The same for a frame type it doesn't know.
        let unknown: [UInt8] = [0x21, 0x03]
        guard case .needsMore = try parser.next(in: unknown.span.bytes, consumed: &consumed) else { Issue.record("needsMore"); return }
        #expect(consumed == 0)
    }

    @Test func unknownFramesOfAnySizeAreStreamed() throws {
        // A reserved type (0x21) with a 2 MiB payload, past the 1 MiB limit: ignored as it arrives (§7.2.8, §9), not
        // H3_EXCESSIVE_LOAD; a known frame past the limit still is.
        let length = 2 << 20
        let stream = h3frame(1, [1]) + varint(0x21) + varint(UInt64(length)) + [UInt8](repeating: 0xAB, count: length) + h3frame(0, [7, 7])
        for step in [65_536, 1 << 30] {
            let described = try merged(describeAll(stream, kind: .request, step: step))
            #expect(described == ["HEADERS 1", "UNKNOWN 33 \(length)", "DATA 2"], "step \(step)")
        }
        var parser = HTTP3FrameParser(streamKind: .request)
        var consumed = 0, remaining = [Int]()
        var bytes = Array(stream.dropFirst(3))
        while !bytes.isEmpty {
            let chunk = Array(bytes.prefix(1 << 20))
            guard case let .unknown(type, _, left) = try parser.next(in: chunk.span.bytes, consumed: &consumed) else { break }
            #expect(type.rawValue == 0x21)
            remaining.append(left)
            bytes.removeFirst(consumed)
            if left == 0 { break }
        }
        #expect(remaining == [length - ((1 << 20) - 5), 5, 0]) // a 5-byte header, then 1 MiB parts
        #expect(throws: HTTP3Error.connection(.excessiveLoad)) {
            _ = try describeAll(varint(1) + varint(UInt64(length)), kind: .request)
        }
    }

    @Test(arguments: [
        // Request and push streams' order (§4.1).
        (h3frame(0, [1]), HTTP3StreamKind.request, HTTP3Role?.none), // DATA before HEADERS
        (h3frame(0x21, [1]) + h3frame(0, [1]), .push, nil), // unknown frames don't count
        (h3frame(1, [1]) + h3frame(0, [1]) + h3frame(1, [1]) + h3frame(0, [1]), .request, nil), // DATA after trailers
        (h3frame(1, [1]) + h3frame(0, [1]) + h3frame(1, [1]) + h3frame(1, [1]), .request, nil), // HEADERS after trailers
        (h3frame(1, [1]) + h3frame(1, [1]) + h3frame(0, [1]), .request, .server), // a request's second HEADERS is trailers
        // What only the other role sends.
        (h3frame(1, [1]) + h3frame(5, varint(1)), .request, .server), // PUSH_PROMISE to a server
        (h3frame(4, []) + h3frame(0xD, varint(1)), .control, .client), // MAX_PUSH_ID to a client
        (h3frame(4, []) + h3frame(0xF0700, varint(0)), .control, .client), // PRIORITY_UPDATE to a client
        (h3frame(4, []) + h3frame(0xF0701, varint(0)), .control, .client),
    ] as [([UInt8], HTTP3StreamKind, HTTP3Role?)])
    func frameOrderAndRoles(bytes: [UInt8], kind: HTTP3StreamKind, role: HTTP3Role?) {
        #expect(throws: HTTP3Error.connection(.frameUnexpected)) { _ = try describeAll(bytes, kind: kind, role: role) }
        // Rejected when the frame's type arrives, before its payload.
        #expect(throws: HTTP3Error.connection(.frameUnexpected)) { _ = try describeAll(bytes, kind: kind, role: role, step: 1) }
    }

    @Test func allowedOrders() throws {
        let interim = h3frame(1, [1]) + h3frame(1, [2]) + h3frame(0, [3]) + h3frame(1, [4]) + h3frame(5, varint(2) + [9])
        // A client: interim heads, the final one, a body, trailers, then a push promise (allowed after the message, §4.1).
        #expect(try describeAll(interim, kind: .request, role: .client) == ["HEADERS 1", "HEADERS 1", "DATA 1", "HEADERS 1", "PUSH_PROMISE 2 1"])
        // A server: a request's head and trailers, no body; and a client's role on its own control stream.
        #expect(try describeAll(h3frame(1, [1]) + h3frame(1, [1]), kind: .request, role: .server).count == 2)
        #expect(try describeAll(h3frame(4, []) + h3frame(0xD, varint(1)) + h3frame(0xF0700, varint(0)), kind: .control, role: .server).count == 3)
        // A push stream to a server is a stream creation error (§6.2.2).
        #expect(throws: HTTP3Error.connection(.streamCreationError)) { _ = try describeAll(h3frame(1, [1]), kind: .push, role: .server) }
        // After the caller says the head was final, the next HEADERS is trailers.
        var parser = HTTP3FrameParser(streamKind: .request, role: .client)
        var consumed = 0
        let head = h3frame(1, [1])
        _ = try parser.next(in: head.span.bytes, consumed: &consumed)
        parser.finalHeadersReceived()
        _ = try parser.next(in: head.span.bytes, consumed: &consumed)
        #expect(throws: HTTP3Error.connection(.frameUnexpected)) { _ = try parser.next(in: head.span.bytes, consumed: &consumed) }
    }

    @Test func settingsRules() throws {
        func apply(_ pairs: [UInt8]) throws(HTTP3Error) -> HTTP3Settings {
            var parser = HTTP3FrameParser(streamKind: .control)
            var consumed = 0
            let frame = h3frame(4, pairs)
            var settings = HTTP3Settings()
            if case let .settings(payload) = try parser.next(in: frame.span.bytes, consumed: &consumed) { try payload.apply(to: &settings) }
            return settings
        }
        let settings = try apply(varint(1) + varint(4096) + varint(6) + varint(65536) + varint(8) + varint(1))
        #expect(settings.qpackMaxTableCapacity == 4096 && settings.maxFieldSectionSize == 65536 && settings.enableConnectProtocol)
        #expect(throws: HTTP3Error.connection(.settingsError)) { _ = try apply(varint(1) + varint(1) + varint(1) + varint(2)) }
        #expect(throws: HTTP3Error.connection(.settingsError)) { _ = try apply(varint(3) + varint(0)) } // HTTP/2's MAX_CONCURRENT_STREAMS
        #expect(throws: HTTP3Error.connection(.settingsError)) { _ = try apply(varint(8) + varint(2)) }
    }
}
