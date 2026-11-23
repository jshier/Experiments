import Bytes
import BytesTestSupport
import HTTP1
import HTTPBytes
import Testing

/// The chunked stages (`HTTP1Dechunker`, `HTTP1Chunker`) driven as a pipeline would: input in pieces, outputs of every
/// small size, against the chunked decoder and the test's own encoder.
@Suite struct BodyStageTests {
    /// Dechunks `coded` handed over `step` bytes at a time into outputs of `room` bytes: the body, the bytes consumed,
    /// the stage, and the input it left (with `.leave`, the trailer section onward).
    static func dechunk(_ coded: [UInt8], step: Int, room: Int, trailers: HTTP1Dechunker.Trailers) throws
        -> (body: [UInt8], consumed: Int, stage: HTTP1Dechunker, left: [UInt8]) {
        var stage = HTTP1Dechunker(trailers: trailers)
        var pending: [UInt8] = []
        var delivered = 0, consumed = 0
        var body: [UInt8] = []
        var output = [UInt8](repeating: 0, count: room)
        while true {
            let flush: TransformFlush = delivered == coded.count ? .finish : .none
            let progress = try output.withOutputRawSpan(overwritingFrom: 0) { (span) throws(HTTP1Error) in
                try stage.transform(pending.span.bytes, into: &span, flush: flush)
            }
            body += output[..<progress.produced]
            pending.removeFirst(progress.consumed)
            consumed += progress.consumed
            switch progress.status {
            case .finished: return (body, consumed, stage, pending + coded[delivered...])
            case .needsOutput: continue
            case .needsInput:
                let more = min(step, coded.count - delivered)
                pending += coded[delivered..<delivered + more]
                delivered += more
            }
        }
    }

    static let body: [UInt8] = {
        var generator = SplitMix64(seed: 5)
        return (0..<5_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    }()

    @Test(arguments: [(1, 1), (1, 7), (3, 64), (7, 1), (64, 5), (100_000, 4_096), (100_000, 1)])
    func dechunkingMatchesTheDecoder(step: Int, room: Int) throws {
        let sizes = [1, 2, 15, 16, 255, 256, 4095, 360]
        for (extensions, trailers) in [(false, [String]()), (true, ["Expires: never", "X-Sum: 1"])] {
            let coded = BodyTests.chunked(Self.body, sizes: sizes, extensions: extensions, trailers: trailers)
            let lastChunk = coded.count - trailers.reduce(2) { $0 + $1.utf8.count + 2 }

            // Skipping trailers: the whole coding consumed, nothing after it.
            let skipped = try Self.dechunk(coded + Array("NEXT".utf8), step: step, room: room, trailers: .skip)
            #expect(skipped.body == Self.body)
            #expect(skipped.consumed == coded.count)

            // Leaving them: finished after the last chunk's line, the trailer section read from the decoder.
            var left = try Self.dechunk(coded + Array("NEXT".utf8), step: step, room: room, trailers: .leave)
            #expect(left.body == Self.body)
            #expect(left.consumed == lastChunk)
            var read: [String] = []
            var position = 0
            reading: while true {
                var used = 0
                switch try left.stage.nextTrailer(in: left.left.span.bytes.extracting(droppingFirst: position), consumed: &used) {
                case .trailer(let field): read.append("\(string(field.name)): \(string(field.value))")
                case .end: position += used; break reading
                case .data, .needsMore: Issue.record("unexpected event after the last chunk"); break reading
                }
                position += used
            }
            #expect(read == trailers)
            #expect(Array(left.left[position...]) == Array("NEXT".utf8))
        }
    }

    @Test func dechunkingACutBodyThrows() {
        let coded = BodyTests.chunked(Self.body, sizes: [5_000], extensions: false, trailers: [])
        for cut in [0, 1, 3, 4_000, coded.count - 1] {
            #expect(throws: HTTP1Error.incompleteBody) {
                _ = try Self.dechunk(Array(coded[..<cut]), step: 512, room: 1_000, trailers: .skip)
            }
        }
    }

    @Test func dechunkerResets() throws {
        let coded = BodyTests.chunked(Self.body, sizes: [100, 4_900], extensions: false, trailers: [])
        var stage = HTTP1Dechunker(trailers: .skip)
        for _ in 0..<2 {
            var decoded: [UInt8] = []
            let progress = try stage.transform(coded.span.bytes, appending: &decoded, flush: .finish)
            #expect(progress.status == .finished)
            #expect(decoded == Self.body)
            stage.reset()
        }
    }

    /// Chunks `body` handed over in `piece`-byte writes (each flushed when `flushes`) into outputs of `room` bytes.
    static func chunk(_ body: [UInt8], piece: Int, room: Int, flushes: Bool) -> [UInt8] {
        var stage = HTTP1Chunker()
        var coded: [UInt8] = []
        var output = [UInt8](repeating: 0, count: room)
        var offset = 0
        var pending: [UInt8] = []
        while true {
            if pending.isEmpty, offset < body.count {
                pending = Array(body[offset..<min(body.count, offset + piece)])
                offset += pending.count
            }
            let flush: TransformFlush = offset == body.count ? .finish : flushes ? .flush : .none
            let progress = output.withOutputRawSpan(overwritingFrom: 0) { span in
                stage.transform(pending.span.bytes, into: &span, flush: flush)
            }
            coded += output[..<progress.produced]
            pending.removeFirst(progress.consumed)
            if progress.status == .finished { return coded }
        }
    }

    @Test(arguments: [(1, 21), (7, 21), (16, 22), (4_000, 64), (100, 4_096), (5_000, 1 << 16)])
    func chunkingRoundTrips(piece: Int, room: Int) throws {
        for flushes in [false, true] {
            let coded = Self.chunk(Self.body, piece: piece, room: room, flushes: flushes)
            let decoded = try BodyTests.decode(coded, step: 997)
            #expect(decoded.body == Self.body)
            #expect(decoded.trailers.isEmpty)
            #expect(decoded.consumed == coded.count)
        }
    }

    /// The largest chunk each room allows: its size line's digits counted exactly (15 fits in 20 bytes, 16 doesn't in 21;
    /// 255 fits in 261).
    @Test func chunksFillTheRoom() {
        let data = [UInt8](repeating: 0x61, count: 1_000)
        for room in 5...300 {
            var stage = HTTP1Chunker()
            var output = [UInt8](repeating: 0, count: room)
            let progress = output.withOutputRawSpan(overwritingFrom: 0) { span in stage.transform(data.span.bytes, into: &span, flush: .none) }
            var best = 0
            for size in 1...room where size + String(size, radix: 16).count + 4 <= room { best = size }
            #expect(progress.consumed == best, "room \(room)")
            #expect(progress.produced == (best == 0 ? 0 : best + String(best, radix: 16).count + 4), "room \(room)")
        }
    }

    /// A decoder's larger limits are lowered to what the stage's unit allows: a long trailer line is an error, not a
    /// stage keeping more than a pipeline's buffer.
    @Test func limitsFitTheUnit() {
        var decoder = HTTP1ChunkedDecoder()
        decoder.maximumTrailerSectionByteCount = 1 << 20
        var stage = HTTP1Dechunker(decoder)
        let body = Array("1\r\na\r\n0\r\nX: \(String(repeating: "v", count: 20_000))".utf8)
        var output: [UInt8] = []
        #expect(throws: HTTP1Error.headTooLarge) { _ = try stage.transform(body.span.bytes, appending: &output, flush: .none) }
    }

    @Test func chunkerWritesNothingWithoutData() {
        var stage = HTTP1Chunker()
        var coded: [UInt8] = []
        for flush in [TransformFlush.none, .flush] {
            let progress = stage.transform(RawSpan(), appending: &coded, flush: flush)
            #expect(progress.status == .needsInput)
            #expect(coded.isEmpty)
        }
        let data: [UInt8] = Array(repeating: 0x61, count: 26)
        _ = stage.transform(data.span.bytes, appending: &coded, flush: .flush)
        _ = stage.transform(RawSpan(), appending: &coded, flush: .finish)
        #expect(coded == Array("1a\r\n\(String(repeating: "a", count: 26))\r\n0\r\n\r\n".utf8))
        // After the end, nothing more.
        #expect(stage.transform(data.span.bytes, appending: &coded, flush: .finish).status == .finished)
        stage.reset()
        var again: [UInt8] = []
        _ = stage.transform(RawSpan(), appending: &again, flush: .finish)
        #expect(again == Array("0\r\n\r\n".utf8))
    }
}
