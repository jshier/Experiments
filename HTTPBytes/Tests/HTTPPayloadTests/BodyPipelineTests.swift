import Bytes
import HTTP1
import HTTPPayload
import Testing

/// Bodies end to end: content coding then chunking through a pipeline, and `HTTPBodyDecoder` back, with the framing
/// deciding where each body ends.
@Suite struct BodyPipelineTests {
    static let body = Array(ContentCodingTests.body.prefix(200_000))

    static func chunked(_ coded: [UInt8], size: Int = 4_096) -> [UInt8] {
        var wire: [UInt8] = []
        var offset = 0
        while offset < coded.count {
            let take = min(size, coded.count - offset)
            wire += Array(String(take, radix: 16).utf8) + [13, 10] + coded[offset..<offset + take] + [13, 10]
            offset += take
        }
        return wire + Array("0\r\n\r\n".utf8)
    }

    /// Decodes `wire` handed over `step` bytes at a time into outputs of `room` bytes, as a server reading a connection:
    /// the body and the bytes consumed (the next message's start).
    static func decode(_ wire: [UInt8], framing: HTTP1BodyLength, encoding: String, step: Int, room: Int, closes: Bool = false) throws
        -> (body: [UInt8], consumed: Int) {
        var decoder = try HTTPBodyDecoder(framing: framing, contentEncoding: Array(encoding.utf8).span.bytes)
        var pending: [UInt8] = []
        var delivered = 0, consumed = 0
        var body: [UInt8] = []
        var output = [UInt8](repeating: 0, count: room)
        while true {
            let flush: TransformFlush = closes && delivered == wire.count ? .finish : .none
            let progress = try output.withOutputRawSpan(overwritingFrom: 0) { span throws(HTTPPayloadError) in
                try decoder.transform(pending.span.bytes, into: &span, flush: flush)
            }
            body += output[..<progress.produced]
            pending.removeFirst(progress.consumed)
            consumed += progress.consumed
            switch progress.status {
            case .finished: return (body, consumed)
            case .needsOutput: continue
            case .needsInput:
                guard delivered < wire.count else { throw HTTPPayloadError.incompleteBody }
                let more = min(step, wire.count - delivered)
                pending += wire[delivered..<delivered + more]
                delivered += more
            }
        }
    }

    @Test(arguments: [HTTPContentCoding.gzip, .brotli, .deflate, .zstd, .identity])
    func codedAndChunkedRoundTrips(coding: HTTPContentCoding) throws {
        // Coded, then chunked, through a pipeline in writes of 10,000 bytes, as a server streams a response.
        var sending = try HTTPContentEncoder(coding).then(HTTP1Chunker().promoted(to: HTTPPayloadError.self), bufferCapacity: 4_096)
        var wire: [UInt8] = []
        var offset = 0
        while offset < Self.body.count {
            let end = min(Self.body.count, offset + 10_000)
            let progress = try sending.transform(Self.body[offset..<end].span.bytes, appending: &wire, flush: end == Self.body.count ? .finish : .none)
            #expect(progress.consumed == end - offset)
            offset = end
        }
        #expect(wire.suffix(5) == Array("0\r\n\r\n".utf8))
        let next = Array("GET / HTTP/1.1\r\n".utf8)
        let encoding = String(describing: coding.token)
        for (step, room) in [(100_000, 65_536), (1_000, 7), (7, 4_096)] {
            let result = try Self.decode(wire + next, framing: .chunked, encoding: encoding, step: step, room: room)
            #expect(result.body == Self.body)
            #expect(result.consumed == wire.count, "the body ends where its framing does")
        }
    }

    @Test func framingDecidesTheEnd() throws {
        let gzip = try ContentCodingTests.encode(Array(Self.body.prefix(5_000)), .gzip)
        // Content-Length: the body ends after its bytes, whatever follows.
        let next = Array("GET /next HTTP/1.1\r\n\r\n".utf8)
        let byLength = try Self.decode(gzip + next, framing: .length(gzip.count), encoding: "gzip", step: 333, room: 100)
        #expect(byLength.body == Array(Self.body.prefix(5_000)))
        #expect(byLength.consumed == gzip.count)
        // Until the connection closes.
        let byClose = try Self.decode(gzip, framing: .untilClose, encoding: "gzip", step: 333, room: 100, closes: true)
        #expect(byClose.body == Array(Self.body.prefix(5_000)))
        // Identity, chunked, streamed (never `.finish`): finished at the last chunk.
        let plain = Array(Self.body.prefix(3_000))
        let identity = try Self.decode(Self.chunked(plain, size: 1_000) + next, framing: .chunked, encoding: "", step: 64, room: 50)
        #expect(identity.body == plain)
        #expect(identity.consumed == Self.chunked(plain, size: 1_000).count)
        // An empty body with a coding named (`Content-Length: 0`, `Content-Encoding: gzip`).
        #expect(try Self.decode(next, framing: .length(0), encoding: "gzip", step: 10, room: 10).consumed == 0)
        #expect(try Self.decode(next, framing: .none, encoding: "gzip", step: 10, room: 10).consumed == 0)
    }

    @Test func codedStreamMustEndWithTheFraming() throws {
        let gzip = try ContentCodingTests.encode(Array(Self.body.prefix(5_000)), .gzip)
        // The gzip stream ends, but the chunked body hasn't: not finished until its last chunk arrives.
        var decoder = try HTTPBodyDecoder(framing: .chunked, contentEncoding: Array("gzip".utf8).span.bytes)
        let withoutLastChunk = Self.chunked(gzip).dropLast(5).map(\.self)
        var output: [UInt8] = []
        let progress = try decoder.transform(withoutLastChunk.span.bytes, appending: &output, flush: .none)
        #expect(progress.status == .needsInput)
        #expect(progress.consumed == withoutLastChunk.count)
        // Bytes after the coded stream, inside the framing (an attacker's request hidden after the gzip stream): refused.
        let smuggled = Self.chunked(gzip + [UInt8](repeating: 0x20, count: 5_000) + Array("GET /admin HTTP/1.1\r\n\r\n".utf8))
        #expect(throws: HTTPPayloadError.malformed) {
            _ = try Self.decode(smuggled, framing: .chunked, encoding: "gzip", step: 100_000, room: 4_096)
        }
        // The framing ends before the coded stream does.
        #expect(throws: HTTPPayloadError.malformed) {
            _ = try Self.decode(Array(gzip.dropLast(4)), framing: .length(gzip.count - 4), encoding: "gzip", step: 1_000, room: 4_096)
        }
        // The connection closes before the framing ends.
        #expect(throws: HTTPPayloadError.incompleteBody) {
            _ = try Self.decode(Array(gzip.prefix(100)), framing: .length(gzip.count), encoding: "gzip", step: 1_000, room: 4_096, closes: true)
        }
        #expect(throws: HTTPPayloadError.incompleteBody) {
            _ = try Self.decode(Array(Self.chunked(gzip).dropLast(3)), framing: .chunked, encoding: "gzip", step: 1_000, room: 4_096, closes: true)
        }
        // Malformed chunked framing comes through as the chunked coding's error.
        #expect(throws: HTTPPayloadError.chunked(.invalidChunkSize)) {
            _ = try Self.decode(Array("zz\r\n".utf8), framing: .chunked, encoding: "gzip", step: 1_000, room: 4_096)
        }
    }

    /// Concatenated streams: gzip members (RFC 1952 §2.2) and zstd frames (RFC 8878 §3) decode to their contents joined,
    /// whatever the pieces: chunk boundaries and handed-over pieces falling exactly between members included. Data after
    /// a member that isn't another member is still refused.
    @Test(arguments: [HTTPContentCoding.gzip, .zstd])
    func concatenatedStreamsDecodeWhole(coding: HTTPContentCoding) throws {
        let parts = [Array(Self.body.prefix(3_000)), Array(Self.body.dropFirst(3_000).prefix(10_000)), [], Array(Self.body.suffix(7))]
        let streams = try parts.map { try ContentCodingTests.encode($0, coding) }
        let coded = streams.flatMap(\.self)
        let expected = parts.flatMap(\.self)
        let next = Array("GET / HTTP/1.1\r\n".utf8)
        // Chunks that end exactly where each member does, then fixed-size chunks; pieces whole, odd, and a byte each.
        let byMember = streams.filter { !$0.isEmpty }.reduce(into: [UInt8]()) { wire, stream in
            wire += Array(String(stream.count, radix: 16).utf8) + [13, 10] + stream + [13, 10]
        } + Array("0\r\n\r\n".utf8)
        for wire in [byMember, Self.chunked(coded, size: 1_000)] {
            for (step, room) in [(100_000, 65_536), (streams[0].count, 4_096), (333, 100), (1, 4_096)] {
                let result = try Self.decode(wire + next, framing: .chunked, encoding: String(describing: coding.token), step: step, room: room)
                #expect(result.body == expected, "\(coding) \(step)")
                #expect(result.consumed == wire.count)
            }
        }
        // By length, ending exactly at a member's end.
        let byLength = try Self.decode(coded + next, framing: .length(coded.count), encoding: String(describing: coding.token), step: streams[0].count, room: 512)
        #expect(byLength.body == expected && byLength.consumed == coded.count)
        // Cut inside the second member: malformed, not the first member's bytes alone.
        #expect(throws: HTTPPayloadError.malformed) {
            let cut = streams[0] + streams[1].prefix(20)
            _ = try Self.decode(cut, framing: .length(cut.count), encoding: String(describing: coding.token), step: 1_000, room: 4_096)
        }
    }

    @Test func stackedTruncationIsCaughtAtTheEnd() throws {
        let plain = Array(Self.body.prefix(1_300))
        let coded = try ContentCodingTests.encode(ContentCodingTests.encode(plain, .gzip), .brotli)
        var decoder = try HTTPContentDecoder(contentEncoding: Array("gzip, br".utf8).span.bytes)
        var output: [UInt8] = []
        let cut = Array(coded.dropLast(1))
        #expect(throws: HTTPPayloadError.malformed) { _ = try decoder.transform(cut.span.bytes, appending: &output, flush: .finish) }
    }

    @Test func resetsBetweenBodies() throws {
        let gzip = try ContentCodingTests.encode(Array(Self.body.prefix(20_000)), .gzip)
        let wire = Self.chunked(gzip)
        var decoder = try HTTPBodyDecoder(framing: .chunked, contentEncoding: Array("gzip".utf8).span.bytes)
        for round in 0..<3 {
            var output: [UInt8] = []
            let progress = try decoder.transform(round == 1 ? gzip.span.bytes : wire.span.bytes, appending: &output, flush: .none)
            #expect(progress.status == .finished)
            #expect(output == Array(Self.body.prefix(20_000)))
            if round == 0 { decoder.reset(framing: .length(gzip.count)) } else { decoder.reset(framing: .chunked) }
        }
    }
}
