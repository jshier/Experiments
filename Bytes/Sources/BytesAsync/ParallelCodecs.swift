public import Bytes
public import BytesCompression
public import Dispatch

// The parallel codecs' asynchronous entry points: on a Dispatch queue (the calling task suspends, its thread
// free), or as child tasks of a task group on Swift's cooperative pool. Each runs the same workers as the
// synchronous `compressAll(_:into:)`, from `BytesCompression`'s `ChunkBatch`, over lent input and output.
//
// The entry points are `nonisolated(nonsending)`, not `@concurrent`: they borrow the caller's `inout` output span
// and `self`, which can't cross isolation domains. What runs on the caller's executor is only the header, the
// trailer, and the wait; the compression runs in child tasks (`…Concurrently`) or on the queue (`on:`), never on
// the caller's actor.
//
// Cancellation: a task cancellation handler stops the call's workers (`ChunkBatch.stop()`, `StopFlag`), which then
// take no more chunks or segments; those under way finish, since a chunk can't stop midway. The call then throws
// `BytesError.cancelled`, keeping the entry points' typed throws: the output is incomplete (an encoder writes no
// trailer, the decoder nothing), and the codec can be used again. A call that had delivered everything by the time
// it was cancelled returns normally.

extension ChunkBatch {
    /// Runs the workers as child tasks of a task group, one each; returns when every chunk is delivered (or the
    /// output is full, or the task is cancelled).
    nonisolated(nonsending) func runConcurrently() async -> ChunkDelivery {
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                for w in 0..<workerCount {
                    // A child task's closure isn't isolated to the caller: the workers run on the global executor.
                    group.addTask { work(w) }
                }
            }
        } onCancel: {
            stop()
        }
        return finish()
    }

    /// Runs the workers from `queue` (on `concurrentPerform`), resuming the calling task when they're done (or
    /// stopped by its cancellation).
    nonisolated(nonsending) func run(on queue: DispatchQueue) async -> ChunkDelivery {
        await withTaskCancellationHandler {
            await perform(on: queue) { run() }
        } onCancel: {
            stop()
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
    ///   written); `BytesError.cancelled` if the task is cancelled before every chunk is delivered (the workers
    ///   take no more chunks; no trailer is written).
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
    /// - Throws: `BytesError.insufficientCapacity` if `output` runs out of room; `BytesError.cancelled` if the
    ///   task is cancelled before every chunk is delivered.
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
    /// - Throws: As `decompressAll(_:into:)`; `BytesError.cancelled` if the task is cancelled before the
    ///   segments are joined (nothing is written; a stream decoding sequentially runs to its end).
    nonisolated(nonsending) mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(BytesError) -> Int {
        // The decoder's pointer escapes its closure: `self` is an `inout` parameter, whose storage stays put
        // until this call returns, and the closure finishes before then.
        let decoder = withUnsafeMutablePointer(to: &self) { unsafe UnsafeDecoder(pointer: $0) }
        var consumed = 0
        var failure: BytesError?
        let stop = StopFlag()
        // Unsafe: the input and the output's free capacity lent to a closure on `queue`. Safe: it's awaited.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                let result: Result<(consumed: Int, produced: Int), BytesError> = await withTaskCancellationHandler {
                    await perform(on: queue) {
                        var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
                        let result: Result<(consumed: Int, produced: Int), BytesError>
                        do throws(BytesError) {
                            let consumed = try unsafe decoder.pointer.pointee.decompressAll(source.span, into: &output, stop: stop)
                            result = .success((consumed, 0))
                        } catch {
                            result = .failure(error)
                        }
                        // Unsafe: checks `output` still covers the lent buffer. Safe: it was made over it.
                        let produced = unsafe output.finalize(for: target.buffer)
                        return result.map { ($0.consumed, produced) }
                    }
                } onCancel: {
                    stop.stop()
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
