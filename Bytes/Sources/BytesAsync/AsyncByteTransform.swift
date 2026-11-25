public import Bytes
public import Dispatch

/// A stage of a byte pipeline whose calls may suspend: `Bytes`' ``Bytes/ByteTransform``, `async`.
///
/// Any `ByteTransform` becomes one with ``Bytes/ByteTransform/synchronously()`` (its calls run in place, on the
/// caller's executor), ``Bytes/ByteTransform/concurrently()`` (its calls run in a `@concurrent` function, on the
/// global concurrent executor: never on the caller's actor), or ``Bytes/ByteTransform/offloaded(to:)`` (its calls
/// run on a Dispatch queue, so a heavy stage, a compressor at a high level, doesn't hold a thread of Swift's
/// cooperative pool while it works).
///
/// The requirement is `nonisolated(nonsending)`: it borrows the caller's spans (`inout OutputRawSpan`), which can't
/// cross to another isolation domain, so a stage that moves its work elsewhere lends the memory for the call
/// (``Bytes/RawSpan/withLentBytes(_:)``) and awaits the work before returning.
///
/// Stages follow `ByteTransform`'s rules, including the end of a stream: `.finished` at `.finish`, or a throw.
public protocol AsyncByteTransform: ~Copyable {
    /// What the stage throws: `Never` if it can't fail.
    associatedtype Failure: Error

    /// Transforms as much of `input` as it can, appending to `output`, as ``Bytes/ByteTransform/transform(_:into:flush:)``.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: The stage's ``Failure``.
    nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush
    ) async throws(Failure) -> TransformProgress
}

public extension AsyncByteTransform where Self: ~Copyable {
    /// Transforms all of `input`, appending the output to `output`, which grows as needed: the drive loop, as
    /// ``Bytes/ByteTransform/transform(_:appending:flush:growth:)``.
    ///
    /// - Parameters:
    ///   - input: The bytes to transform.
    ///   - output: The array to append to.
    ///   - flush: As for ``transform(_:into:flush:)``; with `.finish`, this returns `.finished`.
    ///   - growth: The least room to add at a time.
    /// - Returns: What was consumed and produced.
    /// - Throws: The stage's ``Failure``. The output appended before it stays.
    nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, appending output: inout [UInt8], flush: TransformFlush, growth: Int = 16 << 10
    ) async throws(Failure) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            let room = max(growth, input.byteCount &- consumed)
            let start = output.count
            // Room at the end, initialized (the stage overwrites it): an array's new capacity can't stay open
            // across a suspension, so it's added first and trimmed after.
            output.append(contentsOf: repeatElement(0, count: room))
            var span = output.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            var progress = TransformProgress(consumed: 0, produced: 0, status: .needsInput)
            var failure: Failure?
            do throws(Failure) {
                progress = try await bytes.withOutputRawSpan(overwritingFrom: start) { raw async throws(Failure) in
                    try await transform(input.extracting(consumed...), into: &raw, flush: flush)
                }
            } catch {
                failure = error
            }
            output.removeLast(room &- progress.produced)
            if let failure { throw failure }
            consumed &+= progress.consumed
            produced &+= progress.produced
            if progress.status != .needsOutput {
                return TransformProgress(consumed: consumed, produced: produced, status: progress.status)
            }
        }
    }
}

extension MutableRawSpan {
    /// An output span over these bytes from `offset`, for an asynchronous body.
    @_lifetime(self: copy self)
    nonisolated(nonsending) mutating func withOutputRawSpan<R, E: Error>(
        overwritingFrom offset: Int, _ body: nonisolated(nonsending) (inout OutputRawSpan) async throws(E) -> R
    ) async throws(E) -> R {
        precondition(offset >= 0 && offset <= byteCount, "An output span starting outside a span")
        // Unsafe: an output span over these bytes, outliving `withUnsafeMutableBytes`' closure. Safe: the span is
        // `inout` for this whole call, so its memory stays put; `finalize` checks that `body` left it in place.
        let region = withUnsafeMutableBytes { buffer in
            unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[offset...])
        }
        var output = unsafe OutputRawSpan(buffer: region, initializedCount: 0)
        let result = try await body(&output)
        _ = unsafe output.finalize(for: region)
        return result
    }
}

// MARK: - Adapters

public extension ByteTransform where Self: ~Copyable {
    /// This stage as an asynchronous one whose calls run in place, without suspending: to compose it with
    /// asynchronous stages.
    consuming func synchronously() -> SynchronousTransform<Self> {
        SynchronousTransform(self)
    }

    /// This stage as an asynchronous one whose calls run in a `@concurrent` function: on Swift's global
    /// concurrent executor, in the calling task, so never on the caller's actor. A caller that's already on the
    /// global executor (a nonisolated task) runs the stage without changing threads; one on an actor hops off
    /// and back per call. Priority and task-locals carry over, as for any call.
    ///
    /// The structured way to keep a heavy stage off an actor; prefer it to ``offloaded(to:)`` unless the
    /// work must stay off the cooperative pool's threads.
    consuming func concurrently() -> ConcurrentTransform<Self> where Self: SendableMetatype {
        ConcurrentTransform(self)
    }

    /// This stage as an asynchronous one whose calls run on `queue`: the calling task suspends, and its thread
    /// is free, while the stage works. One hop to the queue and one back per call, so for calls that do a lot
    /// (a compressor's block, a large batch), not a few bytes. ``concurrently()`` is the structured alternative;
    /// this is for work that must stay off the cooperative pool's threads, or run on a queue of its own.
    ///
    /// - Parameter queue: Where the calls run.
    consuming func offloaded(to queue: DispatchQueue) -> OffloadedTransform<Self> where Self: SendableMetatype {
        OffloadedTransform(self, queue: queue)
    }
}

/// A `ByteTransform` as an ``AsyncByteTransform`` whose calls don't suspend: from
/// ``Bytes/ByteTransform/synchronously()``.
public struct SynchronousTransform<Base: ByteTransform & ~Copyable>: ~Copyable {
    /// The stage.
    public var base: Base

    /// Wraps `base`.
    ///
    /// - Parameter base: The stage.
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension SynchronousTransform: AsyncByteTransform where Base: ~Copyable {
    /// The stage's error type.
    public typealias Failure = Base.Failure

    /// Runs the stage's `transform` where the caller is, without suspending.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The stage's progress.
    /// - Throws: The stage's `Failure`.
    public nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush
    ) async throws(Failure) -> TransformProgress {
        try base.transform(input, into: &output, flush: flush)
    }
}

/// A `ByteTransform` as an ``AsyncByteTransform`` whose calls run on a Dispatch queue: from
/// ``Bytes/ByteTransform/offloaded(to:)``.
public struct OffloadedTransform<Base: ByteTransform & ~Copyable & SendableMetatype>: ~Copyable {
    /// The stage.
    public var base: Base
    /// Where its calls run.
    public let queue: DispatchQueue

    /// Wraps `base`, to run on `queue`.
    ///
    /// - Parameters:
    ///   - base: The stage.
    ///   - queue: Where its calls run.
    public init(_ base: consuming Base, queue: DispatchQueue) {
        self.base = base
        self.queue = queue
    }
}

/// A `ByteTransform` as an ``AsyncByteTransform`` whose calls run in a `@concurrent` function: from
/// ``Bytes/ByteTransform/concurrently()``.
public struct ConcurrentTransform<Base: ByteTransform & ~Copyable & SendableMetatype>: ~Copyable {
    /// The stage.
    public var base: Base

    /// Wraps `base`.
    ///
    /// - Parameter base: The stage.
    public init(_ base: consuming Base) {
        self.base = base
    }
}

/// A stage, for work in another isolation domain. Unsafe: a pointer, valid while its owner keeps the stage borrowed.
@unsafe
struct UnsafeStage<Base: ~Copyable>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Base>
}

extension UnsafeStage where Base: ByteTransform & ~Copyable {
    /// Runs the stage over lent input and output: what the offloaded forms run elsewhere.
    ///
    /// Unsafe: the stage's pointer and the lent buffers. Safe when the caller keeps all three borrowed until this
    /// returns (each form awaits it).
    ///
    /// - Returns: The stage's progress (what it wrote is the prefix of `target` it reports), or its error (then
    ///   nothing is counted written).
    func transform(_ source: LentBytes, into target: LentMutableBytes, flush: TransformFlush) -> Result<TransformProgress, Base.Failure> {
        var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
        let result: Result<TransformProgress, Base.Failure>
        do throws(Base.Failure) {
            result = try .success(unsafe pointer.pointee.transform(source.span, into: &output, flush: flush))
        } catch {
            result = .failure(error)
        }
        _ = unsafe output.finalize(for: target.buffer)
        return result
    }
}

/// Lends `input`, `output`'s free capacity, and `stage` to `run`, which runs the stage elsewhere; counts what it
/// wrote. The part ``ConcurrentTransform`` and ``OffloadedTransform`` share.
nonisolated(nonsending) func transformLending<Base: ByteTransform & ~Copyable>(
    _ stage: inout Base, _ input: RawSpan, into output: inout OutputRawSpan,
    _ run: nonisolated(nonsending) (UnsafeStage<Base>, LentBytes, LentMutableBytes) async -> Result<TransformProgress, Base.Failure>
) async throws(Base.Failure) -> TransformProgress {
    // The stage's pointer escapes its closure: `stage` is `inout` for this whole call, so it stays put, and `run`
    // finishes with it before this call returns.
    let pointer = withUnsafeMutablePointer(to: &stage) { unsafe UnsafeStage(pointer: $0) }
    var result: Result<TransformProgress, Base.Failure> = .success(TransformProgress(consumed: 0, produced: 0, status: .needsInput))
    // Unsafe: the input, the output's free capacity, and the stage lent to work elsewhere. Safe: `run` awaits it.
    _ = await unsafe input.withLentBytes { source in
        await unsafe output.withLentFreeCapacity { target in
            result = await unsafe run(pointer, source, target)
            return (try? result.get())?.produced ?? 0
        }
    }
    return try result.get()
}

extension ConcurrentTransform: AsyncByteTransform where Base: ~Copyable & SendableMetatype {
    /// The stage's error type.
    public typealias Failure = Base.Failure

    /// Runs the stage's `transform` on the global concurrent executor (a `@concurrent` function), suspending
    /// until it returns if that means leaving the caller's executor.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The stage's progress.
    /// - Throws: The stage's `Failure`.
    public nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush
    ) async throws(Failure) -> TransformProgress {
        try await unsafe transformLending(&base, input, into: &output) { stage, source, target in
            // Unsafe: the lent stage and buffers, used off this executor. Safe: awaited before they're released.
            await perform { unsafe stage.transform(source, into: target, flush: flush) }
        }
    }
}

extension OffloadedTransform: AsyncByteTransform where Base: ~Copyable & SendableMetatype {
    /// The stage's error type.
    public typealias Failure = Base.Failure

    /// Runs the stage's `transform` on ``queue``, suspending until it returns.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The stage's progress.
    /// - Throws: The stage's `Failure`.
    public nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush
    ) async throws(Failure) -> TransformProgress {
        let queue = queue
        return try await unsafe transformLending(&base, input, into: &output) { stage, source, target in
            // Unsafe: the lent stage and buffers, used on `queue`. Safe: `perform` returns after the block has.
            await perform(on: queue) { unsafe stage.transform(source, into: target, flush: flush) }
        }
    }
}
