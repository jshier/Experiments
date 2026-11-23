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
///
/// ## The end of a stream
///
/// Every stage follows one rule at `.finish`: it returns ``TransformStatus/finished`` once all its output is
/// delivered (``TransformStatus/needsOutput`` until then), or throws if its input ended early (a decoder's
/// truncated stream, a partial record). So a drive loop stops at `.finished`, and `.needsInput` only ever
/// means "more input, please". ``transform(_:appending:flush:growth:)`` is that loop.
///
/// Some formats are a series of streams: gzip's members, Zstandard's frames, xz's and bzip2's streams. A stage
/// decoding one can't tell the input's end from a pause at a stream's end, so before `.finish` it reports that end
/// as ``TransformStatus/needsInput``, and ``TransformStatus/finished`` keeps meaning the whole input has ended.
public protocol ByteTransform: ~Copyable {
    /// What the stage throws: `Never` if it can't fail.
    associatedtype Failure: Error

    /// The most input a call may need at once before it can consume any: a whole unit, such as a TLS record
    /// (16,645 bytes). A stage that keeps back a partial unit needs its buffer to hold this much. 1 (the
    /// default) for stages that consume byte by byte.
    static var maximumUnitByteCount: Int { get }

    /// The least free output a call needs to make progress: a whole unit of output, such as a TLS record
    /// sealed at once. 1 (the default) for stages that can write any amount.
    static var minimumOutputCapacity: Int { get }

    /// Transforms as much of `input` as it can, appending to `output`.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: The stage's `Failure`.
    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress
}

public extension ByteTransform where Self: ~Copyable {
    /// 1: by default a stage consumes byte by byte, keeping no partial unit back.
    @inlinable
    static var maximumUnitByteCount: Int { 1 }

    /// 1: by default a stage can write any amount.
    @inlinable
    static var minimumOutputCapacity: Int { 1 }

    /// Transforms all of `input`, appending the output to `output`, which grows as needed: the drive loop
    /// for a whole message or stream in memory.
    ///
    /// ```swift
    /// var compressed: [UInt8] = []
    /// let progress = try encoder.transform(message, appending: &compressed, flush: .finish)
    /// precondition(progress.status == .finished)
    /// ```
    ///
    /// Calls the stage until it has taken all the input it can (``TransformStatus/needsInput``) or finished,
    /// adding room whenever it needs more: at least ``minimumOutputCapacity``, and `growth` or the input's size
    /// beyond that.
    ///
    /// - Parameters:
    ///   - input: The bytes to transform.
    ///   - output: The array to append to.
    ///   - flush: As for ``transform(_:into:flush:)``; with `.finish`, this returns ``TransformStatus/finished``.
    ///   - growth: The least room to add at a time.
    /// - Returns: What was consumed and produced: input a stage keeps back (a partial unit) isn't consumed.
    /// - Throws: The stage's `Failure`. The output appended before it stays.
    @inlinable
    mutating func transform(
        _ input: RawSpan, appending output: inout [UInt8], flush: TransformFlush, growth: Int = 16 << 10
    ) throws(Failure) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            let room = max(Self.minimumOutputCapacity, growth, input.byteCount &- consumed)
            output.reserveCapacity(output.count &+ room)
            let rest = input.extracting(consumed...)
            var progress = TransformProgress(consumed: 0, produced: 0, status: .needsInput)
            try output.append(addingCapacity: room) { (span: inout OutputSpan<UInt8>) throws(Failure) in
                // Unsafe: an output span over the array's new capacity. Safe: it covers only the uninitialized
                // part and ends with the closure; what the stage wrote is added to the initialized count.
                try unsafe span.withUnsafeMutableBufferPointer { buffer, initializedCount throws(Failure) in
                    let free = unsafe UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[initializedCount...])
                    var raw = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
                    progress = try transform(rest, into: &raw, flush: flush)
                    initializedCount &+= unsafe raw.finalize(for: free)
                }
            }
            consumed &+= progress.consumed
            produced &+= progress.produced
            if progress.status != .needsOutput {
                return TransformProgress(consumed: consumed, produced: produced, status: progress.status)
            }
        }
    }
}

/// A stage that can start over on a new stream, keeping its allocations: a pipeline built once serves stream
/// after stream (an HTTP connection's responses, a benchmark's iterations) with no allocation per stream.
public protocol ResettableByteTransform: ByteTransform, ~Copyable {
    /// Prepares for a new stream, discarding input kept and output not yet delivered. Allocates nothing.
    mutating func reset()
}

/// A stage that rewrites bytes in place, one for one: a stream cipher, a checksum that passes bytes
/// through. After another stage (`then(_:)` with an in-place stage) it works on that stage's
/// output where it was written, with no buffer between them.
public protocol InPlaceByteTransform: ~Copyable {
    /// What the stage throws: `Never` if it can't fail.
    associatedtype Failure: Error

    /// Rewrites `bytes`, the next bytes of the stream.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to rewrite.
    ///   - flush: The flush the bytes came with.
    /// - Throws: The stage's `Failure`.
    mutating func transform(inPlace bytes: inout MutableRawSpan, flush: TransformFlush) throws(Failure)
}

// MARK: - Composition

public extension ByteTransform where Self: ~Copyable {
    /// A pipeline of this stage, then `next`, with a buffer between them.
    ///
    /// ```swift
    /// var pipeline = DeflateEncoder(format: .raw).then(TLSRecordSealer(keys: keys))   // from BytesCompression and BytesCrypto
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
    ///
    /// - Parameter failure: The error type to declare, such as `BytesError.self`.
    /// - Returns: The stage, wrapped: it still never throws.
    @inlinable
    consuming func promoted<E: Error>(to failure: E.Type) -> PromotedTransform<Self, E> where Failure == Never {
        PromotedTransform(self)
    }

    /// This stage, with its errors converted by `transform`.
    ///
    /// - Parameter transform: Converts an error; a closure that captures nothing, so storing it allocates
    ///   nothing.
    /// - Returns: The stage, wrapped.
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
    /// The first stage's output not yet taken by the second, as its unread bytes. Compacted when less than a
    /// quarter is free at the end.
    @usableFromInline var buffer: ByteBuffer
    /// The first stage's status from its last call.
    @usableFromInline var firstStatus = TransformStatus.needsInput

    /// Composes `first` and `second` with a buffer of at least `bufferCapacity` bytes between them: more if the
    /// stages need it, room for the first's output unit beside a partial input unit the second keeps
    /// (`First.minimumOutputCapacity + Second.maximumUnitByteCount`).
    ///
    /// - Parameters:
    ///   - first: The first stage.
    ///   - second: The stage that receives the first's output.
    ///   - bufferCapacity: The buffer between the stages, allocated once, now.
    @inlinable
    public init(_ first: consuming First, _ second: consuming Second, bufferCapacity: Int = 64 << 10) {
        self.first = first
        self.second = second
        let capacity = max(bufferCapacity, First.minimumOutputCapacity &+ Second.maximumUnitByteCount)
        buffer = ByteBuffer(capacity: capacity, compactingBelow: capacity &>> 2)
    }
}

extension Pipeline: ByteTransform where First: ~Copyable, Second: ~Copyable {
    /// What both stages throw.
    public typealias Failure = First.Failure

    /// The first stage's: the pipeline's input goes to it.
    @inlinable
    public static var maximumUnitByteCount: Int { First.maximumUnitByteCount }

    /// The second stage's: the pipeline's output comes from it.
    @inlinable
    public static var minimumOutputCapacity: Int { Second.minimumOutputCapacity }

    /// Runs `input` through both stages into `output`.
    ///
    /// The first stage fills the buffer and the second empties it, alternately, until the input is used and
    /// the buffer drained (`needsInput`), the output is full (`needsOutput`), or the second stage finishes.
    /// The second stage sees `flush` once the first has finished with this call's input.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the second stage's output.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: What the pipeline consumed and produced, and why it returned.
    /// - Throws: Either stage's `Failure`.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            var progressed = false
            if firstStatus != .finished {
                // The fill compacts first when less than a quarter is free at the end, keeping the second
                // stage's unconsumed input together at the front.
                if !buffer.isFull {
                    let result = try runFirst(input.extracting(consumed...), flush: flush)
                    consumed &+= result.consumed
                    firstStatus = result.status
                    progressed = result.consumed > 0 || result.produced > 0
                }
            }
            let firstDone = firstStatus == .finished || (firstStatus == .needsInput && consumed == input.byteCount)
            let result: TransformProgress
            do {
                let pending = buffer.unread
                result = try second.transform(pending, into: &output, flush: firstDone ? flush : .none)
            }
            buffer.consume(result.consumed)
            produced &+= result.produced
            progressed = progressed || result.consumed > 0 || result.produced > 0
            switch result.status {
            case .finished:
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            case .needsOutput:
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            case .needsInput:
                if firstDone && (buffer.isEmpty || !progressed) {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                if !progressed {
                    // The first stage wants more room than is free at the end (a TLS record's body, up to
                    // 16,624 bytes, with 16,384 free: too much free to compact in the fill), and the second keeps
                    // a few bytes it can't use yet (a decoder's partial byte). Move them to the front.
                    if firstStatus == .needsOutput && buffer.compact() {
                        continue
                    }
                    // The first stage wants room the buffer can't give while the second keeps the rest: the buffer
                    // is sized for the units the stages declare, so one of them keeps or needs more than it says.
                    precondition(firstStatus != .needsOutput, "A stage keeps more input than its maximumUnitByteCount, or needs more output than its minimumOutputCapacity")
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
            }
        }
    }

    /// Runs the first stage into the buffer's free space.
    @inlinable
    mutating func runFirst(_ input: RawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        try buffer.fill { (output: inout OutputRawSpan) throws(Failure) -> TransformProgress in
            try first.transform(input, into: &output, flush: flush)
        }
    }
}

extension Pipeline: ResettableByteTransform where First: ResettableByteTransform & ~Copyable, Second: ResettableByteTransform & ~Copyable {
    /// Resets both stages and empties the buffer between them.
    @inlinable
    public mutating func reset() {
        first.reset()
        second.reset()
        buffer.removeAll()
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
    ///
    /// - Parameters:
    ///   - first: The first stage.
    ///   - second: The in-place stage, applied to the first's output where it's written.
    @inlinable
    public init(_ first: consuming First, _ second: consuming Second) {
        self.first = first
        self.second = second
    }
}

extension FusedPipeline: ByteTransform where First: ~Copyable, Second: ~Copyable {
    /// What both stages throw.
    public typealias Failure = First.Failure

    /// The first stage's.
    @inlinable
    public static var maximumUnitByteCount: Int { First.maximumUnitByteCount }

    /// The first stage's: the in-place stage writes nothing of its own.
    @inlinable
    public static var minimumOutputCapacity: Int { First.minimumOutputCapacity }

    /// Runs `input` through the first stage into `output`, then rewrites what it produced in place; the
    /// second stage sees `flush` only when the first has used all its input.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the output.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The first stage's progress.
    /// - Throws: Either stage's `Failure`.
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
    ///
    /// - Parameter failure: The error type to declare, such as `BytesError.self`.
    /// - Returns: The stage, wrapped: it still never throws.
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
    ///
    /// - Parameter base: The stage that can't fail.
    @inlinable
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension PromotedInPlaceTransform: InPlaceByteTransform where Base: ~Copyable {
    /// Rewrites `bytes` with the base stage; never throws.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to rewrite.
    ///   - flush: The flush the bytes came with.
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
    ///
    /// - Parameter base: The stage that can't fail.
    @inlinable
    public init(_ base: consuming Base) {
        self.base = base
    }
}

extension PromotedTransform: ByteTransform where Base: ~Copyable {
    /// The base stage's.
    @inlinable
    public static var maximumUnitByteCount: Int { Base.maximumUnitByteCount }

    /// The base stage's.
    @inlinable
    public static var minimumOutputCapacity: Int { Base.minimumOutputCapacity }

    /// Transforms with the base stage; never throws.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The base stage's progress.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        base.transform(input, into: &output, flush: flush)
    }
}

extension PromotedTransform: ResettableByteTransform where Base: ResettableByteTransform & ~Copyable {
    /// Resets the base stage.
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
    ///
    /// - Parameters:
    ///   - base: The stage whose errors are converted.
    ///   - map: Converts an error.
    @inlinable
    public init(_ base: consuming Base, _ map: @escaping @Sendable (Base.Failure) -> Failure) {
        self.base = base
        self.map = map
    }
}

extension MappedErrorTransform: ByteTransform where Base: ~Copyable {
    /// The base stage's.
    @inlinable
    public static var maximumUnitByteCount: Int { Base.maximumUnitByteCount }

    /// The base stage's.
    @inlinable
    public static var minimumOutputCapacity: Int { Base.minimumOutputCapacity }

    /// Transforms with the base stage, throwing its errors converted.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append transformed bytes.
    ///   - flush: Whether to finish the output so far (or the whole stream) once `input` is used.
    /// - Returns: The base stage's progress.
    /// - Throws: The base stage's error, converted.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress {
        do throws(Base.Failure) {
            return try base.transform(input, into: &output, flush: flush)
        } catch {
            throw map(error)
        }
    }
}

extension MappedErrorTransform: ResettableByteTransform where Base: ResettableByteTransform & ~Copyable {
    /// Resets the base stage.
    @inlinable
    public mutating func reset() {
        base.reset()
    }
}
