// Byte pipelines: streaming transforms (compression, encryption, framing, checksums) composed into one,
// allocation-free after construction, with typed errors.

/// How much of its input a streaming transform should finish.
public enum TransformFlush: Hashable, Sendable {
    /// Transform as it sees fit, keeping input back if that helps (an encoder looking for matches).
    case none
    /// Transform everything so far and end the output on a boundary the next stage can use in full: a
    /// message's end, in a stream of messages.
    case flush
    /// No more input will come: finish the output. A decoder throws if its input ended early.
    case finish
}

/// Why a streaming transform returned.
public enum TransformStatus: Hashable, Sendable {
    /// All the input given was used (or kept, see ``TransformProgress/consumed``); call again with more.
    case needsInput
    /// The output is full; call again with more room. Output is waiting.
    case needsOutput
    /// The stream is complete and all its output delivered. Input after its end isn't consumed.
    case finished
}

/// What one call of a streaming transform did.
public struct TransformProgress: Hashable, Sendable {
    /// Bytes of input used. Pass the rest again, followed by new input, on the next call.
    public var consumed: Int
    /// Bytes appended to the output.
    public var produced: Int
    /// Why the call returned.
    public var status: TransformStatus

    /// Creates a progress report.
    ///
    /// - Parameters:
    ///   - consumed: Bytes of input used.
    ///   - produced: Bytes appended to the output.
    ///   - status: Why the call returned.
    @inlinable
    public init(consumed: Int, produced: Int, status: TransformStatus) {
        self.consumed = consumed
        self.produced = produced
        self.status = status
    }
}

/// A stage of a byte pipeline: transforms bytes as they stream through, from input spans into an output
/// span, as zlib's `deflate` and `inflate` do.
///
/// Compose stages with ``then(_:bufferCapacity:)``; stages share one error type, ``Failure`` (`Never` for
/// stages that can't fail, which makes a pipeline of them non-throwing). ``promoted(to:)`` lifts a
/// non-throwing stage into another's error type, and ``mapError(_:)`` converts between types.
public protocol ByteTransform: ~Copyable {
    /// What the stage throws: `Never` if it can't fail.
    associatedtype Failure: Error

    /// Transforms as much of `input` as it can, appending to `output`.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: The stage's ``Failure``.
    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress
}

/// A stage that can start over on a new stream, keeping its allocations: a pipeline built once serves stream
/// after stream (an HTTP connection's responses, a benchmark's iterations) with no allocation per stream.
public protocol ResettableByteTransform: ByteTransform, ~Copyable {
    /// Prepares for a new stream, discarding input kept and output not yet delivered. Allocates nothing.
    mutating func reset()
}

/// A stage that rewrites bytes in place, one for one: a stream cipher, a checksum that passes bytes
/// through. After another stage (``ByteTransform/then(_:)-(InPlaceByteTransform)``) it works on that stage's
/// output where it was written, with no buffer between them.
public protocol InPlaceByteTransform: ~Copyable {
    /// What the stage throws: `Never` if it can't fail.
    associatedtype Failure: Error

    /// Rewrites `bytes`, the next bytes of the stream.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to rewrite.
    ///   - flush: The flush the bytes came with.
    mutating func transform(inPlace bytes: inout MutableRawSpan, flush: TransformFlush) throws(Failure)
}

// MARK: - Composition

public extension ByteTransform where Self: ~Copyable {
    /// A pipeline of this stage, then `next`, with a buffer between them.
    ///
    /// ```swift
    /// var pipeline = DeflateEncoder(format: .raw).then(RecordSealer(key: key))
    /// let progress = try pipeline.transform(message, into: &output, flush: .flush)
    /// ```
    ///
    /// - Parameters:
    ///   - next: The stage that receives this one's output.
    ///   - bufferCapacity: The buffer between the stages, allocated once, now.
    /// - Returns: The pipeline.
    @inlinable
    consuming func then<Next: ByteTransform & ~Copyable>(
        _ next: consuming Next, bufferCapacity: Int = 64 << 10
    ) -> Pipeline<Self, Next> where Next.Failure == Failure {
        Pipeline(self, next, bufferCapacity: bufferCapacity)
    }

    /// A pipeline of this stage, then `next` working in place on this stage's output: no buffer between
    /// them, no copy.
    ///
    /// - Parameter next: The in-place stage.
    /// - Returns: The fused pipeline.
    @inlinable
    consuming func then<Next: InPlaceByteTransform & ~Copyable>(_ next: consuming Next) -> FusedPipeline<Self, Next>
        where Next.Failure == Failure {
        FusedPipeline(self, next)
    }

    /// This non-throwing stage typed as throwing `failure`, to compose with stages that throw it.
    @inlinable
    consuming func promoted<E: Error>(to failure: E.Type) -> PromotedTransform<Self, E> where Failure == Never {
        PromotedTransform(self)
    }

    /// This stage, with its errors converted by `transform`.
    ///
    /// - Parameter transform: Converts an error; a closure that captures nothing, so storing it allocates
    ///   nothing.
    @inlinable
    consuming func mapError<E: Error>(_ transform: @escaping @Sendable (Failure) -> E) -> MappedErrorTransform<Self, E> {
        MappedErrorTransform(self, transform)
    }
}

/// Two stages composed through a buffer: the first's output is the second's input.
///
/// One function, after specialization: `transform` is inlinable, so a pipeline of concrete stages compiles
/// to their code with the buffer handling between, nothing dynamic. The buffer is allocated once, when the
/// pipeline is made; transforming allocates nothing.
@frozen
public struct Pipeline<First: ByteTransform & ~Copyable, Second: ByteTransform & ~Copyable>: ~Copyable
    where First.Failure == Second.Failure {
    /// The first stage.
    public var first: First
    /// The second stage.
    public var second: Second
    @usableFromInline var buffer: UniqueArray<UInt8>
    /// The first stage's output not yet taken by the second: `buffer[start..<end]`.
    @usableFromInline var start = 0
    @usableFromInline var end = 0
    /// The first stage's status from its last call.
    @usableFromInline var firstStatus = TransformStatus.needsInput

    /// Composes `first` and `second` with a buffer of `bufferCapacity` bytes between them.
    @inlinable
    public init(_ first: consuming First, _ second: consuming Second, bufferCapacity: Int = 64 << 10) {
        self.first = first
        self.second = second
        buffer = UniqueArray(repeating: 0, count: bufferCapacity)
    }
}

extension Pipeline: ByteTransform where First: ~Copyable, Second: ~Copyable {
    public typealias Failure = First.Failure

    /// Runs `input` through both stages into `output`.
    ///
    /// The first stage fills the buffer and the second empties it, alternately, until the input is used and
    /// the buffer drained (`needsInput`), the output is full (`needsOutput`), or the second stage finishes.
    /// The second stage sees `flush` once the first has finished with this call's input.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            var progressed = false
            if firstStatus != .finished {
                // Keep the second stage's unconsumed input together at the front.
                if start > 0 && buffer.count &- end < buffer.count &>> 2 {
                    compact()
                }
                if end < buffer.count {
                    let result = try runFirst(input.extracting(consumed...), flush: flush)
                    consumed &+= result.consumed
                    end &+= result.produced
                    firstStatus = result.status
                    progressed = result.consumed > 0 || result.produced > 0
                }
            }
            let firstDone = firstStatus == .finished || (firstStatus == .needsInput && consumed == input.byteCount)
            let pending = buffer.span.bytes.extracting(start..<end)
            let result = try second.transform(pending, into: &output, flush: firstDone ? flush : .none)
            start &+= result.consumed
            produced &+= result.produced
            if start == end {
                start = 0
                end = 0
            }
            progressed = progressed || result.consumed > 0 || result.produced > 0
            switch result.status {
            case .finished:
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            case .needsOutput:
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            case .needsInput:
                if firstDone && (start == end || !progressed) {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                if !progressed {
                    // The first stage wants room the buffer can't give: the second keeps all of the buffer
                    // (a partial unit, such as a TLS record bigger than the buffer). No call could move.
                    precondition(firstStatus != .needsOutput, "A pipeline's buffer is smaller than its second stage's unit: raise bufferCapacity")
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
            }
        }
    }

    /// Runs the first stage into the buffer's free space.
    @inlinable
    mutating func runFirst(_ input: RawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        let end = end
        var span = buffer.mutableSpan
        // Unsafe: an output span over the buffer's free tail. Safe: it covers exactly `buffer[end...]` and ends
        // with the closure; the produced bytes are counted by the caller from the stage's report.
        return try span.withUnsafeMutableBytes { bytes throws(Failure) -> TransformProgress in
            var output = unsafe OutputRawSpan(buffer: UnsafeMutableRawBufferPointer(rebasing: bytes[end...]), initializedCount: 0)
            let result = try first.transform(input, into: &output, flush: flush)
            _ = unsafe output.finalize(for: UnsafeMutableRawBufferPointer(rebasing: bytes[end...]))
            return result
        }
    }

    /// Moves the buffered bytes to the front.
    @inlinable
    mutating func compact() {
        let count = end &- start
        let from = start
        var span = buffer.mutableSpan
        // Unsafe: a raw copy within the buffer. Safe: both ranges are inside it; `copyMemory` allows overlap.
        span.withUnsafeMutableBytes { bytes in
            unsafe bytes.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: from), byteCount: count)
        }
        start = 0
        end = count
    }
}

extension Pipeline: ResettableByteTransform where First: ResettableByteTransform & ~Copyable, Second: ResettableByteTransform & ~Copyable {
    /// Resets both stages and empties the buffer between them.
    @inlinable
    public mutating func reset() {
        first.reset()
        second.reset()
        start = 0
        end = 0
        firstStatus = .needsInput
    }
}

/// A stage, then an in-place stage working on its output where it was written.
@frozen
public struct FusedPipeline<First: ByteTransform & ~Copyable, Second: InPlaceByteTransform & ~Copyable>: ~Copyable
    where First.Failure == Second.Failure {
    /// The first stage.
    public var first: First
    /// The in-place stage, applied to the first's output.
    public var second: Second

    /// Composes `first` and an in-place `second`.
    @inlinable
    public init(_ first: consuming First, _ second: consuming Second) {
        self.first = first
        self.second = second
    }
}

extension FusedPipeline: ByteTransform where First: ~Copyable, Second: ~Copyable {
    public typealias Failure = First.Failure

    /// Runs `input` through the first stage into `output`, then rewrites what it produced in place; the
    /// second stage sees `flush` only when the first has used all its input.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        let before = output.byteCount
        let result = try first.transform(input, into: &output, flush: flush)
        if result.produced > 0 {
            var all = output.mutableBytes
            var written = all._mutatingExtracting(before..<(before &+ result.produced))
            try second.transform(inPlace: &written, flush: result.status == .needsInput ? flush : .none)
        }
        return result
    }
}

public extension InPlaceByteTransform where Self: ~Copyable {
    /// This non-throwing in-place stage typed as throwing `failure`, to follow stages that throw it.
    @inlinable
    consuming func promoted<E: Error>(to failure: E.Type) -> PromotedInPlaceTransform<Self, E> where Failure == Never {
        PromotedInPlaceTransform(self)
    }
}

/// A non-throwing in-place stage, typed as throwing `Failure`.
@frozen
public struct PromotedInPlaceTransform<Base: InPlaceByteTransform & ~Copyable, Failure: Error>: ~Copyable where Base.Failure == Never {
    /// The stage that can't fail.
    public var base: Base

    /// Wraps `base`.
    @inlinable
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension PromotedInPlaceTransform: InPlaceByteTransform where Base: ~Copyable {
    /// Rewrites `bytes` with the base stage; never throws.
    @inlinable
    public mutating func transform(inPlace bytes: inout MutableRawSpan, flush: TransformFlush) throws(Failure) {
        base.transform(inPlace: &bytes, flush: flush)
    }
}

/// A non-throwing stage, typed as throwing `Failure` to compose with stages that do.
@frozen
public struct PromotedTransform<Base: ByteTransform & ~Copyable, Failure: Error>: ~Copyable where Base.Failure == Never {
    /// The stage that can't fail.
    public var base: Base

    /// Wraps `base`.
    @inlinable
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension PromotedTransform: ByteTransform where Base: ~Copyable {
    /// Transforms with the base stage; never throws.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        base.transform(input, into: &output, flush: flush)
    }
}

extension PromotedTransform: ResettableByteTransform where Base: ResettableByteTransform & ~Copyable {
    @inlinable
    public mutating func reset() {
        base.reset()
    }
}

/// A stage whose errors are converted to another type.
@frozen
public struct MappedErrorTransform<Base: ByteTransform & ~Copyable, Failure: Error>: ~Copyable {
    /// The stage whose errors are converted.
    public var base: Base
    @usableFromInline let map: @Sendable (Base.Failure) -> Failure

    /// Wraps `base`, converting its errors with `map`.
    @inlinable
    public init(_ base: consuming Base, _ map: @escaping @Sendable (Base.Failure) -> Failure) {
        self.base = base
        self.map = map
    }
}

extension MappedErrorTransform: ByteTransform where Base: ~Copyable {
    /// Transforms with the base stage, throwing its errors converted.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        do {
            return try base.transform(input, into: &output, flush: flush)
        } catch {
            throw map(error)
        }
    }
}

extension MappedErrorTransform: ResettableByteTransform where Base: ResettableByteTransform & ~Copyable {
    @inlinable
    public mutating func reset() {
        base.reset()
    }
}
