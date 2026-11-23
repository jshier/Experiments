public import Bytes

// Content codings as pipeline stages (Bytes' `ByteTransform`), to compose with the chunked stages:
// `HTTP1Dechunker().mapError(…).then(contentDecoder)`.

extension HTTPContentDecoder: ByteTransform {
    /// What decoding throws.
    public typealias Failure = HTTPPayloadError

    /// Decodes as much of `input` as fits into `output`: ``decode(_:into:)`` as a stage. Partial units at the end of
    /// `input` are kept in the decoder's carry buffer (and reported consumed), so the stage keeps nothing back.
    ///
    /// - Parameters:
    ///   - input: The body's next coded bytes.
    ///   - output: Where the decoded bytes go.
    ///   - flush: `.finish` when the body has ended: a coded stream cut short then throws
    ///     ``HTTPPayloadError/malformed`` (as ``finish()``); an identity body finishes there.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(HTTPPayloadError) -> TransformProgress {
        var progress = try decode(input, into: &output)
        // At the end, every coding's stream must have ended: the outer one too when the inner one reports `.finished`
        // (a stacked body's outer stream can be cut short after the inner one happened to end).
        if flush == .finish,
           progress.status == .finished || progress.status == .needsInput && progress.consumed == input.byteCount {
            try finish()
            progress.status = .finished
        }
        return progress
    }
}

extension HTTPContentDecoder: ResettableByteTransform {
    /// Prepares to decode another body with the same codings, keeping the codecs and buffers (a pipeline reused per
    /// message); ``reset(applied:then:)`` changes the codings.
    public mutating func reset() {
        let then: HTTPContentCoding? = switch first {
        case .some(let stage): stage.coding
        case .none: nil
        }
        do throws(HTTPPayloadError) {
            try reset(applied: last.coding, then: then)
        } catch {
            preconditionFailure("the decoder's own codings, decoded before: \(error)")
        }
    }
}

extension HTTPContentEncoder: ByteTransform {
    /// What encoding throws: ``HTTPPayloadError/outOfRoom`` only.
    public typealias Failure = HTTPPayloadError

    /// Encodes as much of `input` as fits into `output`: ``encode(_:into:flush:)`` as a stage.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(HTTPPayloadError) -> TransformProgress {
        try encode(input, into: &output, flush: flush)
    }
}
