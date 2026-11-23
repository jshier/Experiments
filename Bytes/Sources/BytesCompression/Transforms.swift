public import Bytes

// The codecs as pipeline stages. Encoders flush as asked; decoders take `.finish` to mean the input has
// ended, and throw `insufficientData` if their stream hasn't.

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
        if flush == .finish && progress.status == .needsInput && progress.consumed == input.byteCount {
            throw .insufficientData // The input ended inside the stream.
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
        if flush == .finish && progress.status == .needsInput && progress.consumed == input.byteCount {
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
