public import Bytes

// Streaming LZMA: the decode loops of LZMACore.swift, run into a window the decoder owns instead of the caller's
// whole output, and copied out from there as room allows.
//
// The window is a flat buffer, not a circular one, so the loops run unchanged (a circular window would cost the
// fast loop a wrap check on every match and matched literal). Positions are window offsets; when the window is
// full and everything in it delivered, the last dictionary's worth of bytes moves to the front (a slide, by a
// multiple of 64 so positions keep their low bits, which lp and pb select probabilities by). The room beyond the
// dictionary is as large as the dictionary up to `LZMAWindow.defaultRoomLimit` (and at least 256 KiB for raw LZMA,
// 2 MiB for xz, whose chunks of up to 2 MiB decode whole): each slide moves the dictionary once per room's worth of
// output. The window is allocated at its final size, the dictionary (or the stream's size, when that's known and
// smaller) plus the room, when the stream starts: no doubling, so no copies and no old and new windows held at once.
// It isn't zeroed (the decode loops read only bytes they wrote, as in the caller's output for `LZMA2Decoder`), so a
// large dictionary on a small stream makes resident only the pages the stream's output reaches.
//
// Input split anywhere works for raw LZMA. The fast loop runs while more than `LZMALoop.inputMargin` bytes
// remain, the careful loop while more than `tailMargin` do (no symbol reads more than 20), and below that each
// symbol is first decoded without effect (`LZMATrial`, `LzmaDec.c`'s `LzmaDec_TryDummy`): if its input isn't all
// there, the decoder stops at the symbol's start and asks for more.

/// A streaming decoder's dictionary window.
@safe @usableFromInline // Exported for clients' destroys, as `LZMAWorkspace`.
struct LZMAWindow: ~Copyable {
    private var memory = GrowableWorkspace()
    /// Bytes below this offset have been delivered.
    var delivered = 0
    /// Bytes of the current dictionary that slides moved out of the window.
    var discarded = 0
    /// The window's size for the current dictionary, and what it would be with no stated size.
    private var target = 0
    private var fullTarget = 0

    init() {}

    /// The most room beyond the dictionary, unless a decoder sets its own: slides move the dictionary once per
    /// this much output.
    /// 4 MiB: for `xz -6`'s 8 MiB dictionary a 12 MiB window instead of 16, for 0.3–0.4% more instructions on
    /// streams past the window (samba, 20.6 MB; none below it). 2 MiB cost 0.9–1.0%, 1 MiB 1.8% (2026-11-22, M1 Max:
    /// Benchmarks/CompressionBenchmarks/LZMAStreamingBenchmarks.swift's streaming rows with each limit).
    static var defaultRoomLimit: Int { 4 << 20 }

    /// The start of the window, `nil` before the first stream that needs one.
    var base: UnsafeMutablePointer<UInt8>? {
        guard let base = unsafe memory.base else { return nil }
        // Unsafe: the allocation as bytes. Safe: raw memory, only ever used as bytes.
        return unsafe base.assumingMemoryBound(to: UInt8.self)
    }

    /// The window's allocated size: the largest any stream has needed.
    var capacity: Int { memory.byteCount }

    /// Starts a dictionary at offset 0. The window is the dictionary (`dictionarySize`, no more than
    /// `maximumDictionarySize`) plus room for decoding beyond it, or `knownSize` if that's smaller. The room is as
    /// large as the dictionary up to `roomLimit`, and at least `minimumRoom`.
    mutating func start(dictionarySize: Int, knownSize: Int?, maximumDictionarySize: Int, minimumRoom: Int, roomLimit: Int) {
        delivered = 0
        discarded = 0
        let kept = min(dictionarySize, maximumDictionarySize)
        fullTarget = kept &+ max(minimumRoom, min(kept, roomLimit))
        target = fullTarget
        if let knownSize, knownSize < target {
            target = (knownSize &+ 63) & ~63
        }
    }

    /// Frees the window: a decoder done with large streams.
    mutating func free() {
        memory.free()
    }

    /// Exchanges the windows of two decoders, so one allocation serves whichever is decoding.
    ///
    /// - Precondition: Neither has output waiting (both are restarted before use).
    mutating func exchangeMemory(with other: inout LZMAWindow) {
        swap(&memory, &other.memory)
    }

    /// Restarts the dictionary at offset 0, everything having been delivered: an LZMA2 dictionary reset.
    mutating func restart() {
        delivered = 0
        discarded = 0
    }

    /// Makes room for `needed` bytes after `position`, everything before it having been delivered: allocates the
    /// window at its size for the dictionary, or slides the last `dictionarySize` bytes to the front.
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if keeping the dictionary would take more than
    ///   `maximumDictionarySize` bytes.
    mutating func makeRoom(
        _ needed: Int, position: inout Int, dictionarySize: Int, maximumDictionarySize: Int
    ) throws(BytesError) {
        if capacity &- position >= needed { return }
        precondition(delivered == position, "LZMA window made room with output undelivered")
        if capacity < target {
            // The whole window at once. Not zeroed: the decode loops read only bytes they wrote, so pages beyond
            // the output aren't touched (or made resident). A window outgrown by a later stream at least doubles
            // (up to the size with no stated size), so streams of growing sizes reallocate only a few times.
            let size = capacity == 0 ? target : max(target, min(capacity &* 2, fullTarget))
            memory.grow(to: size, preserving: position, zeroed: false)
            if capacity &- position >= needed { return }
        }
        let keep = min(position, dictionarySize)
        guard keep <= maximumDictionarySize else { throw .insufficientCapacity }
        let shift = (position &- keep) & ~63
        if shift > 0 {
            // Unsafe: a move within the window. Safe: `position - shift` bytes from `shift`, all below `position`,
            // which is within the window.
            unsafe base!.update(from: base! + shift, count: position &- shift)
            position &-= shift
            delivered &-= shift
            discarded &+= shift
        }
        guard capacity &- position >= needed else { throw .insufficientCapacity }
    }

    /// Copies undelivered bytes, up to `end`, into `output`, as many as fit.
    ///
    /// - Returns: The number of bytes copied.
    mutating func deliver(upTo end: Int, into output: inout OutputRawSpan) -> Int {
        let count = min(end &- delivered, output.freeCapacity)
        guard count > 0 else { return 0 }
        // Unsafe: a span over decoded bytes. Safe: they're below `end`, which is within the window.
        output.append(copying: unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: base! + delivered, count: count)))
        delivered &+= count
        return count
    }

    /// The decoded bytes from `start` to `end`.
    @_lifetime(borrow self)
    func bytes(from start: Int, to end: Int) -> RawSpan {
        // Unsafe: a span over window bytes. Safe: callers pass offsets of decoded bytes, within the window, and the
        // span lives no longer than this borrow of it.
        let span = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: base! + start, count: end &- start))
        return unsafe _overrideLifetime(span, borrowing: self)
    }
}

/// A symbol decoded without effect, to learn whether its input is all there: `LzmaDec.c`'s `LzmaDec_TryDummy`.
/// The same bits as `LZMARangeDecoder`'s careful mode, read in the same order, but no probability adapts.
@safe
struct LZMATrial {
    var range: UInt32
    var code: UInt32
    var input: UnsafePointer<UInt8>
    let end: UnsafePointer<UInt8>
    let probabilities: UnsafePointer<UInt16>
    /// Whether the symbol needed a byte past `end`.
    var isShort = false

    /// Whether the symbol at `registers.position` has all its input before `end`.
    ///
    /// - Parameter dictionary: The decoded bytes, for the literal's context and match byte.
    @inline(never)
    static func symbolFits(
        _ registers: LZMARegisters, range: UInt32, code: UInt32, input: UnsafePointer<UInt8>, end: UnsafePointer<UInt8>,
        probabilities: UnsafePointer<UInt16>, dictionary: UnsafePointer<UInt8>, model: LZMAModel
    ) -> Bool {
        typealias P = LZMAProbabilities
        // Unsafe: the trial reads input before `end` only, probabilities at the indices the decoder uses (within
        // the model), and dictionary bytes before the position (`rep0` is at most the position).
        var trial = unsafe LZMATrial(range: range, code: code, input: input, end: end, probabilities: probabilities)
        let position = registers.position
        let state = registers.state
        let positionState = position & model.positionMask
        if trial.bit(P.isMatch &+ state &<< 4 &+ positionState) == 0 {
            let previous = position == 0 ? 0 : Int(unsafe dictionary[position &- 1])
            let context = (position & model.literalPositionMask) &<< model.lc &+ previous &>> (8 &- model.lc)
            let base = P.literal &+ 0x300 &* context
            var symbol = 1
            if state >= 7 {
                var matchByte = Int(unsafe dictionary[position &- registers.rep0])
                repeat {
                    let matchBit = matchByte &>> 7 & 1
                    matchByte &<<= 1
                    let bit = trial.bit(base &+ (1 &+ matchBit) &<< 8 &+ symbol)
                    symbol = symbol &<< 1 | bit
                    if bit != matchBit { break }
                } while symbol < 0x100
            }
            while symbol < 0x100 {
                symbol = symbol &<< 1 | trial.bit(base &+ symbol)
            }
            return !trial.isShort
        }
        if trial.bit(P.isRep &+ state) == 0 {
            let length = trial.length(P.lengthCoder, positionState: positionState)
            let slot = trial.tree(P.posSlot &+ min(length, 3) &<< 6, count: 6)
            if slot >= 4 {
                let count = slot &>> 1 &- 1
                let distance = (2 | slot & 1) &<< count
                if slot < 14 {
                    trial.reverseTree(P.specPos &+ distance &- slot, count: count)
                } else {
                    trial.directBits(count &- 4)
                    trial.reverseTree(P.align, count: 4)
                }
            }
            return !trial.isShort
        }
        if trial.bit(P.isRepG0 &+ state) == 0 {
            if trial.bit(P.isRep0Long &+ state &<< 4 &+ positionState) == 0 { return !trial.isShort }
        } else if trial.bit(P.isRepG1 &+ state) != 0 {
            _ = trial.bit(P.isRepG2 &+ state)
        }
        _ = trial.length(P.repLengthCoder, positionState: positionState)
        return !trial.isShort
    }

    /// Shifts in a byte when the range drops below 2^24; past `end`, notes that the symbol is short.
    mutating func normalize() {
        guard range < 1 << 24 else { return }
        range &<<= 8
        // Unsafe: reads a byte before `end`.
        if unsafe input < end {
            code = code &<< 8 | UInt32(unsafe input.pointee)
            unsafe input += 1
        } else {
            code &<<= 8
            isShort = true
        }
    }

    /// A bit with the probability at `index`.
    mutating func bit(_ index: Int) -> Int {
        // Unsafe: a probability load. Safe: callers pass indices within the model.
        let p = UInt32(unsafe probabilities[index])
        let bound = (range &>> 11) &* p
        let bit: Int
        if code < bound {
            range = bound
            bit = 0
        } else {
            range &-= bound
            code &-= bound
            bit = 1
        }
        normalize()
        return bit
    }

    /// A `count`-bit tree symbol from the tree at `base`.
    mutating func tree(_ base: Int, count: Int) -> Int {
        var node = 1
        for _ in 0..<count {
            node = node &<< 1 | bit(base &+ node)
        }
        return node &- 1 &<< count
    }

    /// A `count`-bit reverse tree's bits (their value isn't needed).
    mutating func reverseTree(_ base: Int, count: Int) {
        var node = 1
        for _ in 0..<count {
            node = node &<< 1 | bit(base &+ node)
        }
    }

    /// `count` bits at one half.
    mutating func directBits(_ count: Int) {
        for _ in 0..<count {
            range &>>= 1
            if code >= range { code &-= range }
            normalize()
        }
    }

    /// A match length less 2, from the length coder at `coder`.
    mutating func length(_ coder: Int, positionState: Int) -> Int {
        if bit(coder) == 0 {
            return tree(coder &+ LZMAProbabilities.lengthLow &+ positionState &<< 3, count: 3)
        }
        if bit(coder &+ 1) == 0 {
            return 8 &+ tree(coder &+ LZMAProbabilities.lengthMiddle &+ positionState &<< 3, count: 3)
        }
        return 16 &+ tree(coder &+ LZMAProbabilities.lengthHigh, count: 8)
    }
}

extension LZMALoop {
    /// The longest match: a streaming decoder stops starting symbols this far before the window's end.
    static var longestMatch: Int { 273 }
    /// Input the careful loop leaves for trials: more than any symbol reads (20 bytes: 22 adaptive bits of at
    /// most 6 bits of range each, and 26 direct bits).
    static var tailMargin: Int { 32 }
}

/// A raw LZMA (LZMA1) decoder that streams: ZIP's method 14 (after its 4-byte header and the 5 property bytes),
/// `.lzma` files after their 13-byte header, entries of any size in bounded memory.
///
/// ```swift
/// var decoder = LZMADecoder()
/// try decoder.reset(properties: LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23), uncompressedSize: size)
/// let progress = try decoder.decompress(compressed, into: &output)   // as much as fits; call again for more
/// ```
///
/// The decoder keeps a dictionary window of its own and copies decoded bytes out of it, so the output can be any
/// size, and the input can be split anywhere: ``decompress(_:into:)`` stops at the start of a symbol whose input
/// isn't all there. The window is allocated when the stream starts, at the dictionary size (or the stream's size, or
/// the size hint, when that's known and smaller) plus room (as large as the dictionary up to
/// `windowRoomLimit`), and kept across ``reset(properties:uncompressedSize:sizeHint:)``s; only the pages the output
/// reaches become resident. The probability model is allocated at creation (and grows once for lc + lp above 4).
///
/// The decode loops are ``LZMA2Decoder``'s, unchanged; decoding streams costs under 1% more instructions than
/// ``LZMA2Decoder/decompressLZMA(_:properties:uncompressedSize:into:)``, which decodes into the caller's whole
/// output.
@safe
public struct LZMADecoder: ~Copyable {
    /// The default ``maximumDictionarySize``: 256 MiB, four times what `xz -9` and 7-Zip's ultra level use.
    public static var defaultMaximumDictionarySize: Int { 1 << 28 }

    /// The most dictionary the window keeps. A stream whose dictionary is larger decodes until its output
    /// outgrows this plus the window's room, then throws ``BytesError/insufficientCapacity`` (a small stream with a
    /// large dictionary in its header decodes).
    public let maximumDictionarySize: Int

    /// The most room the window keeps beyond the dictionary: a slide moves the dictionary to the window's front once
    /// per this much output (at most), so a smaller room saves memory and costs copies. `package` for the benchmarks
    /// that measure the trade; it applies from the next stream.
    package var windowRoomLimit = LZMAWindow.defaultRoomLimit

    private var workspace = LZMAWorkspace(count: LZMAProbabilities.count(lc: 3, lp: 0))
    var window = LZMAWindow()
    private var registers = LZMARegisters()
    private var range: UInt32 = 0xFFFF_FFFF
    private var code: UInt32 = 0
    private var model = LZMAModel(lc: 3, literalPositionMask: 0, positionMask: 3, dictionarySize: 0)
    private var properties: LZMAProperties?
    private var uncompressedSize: Int?
    private var sizeHint: Int?
    private var stage = Stage.idle
    private var failure: BytesError?

    private enum Stage {
        /// No stream yet.
        case idle
        /// Before the range decoder's first five bytes.
        case header
        case symbols
        /// At the stated size: an end marker may follow.
        case sizeReached
        case finished
    }

    /// Why ``decodeSymbols(_:count:consumed:)`` stopped.
    private enum Stop {
        case endMarker, sizeReached, windowFull, needsInput
    }

    /// Creates a decoder, allocating its probability model; ``reset(properties:uncompressedSize:)`` starts a
    /// stream.
    ///
    /// - Parameter maximumDictionarySize: The most dictionary the window may keep.
    public init(maximumDictionarySize: Int = LZMADecoder.defaultMaximumDictionarySize) {
        self.maximumDictionarySize = maximumDictionarySize
    }

    /// Creates a decoder for a stream.
    ///
    /// - Parameters:
    ///   - properties: lc, lp, pb, and the dictionary size, from the container.
    ///   - uncompressedSize: As for ``reset(properties:uncompressedSize:sizeHint:)``.
    ///   - maximumDictionarySize: The most dictionary the window may keep.
    /// - Throws: ``BytesError/invalidValue`` for a negative size.
    public init(
        properties: LZMAProperties, uncompressedSize: Int? = nil,
        maximumDictionarySize: Int = LZMADecoder.defaultMaximumDictionarySize
    ) throws(BytesError) {
        self.maximumDictionarySize = maximumDictionarySize
        try reset(properties: properties, uncompressedSize: uncompressedSize)
    }

    /// Prepares to decode a new stream, discarding output not yet delivered. Keeps the allocations.
    ///
    /// - Parameters:
    ///   - properties: lc, lp, pb, and the dictionary size, from the container.
    ///   - uncompressedSize: The decompressed size, if the container states it: the stream may then end with an
    ///     end marker or without one. With `nil`, it must end with an end marker.
    ///   - sizeHint: The most the stream decodes to, when the container records it but the stream must still end
    ///     with an end marker (a zip entry with general-purpose flag bit 1): the window is made no larger (one an
    ///     earlier stream made larger stays). A stream that outgrows a window smaller than its dictionary throws
    ///     ``BytesError/insufficientCapacity``. Ignored with `uncompressedSize`, which caps the window itself.
    /// - Throws: ``BytesError/invalidValue`` for a negative size.
    public mutating func reset(properties: LZMAProperties, uncompressedSize: Int? = nil, sizeHint: Int? = nil) throws(BytesError) {
        if let uncompressedSize, uncompressedSize < 0 { throw .invalidValue }
        if let sizeHint, sizeHint < 0 { throw .invalidValue }
        self.properties = properties
        self.uncompressedSize = uncompressedSize
        self.sizeHint = sizeHint
        model = LZMAModel(properties: properties)
        workspace.reserve(LZMAProbabilities.count(lc: properties.literalContextBits, lp: properties.literalPositionBits))
        registers = LZMARegisters()
        // Unsafe: the model's memory. Safe: reserved for these properties just above.
        unsafe LZMALoop.resetState(&registers, model, probabilities: workspace.base)
        // A hint leaves the stream's end to its marker, so the window holds the hinted output plus the room a step
        // asks for (64 KiB) and a longest match: symbols start while the position is a longest match from the end.
        let hinted = sizeHint.flatMap { $0 <= 1 << 60 ? $0 &+ (1 << 16) &+ 2 &* LZMALoop.longestMatch : nil }
        window.start(
            dictionarySize: model.dictionarySize, knownSize: uncompressedSize ?? hinted,
            maximumDictionarySize: maximumDictionarySize, minimumRoom: 1 << 18, roomLimit: windowRoomLimit
        )
        range = 0xFFFF_FFFF
        code = 0
        failure = nil
        stage = .header
    }

    /// Starts the same stream again: the last ``reset(properties:uncompressedSize:sizeHint:)``'s properties, size,
    /// and hint. Without one, the decoder stays without a stream.
    public mutating func reset() {
        guard let properties else { return }
        // A size and hint that were accepted once are accepted again.
        try? reset(properties: properties, uncompressedSize: uncompressedSize, sizeHint: sizeHint)
    }

    /// Whether the stream has ended and all its output has been delivered.
    public var isFinished: Bool { stage == .finished && window.delivered == registers.position }

    /// The most unconsumed input a call may need before it can make progress: 20 bytes, the most one symbol
    /// reads.
    public static var maximumUnitByteCount: Int { 20 }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream.
    ///
    /// Input and output can be split anywhere. ``TransformProgress/consumed`` says how much of `input` was used:
    /// the decoder stops at the start of a symbol whose input isn't all there (it needs at most 20 bytes, the
    /// most a symbol reads, to make progress), so pass the rest again, followed by more. Passing the whole rest
    /// of the stream every time works as well. Bytes after the stream's end aren't consumed.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and why it returned: ``TransformStatus/finished`` once the
    ///   stream has ended and all its output is delivered. A stream cut short keeps asking for input.
    /// - Throws: ``BytesError/invalidValue`` for corrupt data, an end marker before the stated size, or no stream
    ///   (``reset(properties:uncompressedSize:)`` was never called); ``BytesError/insufficientCapacity`` for a
    ///   dictionary larger than ``maximumDictionarySize`` once it's needed. After an error, every call throws it
    ///   until the next reset.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        if let failure { throw failure }
        do throws(BytesError) {
            guard input.byteCount > 0 else { return try unsafe step(nil, count: 0, into: &output) }
            return try input.withUnsafeBytes { buffer throws(BytesError) -> TransformProgress in
                // Unsafe: the base address of a nonempty buffer.
                try unsafe step(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: buffer.count, into: &output)
            }
        } catch {
            failure = error
            throw error
        }
    }

    /// The streaming loop over `count` bytes at `input`.
    private mutating func step(
        _ input: UnsafePointer<UInt8>?, count: Int, into output: inout OutputRawSpan
    ) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        // Unsafe: reads of the input below `count`, checked before each; the decode loops' as `decodeSymbols`
        // describes.
        while true {
            produced &+= window.deliver(upTo: registers.position, into: &output)
            guard window.delivered == registers.position else {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            switch stage {
            case .idle:
                throw .invalidValue
            case .finished:
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            case .header:
                guard let input = unsafe input, count &- consumed >= 5 else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                let bytes = unsafe input + consumed
                guard unsafe bytes[0] == 0 else { throw .invalidValue }
                code = unsafe UInt32(bytes[1]) &<< 24 | UInt32(bytes[2]) &<< 16 | UInt32(bytes[3]) &<< 8 | UInt32(bytes[4])
                consumed &+= 5
                stage = .symbols
            case .symbols:
                let remaining = uncompressedSize.map { $0 &- window.discarded &- registers.position }
                if remaining == 0 {
                    stage = .sizeReached
                    continue
                }
                guard let input = unsafe input else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                try window.makeRoom(
                    min(remaining ?? .max, 1 << 16), position: &registers.position, dictionarySize: model.dictionarySize,
                    maximumDictionarySize: maximumDictionarySize
                )
                switch try unsafe decodeSymbols(input, count: count, consumed: &consumed) {
                case .endMarker:
                    if remaining != nil && window.discarded &+ registers.position != uncompressedSize { throw .invalidValue }
                    guard code == 0 else { throw .invalidValue }
                    stage = .finished
                case .sizeReached:
                    stage = .sizeReached
                case .windowFull:
                    break
                case .needsInput:
                    produced &+= window.deliver(upTo: registers.position, into: &output)
                    let status: TransformStatus = window.delivered == registers.position ? .needsInput : .needsOutput
                    return TransformProgress(consumed: consumed, produced: produced, status: status)
                }
            case .sizeReached:
                // The stated size is reached. A finished range decoder ends the stream; otherwise an end marker
                // must follow.
                if code == 0 {
                    stage = .finished
                    continue
                }
                guard let input = unsafe input, unsafe LZMATrial.symbolFits(
                    registers, range: range, code: code, input: input + consumed, end: input + count,
                    // (A stream of size 0 has no window, and reads no dictionary bytes at position 0.)
                    probabilities: workspace.base, dictionary: window.base ?? UnsafeMutablePointer(bitPattern: 64)!, model: model
                ) else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
                var decoder = unsafe LZMARangeDecoder(
                    range: range, code: code, input: input + consumed, end: input + count, probabilities: workspace.base,
                    careful: true
                )
                try LZMALoop.decodeEndMarker(&registers, &decoder, model: model)
                guard decoder.code == 0 else { throw .invalidValue }
                consumed = unsafe decoder.input - input
                stage = .finished
            }
        }
    }

    /// Decodes symbols from `input` (`count` bytes, from `consumed`) into the window: to its end (stopping a
    /// longest match short of it), to the stated size, to an end marker, or to a symbol whose input isn't all
    /// there.
    private mutating func decodeSymbols(_ input: UnsafePointer<UInt8>, count: Int, consumed: inout Int) throws(BytesError) -> Stop {
        typealias Loop = LZMALoop
        // Unsafe: the decode loops' pointers. Safe: the window holds `capacity` bytes and `limit` is within it;
        // the fast loop runs only while more than `inputMargin` bytes of input and `outputMargin` of room remain,
        // the careful loop checks every byte it reads against the input's end (and here, starts symbols only
        // while more than `tailMargin` bytes remain, more than a symbol reads), and below that a symbol is
        // decoded only after a trial shows its input is there. Matches are checked against the position, which
        // counts only bytes in the window.
        let dictionary = unsafe window.base!
        let end = unsafe input + count
        var decoder = unsafe LZMARangeDecoder(
            range: range, code: code, input: input + consumed, end: end, probabilities: workspace.base, careful: true
        )
        let sizeEnd = uncompressedSize.map { $0 &- window.discarded } ?? .max
        let limit = min(window.capacity, sizeEnd)
        let stop = limit == sizeEnd ? limit : limit &- Loop.longestMatch
        var endMarker = false
        while registers.position < stop {
            let available = unsafe end - decoder.input
            if registers.position > 0 && available > Loop.inputMargin && limit &- registers.position > Loop.outputMargin {
                let inputLimit = unsafe end - Loop.inputMargin
                if model.isDefault {
                    endMarker = try unsafe Loop.fastDefault(
                        &registers, &decoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit,
                        dictionarySize: model.dictionarySize, allowsEndMarker: true
                    )
                } else {
                    endMarker = try unsafe Loop.fastGeneral(
                        &registers, &decoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit, model: model,
                        allowsEndMarker: true
                    )
                }
            } else if registers.position > 0 && available > Loop.tailMargin {
                endMarker = try unsafe Loop.careful(
                    &registers, &decoder, dictionary: dictionary, limit: limit, stop: stop,
                    inputLimit: end - Loop.tailMargin, model: model, allowsEndMarker: true, overrun: .invalidValue
                )
            } else {
                guard unsafe LZMATrial.symbolFits(
                    registers, range: decoder.range, code: decoder.code, input: decoder.input, end: end,
                    probabilities: workspace.base, dictionary: dictionary, model: model
                ) else { break }
                // One symbol: the next position is past `stop`.
                endMarker = try unsafe Loop.careful(
                    &registers, &decoder, dictionary: dictionary, limit: limit, stop: registers.position &+ 1,
                    inputLimit: end, model: model, allowsEndMarker: true, overrun: .invalidValue
                )
            }
            if endMarker { break }
        }
        range = decoder.range
        code = decoder.code
        // Never: every symbol's input was there.
        guard unsafe decoder.input <= end else { throw .insufficientData }
        consumed = unsafe decoder.input - input
        if endMarker { return .endMarker }
        if registers.position == sizeEnd { return .sizeReached }
        return registers.position >= stop ? .windowFull : .needsInput
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZMADecoder: @unchecked Sendable {}

extension LZMADecoder: ResettableByteTransform {
    public typealias Failure = BytesError

    /// Decodes as ``decompress(_:into:)`` does. At `.finish`, input that ends inside the stream throws
    /// ``BytesError/insufficientData``.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        let progress = try decompress(input, into: &output)
        if flush == .finish && progress.status == .needsInput {
            throw .insufficientData // The input ended inside the stream.
        }
        return progress
    }
}
