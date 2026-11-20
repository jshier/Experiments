import Bytes
import BytesCompression
import BytesCrypto
import BytesTesting
import BytesTestSupport
import Testing

/// Runs `data` through `transform` in pieces of up to `chunk` bytes into an output buffer of `outputChunk`
/// bytes, flushing with `flush` after each piece and, with `finish`, finishing at the end (otherwise the last
/// piece gets `flush` too: a message in a longer stream).
func run<T: ByteTransform & ~Copyable>(
    _ transform: inout T, _ data: [UInt8], chunk: Int, outputChunk: Int, flush: TransformFlush = .none, finish: Bool = true
) throws(T.Failure) -> [UInt8] {
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    var offset = 0
    var pending: [UInt8] = []
    repeat {
        let end = min(offset + chunk, data.count)
        // Input a stage kept back (a partial record, a partial code) comes again, followed by the next piece.
        pending += data[offset..<end]
        let mode: TransformFlush = end == data.count && finish ? .finish : flush
        while true {
            var progress = TransformProgress(consumed: 0, produced: 0, status: .needsInput)
            var failure: T.Failure?
            buffer.withUnsafeMutableBytes { raw in
                var span = OutputRawSpan(buffer: raw, initializedCount: 0)
                do throws(T.Failure) {
                    progress = try transform.transform(pending.span.bytes, into: &span, flush: mode)
                } catch {
                    failure = error
                }
                result += raw[..<span.finalize(for: raw)]
            }
            if let failure { throw failure }
            pending.removeFirst(progress.consumed)
            if progress.status == .finished || progress.status == .needsInput { break }
        }
        offset = end
    } while offset < data.count
    return result
}

/// A test stage: XORs bytes with a repeating key, in place.
struct XORStage: InPlaceByteTransform {
    typealias Failure = Never
    var index = 0

    mutating func transform(inPlace bytes: inout MutableRawSpan, flush: TransformFlush) {
        for offset in 0..<bytes.byteCount {
            let value = bytes.bytes.load(fromByteOffset: offset, as: UInt8.self) ^ UInt8(truncatingIfNeeded: 0x5A &+ index)
            bytes.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
            index &+= 1
        }
    }
}

/// A test stage that can't fail: copies its input.
struct CopyStage: ByteTransform {
    typealias Failure = Never

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        let count = min(input.byteCount, output.freeCapacity)
        output.withBytesWriter { (writer) throws(Never) in
            try? writer.write(input.extracting(0..<count))
        }
        return TransformProgress(consumed: count, produced: count, status: count == input.byteCount ? (flush == .finish ? .finished : .needsInput) : .needsOutput)
    }
}

@Suite struct PipelineTests {
    static let text: [UInt8] = {
        var rng = SplitMix64(seed: 3)
        let words = ["mqtt", "packet", "topic", "sensor", "temperature", "{", "}", "\"value\":", " ", "\n", "21.5", "true"]
        var bytes: [UInt8] = []
        while bytes.count < 300_000 { bytes += Array(words.randomElement(using: &rng)!.utf8) }
        return bytes
    }()

    @Test(arguments: [(1000, 7), (4096, 1000), (65_536, 65_536)])
    func compressThenDecompressIsIdentity(chunk: Int, outputChunk: Int) throws {
        var deflate = DeflateEncoder(format: .gzip, level: 6).then(DeflateDecoder(format: .gzip), bufferCapacity: 4096)
        #expect(try run(&deflate, Self.text, chunk: chunk, outputChunk: outputChunk) == Self.text)
        var brotli = BrotliEncoder(quality: 5, windowBits: 18).then(BrotliDecoder(), bufferCapacity: 4096)
        #expect(try run(&brotli, Self.text, chunk: chunk, outputChunk: outputChunk) == Self.text)
    }

    /// Compress and seal on one side, open and decompress on the other, message by message: the first 40 messages
    /// here, all 300 in `PipelineBulkTests`.
    @Test(arguments: [true, false])
    func messagesThroughCompressionAndRecords(useBrotli: Bool) throws {
        try Self.messagesThroughCompressionAndRecords(useBrotli: useBrotli, count: 40)
    }

    static func messagesThroughCompressionAndRecords(useBrotli: Bool, count: Int) throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 7, count: 32).span.bytes)
        var rng = SplitMix64(seed: 9)
        var sendDeflate = DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys.client))
        var receiveDeflate = TLSRecordOpener(keys: keys.client).then(DeflateDecoder(format: .raw))
        var sendBrotli = BrotliEncoder(quality: 1, windowBits: 18).then(TLSRecordSealer(keys: keys.client))
        var receiveBrotli = TLSRecordOpener(keys: keys.client).then(BrotliDecoder())
        for _ in 0..<count {
            let start = Int.random(in: 0..<(Self.text.count - 40_000), using: &rng)
            let message = Array(Self.text[start..<(start + Int.random(in: 1...40_000, using: &rng))])
            let wire = useBrotli
                ? try run(&sendBrotli, message, chunk: message.count, outputChunk: 1 << 17, flush: .flush, finish: false)
                : try run(&sendDeflate, message, chunk: message.count, outputChunk: 1 << 17, flush: .flush, finish: false)
            // The receiver gets the bytes in arbitrary pieces.
            let chunk = Int.random(in: 1...5000, using: &rng)
            let received = useBrotli
                ? try run(&receiveBrotli, wire, chunk: chunk, outputChunk: 1 << 17, finish: false)
                : try run(&receiveDeflate, wire, chunk: chunk, outputChunk: 1 << 17, finish: false)
            #expect(received == message)
        }
    }

    /// Whole streams through pipelines built once and reset between them: a flush per 16 KB sent, then a
    /// finish; received in 64 KB pieces, the opener rewound to replay the first stream's records. Streams of 300 KB
    /// here (19 flushes each), 1.2 MB in `PipelineBulkTests`.
    @Test(arguments: [true, false])
    func resetPipelinesCarryStreamAfterStream(useBrotli: Bool) throws {
        try Self.resetPipelinesCarryStreamAfterStream(useBrotli: useBrotli, copies: 1)
    }

    static func resetPipelinesCarryStreamAfterStream(useBrotli: Bool, copies: Int) throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 5, count: 32).span.bytes).server
        let data = Array((0..<copies).map { _ in Self.text }.joined())
        var sendDeflate = DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys))
        var receiveDeflate = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
        var sendBrotli = BrotliEncoder(quality: 5, windowBits: 18).then(TLSRecordSealer(keys: keys))
        var receiveBrotli = TLSRecordOpener(keys: keys).then(BrotliDecoder())
        var streams: [[UInt8]] = []
        for _ in 0..<3 {
            if useBrotli { sendBrotli.reset() } else { sendDeflate.reset() }
            streams.append(useBrotli
                ? try run(&sendBrotli, data, chunk: 16_384, outputChunk: 1 << 20, flush: .flush)
                : try run(&sendDeflate, data, chunk: 16_384, outputChunk: 1 << 20, flush: .flush))
        }
        // Each stream continues the record sequence, and the receiver, reset, follows it; then the first again.
        for (index, stream) in (streams + [streams[0]]).enumerated() {
            if useBrotli { receiveBrotli.reset() } else { receiveDeflate.reset() }
            if index == streams.count {
                if useBrotli { receiveBrotli.first.reset(sequence: 0) } else { receiveDeflate.first.reset(sequence: 0) }
            }
            let received = useBrotli
                ? try run(&receiveBrotli, stream, chunk: 64 << 10, outputChunk: 1 << 20)
                : try run(&receiveDeflate, stream, chunk: 64 << 10, outputChunk: 1 << 20)
            #expect(received == data, "stream \(index)")
        }
    }

    /// A requested buffer smaller than a TLS record: the pipeline sizes it for the units the stages declare
    /// (the opener writes a record's body at once), so it still works.
    @Test func bufferSmallerThanARecordIsSizedForIt() throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 2, count: 32).span.bytes).server
        var send = TLSRecordSealer(keys: keys)
        let plain = Array(PipelineTests.text.prefix(40_000))
        let wire = try run(&send, plain, chunk: 40_000, outputChunk: 1 << 16, flush: .flush)
        var receive = TLSRecordOpener(keys: keys).then(CopyStage().promoted(to: BytesError.self), bufferCapacity: 1_000)
        #expect(try run(&receive, wire, chunk: wire.count, outputChunk: 1 << 16) == plain)
    }

    /// A stage that needs more output than it declares (2,000 bytes at once, declaring 1), in a buffer that
    /// can't hold it: a precondition failure, not a loop that never returns.
    @Test func undeclaredUnitStops() async throws {
        await #expect(processExitsWith: .failure) {
            var pipeline = UnitStage(unit: 2_000).then(HoldBackStage(), bufferCapacity: 1_000)
            let input = [UInt8](repeating: 7, count: 4_000)
            var output = [UInt8](repeating: 0, count: 4_000)
            output.withUnsafeMutableBytes { buffer in
                var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                _ = pipeline.transform(input.span.bytes, into: &span, flush: .finish)
                _ = span.finalize(for: buffer)
            }
        }
    }

    /// The drive loop: whole messages through stages into growing arrays, ending `.finished` at `.finish`.
    @Test func driveLoopTransformsWholeMessages() throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes).server
        let plain = Array(PipelineTests.text.prefix(100_000))
        var send = DeflateEncoder(format: .gzip, level: 6).then(TLSRecordSealer(keys: keys))
        var wire: [UInt8] = []
        let sent = try send.transform(plain.span.bytes, appending: &wire, flush: .finish, growth: 1_000)
        #expect(sent.consumed == plain.count && sent.status == .finished && sent.produced == wire.count)

        var receive = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .gzip))
        var received: [UInt8] = []
        let got = try receive.transform(wire.span.bytes, appending: &received, flush: .finish)
        #expect(got.status == .finished && received == plain)

        // The opener alone: `.finished` at `.finish` once every record is open; a partial record throws.
        var opener = TLSRecordOpener(keys: keys)
        var records: [UInt8] = []
        var sealer = TLSRecordSealer(keys: keys)
        _ = try sealer.transform(plain.span.bytes.extracting(0..<5_000), appending: &records, flush: .finish)
        var opened: [UInt8] = []
        #expect(try opener.transform(records.span.bytes, appending: &opened, flush: .finish).status == .finished)
        #expect(opened == Array(plain.prefix(5_000)))
        opener.reset(sequence: 0)
        #expect(throws: BytesError.insufficientData) {
            _ = try opener.transform(records.span.bytes.extracting(0..<(records.count - 1)), appending: &opened, flush: .finish)
        }
    }

    @Test func tamperedRecordThrowsThroughThePipeline() throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 1, count: 32).span.bytes)
        var send = DeflateEncoder(format: .raw).then(TLSRecordSealer(keys: keys.server))
        var wire = try run(&send, Array(Self.text.prefix(10_000)), chunk: 10_000, outputChunk: 1 << 16, flush: .flush)
        wire[wire.count / 2] ^= 1
        var receive = TLSRecordOpener(keys: keys.server).then(DeflateDecoder(format: .raw))
        #expect(throws: BytesError.mismatch) { _ = try run(&receive, wire, chunk: wire.count, outputChunk: 1 << 16) }
    }

    @Test func fusedInPlaceStageNeedsNoBuffer() throws {
        // XOR twice is the identity: once fused after compression, once fused after decompression's input.
        var forward = DeflateEncoder(format: .raw, level: 6).then(XORStage().promoted(to: BytesError.self))
        let scrambled = try run(&forward, Self.text, chunk: 9999, outputChunk: 777)
        var backward = CopyStage().promoted(to: BytesError.self).then(XORStage().promoted(to: BytesError.self))
            .then(DeflateDecoder(format: .raw))
        #expect(try run(&backward, scrambled, chunk: 1234, outputChunk: 5000) == Self.text)
    }

    @Test func nonThrowingPipelinesDontThrow() {
        var copies = CopyStage().then(CopyStage(), bufferCapacity: 16)
        var output = [UInt8](repeating: 0, count: 100)
        let input = Array("no try needed".utf8)
        let progress = output.withUnsafeMutableBytes { raw in
            var span = OutputRawSpan(buffer: raw, initializedCount: 0)
            let progress = copies.transform(input.span.bytes, into: &span, flush: .finish) // No `try`.
            _ = span.finalize(for: raw)
            return progress
        }
        #expect(progress.consumed == input.count && Array(output.prefix(input.count)) == input)
    }
}

/// Emits its input in units of `unit` bytes, only when a whole unit fits the output (as a TLS opener
/// writes a record's body).
struct UnitStage: ByteTransform {
    typealias Failure = Never
    let unit: Int

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        var consumed = 0
        while input.byteCount - consumed >= unit {
            guard output.freeCapacity >= unit else {
                return TransformProgress(consumed: consumed, produced: consumed, status: .needsOutput)
            }
            output.withBytesWriter { (writer) throws(Never) in try? writer.write(input.extracting(consumed..<(consumed + unit))) }
            consumed += unit
        }
        return TransformProgress(consumed: consumed, produced: consumed, status: .needsInput)
    }
}

/// Copies all but the last byte of its input until the input ends (as a decoder keeps a partial byte).
struct HoldBackStage: ByteTransform {
    typealias Failure = Never

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        let take = min(flush == .none ? max(input.byteCount - 1, 0) : input.byteCount, output.freeCapacity)
        output.withBytesWriter { (writer) throws(Never) in try? writer.write(input.extracting(0..<take)) }
        return TransformProgress(consumed: take, produced: take, status: take < input.byteCount && output.freeCapacity == 0 ? .needsOutput : .needsInput)
    }
}

extension PipelineTests {
    /// A unit that doesn't fit the free end of the buffer, with too much free to compact, while the second
    /// stage keeps a byte: the pipeline compacts instead of stopping ("buffer smaller than its second stage's
    /// unit"), which a socket stream with 1 MB batches hit.
    @Test func compactsWhenAUnitDoesNotFitTheFreeEnd() {
        var pipeline = UnitStage(unit: 22_000).then(HoldBackStage(), bufferCapacity: 65_536)
        let input = (0..<(22_000 * 6)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var output = [UInt8](repeating: 0, count: input.count)
        let produced = output.withUnsafeMutableBytes { buffer in
            var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
            let progress = pipeline.transform(input.span.bytes, into: &span, flush: .finish)
            #expect(progress.consumed == input.count)
            return span.finalize(for: buffer)
        }
        #expect(produced == input.count && output == input)
    }
}

extension PipelineTests {
    /// A socket stream's two pipelines, without the socket: parallel DEFLATE then TLS records in 1 MB
    /// flushed batches, then TLS records then inflate, the wire cut into reads of many sizes. Here 1.3 MB (a full
    /// batch and a partial one); 6 MB in `PipelineBulkTests`.
    @Test(arguments: [8, 16])
    func parallelCompressionThroughTLSRoundTrips(lanes: Int) throws {
        try Self.parallelCompressionThroughTLSRoundTrips(lanes: lanes, byteCount: (1 << 20) + 300_001)
    }

    static func parallelCompressionThroughTLSRoundTrips(lanes: Int, byteCount: Int) throws {
        var state: UInt64 = 0x1234_5678
        let words = ["sensor", "temp", "building", "floor", "\"value\":", "21.5", ",", "{", "}", "\n"]
        var data: [UInt8] = []
        while data.count < byteCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data += Array(words[Int(state >> 33) % words.count].utf8)
        }
        let secret = [UInt8](repeating: 9, count: 32)
        let keys = TLSTrafficKeys(trafficSecret: secret.span.bytes)
        let batch = 1 << 20
        var send = ParallelDeflateEncoder(format: .raw, level: 1, chunkSize: 64 << 10, lanes: lanes)
            .then(TLSRecordSealer(keys: keys), bufferCapacity: batch + (64 << 10))
        let wire = try run(&send, data, chunk: batch, outputChunk: batch + batch / 8 + (64 << 10), flush: .flush)
        for (read, room) in [(wire.count, 1 << 20), (1000, 1_114_112), (65_543, 7777), (300_001, 1_114_112), (16_389, 600_000)] {
            var receive = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
            let decoded = try run(&receive, wire, chunk: read, outputChunk: room)
            #expect(decoded == data, "reads of \(read), output room \(room)")
        }
    }
}

/// The pipeline runs at full length: 300 messages, 1.2 MB streams, and 6 MB through parallel DEFLATE and TLS.
@Suite(.bulk) struct PipelineBulkTests {
    @Test(arguments: [true, false])
    func messagesThroughCompressionAndRecords(useBrotli: Bool) throws {
        try PipelineTests.messagesThroughCompressionAndRecords(useBrotli: useBrotli, count: 300)
    }

    @Test(arguments: [true, false])
    func resetPipelinesCarryStreamAfterStream(useBrotli: Bool) throws {
        try PipelineTests.resetPipelinesCarryStreamAfterStream(useBrotli: useBrotli, copies: 4)
    }

    @Test(arguments: [8, 16])
    func parallelCompressionThroughTLSRoundTrips(lanes: Int) throws {
        try PipelineTests.parallelCompressionThroughTLSRoundTrips(lanes: lanes, byteCount: 6 << 20)
    }
}
