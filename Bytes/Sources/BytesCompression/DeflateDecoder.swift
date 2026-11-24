public import Bytes

/// A DEFLATE (RFC 1951) decoder for raw, zlib (RFC 1950), and gzip (RFC 1952) streams, in one call or as
/// input arrives.
///
/// ```swift
/// var decoder = DeflateDecoder(format: .gzip)          // allocates its tables and window once
/// let size = try decoder.decompressAll(body, into: &output)   // a whole stream, straight into `output`
///
/// decoder.reset()                                     // the next stream, in pieces
/// let progress = try decoder.decompress(chunk, into: &output)
/// // progress.consumed bytes of `chunk` are used: pass the rest again with the next chunk.
/// ```
///
/// Decoding allocates nothing after initialization. Three ways to decode, one per stream:
///
/// - ``decompressAll(_:into:)`` decodes a whole stream into the caller's buffer, as libdeflate does.
/// - ``decompress(_:into:historyCount:)`` decodes in steps into the caller's buffers, each starting with the
///   output that back-references can reach (``historySize`` bytes, which the caller moves there): no copies by
///   the decoder. For a whole stream in memory decoded a chunk at a time.
/// - ``decompress(_:into:)`` decodes into a window of its own, which keeps that history, and copies out: any
///   output buffer will do.
///
/// ``init(variant:)`` makes a decoder for raw Deflate64 streams (zip method 9): see ``DeflateVariant``.
///
/// ## gzip members
///
/// A gzip file is a series of members (RFC 1952 §2.2): `cat a.gz b.gz`, pigz's and BGZF's blocks. In gzip format
/// the decoder decodes every member, each a DEFLATE stream of its own with its CRC-32 and length checked, and
/// appends their outputs. After a member, the next bytes must start another member's header (`1F 8B 08`) or the
/// input must end: anything else throws ``BytesError/invalidValue``. Empty members are fine. Each member starts
/// with no history (a match reaching into an earlier member's output throws), and costs only its header, trailer,
/// and a reset: no allocation.
///
/// When decoding in steps, the decoder can't tell whether another member follows until it sees the next bytes.
/// So ``decompress(_:into:)`` returns ``TransformStatus/finished`` at a member's end when all of `input` is used
/// and all output delivered: the stream is complete if the input has ended, and a call with more input decodes
/// the next member. As a pipeline stage (``transform(_:into:flush:)``) that end reads as
/// ``TransformStatus/needsInput`` until `.finish` says the input has ended, so `.finished` there means the whole
/// stream has. Raw and zlib streams have one stream and end at it. ``gzipHeader`` is the latest member's header.
///
/// The decode loop is libdeflate's design: packed table entries holding a length's base and extra-bit count
/// and flags tested one bit at a time, the next entry looked up before the current symbol is finished, up to
/// three literals per refill, and matches copied 16 bytes at a time with an overrun. It runs while at least
/// 32 bytes of input remain, and room for a match, so its bit buffer, stores, and copies need no checks;
/// within 32 bytes of the end a careful loop (on ``BitBuffer``) decodes one symbol at a time, and stops at
/// the start of a code that isn't all there.
@safe
public struct DeflateDecoder: ~Copyable {
    /// The stream's state and tables: separate from the window, so decoding can borrow both.
    private var stream: InflateStream

    /// Room the fast loop needs before each symbol: three literals, a longest DEFLATE match, and the copy's
    /// overrun. (Deflate64's longer matches check their own room.)
    static var fastRoom: Int { 3 + Deflate.maximumMatch + AlignedBytesWriter.copyOverrun }

    /// The window: the history, then 128 KB to decode into, until it slides.
    private var window: UniqueArray<UInt8>
    /// The end of the decoded bytes in ``window``.
    private var windowEnd = 0
    /// The first decoded byte not yet delivered.
    private var windowDelivered = 0
    /// The bytes the current gzip member has decoded through ``decompress(_:into:historyCount:)``: how much of the
    /// caller's history back-references may reach.
    private var memberProduced = 0

    /// Creates a decoder, allocating its tables and window.
    ///
    /// - Parameter format: The container the streams come in.
    public init(format: DeflateFormat = .raw) {
        self.init(format: format, variant: .deflate)
    }

    /// Creates a decoder for raw streams of `variant`, allocating its tables and window.
    ///
    /// Deflate64 only comes raw (zip method 9), so this is the way to decode it; `.deflate` is the same as
    /// `init(format: .raw)`.
    ///
    /// - Parameter variant: The code the streams use.
    public init(variant: DeflateVariant) {
        self.init(format: .raw, variant: variant)
    }

    private init(format: DeflateFormat, variant: DeflateVariant) {
        stream = InflateStream(format: format, variant: variant)
        window = UniqueArray(repeating: 0, count: variant.windowSize &+ (128 << 10))
    }

    /// The container format.
    public var format: DeflateFormat { stream.format }

    /// The code the streams use: DEFLATE, or (raw only) Deflate64.
    public var variant: DeflateVariant { stream.variant }

    /// How much output ``decompress(_:into:historyCount:)`` needs in front of the room it decodes into: the
    /// variant's window, 32 KB for DEFLATE and 64 KB for Deflate64.
    public var historySize: Int { stream.variant.windowSize }

    /// Prepares to decode a new stream, discarding any output not yet delivered. Keeps the allocations.
    public mutating func reset() {
        stream.reset()
        windowEnd = 0
        windowDelivered = 0
        memberProduced = 0
    }

    /// Whether the stream has ended and all its output has been delivered. In gzip format, whether a member has
    /// ended so: the input may end here, or another member may follow.
    public var isFinished: Bool { stream.isDone && windowDelivered == windowEnd }

    /// The header of the latest gzip member read, since the decoder was made or ``reset()``: `nil` before the first
    /// (and always for raw and zlib streams).
    public var gzipHeader: GzipHeader? { stream.gzipHeader }

    /// Decodes a whole stream, from the start, straight into `output`'s free capacity.
    ///
    /// The fastest way to decode: no window, no copies. Every call starts a new stream: a decoder used before (by
    /// any call) starts over as after ``reset()``, keeping its memory.
    ///
    /// - Parameters:
    ///   - input: The whole compressed stream. For raw and zlib streams, bytes after its end are ignored; for
    ///     gzip, every member is decoded, and the input must end after the last.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes the stream took, including its container's header and trailer (gzip:
    ///   all of them).
    /// - Throws: ``BytesError/insufficientData`` for a truncated stream; ``BytesError/insufficientCapacity``
    ///   if the output doesn't fit; ``BytesError/invalidValue`` for corrupt data (in gzip, bytes after a member
    ///   that don't start another); ``BytesError/mismatch`` for a wrong checksum or length, or a stored block's
    ///   bad length complement.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        reset()
        return try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            let result = try stream.run(input, from: 0, into: &span, at: 0)
            try InflateStream.checkWhole(result.stop)
            var position = result.position
            var end = result.end
            if stream.format == .gzip && position &>> 3 < input.byteCount {
                end = try stream.runMembers(input, from: &position, into: &span, at: end)
            }
            written = end
            return position &>> 3
        }
    }

    /// Decodes as much of `input` as it can into `buffer` after its first `historyCount` bytes, continuing the
    /// current stream: for decoding a stream in chunks into buffers of the caller's, with no copies.
    ///
    /// The first `historyCount` bytes of `buffer` must be the stream's latest output, which back-references
    /// can reach: at least ``historySize`` bytes of it, or all of it when there's less. Between calls, move
    /// the last ``historySize`` bytes of output to the front of the next buffer (or keep decoding after them
    /// in the same one). The decoder writes from `historyCount` on, and reports how much in
    /// ``TransformProgress/produced``; bytes after those may be overwritten too.
    ///
    /// ```swift
    /// var decoder = DeflateDecoder(variant: .deflate64)
    /// var history = 0, consumed = 0
    /// while true {
    ///     // buffer: history (moved from the last call's output), then room
    ///     let progress = try decoder.decompress(payload.extracting(consumed...), into: &buffer, historyCount: history)
    ///     consumed += progress.consumed
    ///     // use buffer[history ..< history + progress.produced], keep its last historySize bytes
    ///     if progress.status == .finished { break }
    ///     if progress.status == .needsInput { throw … }   // with the whole payload given: truncated
    /// }
    /// ```
    ///
    /// Input works as in ``decompress(_:into:)``: pass it from where the last call stopped (it can be split
    /// anywhere), or the whole rest of the stream every time, the fastest way.
    ///
    /// The call returns `.needsOutput` when the next symbol doesn't fit. Any room makes progress except before a
    /// match longer than it, so a call with ``DeflateVariant/maximumMatchLength`` bytes of room (258, or 65,538
    /// for Deflate64) always makes progress. Give it far more: the fast loop runs only while 3 + 258 + 32 bytes
    /// are free, and a long Deflate64 match is left for the next call when it doesn't fit. In 1 MB chunks (with
    /// the history moved before each) it ran within 0.5% of the instructions of one call for the whole stream.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes, starting with any not consumed last time.
    ///   - buffer: The history, then room to decode into.
    ///   - historyCount: How many bytes at the start of `buffer` are history.
    /// gzip members follow one another as in ``decompress(_:into:)``: `.finished` at a member's end with all of
    /// `input` used; history from an earlier member is out of reach.
    ///
    /// - Returns: What was consumed and produced, and whether more input or more room is needed, or the
    ///   stream (gzip: a member, with nothing after it in `input`) is finished.
    /// - Throws: As ``decompress(_:into:)``; ``BytesError/invalidValue`` also for a match reaching before the
    ///   history.
    /// - Precondition: `historyCount` is within `buffer`, and no output of ``decompress(_:into:)`` is waiting.
    public mutating func decompress(
        _ input: RawSpan, into buffer: inout MutableRawSpan, historyCount: Int
    ) throws(BytesError) -> TransformProgress {
        precondition(historyCount >= 0 && historyCount <= buffer.byteCount, "History outside the buffer")
        precondition(windowDelivered == windowEnd, "Output of decompress(_:into:) is waiting")
        guard stream.format == .gzip else {
            let result = try stream.run(input, from: stream.bitOffset, into: &buffer, at: historyCount)
            stream.bitOffset = result.position & 7
            return TransformProgress(consumed: result.position &>> 3, produced: result.end &- historyCount, status: result.stop.status)
        }
        // gzip: back-references reach only the current member's output, so the buffer is cut where the member began
        // (or the history starts); and a member's end with more input starts the next.
        var position = stream.bitOffset
        var end = historyCount
        var stop: InflateStream.Stop
        while true {
            if stream.isDone {
                guard position &>> 3 < input.byteCount else {
                    stop = .finished
                    break
                }
                stream.startMember()
                memberProduced = 0
            }
            let history = min(end, memberProduced)
            let base = end &- history
            var member = buffer._mutatingExtracting(base...)
            let result = try stream.run(input, from: position, into: &member, at: history)
            position = result.position
            memberProduced &+= result.end &- history
            end = base &+ result.end
            stop = result.stop
            guard stop == .finished else { break }
        }
        stream.bitOffset = position & 7
        return TransformProgress(consumed: position &>> 3, produced: end &- historyCount, status: stop.status)
    }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream.
    ///
    /// Input can be split anywhere. ``TransformProgress/consumed`` says how much of `input` was used; pass the
    /// rest again, followed by more, on the next call. The decoder only stops short of the end at the
    /// start of a code or header that isn't all there, so it needs at most 512 bytes of unconsumed input to
    /// make progress.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// In gzip format a member's end with more of `input` after it goes on into the next member (see "gzip
    /// members" above); input can be split anywhere there too.
    ///
    /// - Returns: What was consumed and produced, and whether more input or more room is needed, or the
    ///   stream is finished: for gzip, a member ended with all of `input` used and all output delivered (call
    ///   again with more input if there is more: another member).
    /// - Throws: ``BytesError/invalidValue`` for corrupt data (in gzip, bytes after a member that can't start
    ///   another); ``BytesError/mismatch`` for a wrong checksum or length. A stream that never ends just keeps
    ///   asking for input.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        var position = stream.bitOffset
        var produced = 0
        let status: TransformStatus
        var windowFull = false
        while true {
            produced &+= deliver(into: &output)
            guard windowDelivered == windowEnd else {
                status = .needsOutput
                break
            }
            if stream.isDone {
                // gzip: input after a member starts the next, with a window of its own (everything is delivered).
                guard stream.format == .gzip && position &>> 3 < input.byteCount else {
                    status = .finished
                    break
                }
                stream.startMember()
                windowEnd = 0
                windowDelivered = 0
                windowFull = false
            }
            // Full: the next symbol didn't fit. For DEFLATE that's always within `fastRoom` of the end; a
            // Deflate64 match can need up to 64 KB, which a slid window (128 KB free) always has.
            if windowFull || window.count &- windowEnd < Self.fastRoom {
                slide()
            }
            var span = window.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            let result = try stream.run(input, from: position, into: &raw, at: windowEnd)
            position = result.position
            windowEnd = result.end
            windowFull = result.stop == .outputFull
            if result.stop == .needsInput {
                produced &+= deliver(into: &output)
                status = windowDelivered == windowEnd ? .needsInput : .needsOutput
                break
            }
        }
        stream.bitOffset = position & 7
        return TransformProgress(consumed: position &>> 3, produced: produced, status: status)
    }

    /// Copies undelivered output from the window into `output`, as much as fits.
    ///
    /// - Parameter output: Where to append.
    /// - Returns: The number of bytes copied.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(windowEnd &- windowDelivered, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: window.span.bytes.extracting(windowDelivered..<(windowDelivered &+ count)))
        windowDelivered &+= count
        return count
    }

    /// Moves the last 32 KB (Deflate64: 64 KB) of output, the history back-references can reach, to the front
    /// of the window. Everything has been delivered.
    private mutating func slide() {
        let kept = min(windowEnd, historySize)
        let start = windowEnd &- kept
        var span = window.mutableSpan
        span.copyBytes(within: start..<windowEnd, toByteOffset: 0)
        windowEnd = kept
        windowDelivered = kept
    }
}

/// A DEFLATE stream's state and tables, decoding into whatever buffer it's given.
@safe
struct InflateStream: ~Copyable {
    /// The container format.
    let format: DeflateFormat
    /// DEFLATE or Deflate64 (raw only).
    let variant: DeflateVariant

    // MARK: Tables

    /// Root table widths: codes up to this long take one lookup, longer ones a second in a subtable.
    static var literalRootBits: Int { 11 }
    static var distanceRootBits: Int { 8 }

    // Tables, in one array: the fixed code's two (built once) and the current dynamic block's two. The sizes
    // cover the largest tables any valid code can need (from zlib's `enough`: 2,342 entries for 11-bit
    // literal/length roots, 402 for 8-bit distance roots). Read through spans, so every lookup is
    // bounds-checked; see `decodeSymbols` for why that costs nothing on the root lookups.
    static var tableSize: Int { 2560 }
    static var distanceTableSize: Int { 512 }
    static var fixedLiterals: Int { 0 }
    static var fixedDistances: Int { tableSize }
    static var dynamicLiterals: Int { tableSize + distanceTableSize }
    static var dynamicDistances: Int { 2 * tableSize + distanceTableSize }
    static var totalTableSize: Int { 2 * tableSize + 2 * distanceTableSize }

    private var tables: UniqueArray<UInt32>
    /// The code-length code, which only headers use: `Bytes`' plain table, entries holding just the symbol.
    private var codeLengthTable = HuffmanTable(symbolCount: 19, maximumCodeLength: 7, rootBits: 7)

    /// Room the fast loop needs before each symbol: three literals, a longest match, and the copy's overrun.
    static var fastRoom: Int { DeflateDecoder.fastRoom }

    // MARK: Stream state

    private enum Stage {
        case zlibHeader
        case gzipHeader
        case gzipExtraLength
        case gzipExtra(remaining: Int)
        case gzipName
        case gzipComment
        case gzipHeaderCRC
        case blockHeader
        case stored(remaining: Int)
        case huffman(fixed: Bool)
        case trailer
        case done
    }

    private var stage: Stage
    private var isFinalBlock = false
    /// Bits of the next call's first input byte already consumed.
    var bitOffset = 0
    /// gzip's header flags.
    private var gzipFlags = Byte.zero
    /// The latest gzip member's header, kept from one member to the next until a reset.
    private(set) var gzipHeader: GzipHeader?
    /// The CRC-32 of the gzip header so far, for its optional header CRC.
    private var headerCRC = CRC32()
    /// The running checksum of the output: CRC-32 for gzip, Adler-32 for zlib.
    private var checksum: UInt32 = 0
    /// The output's length modulo 2^32, for gzip's trailer.
    private var length: UInt32 = 0

    /// Creates a stream's state, allocating its tables.
    ///
    /// - Parameters:
    ///   - format: The container the streams come in.
    ///   - variant: The code they use; Deflate64 only raw.
    init(format: DeflateFormat, variant: DeflateVariant = .deflate) {
        precondition(variant == .deflate || format == .raw, "Deflate64 streams are raw")
        self.format = format
        self.variant = variant
        tables = UniqueArray(repeating: 0, count: Self.totalTableSize)
        stage = Self.initialStage(format)
        checksum = format.initialChecksum
        // The fixed code is valid, so building it can't throw.
        try! buildTable(Deflate.fixedLiteralLengths.span, .literalLength, at: Self.fixedLiterals, rootBits: Self.literalRootBits)
        try! buildTable(InlineArray<32, UInt8>(repeating: 5).span, .distance, at: Self.fixedDistances, rootBits: Self.distanceRootBits)
    }

    private static func initialStage(_ format: DeflateFormat) -> Stage {
        switch format {
        case .raw: .blockHeader
        case .zlib: .zlibHeader
        case .gzip: .gzipHeader
        }
    }

    /// Whether the stream is between two blocks, the last not final: where a parallel decoder's segment may
    /// end.
    var isBetweenBlocks: Bool {
        if case .blockHeader = stage { return !isFinalBlock }
        return false
    }

    /// Prepares to decode a new stream. Keeps the tables.
    mutating func reset() {
        startMember()
        gzipHeader = nil
    }

    /// Prepares to decode the next gzip member after one that ended (or, as part of ``reset()``, a new stream):
    /// the stream's state but the latest header.
    mutating func startMember() {
        stage = Self.initialStage(format)
        isFinalBlock = false
        bitOffset = 0
        gzipFlags = .zero
        headerCRC = CRC32()
        checksum = format.initialChecksum
        length = 0
    }

    /// Throws for a whole-stream decode that stopped before the stream's end.
    ///
    /// - Throws: ``BytesError/insufficientData`` for input that ended first, ``BytesError/insufficientCapacity`` for
    ///   output that filled.
    @inline(__always)
    static func checkWhole(_ stop: Stop) throws(BytesError) {
        switch stop {
        case .finished: break
        case .needsInput: throw .insufficientData
        case .outputFull: throw .insufficientCapacity
        }
    }

    /// Decodes the gzip members after the first, each into `output` after the last with no history before it,
    /// until the input ends: the rest of a whole-stream decode, out of line so a single member's call doesn't
    /// carry it.
    ///
    /// - Parameters:
    ///   - input: The whole stream.
    ///   - position: The bit after the first member's trailer; advanced to the input's end.
    ///   - output: The buffer the first member was decoded into.
    ///   - end: Where its output ended.
    /// - Returns: Where the last member's output ends.
    /// - Throws: As ``run(_:from:into:at:)``; ``BytesError/insufficientData`` for a member cut short,
    ///   ``BytesError/insufficientCapacity`` for output that doesn't fit.
    @inline(never)
    mutating func runMembers(
        _ input: RawSpan, from position: inout Int, into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> Int {
        var end = end
        repeat {
            startMember()
            var member = output._mutatingExtracting(end...)
            let result = try run(input, from: position, into: &member, at: 0)
            try Self.checkWhole(result.stop)
            position = result.position
            end &+= result.end
        } while position &>> 3 < input.byteCount
        return end
    }

    /// Starts a new stream and reads just its container's header (nothing for raw DEFLATE), for a parallel
    /// decoder that decodes the blocks with raw streams.
    ///
    /// - Returns: The byte offset where the first block starts, or `nil` if the header isn't all there.
    /// - Throws: As ``run(_:from:into:at:)`` for a header it doesn't accept.
    mutating func readHeader(_ input: RawSpan) throws(BytesError) -> Int? {
        reset()
        var position = 0
        while true {
            if case .blockHeader = stage { return position &>> 3 }
            guard try readContainerHeader(input, at: &position) else { return nil }
        }
    }

    /// Whether the stream has ended.
    var isDone: Bool {
        if case .done = stage { return true }
        return false
    }

    // MARK: - The stream's stages

    /// Why ``run(_:from:into:at:)`` stopped.
    enum Stop: Equatable {
        case needsInput, outputFull, finished

        /// The streaming status it reports.
        var status: TransformStatus {
            switch self {
            case .finished: .finished
            case .outputFull: .needsOutput
            case .needsInput: .needsInput
            }
        }
    }

    /// Decodes from bit `start` of `input` into `output` from `outputStart`, through the stream's stages,
    /// until it needs more input, the output is full, or the stream ends. Updates the checksum and length
    /// of what it writes.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - start: The bit to start at.
    ///   - output: The buffer to decode into; bytes before `outputStart` are history.
    ///   - outputStart: Where to write next.
    /// - Returns: The next unread bit, the end of the output, and why it stopped.
    /// - Throws: As ``decompress(_:into:)``.
    mutating func run(
        _ input: RawSpan, from start: Int, into output: inout MutableRawSpan, at outputStart: Int
    ) throws(BytesError) -> (position: Int, end: Int, stop: Stop) {
        var position = start
        var end = outputStart
        while true {
            switch stage {
            case .done:
                return (position, end, .finished)
            case .zlibHeader, .gzipHeader, .gzipExtraLength, .gzipExtra, .gzipName, .gzipComment, .gzipHeaderCRC:
                guard try readContainerHeader(input, at: &position) else { return (position, end, .needsInput) }
            case .blockHeader:
                if isFinalBlock {
                    stage = .trailer
                } else {
                    guard try readBlockHeader(input, at: &position) else { return (position, end, .needsInput) }
                }
            case let .stored(remaining):
                let byteOffset = position &>> 3 // Stored data starts on a byte boundary.
                // Pairwise `min`: with three or more arguments it's variadic, which can allocate an array.
                let count = min(min(remaining, input.byteCount &- byteOffset), output.byteCount &- end)
                var writer = try AlignedBytesWriter(&output, atByteOffset: end)
                try writer.write(input.extracting(byteOffset..<(byteOffset &+ count)))
                updateChecksum(writer.writtenBytes.extracting(end...))
                position &+= count &<< 3
                end &+= count
                guard count == remaining else {
                    stage = .stored(remaining: remaining &- count)
                    return (position, end, end == output.byteCount ? .outputFull : .needsInput)
                }
                stage = .blockHeader
            case let .huffman(fixed):
                let literals = fixed ? Self.fixedLiterals : Self.dynamicLiterals
                let distances = fixed ? Self.fixedDistances : Self.dynamicDistances
                var result: (bitPosition: Int, end: Int, stop: SymbolStop)
                do {
                    let literalTable = tables.span.extracting(literals..<(literals &+ Self.tableSize))
                    let distanceTable = tables.span.extracting(distances..<(distances &+ Self.distanceTableSize))
                    result = if variant == .deflate64 {
                        try Self.decodeSymbols64(
                            input, from: position, literals: literalTable, distances: distanceTable, into: &output, at: end
                        )
                    } else {
                        try Self.decodeSymbols(
                            input, from: position, literals: literalTable, distances: distanceTable, into: &output, at: end
                        )
                    }
                    if result.stop == .nearEnd {
                        result = try Self.decodeSymbolsCarefully(
                            input, from: result.bitPosition, literals: literalTable, distances: distanceTable,
                            into: &output, at: result.end
                        )
                    }
                }
                updateChecksum(output.bytes.extracting(end..<result.end))
                position = result.bitPosition
                end = result.end
                switch result.stop {
                case .endOfBlock: stage = .blockHeader
                case .outputFull: return (position, end, .outputFull)
                case .needsInput, .nearEnd: return (position, end, .needsInput)
                }
            case .trailer:
                position = (position &+ 7) & ~7
                guard try readTrailer(input, at: &position) else { return (position, end, .needsInput) }
                stage = .done
            }
        }
    }

    /// Adds decoded bytes to the container's checksum and length.
    ///
    /// - Parameter bytes: Bytes just decoded.
    private mutating func updateChecksum(_ bytes: RawSpan) {
        guard format != .raw else { return }
        checksum = format.checksum(bytes, continuing: checksum)
        length &+= UInt32(truncatingIfNeeded: bytes.byteCount)
    }

    // MARK: Container headers and trailers

    /// Reads the next part of a zlib or gzip header at byte `position / 8`.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position, a multiple of 8; advanced past what was read.
    /// - Returns: `false` if the part isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/invalidValue`` for a header this decoder doesn't accept (another method, a
    ///   preset dictionary, reserved flags, a bad header check); ``BytesError/mismatch`` for a wrong header CRC.
    private mutating func readContainerHeader(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var reader = try BytesReader(input, atBitPosition: position)
        do throws(BytesError) {
            switch stage {
            case .zlibHeader:
                let header = try reader.read(Byte2.self, .bigEndian)
                guard header[ZlibHeader.method] == 8, header[ZlibHeader.windowBits] <= 7, header % 31 == 0,
                      header.isClear(ZlibHeader.presetDictionary) else { throw BytesError.invalidValue }
                stage = .blockHeader
            case .gzipHeader:
                guard reader.remainingByteCount >= 10 else {
                    // Not all there yet, but bytes that can't start a member (after one: trailing garbage) throw now,
                    // rather than waiting for input that can't help.
                    try Self.checkGzipMagic(reader.remainingBytes)
                    return false
                }
                let fixed = try reader.read(byteCount: 10)
                // Two loads within the 10 bytes just read. As two words, the fields cost a few shifts (they were
                // read one at a time through a checked reader, about 100 instructions a member).
                let low = UInt64(littleEndian: fixed.load(fromByteOffset: 0, as: UInt64.self))
                let high = UInt16(littleEndian: fixed.load(fromByteOffset: 8, as: UInt16.self))
                guard low & 0xFF_FFFF == 0x08_8B_1F else { throw BytesError.invalidValue } // ID1, ID2, CM (8, DEFLATE)
                gzipFlags = Byte(truncatingIfNeeded: low &>> 24)
                try gzipFlags.requireZero(GzipFlags.reserved)
                gzipHeader = GzipHeader(
                    flags: gzipFlags, modificationTime: UInt32(truncatingIfNeeded: low &>> 32),
                    extraFlags: UInt8(truncatingIfNeeded: high), operatingSystem: UInt8(truncatingIfNeeded: high &>> 8)
                )
                // The header's CRC only matters with FHCRC (the optional fields, when present, add to it regardless).
                if gzipFlags[GzipFlags.headerCRC] { headerCRC.update(fixed) }
                stage = .gzipExtraLength
            case .gzipExtraLength:
                if gzipFlags[GzipFlags.extra] {
                    let lengthBytes = try reader.read(byteCount: 2)
                    headerCRC.update(lengthBytes)
                    var lengthReader = AlignedBytesReader(lengthBytes)
                    stage = try .gzipExtra(remaining: Int(lengthReader.read(Byte2.self, .littleEndian)))
                } else {
                    stage = .gzipName
                }
            case let .gzipExtra(remaining):
                let count = min(remaining, reader.remainingByteCount)
                headerCRC.update(try reader.read(byteCount: count))
                stage = count == remaining ? .gzipName : .gzipExtra(remaining: remaining &- count)
                if count < remaining {
                    position = reader.bitPosition
                    return false
                }
            case .gzipName, .gzipComment:
                let isName = if case .gzipName = stage { true } else { false }
                if gzipFlags[isName ? GzipFlags.name : GzipFlags.comment] { // Zero-terminated.
                    let rest = reader.remainingBytes
                    let zero = rest.firstByteOffset { $0.matching(0) }
                    let count = zero.map { $0 &+ 1 } ?? rest.byteCount
                    headerCRC.update(try reader.read(byteCount: count))
                    if zero == nil {
                        position = reader.bitPosition
                        return false
                    }
                }
                stage = isName ? .gzipComment : .gzipHeaderCRC
            case .gzipHeaderCRC:
                if gzipFlags[GzipFlags.headerCRC] { // The low 16 bits of the header's CRC-32.
                    let expected = try reader.read(Byte2.self, .littleEndian)
                    guard expected == UInt16(truncatingIfNeeded: headerCRC.value) else { throw BytesError.mismatch }
                }
                stage = .blockHeader
            default:
                preconditionFailure("Not a header stage")
            }
        } catch .insufficientData {
            return false
        }
        position = reader.bitPosition
        return true
    }

    /// Throws unless `bytes` start as a gzip header does, as far as they go: its magic and method, `1F 8B 08`.
    ///
    /// - Throws: ``BytesError/invalidValue`` for a byte that differs.
    private static func checkGzipMagic(_ bytes: RawSpan) throws(BytesError) {
        let magic: InlineArray<3, UInt8> = [0x1F, 0x8B, 0x08]
        for index in 0..<min(bytes.byteCount, 3) where bytes.load(fromByteOffset: index, as: UInt8.self) != magic[index] {
            throw .invalidValue
        }
    }

    /// Reads and checks the container's trailer at byte `position / 8`.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position, a multiple of 8; advanced past the trailer.
    /// - Returns: `false` if the trailer isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/mismatch`` for a wrong checksum or length.
    private func readTrailer(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var reader = try BytesReader(input, atBitPosition: position)
        let trailer: RawSpan
        do throws(BytesError) {
            trailer = try reader.read(byteCount: format.trailerSize)
        } catch .insufficientData {
            return false
        }
        guard format.trailerMatches(trailer, checksum: checksum, length: length) else { throw .mismatch }
        position = reader.bitPosition
        return true
    }

    // MARK: Block headers

    /// Reads a block header at bit `position`: the final flag, the type, and a stored block's length or a
    /// dynamic block's tables, all or nothing.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position; advanced past the header.
    /// - Returns: `false` if the header isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/invalidValue`` for the reserved block type or invalid tables;
    ///   ``BytesError/mismatch`` for a stored block's bad length complement.
    private mutating func readBlockHeader(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var bits = try BitBuffer(input, atBitPosition: position, bitOrder: .leastSignificantFirst)
        let isFinal = bits.read(Bool.self)
        let type = try bits.read(DeflateBlockType.self, as: Crumb.self)
        let next: Stage
        switch type {
        case .stored:
            bits.alignToByte()
            guard !bits.isOverrun else { return false }
            var stored = try bits.finish()
            let length: Byte2
            do {
                length = try stored.read(Byte2.self)
                try stored.expect(~length) // NLEN, the one's complement
            } catch .insufficientData {
                return false
            }
            isFinalBlock = isFinal
            position = stored.bitPosition
            stage = .stored(remaining: Int(length.littleEndian))
            return true
        case .fixedHuffman:
            next = .huffman(fixed: true)
        case .dynamicHuffman:
            guard try readDynamicTables(&bits) else { return false }
            next = .huffman(fixed: false)
        }
        // A truncated header reads zeros from the buffer; caught here, before anything changes.
        guard !bits.isOverrun else { return false }
        isFinalBlock = isFinal
        stage = next
        position = bits.bitPosition
        return true
    }

    /// Reads a dynamic block's header (RFC 1951, 3.2.7) and builds its two tables.
    ///
    /// - Parameter bits: The bit buffer, positioned after the block type.
    /// - Returns: `false` if the header ran past the end of the input.
    /// - Throws: ``BytesError/invalidValue`` for too many codes, an invalid or over-subscribed code, a bad
    ///   repeat, or a missing end-of-block code.
    private mutating func readDynamicTables(_ bits: inout BitBuffer) throws(BytesError) -> Bool {
        let literalCount = bits.read(Int.self, as: Bits<5>.self) &+ 257 // HLIT
        let distanceCount = bits.read(Int.self, as: Bits<5>.self) &+ 1 // HDIST
        let codeLengthCount = bits.read(Int.self, as: Nibble.self) &+ 4 // HCLEN
        guard !bits.isOverrun else { return false }
        guard literalCount <= 286, distanceCount <= (variant == .deflate64 ? 32 : 30) else { throw .invalidValue }

        // The code-length code: 3 bits per length, in a fixed order.
        var codeLengthLengths = InlineArray<19, UInt8>(repeating: 0)
        for index in 0..<codeLengthCount {
            codeLengthLengths[Int(Deflate.codeLengthOrder[index])] = bits.read(Bits<3>.self).rawValue
        }
        guard !bits.isOverrun else { return false }
        // zlib rejects incomplete code-length codes, unlike the others.
        try codeLengthTable.build(codeLengths: codeLengthLengths.span, bitOrder: .leastSignificantFirst, allowingIncomplete: false)

        // The literal/length and distance code lengths, as one sequence with run-length codes 16 to 18.
        var lengths = InlineArray<318, UInt8>(repeating: 0) // 286 + 32
        let total = literalCount &+ distanceCount
        var index = 0
        while index < total {
            bits.refill()
            // Past the end, zeros decode as some code: harmless, since the overrun is checked before
            // anything is used.
            let symbol = try codeLengthTable.decode(&bits)
            let repeated: UInt8
            let count: Int
            switch symbol {
            case 0...15:
                lengths[index] = UInt8(symbol)
                index &+= 1
                continue
            case 16: // The previous length, 3 to 6 times.
                guard index > 0 else {
                    // Zeros past the end of a truncated header can decode as code 16 here: that's more input
                    // needed, not an invalid stream (a socket stream's reads ended 8 bytes into a header).
                    if bits.isOverrun { return false }
                    throw .invalidValue
                }
                repeated = lengths[index &- 1]
                count = 3 &+ Int(bits.read(Crumb.self))
            case 17: // Zero, 3 to 10 times.
                repeated = 0
                count = 3 &+ Int(bits.read(Bits<3>.self))
            default: // 18: zero, 11 to 138 times.
                repeated = 0
                count = 11 &+ Int(bits.read(Bits<7>.self))
            }
            guard index &+ count <= total else {
                if bits.isOverrun { return false }
                throw .invalidValue
            }
            for offset in index..<(index &+ count) {
                lengths[offset] = repeated
            }
            index &+= count
        }
        guard !bits.isOverrun else { return false }
        guard lengths[256] != 0 else { throw .invalidValue } // A block needs its end code.

        let span = lengths.span
        try buildTable(span.extracting(0..<literalCount), .literalLength, at: Self.dynamicLiterals, rootBits: Self.literalRootBits)
        try buildTable(span.extracting(literalCount..<total), .distance, at: Self.dynamicDistances, rootBits: Self.distanceRootBits)
        return true
    }

    /// Builds the decoding table at `offset` in ``tables`` for the canonical Huffman code with code `lengths`
    /// (0 for unused symbols), with `alphabet`'s packed entries.
    ///
    /// Accepts the incomplete codes zlib does: an empty one (a block without matches) and a single 1-bit
    /// code (RFC 1951 allows it for distances, zlib for literals too).
    ///
    /// - Parameters:
    ///   - lengths: The code length of each symbol.
    ///   - alphabet: Which alphabet's entries to build.
    ///   - offset: Where the table starts in ``tables``.
    ///   - rootBits: The root table's index width.
    /// - Throws: ``BytesError/invalidValue`` if the lengths aren't a valid code.
    private mutating func buildTable(
        _ lengths: Span<UInt8>, _ alphabet: DeflateAlphabet, at offset: Int, rootBits: Int
    ) throws(BytesError) {
        let size = alphabet == .literalLength ? Self.tableSize : Self.distanceTableSize
        var all = tables.mutableSpan
        var table = all._mutatingExtracting(offset..<(offset &+ size))
        let deflate64 = variant == .deflate64
        _ = try HuffmanTable.build(
            codeLengths: lengths, bitOrder: .leastSignificantFirst, rootBits: rootBits, maximumCodeLength: 15,
            into: &table, invalid: HuffmanEntry.invalid.raw,
            symbol: { symbol, length in alphabet.entry(symbol, codeLength: length, deflate64: deflate64).raw },
            subtable: { offset, bits in HuffmanEntry(codeLength: bits, kind: .subtable, value: offset).raw }
        )
    }

    // MARK: - Symbols

    /// Why ``decodeSymbols(_:from:literals:distances:into:at:)`` stopped.
    enum SymbolStop {
        case endOfBlock, outputFull, needsInput
        /// The fast loop stopped within 32 bytes of the input's end or near the output's: continue with
        /// ``decodeSymbolsCarefully(_:from:literals:distances:into:at:)``.
        case nearEnd
    }

    /// Input the fast loop needs, in bits: an iteration consumes at most 93 bits (three 15-bit literals,
    /// or a match's 48), so with 32 bytes left it never reads past the end.
    static var fastInputBits: Int { 32 &* 8 }

    /// Decodes Huffman-coded symbols from `bitPosition` into `output` from `end`, until the block ends,
    /// the output is full, or the next code isn't all there.
    ///
    /// Table lookups are bounds-checked. Stating the tables' sizes once, here, makes those checks free for
    /// root lookups: with the count a known constant, the optimizer sees that a masked root index is in
    /// bounds. Only subtable lookups (codes longer than the root, rare) keep a check.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - bitPosition: Where the block's symbols start or resume.
    ///   - literals: The literal/length table, exactly ``tableSize`` entries.
    ///   - distances: The distance table, exactly ``distanceTableSize`` entries.
    ///   - output: The buffer to decode into.
    ///   - end: Where in `output` to write next.
    /// - Returns: The new bit position and output end, and why it stopped. On `needsInput` and
    ///   `outputFull`, the position is the start of the symbol it couldn't finish.
    /// - Throws: ``BytesError/invalidValue`` for an invalid code or a distance reaching before the output's
    ///   start.
    /// - Precondition: The tables have exactly those sizes.
    @inline(never)
    private static func decodeSymbols(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        try decodeSymbols(input, from: bitPosition, literals: literals, distances: distances, into: &output, at: end, deflate64: false)
    }

    /// ``decodeSymbols(_:from:literals:distances:into:at:)`` for Deflate64: its own copy of the loop, so
    /// DEFLATE's doesn't carry the longer matches' extra refill and room check.
    @inline(never)
    private static func decodeSymbols64(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        try decodeSymbols(input, from: bitPosition, literals: literals, distances: distances, into: &output, at: end, deflate64: true)
    }

    /// The fast loop, specialized by the two wrappers above on a constant `deflate64`.
    ///
    /// libdeflate's `decompress_template.h` on locals, with no bounds checks of its own (2026-11-22): checked
    /// accesses (`BitBuffer`'s refill, the writer's stores and copies) cost 2–3 instructions each, 12–20 a match.
    @inline(__always)
    private static func decodeSymbols(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int, deflate64: Bool
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        precondition(literals.count == tableSize && distances.count == distanceTableSize)
        precondition(bitPosition >= 0 && end >= 0 && end <= output.byteCount, "Position outside the buffers")
        let inputBits = input.byteCount &<< 3
        let roomLimit = output.byteCount &- fastRoom
        // Not even one iteration's worth: leave it all to the careful loop.
        guard inputBits &- bitPosition >= fastInputBits, end <= roomLimit else { return (bitPosition, end, .nearEnd) }

        // It checks only the output against a limit, made in rounds: where the room ends, or sooner where the
        // input could. Every iteration takes at most 16 bits per byte it writes (a literal 15 bits, a match of
        // 3 or more at most 48), or for Deflate64 20 (a match's 60), so while the output is at most `out + (input
        // left - 32 bytes) / 16` (Deflate64: `* 3 / 64`, shifts rather than a division by 20, whose constant
        // took a register), at least 32 bytes of input are left when an iteration starts, and `fastRoom` bytes of
        // output. A round takes a few instructions, and a call has a few dozen to a few hundred.
        //
        // That makes every access in an iteration safe unchecked: its refills load 8 bytes at most 20 bytes
        // past its starting bit (93 bits consumed, then 63 buffered), and it writes at most three literals, or
        // two and a match of up to 258 bytes and the copy's 32-byte overrun.
        var bits = FastBits(input, at: bitPosition)
        var out = end
        // The output as a local: through the `inout` parameter, its base address was loaded from memory before
        // every store (the stores might change it, as far as LLVM can tell).
        var buffer = output._mutatingExtracting(0..<output.byteCount)
        // The next symbol's entry is looked up ahead of time (as libdeflate does): at the top of each iteration
        // it's ready, so decoding doesn't wait for a refill, a mask, and a table load first. After a match, the
        // next lookup happens before the match is copied, overlapping the two.
        var entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
        rounds: while true {
            let inputLeft = inputBits &- bits.position &- fastInputBits
            guard inputLeft >= 0 else { break rounds }
            let limit = min(roomLimit, out &+ (deflate64 ? (inputLeft &* 3) &>> 6 : inputLeft &>> 4))
            guard out <= limit else { break rounds }
            fast: while out <= limit {
                // 56 or more bits buffered. A link consumes nothing (its `totalBits` is 0).
                var saved = bits.buffer
                bits.consume(entry)
                if entry.isLiteral {
                    // Literals come in runs: up to three per refill, each a root code of 11 bits at most. After
                    // two, 34 or more bits are left: enough for any literal/length code (a link, then 15 bits), or
                    // a length (20) and the distance's root lookup (8).
                    let first = entry
                    entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
                    saved = bits.buffer
                    bits.consume(entry)
                    Self.store(first, &buffer, at: out)
                    out &+= 1
                    if entry.isLiteral {
                        let second = entry
                        entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
                        saved = bits.buffer
                        bits.consume(entry)
                        Self.store(second, &buffer, at: out)
                        out &+= 1
                        if entry.isLiteral {
                            // 23 or more bits are left: enough for the next root lookup, made before the refill
                            // so it doesn't wait for the refill's load.
                            let third = entry
                            entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
                            bits.refill(input)
                            Self.store(third, &buffer, at: out)
                            out &+= 1
                            continue fast
                        }
                    }
                }
                if entry.isExceptional {
                    if entry.isSubtable {
                        // A code longer than the root: its subtable's entry for the bits after the root's (the link
                        // consumed none). A literal, a length, or the end of the block.
                        entry = subtableEntry(entry, literals, bits.buffer, rootBits: literalRootBits)
                        saved = bits.buffer
                        bits.consume(entry)
                        if entry.isLiteral {
                            let literal = entry
                            entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
                            bits.refill(input)
                            Self.store(literal, &buffer, at: out)
                            out &+= 1
                            continue fast
                        }
                    }
                    if entry.isExceptional {
                        if entry.isEndOfBlock {
                            return (bits.position, out, .endOfBlock)
                        }
                        // Deflate64's symbol 285, marked exceptional so that only it pays for this check: it reaches
                        // 65,538 bytes, past the room the loop keeps (a DEFLATE match's). One that can't be copied
                        // with the overrun is left to the careful loop, from the length's code.
                        guard deflate64, entry.isLongLength else { throw .invalidValue }
                        // The extra bits by the fields, not `extra(saved:)`: its shift by `raw >> 8` sees the
                        // exceptional flag here, and the mask LLVM kept for it took a register in the whole loop.
                        let length = entry.value &+ entry.extra(saved)
                        if buffer.byteCount &- out < length &+ AlignedBytesWriter.copyOverrun {
                            return (bits.position &- entry.totalBits, out, .nearEnd)
                        }
                        // Its 31 bits can leave fewer than the distance's root lookup needs.
                        bits.refill(input)
                    }
                }

                // A match. Its length's code and extra bits are consumed, and 14 or more bits are left: enough for
                // the distance's root lookup (any length but Deflate64's symbol 285 takes 20 bits at most).
                let length = entry.value &+ entry.extra(saved: saved)
                entry = rootEntry(distances, bits.buffer, rootBits: distanceRootBits)
                if entry.isExceptional {
                    // A subtable link (or an invalid code): up to 15 + 14 bits, then the next root lookup's 11.
                    bits.refill(input)
                    guard entry.isSubtable else { throw .invalidValue }
                    entry = subtableEntry(entry, distances, bits.buffer, rootBits: distanceRootBits)
                    guard !entry.isExceptional else { throw .invalidValue }
                } else if bits.count < distanceRootBits &+ (deflate64 ? 14 : 13) &+ literalRootBits {
                    // A root code's 8 bits and 13 extra (Deflate64: 14), then the next root lookup's 11.
                    bits.refill(input)
                }
                saved = bits.buffer
                bits.consume(entry)
                let distance = entry.value &+ entry.extra(saved: saved)
                guard distance <= out else { throw .invalidValue } // Before the output's start.
                entry = rootEntry(literals, bits.buffer, rootBits: literalRootBits)
                bits.refill(input)
                try Self.copyMatch(&buffer, at: out, distance: distance, length: length)
                out &+= length
            }
        }

        return (bits.position, out, .nearEnd)
    }

    /// The fast loop's bit buffer: libdeflate's. `left`'s low 6 bits count the valid bits in `buffer`, and its
    /// higher bits are garbage, because consuming an entry subtracts the whole raw entry rather than masking its
    /// count first (its bits 6 and up don't change the low 6 bits of the difference).
    ///
    /// A struct with mutating methods rather than nested functions over captured variables, which can stay in
    /// memory behind access checks.
    private struct FastBits {
        var buffer: UInt64 = 0
        var left = 0
        /// The next byte to load.
        var next: Int

        /// Starts at bit `position` of `input`, refilled.
        ///
        /// - Precondition: 8 bytes or more of `input` from `position / 8`.
        @inline(__always)
        init(_ input: RawSpan, at position: Int) {
            next = position &>> 3
            refill(input)
            buffer &>>= UInt64(truncatingIfNeeded: position & 7)
            left &-= position & 7
        }

        /// The number of valid bits.
        @inline(__always) var count: Int { left & 63 }

        /// The position of the next bit to consume, from the start of the input.
        @inline(__always) var position: Int { next &<< 3 &- count }

        /// Loads 8 bytes above the valid bits, keeping 56 to 63 valid: `BitBuffer`'s refill, unchecked.
        ///
        /// - Precondition: 8 bytes of `input` from ``next``.
        @inline(__always)
        mutating func refill(_ input: RawSpan) {
            // Unsafe: an unchecked 8-byte load. Safe: the fast loop runs only while 32 bytes or more of input
            // are left at an iteration's start, and an iteration's refills load at most 20 bytes past it.
            let word = unsafe input.unsafeLoadUnaligned(fromUncheckedByteOffset: next, as: UInt64.self)
            buffer |= UInt64(littleEndian: word) &<< UInt64(truncatingIfNeeded: left)
            next &+= 7 &- ((left &>> 3) & 7)
            left |= 56
        }

        /// Consumes an entry's bits: shifts by its low 6 bits, and subtracts the whole entry.
        @inline(__always)
        mutating func consume(_ entry: HuffmanEntry) {
            buffer &>>= UInt64(entry.raw)
            left &-= Int(entry.raw)
        }
    }

    /// Writes a literal, unchecked.
    ///
    /// - Precondition: `offset` is within `output` (the fast loop keeps `fastRoom` bytes past it).
    @inline(__always)
    private static func store(_ literal: HuffmanEntry, _ output: inout MutableRawSpan, at offset: Int) {
        // Unsafe: an unchecked store. Safe: the fast loop's output limit leaves room for an iteration's writes.
        unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: literal.raw &>> 16), toUncheckedByteOffset: offset, as: UInt8.self)
    }

    /// Moves a `T` from `source` to `destination` within `output`, unchecked.
    @unsafe @inline(__always)
    private static func move<T: BitwiseCopyable>(_: T.Type, from source: Int, to destination: Int, in output: inout MutableRawSpan) {
        let value = unsafe output.bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: source, as: T.self)
        unsafe output.storeBytes(of: value, toUncheckedByteOffset: destination, as: T.self)
    }

    /// Copies a match in the fast loop: 16 or 8 bytes at a time with an overrun of up to 32 bytes, libdeflate's
    /// copy with no branch on the length up to 32. Distances below 8 go through the writer's exact copy (a
    /// `memset` for 1, a pattern fill for 2–7).
    ///
    /// - Precondition: `1 <= distance <= offset`, and `length + 32` bytes of room after `offset`.
    @inline(always)
    private static func copyMatch(_ output: inout MutableRawSpan, at offset: Int, distance: Int, length: Int) throws(BytesError) {
        let source = offset &- distance
        // Unsafe: unchecked moves. Safe: the fast loop checked the distance and keeps `length + 32` bytes of room;
        // a move of n bytes at `index` reads up to `offset + index + n - distance`, at most `offset + index` when
        // `distance >= n`: bytes already final.
        if distance >= 16 {
            unsafe move(SIMD16<UInt8>.self, from: source, to: offset, in: &output)
            unsafe move(SIMD16<UInt8>.self, from: source &+ 16, to: offset &+ 16, in: &output)
            var index = 32
            while index < length {
                unsafe move(SIMD16<UInt8>.self, from: source &+ index, to: offset &+ index, in: &output)
                index &+= 16
            }
        } else if distance >= 8 {
            unsafe move(UInt64.self, from: source, to: offset, in: &output)
            unsafe move(UInt64.self, from: source &+ 8, to: offset &+ 8, in: &output)
            unsafe move(UInt64.self, from: source &+ 16, to: offset &+ 16, in: &output)
            unsafe move(UInt64.self, from: source &+ 24, to: offset &+ 24, in: &output)
            var index = 32
            while index < length {
                unsafe move(UInt64.self, from: source &+ index, to: offset &+ index, in: &output)
                index &+= 8
            }
        } else {
            var writer = try AlignedBytesWriter(&output, atByteOffset: offset)
            try writer.copy(fromDistance: distance, count: length)
        }
    }

    /// Decodes symbols near the end of the input or output: one at a time, each finished only if its bits are
    /// all there and its output fits; otherwise it stops at the symbol's start.
    ///
    /// Separate from the fast loop and never inlined: together they were too big for the inliner, which then
    /// left `BytesWriter` and span getters as calls in the fast loop (1,390 instructions against 644).
    ///
    /// - Returns: As ``decodeSymbols(_:from:literals:distances:into:at:)``, never `nearEnd`.
    @inline(never)
    private static func decodeSymbolsCarefully(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        precondition(literals.count == tableSize && distances.count == distanceTableSize)
        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
        var writer = try AlignedBytesWriter(&output, atByteOffset: end)
        let inputBits = input.byteCount &<< 3
        while true {
            let start = bits.bitPosition
            let available = inputBits &- start
            bits.refill()
            let entry = lookup(literals, bits.bits, rootBits: literalRootBits)
            switch entry.kind {
            case .literal:
                guard entry.totalBits <= available else { return (start, writer.byteCount, .needsInput) }
                guard writer.remainingByteCount >= 1 else { return (start, writer.byteCount, .outputFull) }
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
            case .endOfBlock:
                guard entry.totalBits <= available else { return (start, writer.byteCount, .needsInput) }
                bits.consume(bitCount: entry.totalBits)
                return (bits.bitPosition, writer.byteCount, .endOfBlock)
            case .lengthOrDistance:
                let length = entry.value &+ entry.extra(bits.bits)
                bits.consume(bitCount: entry.totalBits)
                bits.refill()
                let distanceEntry = lookup(distances, bits.bits, rootBits: distanceRootBits)
                guard distanceEntry.kind == .lengthOrDistance else {
                    // Zeros past the end can look like an invalid code.
                    if inputBits &- bits.bitPosition < 15 { return (start, writer.byteCount, .needsInput) }
                    throw .invalidValue
                }
                let distance = distanceEntry.value &+ distanceEntry.extra(bits.bits)
                bits.consume(bitCount: distanceEntry.totalBits)
                guard bits.bitPosition <= inputBits else { return (start, writer.byteCount, .needsInput) }
                guard writer.remainingByteCount >= length else { return (start, writer.byteCount, .outputFull) }
                if writer.remainingByteCount >= length &+ AlignedBytesWriter.copyOverrun {
                    try writer.copy(fromDistance: distance, count: length, allowingOverrun: true)
                } else {
                    try writer.copy(fromDistance: distance, count: length)
                }
            default:
                if available < 15 { return (start, writer.byteCount, .needsInput) }
                throw .invalidValue
            }
        }
    }

    /// The entry for the code at the start of `bits`.
    ///
    /// - Parameters:
    ///   - table: A root table followed by its subtables.
    ///   - bits: The buffered bits; enough must be valid for the longest code.
    ///   - rootBits: The root table's index width.
    /// - Returns: The entry, with any subtable link resolved.
    @inline(__always)
    private static func lookup(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        resolve(rootEntry(table, bits, rootBits: rootBits), table, bits, rootBits: rootBits)
    }

    /// The root table's entry for the start of `bits`: needs only `rootBits` valid bits.
    ///
    /// - Parameters:
    ///   - table: A root table followed by its subtables.
    ///   - bits: The buffered bits.
    ///   - rootBits: The root table's index width.
    /// - Returns: The root entry, which may be a subtable link.
    @inline(__always)
    private static func rootEntry(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        HuffmanEntry(raw: table[Int(truncatingIfNeeded: bits.bits(from: 0, upTo: rootBits))])
    }

    /// `entry`, or for a link to a subtable, the subtable's entry for the bits after the root's.
    ///
    /// - Parameters:
    ///   - entry: A root entry.
    ///   - table: The table `entry` came from.
    ///   - bits: The buffered bits `entry` was looked up with.
    ///   - rootBits: The root table's index width.
    /// - Returns: `entry` unless it's a subtable link.
    @inline(__always)
    private static func resolve(
        _ entry: HuffmanEntry, _ table: Span<UInt32>, _ bits: UInt64, rootBits: Int
    ) -> HuffmanEntry {
        guard entry.isSubtable else { return entry }
        return subtableEntry(entry, table, bits, rootBits: rootBits)
    }

    /// The subtable's entry that the link `entry` leads to, for the bits after the root's.
    ///
    /// - Parameters:
    ///   - entry: A subtable link.
    ///   - table: The table `entry` came from.
    ///   - bits: The buffered bits `entry` was looked up with.
    ///   - rootBits: The root table's index width.
    /// - Returns: The subtable's entry.
    @inline(__always)
    private static func subtableEntry(
        _ entry: HuffmanEntry, _ table: Span<UInt32>, _ bits: UInt64, rootBits: Int
    ) -> HuffmanEntry {
        // Shift, then mask: `bits(from:upTo:)` masks first, which needs the sum, and grew `decodeSymbols` by 5
        // instructions.
        let index = Int(truncatingIfNeeded: bits.bits(from: rootBits, count: entry.codeLength))
        return HuffmanEntry(raw: table[entry.value &+ index])
    }
}
