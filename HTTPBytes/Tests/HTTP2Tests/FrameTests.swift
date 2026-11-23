import Bytes
import HTTP2
import HTTPBytes
import Testing

/// A frame's header and payload bytes.
func frame(_ type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, _ payload: [UInt8]) -> [UInt8] {
    let length = payload.count
    return [UInt8(length >> 16), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length), type, flags,
            UInt8(stream >> 24), UInt8(truncatingIfNeeded: stream >> 16), UInt8(truncatingIfNeeded: stream >> 8), UInt8(truncatingIfNeeded: stream)] + payload
}

/// What a frame was, as plain values.
func describe(_ parser: inout HTTP2FrameParser, _ bytes: [UInt8]) throws(HTTP2Error) -> (String, Int) {
    var consumed = 0
    let description: String
    switch try parser.next(in: bytes.span.bytes, consumed: &consumed) {
    case .data(let stream, let payload, let endStream, let total): description = "DATA \(stream.rawValue) \(payload.byteCount) \(endStream) \(total)"
    case .headers(let stream, let block, let endStream, let endHeaders, let priority):
        description = "HEADERS \(stream.rawValue) \(block.byteCount) \(endStream) \(endHeaders) \(priority.map { "\($0.dependency.rawValue)/\($0.weight)/\($0.exclusive)" } ?? "-")"
    case .rejectedHeaders(let stream, let block, let endHeaders, let error):
        description = "REJECTED HEADERS \(stream.rawValue) \(block.byteCount) \(endHeaders) \(error)"
    case .priority(let stream, let priority): description = "PRIORITY \(stream.rawValue) \(priority.weight)"
    case .resetStream(let stream, let code): description = "RST_STREAM \(stream.rawValue) \(code)"
    case .settings(let settings):
        var pairs: [String] = []
        for index in 0..<settings.count { let (id, value) = settings.setting(at: index); pairs.append("\(id.rawValue)=\(value)") }
        description = "SETTINGS \(settings.isAcknowledgment) \(pairs.joined(separator: ","))"
    case .pushPromise(let stream, let promised, let block, let endHeaders): description = "PUSH_PROMISE \(stream.rawValue) \(promised.rawValue) \(block.byteCount) \(endHeaders)"
    case .ping(let ack, let data): description = "PING \(ack) \(String(data, radix: 16))"
    case .goaway(let last, let code, let debug): description = "GOAWAY \(last.rawValue) \(code) \(debug.byteCount)"
    case .windowUpdate(let stream, let increment): description = "WINDOW_UPDATE \(stream.rawValue) \(increment)"
    case .continuation(let stream, let block, let endHeaders): description = "CONTINUATION \(stream.rawValue) \(block.byteCount) \(endHeaders)"
    case .priorityUpdate(let stream, let value): description = "PRIORITY_UPDATE \(stream.rawValue) \(value.byteCount)"
    case .unknown(let type, _, let stream, let payload): description = "UNKNOWN \(type.rawValue) \(stream.rawValue) \(payload.byteCount)"
    case .needsMore: description = "MORE"
    }
    return (description, consumed)
}

func describe(_ bytes: [UInt8]) throws(HTTP2Error) -> String {
    var parser = HTTP2FrameParser()
    return try describe(&parser, bytes).0
}

@Suite struct FrameTests {
    @Test func everyFrameType() throws {
        #expect(try describe(frame(0, flags: 1, stream: 1, [1, 2, 3])) == "DATA 1 3 true 3")
        #expect(try describe(frame(0, flags: 0x8, stream: 1, [2, 9, 9, 0, 0])) == "DATA 1 2 false 5")
        #expect(try describe(frame(1, flags: 0x4 | 0x20, stream: 3, [0x80, 0, 0, 1, 15, 0xAA])) == "HEADERS 3 1 false true 1/16/true")
        #expect(try describe(frame(2, stream: 5, [0, 0, 0, 3, 255])) == "PRIORITY 5 256")
        #expect(try describe(frame(3, stream: 5, [0, 0, 0, 8])) == "RST_STREAM 5 CANCEL")
        #expect(try describe(frame(4, [0, 4, 0, 1, 0, 0, 0, 5, 0, 0, 0x40, 0])) == "SETTINGS false 4=65536,5=16384")
        #expect(try describe(frame(4, flags: 1, [])) == "SETTINGS true ")
        #expect(try describe(frame(5, flags: 4, stream: 1, [0, 0, 0, 2, 7])) == "PUSH_PROMISE 1 2 1 true")
        #expect(try describe(frame(6, flags: 1, [1, 2, 3, 4, 5, 6, 7, 8])) == "PING true 102030405060708")
        #expect(try describe(frame(7, [0, 0, 0, 7, 0, 0, 0, 0, 0x61])) == "GOAWAY 7 NO_ERROR 1")
        #expect(try describe(frame(8, stream: 1, [0, 0, 1, 0])) == "WINDOW_UPDATE 1 256")
        #expect(try describe(frame(0x10, [0, 0, 0, 1, 0x75, 0x3D, 0x31])) == "PRIORITY_UPDATE 1 3")
        #expect(try describe(frame(0xFA, flags: 3, stream: 9, [1])) == "UNKNOWN 250 9 1")
    }

    @Test func partialFramesNeedMore() throws {
        let bytes = frame(0, stream: 1, [1, 2, 3])
        for cut in 0..<bytes.count {
            var parser = HTTP2FrameParser()
            let (description, consumed) = try describe(&parser, Array(bytes[..<cut]))
            #expect(description == "MORE" && consumed == 0)
        }
    }

    @Test func continuationSequences() throws {
        var parser = HTTP2FrameParser()
        #expect(try describe(&parser, frame(1, stream: 1, [1, 2])).0 == "HEADERS 1 2 false false -")
        #expect(try describe(&parser, frame(9, stream: 1, [3])).0 == "CONTINUATION 1 1 false")
        #expect(try describe(&parser, frame(9, flags: 4, stream: 1, [4])).0 == "CONTINUATION 1 1 true")
        #expect(try describe(&parser, frame(0, stream: 1, [5])).0 == "DATA 1 1 false 1")
        // Anything else inside a field block, or a CONTINUATION outside one, is a connection error.
        var interrupted = HTTP2FrameParser()
        _ = try describe(&interrupted, frame(1, stream: 1, [1]))
        #expect(throws: HTTP2Error.connection(.protocolError)) { _ = try describe(&interrupted, frame(0, stream: 1, [1])) }
        var otherStream = HTTP2FrameParser()
        _ = try describe(&otherStream, frame(1, stream: 1, [1]))
        #expect(throws: HTTP2Error.connection(.protocolError)) { _ = try describe(&otherStream, frame(9, flags: 4, stream: 3, [1])) }
        #expect(throws: HTTP2Error.connection(.protocolError)) { _ = try describe(frame(9, flags: 4, stream: 1, [1])) }
    }

    @Test(arguments: [
        (frame(0, [1]), HTTP2Error.connection(.protocolError)),                       // DATA on stream 0
        (frame(0, flags: 8, stream: 1, [3, 1, 1]), .connection(.protocolError)),      // padding fills the payload
        (frame(1, [1]), .connection(.protocolError)),                                 // HEADERS on stream 0
        (frame(2, stream: 1, [0, 0, 0, 0]), .stream(HTTP2StreamID(1), .frameSizeError)), // PRIORITY of 4 bytes
        (frame(3, stream: 1, [0, 0, 0]), .connection(.frameSizeError)),
        (frame(4, stream: 1, []), .connection(.protocolError)),                       // SETTINGS on a stream
        (frame(4, flags: 1, [0, 0, 0, 0, 0, 0]), .connection(.frameSizeError)),       // ACK with a payload
        (frame(4, [0, 0, 0, 0, 0]), .connection(.frameSizeError)),                    // not a multiple of 6
        (frame(6, [1, 2, 3, 4, 5, 6, 7]), .connection(.frameSizeError)),
        (frame(6, stream: 1, [1, 2, 3, 4, 5, 6, 7, 8]), .connection(.protocolError)),
        (frame(7, [0, 0, 0, 0]), .connection(.frameSizeError)),
        (frame(8, [0, 0, 0, 0]), .connection(.protocolError)),                        // connection increment 0
        (frame(8, stream: 5, [0, 0, 0, 0]), .stream(HTTP2StreamID(5), .protocolError)),
        (frame(0x10, [0, 0, 0, 0]), .connection(.protocolError)),                     // prioritizes stream 0
        (frame(0, stream: 1, [UInt8](repeating: 0, count: 16_385)), .connection(.frameSizeError)),
    ])
    func malformedFramesAreRejected(bytes: [UInt8], error: HTTP2Error) {
        #expect(throws: error) { _ = try describe(bytes) }
    }

    @Test func settingsRanges() throws {
        var settings = HTTP2Settings()
        try settings.apply(.maxFrameSize, 16_777_215)
        try settings.apply(HTTP2SettingID(rawValue: 0x99), 7)   // unknown: ignored
        #expect(settings.maxFrameSize == 16_777_215)
        #expect(throws: HTTP2Error.connection(.protocolError)) { try settings.apply(.maxFrameSize, 16_383) }
        #expect(throws: HTTP2Error.connection(.protocolError)) { try settings.apply(.enablePush, 2) }
        #expect(throws: HTTP2Error.connection(.flowControlError)) { try settings.apply(.initialWindowSize, 0x8000_0000) }
    }

    @Test func writtenFramesParseBack() throws {
        let payload = Array("hello".utf8)
        let bytes = try [UInt8](byteCapacity: 256, mode: BigEndianBytes.self) { (writer) throws(BytesError) in
            try HTTP2FrameWriter.writeData(payload.span.bytes, stream: HTTP2StreamID(3), endStream: true, to: &writer)
            try HTTP2FrameWriter.writeHeaders(payload.span.bytes, stream: HTTP2StreamID(5), endStream: false, endHeaders: true, to: &writer)
            try HTTP2FrameWriter.writeSettings([(.maxFrameSize, 32_768), (.enableConnectProtocol, 1)], to: &writer)
            try HTTP2FrameWriter.writeSettingsAcknowledgment(to: &writer)
            try HTTP2FrameWriter.writePing(0x0102_0304_0506_0708, ack: true, to: &writer)
            try HTTP2FrameWriter.writeGoaway(lastStream: HTTP2StreamID(9), .enhanceYourCalm, debugData: payload.span.bytes, to: &writer)
            try HTTP2FrameWriter.writeResetStream(HTTP2StreamID(3), .cancel, to: &writer)
            try HTTP2FrameWriter.writeWindowUpdate(1_000, stream: .connection, to: &writer)
            try HTTP2FrameWriter.writePriorityUpdate(Array("u=2".utf8).span.bytes, for: HTTP2StreamID(7), to: &writer)
        }
        var parser = HTTP2FrameParser()
        var offset = 0
        var described: [String] = []
        while offset < bytes.count {
            let (description, consumed) = try describe(&parser, Array(bytes[offset...]))
            described.append(description)
            offset += consumed
        }
        #expect(described == [
            "DATA 3 5 true 5", "HEADERS 5 5 false true -", "SETTINGS false 5=32768,8=1", "SETTINGS true ",
            "PING true 102030405060708", "GOAWAY 9 ENHANCE_YOUR_CALM 5", "RST_STREAM 3 CANCEL", "WINDOW_UPDATE 0 1000",
            "PRIORITY_UPDATE 7 3",
        ])
    }

    @Test func preface() {
        let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        #expect(HTTP2ConnectionPreface.matches(preface.span.bytes) == true)
        #expect(HTTP2ConnectionPreface.matches((preface + [0, 0]).span.bytes) == true)
        #expect(HTTP2ConnectionPreface.matches(Array(preface[..<10]).span.bytes) == nil)
        #expect(HTTP2ConnectionPreface.matches(Array("GET / HTTP/1.1\r\n".utf8).span.bytes) == false)
    }
}
