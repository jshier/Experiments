public import Bytes
public import HTTP1

/// An HTTP/1 message body as it arrives: its framing (`Content-Length`, chunked, or until the connection closes) and its
/// content codings, decoded in one stage that ends where the framing does.
///
/// The framing decides where the body ends, never the content coding: the stage finishes only at the framing's end,
/// and the coded stream must end exactly there (``HTTPPayloadError/malformed`` if it ends early, with bytes after it, or
/// not at all). A body's chunk data goes from the chunked decoder's slices straight into the content decoder, with no
/// copy and no buffer between them. Composing `HTTP1Dechunker` and `HTTPContentDecoder` with Bytes' `then(_:)` instead
/// would end the body when the coded stream ends, leaving the framing's last bytes (or an attacker's chunk data after
/// the stream) to be read as the next message: use this type for bodies.
///
/// ```swift
/// var body = try HTTPBodyDecoder(framing: try framing.requestBody(version: line.version), contentEncoding: encoding)
/// let progress = try body.transform(unread, into: &output, flush: .none)
/// ```
///
/// Trailer fields of a chunked body are checked against the chunked decoder's limits and dropped. Once a decoder has
/// seen a coding, ``reset(framing:)`` and ``reset(framing:contentEncoding:)`` start the next body without allocating.
public struct HTTPBodyDecoder: ~Copyable, ByteTransform, ResettableByteTransform {
    /// What decoding throws: ``HTTPPayloadError``, with the chunked coding's errors as ``HTTPPayloadError/chunked(_:)``.
    public typealias Failure = HTTPPayloadError

    @usableFromInline var framing: HTTP1BodyLength
    @usableFromInline var chunks: HTTP1ChunkedDecoder
    @usableFromInline let initialChunks: HTTP1ChunkedDecoder
    @usableFromInline var remaining = 0
    @usableFromInline var framingEnded = false
    /// Whether any body bytes arrived: an empty body ends without a coded stream (`Content-Length: 0` with a coding).
    @usableFromInline var sawData = false
    /// The content decoder.
    public private(set) var content: HTTPContentDecoder

    /// A body framed as `framing` says, coded with `content`'s codings; chunked coding read with `chunked`'s limits.
    public init(framing: HTTP1BodyLength, content: consuming HTTPContentDecoder, chunked: HTTP1ChunkedDecoder = HTTP1ChunkedDecoder()) {
        self.framing = framing
        self.content = content
        chunks = chunked
        initialChunks = chunked
        start(framing)
    }

    /// A body framed as `framing` says, coded as `contentEncoding` (a `Content-Encoding` value) says.
    ///
    /// - Throws: As ``HTTPContentDecoder/init(contentEncoding:maximumDecodedByteCount:)``.
    public init(framing: HTTP1BodyLength, contentEncoding: RawSpan, maximumDecodedByteCount: Int = 1 << 30,
                chunked: HTTP1ChunkedDecoder = HTTP1ChunkedDecoder()) throws(HTTPPayloadError) {
        try self.init(framing: framing,
                      content: HTTPContentDecoder(contentEncoding: contentEncoding, maximumDecodedByteCount: maximumDecodedByteCount),
                      chunked: chunked)
    }

    @usableFromInline
    mutating func start(_ framing: HTTP1BodyLength) {
        self.framing = framing
        chunks = initialChunks
        framingEnded = false
        sawData = false
        if case let .length(count) = framing { remaining = count } else { remaining = 0 }
    }

    /// Starts the next body with the same framing and codings.
    public mutating func reset() {
        start(framing)
        content.reset()
    }

    /// Starts the next body, framed as `framing` says, with the same codings.
    public mutating func reset(framing: HTTP1BodyLength) {
        start(framing)
        content.reset()
    }

    /// Starts the next body, framed as `framing` says and coded as `contentEncoding` says.
    ///
    /// - Throws: As ``HTTPContentDecoder/reset(contentEncoding:)``.
    public mutating func reset(framing: HTTP1BodyLength, contentEncoding: RawSpan) throws(HTTPPayloadError) {
        start(framing)
        try content.reset(contentEncoding: contentEncoding)
    }

    /// Decodes as much of `input`, the body's next bytes, as fits into `output`.
    ///
    /// - Parameters:
    ///   - input: The connection's next bytes: this body's, then perhaps the next message's (left unconsumed).
    ///   - output: Where the decoded body goes.
    ///   - flush: `.finish` when the connection has closed: what's missing is then
    ///     ``HTTPPayloadError/incompleteBody`` (or, for a body read until the close, the body's end).
    /// - Returns: What was consumed and produced; `.finished` at the framing's end, with bytes after it (the next
    ///   message) not consumed.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(HTTPPayloadError) -> TransformProgress {
        let produced0 = output.byteCount
        var position = 0
        func progress(_ status: TransformStatus) -> TransformProgress {
            TransformProgress(consumed: position, produced: output.byteCount &- produced0, status: status)
        }
        while true {
            if framingEnded {
                // The coded stream must have ended with the framing (an empty body needn't have one), after the output it
                // still holds (all its input taken, its output full last time) is delivered.
                if sawData, !content.isFinished {
                    let drained = try content.decode(RawSpan(), into: &output)
                    if drained.status == .needsOutput { return progress(.needsOutput) }
                }
                if sawData { try content.finish() }
                return progress(.finished)
            }
            // The next piece of body data, and where it starts in `input`.
            let piece: RawSpan
            switch framing {
            case .none:
                framingEnded = true
                continue
            case .length:
                guard remaining > 0 else { framingEnded = true; continue }
                let take = Swift.min(remaining, input.byteCount &- position)
                guard take > 0 else {
                    if flush == .finish { throw .incompleteBody }
                    return progress(.needsInput)
                }
                remaining &-= take
                piece = input.extracting(position..<position &+ take)
            case .untilClose:
                guard position < input.byteCount else {
                    if flush == .finish { framingEnded = true; continue }
                    return progress(.needsInput)
                }
                piece = input.extracting(droppingFirst: position)
            case .chunked:
                var used = 0
                let event: HTTP1ChunkEvent
                do throws(HTTP1Error) {
                    event = try chunks.next(in: input.extracting(droppingFirst: position), consumed: &used)
                } catch {
                    throw .chunked(error)
                }
                switch event {
                case let .data(data):
                    // The size line before the data is consumed with it.
                    position &+= used &- data.byteCount
                    piece = data
                case .trailer:
                    position &+= used
                    continue
                case .end:
                    position &+= used
                    framingEnded = true
                    continue
                case .needsMore:
                    position &+= used
                    if flush == .finish { throw .incompleteBody }
                    return progress(.needsInput)
                }
            }
            // Body data after the coded stream ended: not this coding's stream.
            // (After a gzip member or a zstd frame, it's the next one's.)
            if content.isClosed { throw .malformed }
            sawData = true
            let decoded = try content.decode(piece, into: &output)
            position &+= decoded.consumed
            let unused = piece.byteCount &- decoded.consumed
            if unused > 0 {
                // What the content decoder didn't take comes again on the next pass (or call).
                if decoded.status == .finished { throw .malformed }
                switch framing {
                case .length: remaining &+= unused
                case .chunked: chunks.giveBack(unused)
                default: break
                }
            }
            if decoded.status == .needsOutput || (unused > 0 && output.freeCapacity == 0) { return progress(.needsOutput) }
        }
    }
}
