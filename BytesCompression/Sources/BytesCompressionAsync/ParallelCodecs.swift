public import Bytes

// The async lending (`withLentBytesAsync`, `withLentFreeCapacityAsync`) and the Dispatch hop (`perform(on:)`).
internal import BytesAsync
public import BytesCompression
public import Dispatch

// The parallel codecs' asynchronous entry points: on a Dispatch queue (the calling task suspends, its thread
// free), or as child tasks of a task group on Swift's cooperative pool. Each runs the same workers as the
// synchronous `compressAll(_:into:)` and `decompressAll(_:into:)`, from `BytesCompression`'s `ChunkBatch` and
// `SegmentBatch`, over lent input and output.
//
// The entry points are `nonisolated(nonsending)`, not `@concurrent`: they borrow the caller's `inout` output span
// and `self`, which can't cross isolation domains. What runs on the caller's executor is only an encoder's header
// and trailer, and the wait; the work runs in child tasks (`…Concurrently`) or on the queue (`on:`), never on the
// caller's actor. (The decoder's sequential parts, its plan, join, and any sequential decode, run in a child task
// too: they can be the whole stream.)
//
// Cancellation: a task cancellation handler stops the call's workers (`ChunkBatch.stop()`, `StopFlag`), which then
// take no more chunks or segments; those under way finish, since a chunk can't stop midway. The call then throws
// `CancellableError.cancelled` (the codecs' own failures are `.failed`): the output is incomplete (an encoder writes no
// trailer, the decoder nothing), and the codec can be used again. A call that had delivered everything by the time
// it was cancelled returns normally.

/// `body`'s failure as a cancellable call's: ``CancellableError/failed(_:)``.
@inline(__always)
func failing<R>(_ body: () throws(BytesError) -> R) throws(CancellableError<BytesError>) -> R {
    do throws(BytesError) {
        return try body()
    } catch {
        throw .failed(error)
    }
}

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
    /// - Throws: `.failed(.insufficientCapacity)` if `output` runs out of room (what was written stays
    ///   written); `.cancelled` if the task is cancelled before every chunk is delivered (the workers take no more
    ///   chunks; no trailer is written).
    nonisolated(nonsending) mutating func compressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(CancellableError<BytesError>) {
        let job = try failing { () throws(BytesError) in try begin(byteCount: input.byteCount, into: &output) }
        var delivery = ChunkDelivery()
        // Unsafe: the input and the output's free capacity lent to the workers. Safe: the batch is awaited.
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                delivery = await unsafe batch(job, input: source, output: target).run(on: queue)
                return delivery.produced
            }
        }
        if delivery.cancelled { throw .cancelled }
        try failing { () throws(BytesError) in try Self.end(delivery, job: job, into: &output) }
    }

    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, the workers child tasks of a
    /// task group on Swift's cooperative thread pool.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream, header and trailer included.
    /// - Throws: As ``compressAll(_:into:on:)``.
    package nonisolated(nonsending) mutating func compressAllConcurrently(
        _ input: RawSpan, into output: inout OutputRawSpan
    ) async throws(CancellableError<BytesError>) {
        let job = try failing { () throws(BytesError) in try begin(byteCount: input.byteCount, into: &output) }
        var delivery = ChunkDelivery()
        // Unsafe and safe as above: the task group ends before this call does.
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                delivery = await unsafe batch(job, input: source, output: target).runConcurrently()
                return delivery.produced
            }
        }
        if delivery.cancelled { throw .cancelled }
        try failing { () throws(BytesError) in try Self.end(delivery, job: job, into: &output) }
    }
}

package extension ParallelBrotliEncoder {
    /// Compresses all of `input` into `output` as `compressAll(_:into:)` does, on `queue`: the calling task
    /// suspends until it's done, and its thread is free meanwhile.
    ///
    /// - Parameters:
    ///   - input: The data.
    ///   - output: Where to append the stream.
    ///   - queue: Where to run.
    /// - Throws: `.failed(.insufficientCapacity)` if `output` runs out of room; `.cancelled` if the task is
    ///   cancelled before every chunk is delivered.
    nonisolated(nonsending) mutating func compressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(CancellableError<BytesError>) {
        let job = job(byteCount: input.byteCount)
        var delivery = ChunkDelivery()
        // Unsafe and safe as for the DEFLATE encoder.
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                delivery = await unsafe batch(job, input: source, output: target).run(on: queue)
                return delivery.produced
            }
        }
        if delivery.cancelled { throw .cancelled }
        try failing { () throws(BytesError) in try Self.end(delivery) }
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
    ) async throws(CancellableError<BytesError>) {
        let job = job(byteCount: input.byteCount)
        var delivery = ChunkDelivery()
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                delivery = await unsafe batch(job, input: source, output: target).runConcurrently()
                return delivery.produced
            }
        }
        if delivery.cancelled { throw .cancelled }
        try failing { () throws(BytesError) in try Self.end(delivery) }
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
    /// - Throws: `.failed` as `decompressAll(_:into:)` throws; `.cancelled` if the task is cancelled before the
    ///   segments are joined (nothing is written), or before a sequential decode or gzip's later members (a decode,
    ///   once started, runs to its end).
    nonisolated(nonsending) mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(CancellableError<BytesError>) -> Int {
        // The decoder's pointer escapes its closure: `self` is an `inout` parameter, whose storage stays put
        // until this call returns, and the closure finishes before then.
        let decoder = withUnsafeMutablePointer(to: &self) { unsafe UnsafeDecoder(pointer: $0) }
        var consumed = 0
        var failure: CancellableError<BytesError>?
        let stop = StopFlag()
        // Unsafe: the input and the output's free capacity lent to a closure on `queue`. Safe: it's awaited.
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                let result: Result<(consumed: Int, produced: Int), CancellableError<BytesError>> = await withTaskCancellationHandler {
                    await perform(on: queue) {
                        var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
                        let result: Result<(consumed: Int, produced: Int), CancellableError<BytesError>>
                        do throws(BytesError) {
                            // The whole decode in one call on the queue, which checks `stop` between its steps.
                            if let consumed = try unsafe decoder.pointer.pointee.decompressAll(source.span, into: &output, stopping: stop) {
                                result = .success((consumed, 0))
                            } else {
                                result = .failure(.cancelled)
                            }
                        } catch {
                            result = .failure(.failed(error))
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

    /// Decompresses as `decompressAll(_:into:)` does, the segment workers child tasks of a task group on Swift's
    /// cooperative thread pool. The call's sequential parts (the plan, the join, a sequential decode, gzip's later
    /// members) run in a child task of their own, not on the caller's executor.
    ///
    /// - Parameters:
    ///   - input: The stream.
    ///   - output: Where to append the data.
    /// - Returns: The bytes of `input` the stream took.
    /// - Throws: As ``decompressAll(_:into:on:)``.
    package nonisolated(nonsending) mutating func decompressAllConcurrently(
        _ input: RawSpan, into output: inout OutputRawSpan
    ) async throws(CancellableError<BytesError>) -> Int {
        // The decoder's pointer escapes its closure: `self` is an `inout` parameter, whose storage stays put
        // until this call returns, and the task group ends before then.
        let decoder = withUnsafeMutablePointer(to: &self) { unsafe UnsafeDecoder(pointer: $0) }
        var consumed = 0
        var failure: CancellableError<BytesError>?
        let stop = StopFlag()
        // Unsafe: the input and the output's free capacity lent to the child tasks. Safe: the task group ends before
        // this call does.
        _ = await unsafe input.withLentBytesAsync { source in
            await unsafe output.withLentFreeCapacityAsync { target in
                let result = await withTaskCancellationHandler {
                    await withTaskGroup(of: Result<(consumed: Int, produced: Int), CancellableError<BytesError>>.self) { group in
                        // A child task's closure isn't isolated to the caller: the call runs on the global executor.
                        group.addTask { await unsafe decoder.decompressConcurrently(source, into: target, stop: stop) }
                        return await group.next() ?? .failure(.cancelled)
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

extension UnsafeDecoder {
    /// ``ParallelDeflateDecoder/decompressAllConcurrently(_:into:)``'s work, in a child task: the plan, the segment
    /// workers as child tasks of their own, the join; or a sequential decode; then gzip's later members.
    ///
    /// Unsafe: the decoder through a pointer, the input and output lent. Safe: the caller keeps the decoder borrowed
    /// and both lent until this returns.
    /// Checks `stop` between the steps, as the synchronous `decompressAll(_:into:stopping:)` does: before the join (which
    /// would decode the segments the stopped workers skipped), a sequential decode, and gzip's later members.
    func decompressConcurrently(
        _ source: LentBytes, into target: LentMutableBytes, stop: StopFlag
    ) async -> Result<(consumed: Int, produced: Int), CancellableError<BytesError>> {
        var joined: (consumed: Int, produced: Int)?
        do throws(BytesError) {
            if let plan = unsafe pointer.pointee.plan(source.span) {
                let batch = unsafe pointer.pointee.segmentBatch(plan, input: source, output: target, stop: stop)
                await withDiscardingTaskGroup { group in
                    for w in 0..<batch.workerCount {
                        group.addTask { batch.work(w) }
                    }
                }
                if stop.isStopped { return .failure(.cancelled) }
                joined = try unsafe pointer.pointee.joinSegments(source.span, plan: plan, into: target)
            }
            // Unsafe: an output span over the lent buffer, starting after the joined bytes. Safe: the buffer outlives it,
            // and the join initialized those bytes.
            var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: joined?.produced ?? 0)
            let streamEnd: Int
            if let joined {
                streamEnd = joined.consumed
            } else {
                if stop.isStopped { return .failure(.cancelled) }
                streamEnd = try unsafe pointer.pointee.decompressSequentially(source.span, into: &output)
            }
            if unsafe pointer.pointee.membersFollow(source.span, after: streamEnd), stop.isStopped { return .failure(.cancelled) }
            let consumed = try unsafe pointer.pointee.decompressMembers(source.span, after: streamEnd, into: &output)
            // Unsafe: checks `output` still covers the lent buffer. Safe: it was made over it.
            return .success((consumed, unsafe output.finalize(for: target.buffer)))
        } catch {
            return .failure(.failed(error))
        }
    }
}
