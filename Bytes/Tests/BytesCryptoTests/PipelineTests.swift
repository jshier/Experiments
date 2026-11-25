import Bytes
import BytesCrypto
import BytesTestSupport
import Testing

// The pipeline tests that need no codec. Those through compression (codecs and TLS records together) moved with
// BytesCompression to its own package (BytesCompression/Tests/BytesCompressionTests/PipelineTests.swift).

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

/// A test stage that can't fail: copies its input.
struct CopyStage: ByteTransform {
    typealias Failure = Never

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        let count = min(input.byteCount, output.freeCapacity)
        output.withBytesWriter { writer in
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
        while bytes.count < 300_000 {
            bytes += Array(words.randomElement(using: &rng)!.utf8)
        }
        return bytes
    }()

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
    @Test func undeclaredUnitStops() async {
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
            output.withBytesWriter { writer in try? writer.write(input.extracting(consumed..<(consumed + unit))) }
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
        output.withBytesWriter { writer in try? writer.write(input.extracting(0..<take)) }
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
