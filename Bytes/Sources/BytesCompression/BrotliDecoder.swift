public import Bytes

/// A Brotli (RFC 7932) decoder, in one call or as input arrives: HTTP's `Content-Encoding: br`.
///
/// ```swift
/// var decoder = BrotliDecoder()
/// let consumed = try decoder.decompressAll(body, into: &output)   // a whole stream, straight into `output`
///
/// decoder.reset()                                                 // the next stream, in pieces
/// let progress = try decoder.decompress(chunk, into: &output)
/// ```
///
/// After the first streams, decoding allocates nothing: the Huffman tables (one arena, which only grows) and
/// the streaming window (which grows only as far as a stream's window size needs) are kept across
/// ``reset()``. ``decompressAll(_:into:)`` decodes into the caller's buffer, which serves as the history;
/// ``decompress(_:into:)`` decodes into the window and copies out.
///
/// Input can be split anywhere: the decoder works in units (a meta-block header, a block switch, a
/// command's lengths, a literal, a distance, a piece of a copy) and, within 16 bytes of the end of the
/// input, checks after each unit that it didn't run past it, starting the unit again on the next call if
/// it did. A whole compressed meta-block header (its prefix codes and context maps, usually well under
/// 1 KB) is one unit.
@safe
public struct BrotliDecoder: ~Copyable {
    private var stream: BrotliStream
    private var window: UniqueArray<UInt8>
    private var windowEnd = 0
    private var windowDelivered = 0

    /// The window's room for new output beyond the history: when it fills, the window slides (or grows, until
    /// it holds the stream's whole window size).
    static var area: Int { 256 << 10 }
    /// Room kept free so a unit always fits: the longest transformed dictionary word.
    static var unitRoom: Int { 64 }

    /// Creates a decoder, allocating its tables and a first window.
    public init() {
        stream = BrotliStream()
        window = UniqueArray(repeating: 0, count: 2 &* Self.area)
    }

    /// Prepares to decode a new stream, discarding output not yet delivered. Keeps the allocations.
    public mutating func reset() {
        stream.reset()
        windowEnd = 0
        windowDelivered = 0
    }

    /// Whether the stream has ended and all its output has been delivered.
    public var isFinished: Bool { stream.isDone && windowDelivered == windowEnd }

    /// Decodes a whole stream, from the start, straight into `output`'s free capacity.
    ///
    /// - Parameters:
    ///   - input: The whole compressed stream. Bytes after its end are ignored.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes the stream took.
    /// - Throws: ``BytesError/insufficientData`` for a truncated stream; ``BytesError/insufficientCapacity``
    ///   if the output doesn't fit; ``BytesError/invalidValue`` for corrupt data.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            let result = try stream.run(input, from: 0, into: &span, at: 0)
            switch result.stop {
            case .finished: break
            case .needsInput, .fastAgain: throw .insufficientData // `run` never returns `fastAgain`.
            case .outputFull: throw .insufficientCapacity
            }
            written = result.end
            return result.position &>> 3
        }
    }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream.
    ///
    /// ``TransformProgress/consumed`` says how much of `input` was used; pass the rest again, followed by more,
    /// on the next call.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError/invalidValue`` for corrupt data.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        var position = stream.bitOffset
        var produced = 0
        let status: TransformStatus
        while true {
            produced &+= deliver(into: &output)
            guard windowDelivered == windowEnd else {
                status = .needsOutput
                break
            }
            if stream.isDone {
                status = .finished
                break
            }
            if window.count &- windowEnd < Self.unitRoom {
                makeRoom()
            }
            var span = window.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            let result = try stream.run(input, from: position, into: &raw, at: windowEnd)
            position = result.position
            windowEnd = result.end
            if result.stop == .needsInput {
                produced &+= deliver(into: &output)
                status = windowDelivered == windowEnd ? .needsInput : .needsOutput
                break
            }
        }
        stream.bitOffset = position & 7
        return TransformProgress(consumed: position &>> 3, produced: produced, status: status)
    }

    /// Copies undelivered output into `output`, as much as fits.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(windowEnd &- windowDelivered, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: window.span.bytes.extracting(windowDelivered..<(windowDelivered &+ count)))
        windowDelivered &+= count
        return count
    }

    /// Frees room after everything has been delivered: slides the last window's worth of history to the
    /// front, or, while the history the stream may reach doesn't fit, grows the window.
    private mutating func makeRoom() {
        let history = min(windowEnd, stream.windowSize)
        if history &+ Self.area > window.count {
            // Grow, keeping everything (the stream's window doesn't fit yet).
            var bigger = UniqueArray<UInt8>(repeating: 0, count: history &+ Self.area)
            var target = bigger.mutableSpan
            target.copyBytes(from: window.span.bytes.extracting((windowEnd &- history)..<windowEnd), toByteOffset: 0)
            window = bigger
        } else {
            var span = window.mutableSpan
            span.copyBytes(within: (windowEnd &- history)..<windowEnd, toByteOffset: 0)
        }
        windowEnd = history
        windowDelivered = history
    }
}
