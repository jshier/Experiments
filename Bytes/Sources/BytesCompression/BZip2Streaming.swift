public import Bytes

// MARK: - Streaming

extension BZip2Decoder {
    /// Prepares to decode a new stream with ``decompress(_:into:)``, discarding output not yet delivered. Keeps
    /// the workspace; allocates nothing.
    public mutating func reset() {
        streaming = BZip2StreamingState()
    }

    /// Whether a stream has ended with all its output delivered: the input may end here, or another stream may
    /// follow.
    public var isFinished: Bool { streaming.stage == .streamHeader && streaming.hasEndedStream }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream (and the
    /// streams that directly follow it, as ``decompressAll(_:decodedSize:into:)`` does).
    ///
    /// Each block is decoded into the decoder's workspace when its symbols have all arrived, then its run-length
    /// coding is undone straight into `output`, stopping wherever `output` fills, in the middle of a run if need
    /// be: memory stays the workspace's whatever the output's size, and a block (up to 900 KB, but runs can expand
    /// it many times over) needn't fit.
    ///
    /// Input can be split anywhere. ``TransformProgress/consumed`` says how much of `input` was used (a
    /// partial byte's bits are remembered); pass the rest again, followed by more, on the next call. The decoder
    /// stops short of the end of `input` only where something isn't all there: at a block's start (its header,
    /// symbol map, selectors, and code lengths, read again from the start when they run past the input), at a
    /// symbol (within 20 bits of the input's end), or at the end marker. So to make progress it needs at most a
    /// block's tables of unconsumed input: a few hundred bytes for most blocks, about 21 KB for the largest
    /// libbzip2 writes (18,002 selectors), 32 KB with the format's most selectors (a corrupt stream's code
    /// lengths can run on without end: it keeps asking for input). Passing the whole rest of the stream on every
    /// call is the fast way: then each block is read once.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time (the first call: the
    ///     stream's `BZh` header).
    ///   - output: Where to append decompressed bytes. Bytes of its free capacity past those reported may be
    ///     overwritten.
    /// - Returns: What was consumed and produced, and why it returned: ``TransformStatus/finished`` at the end
    ///   of a stream, with all its output delivered, when `input` doesn't continue with another stream's header
    ///   (bytes after the end marker, rounded up to a byte, that don't start one aren't consumed; with fewer than
    ///   4 bytes after it, call again with more to continue into a stream that follows);
    ///   ``TransformStatus/needsInput`` when `input` ends inside a stream (truncated input keeps asking, so a
    ///   caller with no more throws ``BytesError/insufficientData``, as ``transform(_:into:flush:)`` does at
    ///   `.finish`); ``TransformStatus/needsOutput`` when `output` is full.
    /// - Throws: ``BytesError/invalidValue`` for a missing header, corrupt data, or a CRC that doesn't match.
    ///   After an error, every call throws ``BytesError/invalidValue`` until ``reset()``.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        let workspace = unsafe workspace.base
        var state = streaming
        do throws(BytesError) {
            let progress = try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (TransformProgress, Int) in
                // Unsafe: the buffers' addresses (a placeholder for an empty one, never accessed: every access is
                // checked against its count first).
                let progress = try unsafe BZip2Stream.step(
                    &state, input, count: count, output: output.assumingMemoryBound(to: UInt8.self), capacity: capacity,
                    workspace: workspace
                )
                return (progress, progress.produced)
            }
            streaming = state
            return progress
        } catch {
            // The workspace may hold part of a block now: nothing more until a reset.
            streaming.stage = .failed
            throw error
        }
    }
}

extension BZip2Decoder: ByteTransform {
    public typealias Failure = BytesError

    /// Decodes as ``decompress(_:into:)`` does. At `.finish`, input that ends inside a stream throws
    /// ``BytesError/insufficientData``; otherwise the end of a stream with all the input consumed reads as
    /// ``TransformStatus/needsInput``, since another may follow.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var progress = try decompress(input, into: &output)
        if flush == .finish {
            if progress.status == .needsInput { throw .insufficientData } // The input ended inside a stream.
        } else if progress.status == .finished && progress.consumed == input.byteCount {
            progress.status = .needsInput
        }
        return progress
    }
}

extension BZip2Decoder: ResettableByteTransform {}

/// Where ``BZip2Decoder/decompress(_:into:)`` is: the stream, the block, and what of the block is decoded or
/// delivered.
struct BZip2StreamingState {
    enum Stage {
        /// At a stream's `BZh` header (byte-aligned): the first, or after a stream's end.
        case streamHeader
        /// At a block's magic, or the end marker's.
        case blockHeader
        /// In a block's symbols: the tables are in the workspace, the symbols so far in ``symbols``.
        case symbols
        /// The block's bytes are in the workspace, its run-length coding undone into outputs as far as
        /// ``expansion``.
        case expanding
        /// An error was thrown.
        case failed
    }

    var stage = Stage.streamHeader
    /// Bits of the next input's first byte already read.
    var bitOffset = 0
    /// Whether a stream's end marker was read, and no stream has started since.
    var hasEndedStream = false
    /// The stream's block size.
    var blockLimit = 0
    var combinedCRC: UInt32 = 0

    // The block's header.
    var storedCRC: UInt32 = 0
    var randomized = false
    var origin = 0
    var header = BZip2BlockHeader(alphabetSize: 0, selectorCount: 0)

    /// The symbols decoded so far (its bit reader's input is the last call's, replaced on every call), the next
    /// selector, and the symbols left in the one before it.
    var symbols: BZip2SymbolState?
    var group = 0
    var groupLeft = 0

    /// The block's length before run-length decoding, how far that has got, and the CRC (unconditioned) of its
    /// output so far.
    var blockLength = 0
    var expansion = BZip2Expansion()
    var crc: UInt32 = 0xFFFF_FFFF
}

extension BZip2Stream {
    /// ``BZip2Decoder/decompress(_:into:)``'s work: from `state`, over `count` bytes of input and `capacity` of
    /// output.
    static func step(
        _ state: inout BZip2StreamingState, _ input: UnsafeRawPointer, count: Int, output: UnsafeMutablePointer<UInt8>,
        capacity: Int, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> TransformProgress {
        // Unsafe: input loads, and the workspace's regions. Safe: loads are checked against `count` (the bit
        // reader adds zeros past it); the regions are within the workspace by their constant offsets; the block
        // passes as `decodeStream` describes, and run-length decoding as `expand` does.
        let block = unsafe (workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt8.self)
        var position = state.bitOffset // In bits.
        var produced = 0
        let status: TransformStatus
        decoding: while true {
            switch state.stage {
            case .expanding:
                let (expansion, end) = try unsafe expandRunsResumably(
                    UnsafePointer(block), count: state.blockLength, from: state.expansion, output: output, at: produced,
                    capacity: capacity
                )
                state.crc = unsafe BZip2CRC.extend(state.crc, output + produced, count: end &- produced)
                state.expansion = expansion
                produced = end
                guard expansion.isDone(count: state.blockLength) else {
                    status = .needsOutput
                    break decoding
                }
                let crc = ~state.crc
                guard crc == state.storedCRC else { throw .invalidValue }
                state.combinedCRC = (state.combinedCRC &<< 1 | state.combinedCRC &>> 31) ^ crc
                state.stage = .blockHeader

            case .streamHeader:
                // Streams start on a byte.
                let start = position &>> 3
                if state.hasEndedStream {
                    guard unsafe startsStream(input, count: count, at: start) else {
                        status = .finished
                        break decoding
                    }
                } else {
                    for index in 0..<min(count &- start, 3) {
                        let expected = UInt8(truncatingIfNeeded: 0x42_5A_68 &>> (16 &- index &* 8))
                        guard unsafe input.load(fromByteOffset: start &+ index, as: UInt8.self) == expected else { throw .invalidValue }
                    }
                    guard count &- start >= 4 else {
                        status = .needsInput
                        break decoding
                    }
                }
                let level = Int(unsafe input.load(fromByteOffset: start &+ 3, as: UInt8.self)) &- 0x30
                guard level >= 1 && level <= 9 else { throw .invalidValue }
                state.blockLimit = level &* 100_000
                state.combinedCRC = 0
                state.hasEndedStream = false
                position &+= 32
                state.stage = .blockHeader

            case .blockHeader:
                // Read again from here on the next call if any of it isn't in the input yet.
                var bits = unsafe BZip2Bits(input, end: count, at: position &>> 3)
                bits.skip(position & 7)
                let magic = bits.read(48)
                if magic == endMagic {
                    let stored = UInt32(truncatingIfNeeded: bits.read(32))
                    guard !bits.isOverrun else {
                        status = .needsInput
                        break decoding
                    }
                    guard stored == state.combinedCRC else { throw .invalidValue }
                    // The next stream starts at the next byte.
                    position = (bits.bitPosition &+ 7) & ~7
                    state.hasEndedStream = true
                    state.stage = .streamHeader
                    continue
                }
                guard magic == blockMagic else {
                    guard bits.isOverrun else { throw .invalidValue }
                    status = .needsInput
                    break decoding
                }
                let storedCRC = UInt32(truncatingIfNeeded: bits.read(32))
                let randomized = bits.read(1) != 0
                let origin = Int(truncatingIfNeeded: bits.read(24))
                let header: BZip2BlockHeader
                do throws(BytesError) {
                    (bits, header) = try unsafe readTables(bits, workspace: workspace)
                } catch {
                    // Errors from bits past the end are the input's end.
                    guard error == .insufficientData else { throw error }
                    status = .needsInput
                    break decoding
                }
                guard !bits.isOverrun else {
                    status = .needsInput
                    break decoding
                }
                state.storedCRC = storedCRC
                state.randomized = randomized
                state.origin = origin
                state.header = header
                state.symbols = unsafe BZip2SymbolState(bits: bits, header: header, workspace: workspace)
                state.group = 0
                state.groupLeft = 0
                position = bits.bitPosition
                state.stage = .symbols

            case .symbols:
                guard var symbols = state.symbols else { throw .invalidValue } // (Always there in this stage.)
                symbols.bits = unsafe BZip2Bits(input, end: count, at: position &>> 3)
                symbols.bits.skip(position & 7)
                let ended: Bool
                (symbols, state.group, state.groupLeft, ended) = try unsafe decodeSymbolsResumably(
                    symbols, group: state.group, left: state.groupLeft, header: state.header, workspace: workspace
                )
                position = symbols.bits.bitPosition
                guard ended else {
                    state.symbols = symbols
                    status = .needsInput
                    break decoding
                }
                state.symbols = nil
                let length = symbols.length
                guard length <= state.blockLimit && state.origin < length else { throw .invalidValue }
                if length >= BZip2Segments.minimumBlock {
                    unsafe linkPadded(workspace, count: symbols.runCount)
                    try unsafe BZip2Segments.walk(workspace, count: length, origin: state.origin)
                } else {
                    unsafe link(workspace, count: symbols.runCount)
                    unsafe walk(workspace, count: length, origin: state.origin)
                }
                if state.randomized { unsafe derandomize(block, count: length) }
                state.blockLength = length
                state.expansion = BZip2Expansion()
                state.crc = 0xFFFF_FFFF
                state.stage = .expanding

            case .failed:
                throw .invalidValue
            }
        }
        state.bitOffset = position & 7
        return TransformProgress(consumed: position &>> 3, produced: produced, status: status)
    }

    /// `decodeSymbols` from where an earlier call stopped (`group` the next selector, `left` symbols left in the
    /// one before it), stopping where the input may not hold a whole symbol: the same loop, with the careful
    /// groups near the input's end resumable.
    ///
    /// - Returns: The state, the next selector, the symbols left in the one before it, and whether the block
    ///   ended.
    @inline(never)
    static func decodeSymbolsResumably(
        _ state: BZip2SymbolState, group: Int, left: Int, header: BZip2BlockHeader, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (BZip2SymbolState, Int, Int, Bool) {
        // Unsafe: the selectors' and tables' addresses, and `BZip2SymbolState`'s accesses, as in `decodeSymbols`;
        // `group - 1` is a selector read before.
        var state = state
        var group = group
        let selectors = unsafe (workspace + BZip2Workspace.selectors).assumingMemoryBound(to: UInt8.self)
        let groups = unsafe workspace + BZip2Workspace.groups
        if left > 0 {
            let table = unsafe UnsafeRawPointer(groups + Int(selectors[group &- 1]) &* BZip2Tables.stride)
            let (resumed, remaining, ended) = try unsafe decodeGroupResumably(state, table: table, count: left)
            if ended || remaining > 0 { return (resumed, group, remaining, ended) }
            state = resumed
        }
        while true {
            guard group < header.selectorCount else { throw .invalidValue }
            let table = unsafe UnsafeRawPointer(groups + Int(selectors[group]) &* BZip2Tables.stride)
            group &+= 1
            if state.bits.end &- state.bits.next >= 160 {
                // As in `decodeSymbols`: every refill's 8 bytes are in the input, loaded a symbol ahead.
                var ended = false
                var word = unsafe state.bits.nextWord()
                for _ in 0..<50 {
                    state.bits.refill(with: word)
                    word = unsafe state.bits.nextWord()
                    if try unsafe state.decode(table) {
                        ended = true
                        break
                    }
                }
                if ended { return (state, group, 0, true) }
            } else {
                let (next, remaining, ended) = try unsafe decodeGroupResumably(state, table: table, count: 50)
                if ended || remaining > 0 { return (next, group, remaining, ended) }
                state = next
            }
        }
    }

    /// Decodes up to `count` symbols of a group near the input's end, stopping before one that may not be all
    /// there: within 20 bits (the longest code) of the end. (A whole stream never stops here: its end marker's
    /// 80 bits follow the last symbol.)
    ///
    /// - Returns: The state, the symbols left (0 when all `count` were decoded or the block ended), and whether
    ///   the block ended.
    @inline(never)
    static func decodeGroupResumably(
        _ state: BZip2SymbolState, table: UnsafeRawPointer, count: Int
    ) throws(BytesError) -> (BZip2SymbolState, Int, Bool) {
        var state = state
        var left = count
        while left > 0 {
            guard state.bits.remainingBits >= maximumCodeLength else { return (state, left, false) }
            state.bits.refill()
            left &-= 1
            // Unsafe: as `decode` says; the refill left at least 56 bits buffered.
            if try unsafe state.decode(table) { return (state, 0, true) }
        }
        return (state, 0, false)
    }
}

extension BZip2Bits {
    /// Skips `bitCount` bits, 0 through 7: those of the first byte an earlier call read.
    @inline(__always)
    mutating func skip(_ bitCount: Int) {
        guard bitCount > 0 else { return }
        refill()
        consume(bitCount)
    }
}
