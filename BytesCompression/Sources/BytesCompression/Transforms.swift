public import Bytes

// The codecs as pipeline stages. Encoders flush as asked; decoders take `.finish` to mean the input has
// ended, and throw `insufficientData` if their stream hasn't. Where another stream may follow one (gzip members,
// Zstandard frames, xz and bzip2 streams), a stream's end reads as `.needsInput` until `.finish`: `.finished`
// always means the whole input decoded.

extension DeflateEncoder: ByteTransform {
    /// What compressing throws: `insufficientCapacity` and nothing else in practice.
    public typealias Failure = BytesError

    /// Compresses as much of `input` as it can into `output`: ``compress(_:into:flush:)`` as a pipeline stage.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the stream.
    ///   - flush: `.flush` ends the output so far on a byte boundary (a sync flush); `.finish` ends the stream.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` as ``compress(_:into:flush:)`` does.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

extension DeflateDecoder: ByteTransform {
    /// What decoding throws: a malformed or cut-short stream.
    public typealias Failure = BytesError

    /// The most unconsumed input ``decompress(_:into:)`` needs before it can make progress: 289 bytes, a dynamic block's
    /// header (read whole) from any bit of its first byte. That's 2,300 bits at most: the block type (3), the code
    /// counts (14), 19 three-bit code-length code lengths, and up to 286 + 32 code lengths of at most 7 bits each (a
    /// repeat code's 9 to 14 bits cover at least 3 lengths). Its other units are smaller: a code with its extra bits,
    /// a stored block's lengths, gzip's 10-byte header and 8-byte trailer (its extra field, name, and comment are taken
    /// as they arrive).
    public static var maximumUnitByteCount: Int { (7 &+ 3 &+ 14 &+ 19 &* 3 &+ (286 &+ 32) &* 7 &+ 7) &>> 3 }

    /// Decodes as much of `input` as it can into `output`: ``decompress(_:into:)`` as a pipeline stage.
    ///
    /// In gzip format another member may follow any member's end, so until `.finish` says the input has ended, the
    /// end of a member reads as ``TransformStatus/needsInput``: ``TransformStatus/finished`` means the whole stream
    /// has ended.
    ///
    /// - Parameters:
    ///   - input: The next bytes of the stream, starting with any not consumed last time.
    ///   - output: Where to append the decoded bytes.
    ///   - flush: `.finish` when the input has ended: a stream that hasn't is then an error.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` for a malformed stream; ``BytesError/insufficientData`` if `flush` is `.finish`
    ///   and the stream (gzip: the last member) doesn't end in `input`.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var progress = try decompress(input, into: &output)
        if flush == .finish {
            // What it kept back (a partial code or header) can't be finished: no more input is coming.
            if progress.status == .needsInput { throw .insufficientData } // The input ended inside the stream.
        } else if progress.status == .finished && format == .gzip {
            progress.status = .needsInput // Another member may follow.
        }
        return progress
    }
}

extension BrotliEncoder: ByteTransform {
    /// What compressing throws: `insufficientCapacity` and nothing else in practice.
    public typealias Failure = BytesError

    /// Compresses as much of `input` as it can into `output`: ``compress(_:into:flush:)`` as a pipeline stage.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the stream.
    ///   - flush: `.flush` ends the output so far on a byte boundary; `.finish` ends the stream.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` as ``compress(_:into:flush:)`` does.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

extension BrotliDecoder: ByteTransform {
    /// What decoding throws: a malformed or cut-short stream.
    public typealias Failure = BytesError

    /// The most unconsumed input ``decompress(_:into:)`` needs before it can make progress: 451 bytes, a command tree's
    /// prefix code (the largest part of a meta-block header read whole: 3,594 bits) from any bit of its first byte.
    public static var maximumUnitByteCount: Int { (7 &+ BrotliStream.maximumPartBits &+ 7) &>> 3 }

    /// Decodes as much of `input` as it can into `output`: ``decompress(_:into:)`` as a pipeline stage.
    ///
    /// - Parameters:
    ///   - input: The next bytes of the stream, starting with any not consumed last time.
    ///   - output: Where to append the decoded bytes.
    ///   - flush: `.finish` when the input has ended: a stream that hasn't is then an error.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` for a malformed stream; ``BytesError/insufficientData`` if `flush` is `.finish`
    ///   and the stream doesn't end in `input`.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        let progress = try decompress(input, into: &output)
        // At `.finish`, what it kept back (a partial unit) can't be finished: no more input is coming.
        if flush == .finish && progress.status == .needsInput {
            throw .insufficientData // The input ended inside the stream.
        }
        return progress
    }
}

extension ZstdEncoder: ByteTransform {
    /// What compressing throws: ``BytesError/mismatch`` for a frame that ends with another size than promised.
    public typealias Failure = BytesError

    /// Compresses as much of `input` as it can into `output`: ``compress(_:into:flush:)`` as a pipeline stage.
    ///
    /// - Parameters:
    ///   - input: The next bytes, starting with any not consumed last time.
    ///   - output: Where to append the frame.
    ///   - flush: `.flush` ends a block, so everything so far decodes; `.finish` ends the frame.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError`` as ``compress(_:into:flush:)`` does.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

extension DeflateEncoder: ResettableByteTransform {}
extension ZstdEncoder: ResettableByteTransform {}
extension DeflateDecoder: ResettableByteTransform {}
extension BrotliEncoder: ResettableByteTransform {}
extension BrotliDecoder: ResettableByteTransform {}
