public import Bytes
public import BytesCompression
public import Dispatch

// The parallel codecs' asynchronous entry points: on a Dispatch queue (the calling task suspends, its thread
// free), or as child tasks of a task group on Swift's cooperative pool. Each runs the same workers as the
// synchronous `compressAll(_:into:)`, from `BytesCompression`'s `ChunkBatch`, over lent input and output.

extension ChunkBatch {
    /// Runs the workers as child tasks of a task group, one each; returns when every chunk is delivered (or the
    /// output is full).
    nonisolated(nonsending) func runConcurrently() async -> ChunkDelivery {
        await withDiscardingTaskGroup { group in
            for w in 0..<workerCount {
                group.addTask { work(w) }
            }
        }
        return finish()
    }

    /// Runs the workers from `queue` (on `concurrentPerform`), resuming the calling task when they're done.
    nonisolated(nonsending) func run(on queue: DispatchQueue) async -> ChunkDelivery {
        // Unsafe: an unchecked continuation. Safe: resumed exactly once, by the closure.
        await unsafe withUnsafeContinuation { continuation in
            queue.async { unsafe continuation.resume(returning: run()) }
        }
    }
}

public extension ParallelDeflateEncoder {
    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, on `queue`: the calling task
    /// suspends until it's done, and its thread is free meanwhile. One hop to the queue and one back per call.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream, header and trailer included.
    ///   - queue: Where to run: any queue (the workers themselves use Dispatch's worker threads).
    /// - Throws: `BytesError.insufficientCapacity` if `output` runs out of room (what was written stays
    ///   written).
    nonisolated(nonsending) mutating func compressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(BytesError) {
        let job = try begin(byteCount: input.byteCount, into: &output)
        var delivery = ChunkDelivery()
        // Unsafe: the input and the output's free capacity lent to the workers. Safe: the batch is awaited.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                delivery = await unsafe batch(job, input: source, output: target).run(on: queue)
                return delivery.produced
            }
        }
        try Self.end(delivery, job: job, into: &output)
    }

    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, the workers child tasks of a
    /// task group on Swift's cooperative thread pool.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream, header and trailer included.
    /// - Throws: As ``compressAll(_:into:on:)``.
    nonisolated(nonsending) mutating func compressAllConcurrently(
        _ input: RawSpan, into output: inout OutputRawSpan
    ) async throws(BytesError) {
        let job = try begin(byteCount: input.byteCount, into: &output)
        var delivery = ChunkDelivery()
        // Unsafe and safe as above: the task group ends before this call does.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                delivery = await unsafe batch(job, input: source, output: target).runConcurrently()
                return delivery.produced
            }
        }
        try Self.end(delivery, job: job, into: &output)
    }
}

public extension ParallelBrotliEncoder {
    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, on `queue`: the calling task
    /// suspends until it's done, and its thread is free meanwhile.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream.
    ///   - queue: Where to run.
    /// - Throws: `BytesError.insufficientCapacity` if `output` runs out of room.
    nonisolated(nonsending) mutating func compressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(BytesError) {
        let job = job(byteCount: input.byteCount)
        var delivery = ChunkDelivery()
        // Unsafe and safe as for the DEFLATE encoder.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                delivery = await unsafe batch(job, input: source, output: target).run(on: queue)
                return delivery.produced
            }
        }
        try Self.end(delivery)
    }

    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, the workers child tasks of a
    /// task group on Swift's cooperative thread pool.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream.
    /// - Throws: As ``compressAll(_:into:on:)``.
    nonisolated(nonsending) mutating func compressAllConcurrently(
        _ input: RawSpan, into output: inout OutputRawSpan
    ) async throws(BytesError) {
        let job = job(byteCount: input.byteCount)
        var delivery = ChunkDelivery()
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                delivery = await unsafe batch(job, input: source, output: target).runConcurrently()
                return delivery.produced
            }
        }
        try Self.end(delivery)
    }
}

/// A decoder, for a closure on another thread. Unsafe: a pointer, valid while its owner keeps the decoder
/// borrowed.
@unsafe
struct UnsafeDecoder: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<ParallelDeflateDecoder>
}

public extension ParallelDeflateDecoder {
    /// Decompresses as `decompressAll(_:into:)` does, on `queue`: the calling task suspends until it's done,
    /// and its thread is free meanwhile.
    ///
    /// - Parameters:
    ///   - input: The stream.
    ///   - output: Where to append the data.
    ///   - queue: Where to run.
    /// - Returns: The bytes of `input` the stream took.
    /// - Throws: As `decompressAll(_:into:)`.
    nonisolated(nonsending) mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(BytesError) -> Int {
        // The decoder's pointer escapes its closure: `self` is an `inout` parameter, whose storage stays put
        // until this call returns, and the closure finishes before then.
        let decoder = withUnsafeMutablePointer(to: &self) { unsafe UnsafeDecoder(pointer: $0) }
        var consumed = 0
        var failure: BytesError?
        // Unsafe: the input and the output's free capacity lent to a closure on `queue`. Safe: it's awaited.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                let result: Result<(consumed: Int, produced: Int), BytesError> = await unsafe withUnsafeContinuation { continuation in
                    queue.async {
                        var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
                        do throws(BytesError) {
                            let consumed = try unsafe decoder.pointer.pointee.decompressAll(source.span, into: &output)
                            unsafe continuation.resume(returning: .success((consumed, unsafe output.finalize(for: target.buffer))))
                        } catch {
                            unsafe continuation.resume(returning: .failure(error))
                        }
                    }
                }
                switch result {
                case let .success((taken, produced)):
                    consumed = taken
                    return produced
                case let .failure(error):
                    failure = error
                    return 0
                }
            }
        }
        if let failure { throw failure }
        return consumed
    }
}
