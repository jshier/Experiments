import Bytes
import BytesAsync
import BytesCompression
import BytesCompressionAsync
import Dispatch
import Testing

/// The async parallel codecs stop when their task is cancelled: the workers take no more chunks, and the call throws
/// `BytesError.cancelled`. A task cancelled before the call stops it before any chunk is taken; the codec then works
/// again for the next call.
@Suite struct ParallelCancellationTests {
    enum Form: CaseIterable, Sendable {
        case deflateOnQueue, deflateConcurrently, brotliOnQueue, brotliConcurrently, inflateOnQueue, inflateConcurrently

        var decodes: Bool { self == .inflateOnQueue || self == .inflateConcurrently }
    }

    /// The outcome of one async call, in a task cancelled before it (`cancelFirst`) or not.
    static func run(_ form: Form, _ input: [UInt8], cancelFirst: Bool) async -> Result<[UInt8], BytesError> {
        await Task {
            if cancelFirst {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return await call(form, input)
        }.value
    }

    static func call(_ form: Form, _ input: [UInt8]) async -> Result<[UInt8], BytesError> {
        let queue = DispatchQueue(label: "cancellation")
        var output = [UInt8](repeating: 0, count: input.count * 2 + 1024)
        let pointer = output.withUnsafeMutableBytes { $0 }
        var span = OutputRawSpan(buffer: pointer, initializedCount: 0)
        do throws(BytesError) {
            switch form {
            case .deflateOnQueue, .deflateConcurrently:
                var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: 4)
                if form == .deflateOnQueue {
                    try await encoder.compressAll(input.span.bytes, into: &span, on: queue)
                } else {
                    try await encoder.compressAllConcurrently(input.span.bytes, into: &span)
                }
            case .brotliOnQueue, .brotliConcurrently:
                var encoder = ParallelBrotliEncoder(quality: 1, chunkSize: 32 << 10, lanes: 4)
                if form == .brotliOnQueue {
                    try await encoder.compressAll(input.span.bytes, into: &span, on: queue)
                } else {
                    try await encoder.compressAllConcurrently(input.span.bytes, into: &span)
                }
            case .inflateOnQueue, .inflateConcurrently:
                var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 4)
                if form == .inflateOnQueue {
                    _ = try await decoder.decompressAll(input.span.bytes, into: &span, on: queue)
                } else {
                    _ = try await decoder.decompressAllConcurrently(input.span.bytes, into: &span)
                }
            }
        } catch {
            _ = span.finalize(for: pointer)
            return .failure(error)
        }
        return .success(Array(output[..<span.finalize(for: pointer)]))
    }

    /// Text-like input of `count` bytes that compresses, and isn't one repeated block.
    static func input(_ count: Int) -> [UInt8] {
        var state: UInt32 = 0x1234_5678
        return (0..<count).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: (state >> 24) % 26 + 97) ^ UInt8(i / 4096 & 1)
        }
    }

    /// The decoder's input: the encoder's independent chunks, so it decodes in segments.
    static func compressed(_ input: [UInt8]) throws(BytesError) -> [UInt8] {
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: input.count))
        let produced = try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(input.span.bytes, into: &span)
            return span.byteCount
        }
        return Array(output[..<produced])
    }

    @Test(arguments: Form.allCases)
    func cancelledBeforeTheCallThrows(form: Form) async throws {
        let data = Self.input(1 << 20)
        let input = form.decodes ? try Self.compressed(data) : data
        let cancelled = await Self.run(form, input, cancelFirst: true)
        #expect(cancelled == .failure(.cancelled))
        // Not cancelled, the same call completes (and the decoder gives back the data).
        let completed = await Self.run(form, input, cancelFirst: false)
        guard case let .success(output) = completed else {
            Issue.record("\(form): \(completed)")
            return
        }
        #expect(!output.isEmpty)
        if form.decodes {
            #expect(output == data)
        }
    }

    /// A batch stopped before it runs delivers nothing and ends in `cancelled`; the encoder's next call (its
    /// scheduler started again) gives the same stream as a fresh encoder's.
    @Test func encoderWorksAfterAStoppedBatch() throws {
        let data = Self.input(1 << 20)
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: 4)
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: data.count))
        var delivery = ChunkDelivery()
        _ = try output.withOutputRawSpan { span throws(BytesError) in
            let job = try encoder.begin(byteCount: data.count, into: &span)
            _ = data.span.bytes.withLentBytes { source in
                span.withLentFreeCapacity { target in
                    let batch = encoder.batch(job, input: source, output: target)
                    batch.stop()
                    delivery = batch.run()
                    return delivery.produced
                }
            }
            #expect(throws: BytesError.cancelled) { try ParallelDeflateEncoder.end(delivery, job: job, into: &span) }
            return 0
        }
        #expect(delivery.cancelled && delivery.produced == 0)
        var fresh = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 32 << 10, lanes: 4)
        #expect(try Self.encode(&encoder, data) == Self.encode(&fresh, data))
    }

    static func encode(_ encoder: inout ParallelDeflateEncoder, _ data: [UInt8]) throws(BytesError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: data.count))
        let produced = try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        return Array(output[..<produced])
    }

    /// Cancelled while it runs, a call either finishes (the output whole) or throws `cancelled`; either way it
    /// returns, and an encoder reused afterwards gives the same stream as a fresh one.
    @Test(arguments: [Form.deflateConcurrently, .inflateConcurrently])
    func cancelledWhileRunningStopsOrFinishes(form: Form) async throws {
        let data = Self.input(4 << 20)
        let input = form.decodes ? try Self.compressed(data) : data
        let expected = await Self.call(form, input)
        let task = Task { await Self.call(form, input) }
        task.cancel()
        let outcome = await task.value
        switch outcome {
        case let .failure(error): #expect(error == .cancelled)
        case .success: #expect(outcome == expected)
        }
        if form.decodes { #expect(expected == .success(data)) }
    }
}
