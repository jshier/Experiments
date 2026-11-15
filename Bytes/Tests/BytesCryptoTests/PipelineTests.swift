import Bytes
import BytesCompression
import BytesCrypto
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
        var rng = SplitMix64(state: 3)
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

    /// Compress and seal on one side, open and decompress on the other, message by message.
    @Test(arguments: [true, false])
    func messagesThroughCompressionAndRecords(useBrotli: Bool) throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 7, count: 32).span.bytes)
        var rng = SplitMix64(state: 9)
        var sendDeflate = DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys.client))
        var receiveDeflate = TLSRecordOpener(keys: keys.client).then(DeflateDecoder(format: .raw))
        var sendBrotli = BrotliEncoder(quality: 1, windowBits: 18).then(TLSRecordSealer(keys: keys.client))
        var receiveBrotli = TLSRecordOpener(keys: keys.client).then(BrotliDecoder())
        for _ in 0..<300 {
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
    /// finish; received in 64 KB pieces, the opener rewound to replay the first stream's records.
    @Test(arguments: [true, false])
    func resetPipelinesCarryStreamAfterStream(useBrotli: Bool) throws {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 5, count: 32).span.bytes).server
        let data = Array((0..<4).map { _ in Self.text }.joined())
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

    /// A buffer smaller than a TLS record: the opener can never write one into it. A precondition failure,
    /// not a loop that never returns.
    @Test func bufferTooSmallForAStageStops() async throws {
        await #expect(processExitsWith: .failure) {
            let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 2, count: 32).span.bytes).server
            var send = TLSRecordSealer(keys: keys)
            let wire = try run(&send, Array(PipelineTests.text.prefix(10_000)), chunk: 10_000, outputChunk: 1 << 16, flush: .flush)
            var receive = TLSRecordOpener(keys: keys).then(CopyStage().promoted(to: BytesError.self), bufferCapacity: 1_000)
            _ = try run(&receive, wire, chunk: wire.count, outputChunk: 1 << 16)
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
