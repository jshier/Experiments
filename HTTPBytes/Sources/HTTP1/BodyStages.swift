public import Bytes

// Chunked transfer coding as pipeline stages (Bytes' `ByteTransform`): a body's bytes in, its data out, or the reverse.
// The decoder itself (`HTTP1ChunkedDecoder`) hands out slices of its input without copying; these stages copy the data
// out, for transfer-coding work on its own (a proxy re-framing a body). A coded body is HTTPPayload's
// `HTTPBodyDecoder`'s: a pipeline ends when its last stage does, and a content decoder after this stage would end the
// body where its coded stream ends, not where the chunked framing does.

/// Chunked transfer coding decoded as a pipeline stage: the body's bytes in, its data out.
///
/// By default (``Trailers/skip``) the stage checks the trailer fields, drops them, and finishes after the trailer
/// section. With ``Trailers/leave`` it finishes after the last chunk's line, with the trailer section left unconsumed:
/// read it with ``nextTrailer(in:consumed:)`` before anything else reads those bytes (until then they're this body's,
/// not the next message's).
///
/// Data that doesn't fit the output is handed back to the decoder and reported unconsumed, so a full output costs
/// nothing but a call. Given `.finish` before the coding's end, the stage throws ``HTTP1Error/incompleteBody``.
@frozen
public struct HTTP1Dechunker: Sendable, ByteTransform, ResettableByteTransform {
    /// What decoding throws: the chunked coding's errors, and ``HTTP1Error/incompleteBody``.
    public typealias Failure = HTTP1Error

    /// What the stage does with the trailer section after the last chunk.
    @frozen
    public enum Trailers: Sendable, Hashable {
        /// Check the trailer fields, drop them, and finish after the section.
        case skip
        /// Finish after the last chunk's line, the trailer section left for ``HTTP1Dechunker/nextTrailer(in:consumed:)``.
        case leave
    }

    /// The chunked decoder's state and limits (set at `init`).
    @usableFromInline var decoder: HTTP1ChunkedDecoder
    /// What happens to the trailer section.
    public let trailers: Trailers
    @usableFromInline let initialDecoder: HTTP1ChunkedDecoder

    /// The most input a call keeps back: a chunk-size line (extensions at most 4,096 bytes) or a trailer line (the trailer
    /// section at most 16 KiB); `init` lowers a decoder's larger limits to these.
    @inlinable
    public static var maximumUnitByteCount: Int { 16_384 &+ 64 }

    /// A stage decoding with `decoder`'s limits and options, its extension and trailer limits lowered to what
    /// ``maximumUnitByteCount`` allows (a pipeline's buffer holds a unit; a peer's longer line must be an error, not a
    /// stage keeping more than its unit).
    @inlinable
    public init(_ decoder: HTTP1ChunkedDecoder = HTTP1ChunkedDecoder(), trailers: Trailers = .skip) {
        var decoder = decoder
        decoder.maximumExtensionByteCount = Swift.min(decoder.maximumExtensionByteCount, 4_096)
        decoder.maximumTrailerSectionByteCount = Swift.min(decoder.maximumTrailerSectionByteCount, 16_384)
        decoder.pausesAtTrailers = trailers == .leave
        self.decoder = decoder
        self.trailers = trailers
        initialDecoder = decoder
    }

    /// With ``Trailers/leave``, after the stage finished: the next trailer field in `bytes` (the input from where the
    /// stage stopped, less what earlier calls consumed), then ``HTTP1ChunkEvent/end`` after the section's empty line.
    ///
    /// - Parameter consumed: Set to how many of `bytes` the event used.
    @inlinable
    @_lifetime(copy bytes)
    public mutating func nextTrailer(in bytes: RawSpan, consumed: inout Int) throws(HTTP1Error) -> HTTP1ChunkEvent {
        precondition(trailers == .leave && decoder.phase != .size && decoder.phase != .data && decoder.phase != .dataEnd,
                     "trailers are read after the stage finished, with `.leave`")
        return try decoder.next(in: bytes, consumed: &consumed)
    }

    /// Starts a new body with the same options.
    @inlinable
    public mutating func reset() { decoder = initialDecoder }

    /// Decodes as much of `input` as fits into `output`.
    ///
    /// - Parameters:
    ///   - input: The body's next bytes, starting with any not consumed last time.
    ///   - output: Where the body's data goes.
    ///   - flush: `.finish` when the body's bytes have ended (the connection closed): a coding that hasn't ended is
    ///     then ``HTTP1Error/incompleteBody``.
    /// - Returns: What was consumed and produced; `.finished` at the coding's end (see ``Trailers``).
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(HTTP1Error) -> TransformProgress {
        var position = 0
        let start = output.byteCount
        while true {
            if decoder.phase == .done || decoder.phase == .trailers && trailers == .leave {
                return TransformProgress(consumed: position, produced: output.byteCount &- start, status: .finished)
            }
            var used = 0
            switch try decoder.next(in: input.extracting(droppingFirst: position), consumed: &used) {
            case let .data(data):
                let room = output.freeCapacity
                guard data.byteCount > room else {
                    output.append(copying: data)
                    position &+= used
                    continue
                }
                // What doesn't fit goes back to the decoder, unconsumed.
                output.append(copying: data.extracting(0..<room))
                let back = data.byteCount &- room
                decoder.giveBack(back)
                position &+= used &- back
                return TransformProgress(consumed: position, produced: output.byteCount &- start, status: .needsOutput)
            case .trailer:
                position &+= used
            case .end:
                position &+= used
                return TransformProgress(consumed: position, produced: output.byteCount &- start, status: .finished)
            case .needsMore:
                position &+= used
                // Paused after the last chunk's line: the loop's first test finishes.
                if trailers == .leave, decoder.phase == .trailers { continue }
                if flush == .finish { throw .incompleteBody }
                return TransformProgress(consumed: position, produced: output.byteCount &- start, status: .needsInput)
            }
        }
    }
}

/// Chunked transfer coding as a pipeline stage: data in, a chunked body out. Each call's input becomes one chunk (as
/// much as fits the output), so chunks follow the producer's writes; `.finish` writes the last chunk and an empty
/// trailer section. A call with no input writes nothing, `.flush` included (a chunk of size 0 would end the body).
@frozen
public struct HTTP1Chunker: Sendable, ByteTransform, ResettableByteTransform {
    /// Chunking can't fail.
    public typealias Failure = Never

    /// Room for the smallest chunk (`1` CR LF, a byte, CR LF): any call can then make progress (the last chunk is 5).
    @inlinable
    public static var minimumOutputCapacity: Int { 6 }

    @usableFromInline var ended = false

    /// A chunker for one body.
    @inlinable
    public init() {}

    /// Starts a new body.
    @inlinable
    public mutating func reset() { ended = false }

    /// Writes `input` as a chunk (as much of it as fits `output`), then, at `.finish`, the last chunk.
    @inlinable
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        if ended { return TransformProgress(consumed: 0, produced: 0, status: .finished) }
        let start = output.byteCount
        var consumed = 0
        if input.byteCount > 0 {
            // The most data that fits with its size line and two CR LFs: with d the digits of the room less 5, the room
            // less 4 and d always fits; one byte more fits when that size has fewer digits (261 bytes of room: d = 3
            // for 256, so 254; but 255 has 2 digits and fits; 21 bytes: 15, as 16 needs 2).
            @inline(__always) func digits(_ count: Int) -> Int { (Int.bitWidth &- count.leadingZeroBitCount &+ 3) &>> 2 }
            let free = output.freeCapacity
            let d = digits(Swift.max(free &- 5, 1))
            var fits = free &- 4 &- d
            if digits(fits &+ 1) < d { fits &+= 1 }
            let take = Swift.min(input.byteCount, fits)
            guard take > 0 else { return TransformProgress(consumed: 0, produced: 0, status: .needsOutput) }
            Self.appendSizeLine(take, to: &output)
            output.append(copying: input.extracting(0..<take))
            output.append((0x0A0D as UInt16).littleEndian, as: UInt16.self)
            consumed = take
            if take < input.byteCount {
                return TransformProgress(consumed: consumed, produced: output.byteCount &- start, status: .needsOutput)
            }
        }
        if flush == .finish {
            guard output.freeCapacity >= 5 else {
                return TransformProgress(consumed: consumed, produced: output.byteCount &- start, status: .needsOutput)
            }
            // "0" CR LF CR LF: the last chunk and an empty trailer section.
            output.append(0x30 as UInt8, as: UInt8.self)
            output.append((0x0A0D_0A0D as UInt32).littleEndian, as: UInt32.self)
            ended = true
            return TransformProgress(consumed: consumed, produced: output.byteCount &- start, status: .finished)
        }
        return TransformProgress(consumed: consumed, produced: output.byteCount &- start, status: .needsInput)
    }

    /// Appends `byteCount` (more than 0) in lowercase hexadecimal, then CR LF.
    @inlinable
    static func appendSizeLine(_ byteCount: Int, to output: inout OutputRawSpan) {
        var shift = (Int.bitWidth &- byteCount.leadingZeroBitCount &- 1) & ~3
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: byteCount &>> shift) & 0xF
            output.append(nibble < 10 ? 0x30 &+ nibble : 0x57 &+ nibble, as: UInt8.self)
            shift &-= 4
        }
        output.append((0x0A0D as UInt16).littleEndian, as: UInt16.self)
    }
}
