public import Bytes

// The codecs as pipeline stages. Encoders flush as asked; decoders take `.finish` to mean the input has
// ended, and throw `insufficientData` if their stream hasn't.

extension DeflateEncoder: ByteTransform {
    public typealias Failure = BytesError

    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

extension DeflateDecoder: ByteTransform {
    public typealias Failure = BytesError

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
    public typealias Failure = BytesError

    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}

extension BrotliDecoder: ByteTransform {
    public typealias Failure = BytesError

    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        let progress = try decompress(input, into: &output)
        if flush == .finish && progress.status == .needsInput && progress.consumed == input.byteCount {
            throw .insufficientData // The input ended inside the stream.
        }
        return progress
    }
}

extension DeflateEncoder: ResettableByteTransform {}
extension DeflateDecoder: ResettableByteTransform {}
extension BrotliEncoder: ResettableByteTransform {}
extension BrotliDecoder: ResettableByteTransform {}
