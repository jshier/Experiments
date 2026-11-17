public import Bytes
public import Dispatch

/// A stage of a byte pipeline whose calls may suspend: `Bytes`' ``Bytes/ByteTransform``, `async`.
///
/// Any `ByteTransform` becomes one with ``Bytes/ByteTransform/synchronously()`` (its calls run in place) or
/// ``Bytes/ByteTransform/offloaded(to:)`` (its calls run on a Dispatch queue, so a heavy stage, a compressor at a
/// high level, doesn't hold a thread of Swift's cooperative pool while it works).
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
                progress = try await bytes.withOutputRawSpan(overwritingFrom: start) { (raw) async throws(Failure) in
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

    /// This stage as an asynchronous one whose calls run on `queue`: the calling task suspends, and its thread
    /// is free, while the stage works. One hop to the queue and one back per call, so for calls that do a lot
    /// (a compressor's block, a large batch), not a few bytes.
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
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension SynchronousTransform: AsyncByteTransform where Base: ~Copyable {
    public typealias Failure = Base.Failure

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
    public init(_ base: consuming Base, queue: DispatchQueue) {
        self.base = base
        self.queue = queue
    }
}

/// A stage, for a closure on another thread. Unsafe: a pointer, valid while its owner keeps the stage borrowed.
@unsafe
struct UnsafeStage<Base: ~Copyable>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Base>
}

extension OffloadedTransform: AsyncByteTransform where Base: ~Copyable & SendableMetatype {
    public typealias Failure = Base.Failure

    public nonisolated(nonsending) mutating func transform(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush
    ) async throws(Failure) -> TransformProgress {
        let queue = queue
        // The stage's pointer escapes its closure: `self` is `inout` for this whole call, so `base` stays put,
        // and the closure on `queue` finishes before the call returns.
        let stage = withUnsafeMutablePointer(to: &base) { unsafe UnsafeStage(pointer: $0) }
        var progress = TransformProgress(consumed: 0, produced: 0, status: .needsInput)
        var failure: Failure?
        // Unsafe: the input, the output's free capacity, and the stage lent to a closure on `queue`. Safe: it's
        // awaited before this call returns.
        _ = await unsafe input.withLentBytes { source in
            await unsafe output.withLentFreeCapacity { target in
                let result: Result<TransformProgress, Failure> = await unsafe withUnsafeContinuation { continuation in
                    queue.async {
                        var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
                        do throws(Failure) {
                            let progress = try unsafe stage.pointer.pointee.transform(source.span, into: &output, flush: flush)
                            _ = unsafe output.finalize(for: target.buffer)
                            unsafe continuation.resume(returning: .success(progress))
                        } catch {
                            _ = unsafe output.finalize(for: target.buffer)
                            unsafe continuation.resume(returning: .failure(error))
                        }
                    }
                }
                switch result {
                case let .success(value):
                    progress = value
                    return value.produced
                case let .failure(error):
                    failure = error
                    return 0
                }
            }
        }
        if let failure { throw failure }
        return progress
    }
}
