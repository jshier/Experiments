public import Bytes

/// A Zstandard (RFC 8878) encoder, in one call or as input arrives: `.zst` files, HTTP's `Content-Encoding: zstd`.
///
/// ```swift
/// var encoder = ZstdEncoder(level: 3)                       // allocates its tables once
/// try encoder.compressAll(body, into: &output)               // a whole frame, content size stated
///
/// encoder.reset()                                            // the next frame, in pieces
/// var progress = try encoder.compress(chunk, into: &output)
/// progress = try encoder.compress(lastChunk, into: &output, flush: .finish)
/// ```
///
/// Levels 1 through 4 are libzstd's, with the same parameters and the same match finders, block splitting, and
/// entropy coding decisions (libzstd 1.5.7's `fast` and `dfast` strategies): a frame from ``compressAll(_:into:)`` is
/// byte for byte what `ZSTD_compress2` makes with the same parameters. ``Parameters`` sets them individually.
///
/// Frames stated to be single-segment (their window is their content) are made only when the content's size is known
/// and fits in the configured window, so a frame never needs a larger window than ``Parameters/windowLog`` says: what
/// an HTTP client's 8 MB limit (RFC 9659) requires. ``Parameters/httpWindowLog`` is a window for HTTP bodies.
///
/// Encoding allocates nothing after the first frame of each kind: the tables at creation, and a window for
/// ``compress(_:into:flush:)`` that grows to the configured window plus a block as streams need it. One encoder serves
/// frame after frame (``reset()``): its tables aren't cleared, their old entries are ignored.
@safe
public struct ZstdEncoder: ~Copyable {
    /// Compression parameters, as libzstd's (`ZSTD_c_windowLog`, `ZSTD_c_hashLog`, …).
    public struct Parameters: Hashable, Sendable {
        /// How matches are found.
        public enum Strategy: Int, Hashable, Sendable, CaseIterable {
            /// One hash table, positions skipped faster the longer no match is found (libzstd's `ZSTD_fast`).
            case fast = 1
            /// A hash table of 8-byte sequences and one of short ones (`ZSTD_dfast`).
            case doubleFast = 2
        }

        /// How matches are found.
        public var strategy: Strategy
        /// The window's log2: how far back matches reach, and what a decoder must keep. 10 through 27.
        public var windowLog: Int
        /// The (long) hash table's log2: 6 through 28.
        public var hashLog: Int
        /// The double-fast strategy's short hash table's log2: 6 through 28 (unused by ``Strategy/fast``).
        public var chainLog: Int
        /// The bytes hashed to find a match: 4 through 7 (matches are at least 4 bytes).
        public var minimumMatchLength: Int
        /// The fast strategy's step: positions skipped between searches beyond the first (0 for none).
        public var targetLength: Int

        /// Parameters set one by one.
        public init(strategy: Strategy, windowLog: Int, hashLog: Int, chainLog: Int, minimumMatchLength: Int, targetLength: Int = 0) {
            precondition((10...27).contains(windowLog), "windowLog must be 10 through 27")
            precondition((6...28).contains(hashLog) && (6...28).contains(chainLog), "hashLog and chainLog must be 6 through 28")
            precondition((4...7).contains(minimumMatchLength), "minimumMatchLength must be 4 through 7")
            precondition(targetLength >= 0, "targetLength must not be negative")
            self.strategy = strategy
            self.windowLog = windowLog
            self.hashLog = hashLog
            self.chainLog = chainLog
            self.minimumMatchLength = minimumMatchLength
            self.targetLength = targetLength
        }

        /// libzstd's parameters for `level` (its table for inputs over 256 KB), optionally with a smaller window.
        ///
        /// - Parameters:
        ///   - level: 1 through ``maximumLevel``, or 0 for libzstd's default, 3 (others are clamped to that range).
        ///   - windowLog: The window's log2, if not the level's: smaller for less memory, or for HTTP
        ///     (``httpWindowLog``).
        public init(level: Int, windowLog: Int? = nil) {
            // 0 is libzstd's default level, 3 (it ran as 1).
            switch min(max(level == 0 ? 3 : level, 1), Self.maximumLevel) {
            case 1: self.init(strategy: .fast, windowLog: 19, hashLog: 14, chainLog: 13, minimumMatchLength: 7)
            case 2: self.init(strategy: .fast, windowLog: 20, hashLog: 16, chainLog: 15, minimumMatchLength: 6)
            case 3: self.init(strategy: .doubleFast, windowLog: 21, hashLog: 17, chainLog: 16, minimumMatchLength: 5)
            default: self.init(strategy: .doubleFast, windowLog: 21, hashLog: 18, chainLog: 18, minimumMatchLength: 5)
            }
            if let windowLog {
                precondition((10...27).contains(windowLog), "windowLog must be 10 through 27")
                self.windowLog = windowLog
            }
        }

        /// The highest level: libzstd's 4.
        @inlinable
        public static var maximumLevel: Int { 4 }

        /// A window for HTTP's `zstd` content coding: 512 KB (log 19).
        ///
        /// RFC 9659 requires encoders to keep the window at most 8 MB, decoders to support that much. 512 KB keeps a
        /// level 3 encoder's streaming memory at 2.1 MB (3.7 MB with level 3's own 2 MB window; level 1: 1.4 MB) and
        /// costs bodies smaller than it nothing (their frames are a single
        /// segment, their window their size); on larger bodies, ratios are within a few percent of level 3's 2 MB
        /// window (Benchmarks/RESULTS-zstd-encoder.md).
        @inlinable
        public static var httpWindowLog: Int { 19 }

        /// The window's size in bytes.
        public var windowSize: Int { 1 << windowLog }

        /// The parameters libzstd uses for content of a known size (`ZSTD_adjustCParams_internal`): the window no
        /// larger than the content, the tables no larger than the window needs.
        func adjusted(forContentSize size: Int?) -> Parameters {
            var result = self
            if let size, size <= 1 << 30 {
                let sourceLog = size < 64 ? 6 : Int.bitWidth &- (size &- 1).leadingZeroBitCount
                result.windowLog = min(result.windowLog, sourceLog)
                result.hashLog = min(result.hashLog, result.windowLog &+ 1)
                result.chainLog = min(result.chainLog, result.windowLog)
            }
            result.windowLog = max(result.windowLog, 10)
            return result
        }
    }

    /// The parameters.
    public let parameters: Parameters
    /// Whether frames end with a checksum of their content (the low 32 bits of its XXH64).
    let includesChecksum: Bool

    private var blocks: ZstdBlockEncoder

    /// The match finder's hash multipliers (``ZstdMatchInput/shortMultiplier``): stored, so the match finders get
    /// them as values rather than constants LLVM rebuilds at every use.
    private let shortMultiplier: UInt64
    private let longMultiplier: UInt64

    /// The index of the next byte the encoder will see: indices keep growing across frames, so old table entries
    /// are recognizably old.
    private var nextIndex = 2

    // The frame being written.
    private var frame = FrameState()
    /// Output staged in the block encoder's buffer, not yet delivered: `stagedStart..<stagedEnd`.
    private var stagedStart = 0
    private var stagedEnd = 0

    // Streaming.
    private var window = GrowableWorkspace()
    /// The window's bytes: `0..<windowEnd`; `windowPosition` is the next to compress.
    private var windowEnd = 0
    private var windowPosition = 0
    /// The index of the window's first byte.
    private var windowIndexBase = 0
    /// The content size promised for the next streamed frame.
    private var pledgedContentSize: Int?

    private struct FrameState {
        var started = false
        var finished = false
        /// The frame's parameters, adjusted for its content size when known.
        var parameters: Parameters?
        var contentSize: Int?
        var startIndex = 0
        var isFirstBlock = true
        var lastBlockWritten = false
        /// Bytes saved so far: block splitting needs some (libzstd's `savings`).
        var savings = 0
        var consumed = 0
        /// The checksum's hash, as the content streams in.
        var hasher: XXHash64?
        /// The checksum's hash of content given at once.
        var digest: UInt64?
    }

    /// Creates an encoder for `level`, allocating its tables (see ``memoryUsage``).
    ///
    /// - Parameters:
    ///   - level: libzstd's level: 1 through ``Parameters/maximumLevel``.
    ///   - windowLog: The window's log2, if not the level's (``Parameters/httpWindowLog`` for HTTP).
    ///   - checksum: Whether frames end with a content checksum.
    public init(level: Int = 3, windowLog: Int? = nil, checksum: Bool = false) {
        self.init(parameters: Parameters(level: level, windowLog: windowLog), checksum: checksum)
    }

    /// Creates an encoder with `parameters`, allocating its tables.
    public init(parameters: Parameters, checksum: Bool = false) {
        self.parameters = parameters
        includesChecksum = checksum
        shortMultiplier = ZstdMatchInput.multiplier(forLength: parameters.minimumMatchLength)
        longMultiplier = ZstdMatchInput.multiplier(forLength: 8)
        let blockSizeMaximum = min(Zstd.blockSizeMaximum, parameters.windowSize)
        blocks = ZstdBlockEncoder(
            hashLog: parameters.hashLog, chainLog: parameters.strategy == .doubleFast ? parameters.chainLog : nil,
            blockSizeMaximum: blockSizeMaximum
        )
    }

    /// The bytes the encoder has allocated: its tables and buffers, and the streaming window once a stream has
    /// needed it (at most the window plus a block).
    public var memoryUsage: Int { blocks.layout.size &+ window.byteCount }

    /// The streaming window's largest size: the window and a block.
    private var windowCapacity: Int { parameters.windowSize &+ min(Zstd.blockSizeMaximum, parameters.windowSize) }

    /// An upper bound on the size of a frame ``compressAll(_:into:)`` makes of `byteCount` bytes (libzstd's
    /// `ZSTD_compressBound`): headers, block headers, and a checksum included.
    @inlinable
    public static func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        let margin = byteCount < 128 << 10 ? ((128 << 10) &- byteCount) &>> 11 : 0
        return byteCount &+ (byteCount &>> 8) &+ margin
    }

    /// Prepares to encode a new frame, discarding anything not yet delivered. Keeps the allocations.
    public mutating func reset() {
        reset(contentSize: nil)
    }

    /// Prepares to encode a new frame of `contentSize` bytes with ``compress(_:into:flush:)``: the frame states its
    /// size, and is a single segment when that fits in the window, as ``compressAll(_:into:)``'s frames are.
    ///
    /// - Parameter contentSize: The bytes the frame will hold; ``compress(_:into:flush:)`` throws
    ///   ``BytesError/mismatch`` at the end if it held another number. `nil` for unknown.
    public mutating func reset(contentSize: Int?) {
        frame = FrameState()
        stagedStart = 0
        stagedEnd = 0
        windowEnd = 0
        windowPosition = 0
        pledgedContentSize = contentSize
    }

    // MARK: - One call

    /// Encodes `input` as one whole frame, appending it to `output`, from the start of a new frame.
    ///
    /// Every call starts a new frame: an encoder used before (by any call) starts over as after ``reset()``, keeping
    /// its memory. The frame states its content size; it's a single segment when the content fits in the window. Matches are
    /// searched in `input` itself, nothing is copied but the output. ``maximumCompressedSize(forByteCount:)`` bytes
    /// of free capacity are always enough.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the frame.
    /// - Throws: ``BytesError/insufficientCapacity`` if the frame doesn't fit (`output` then holds part of it).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        reset(contentSize: nil)
        let count = input.byteCount
        startFrame(contentSize: count)
        if includesChecksum { frame.digest = XXHash64.hash(input) }
        try deliverAll(into: &output)
        if count > 0 {
            try input.withUnsafeBytes { buffer throws(BytesError) in
                // The input's base address (nonempty). Blocks read within `count` bytes of it.
                let source = buffer.baseAddress!
                var position = 0
                var base = nextIndex
                // Past this frame's indices however it ends: a frame cut short by a full output left its positions in
                // the tables, and the next frame, starting at the same index, took them for its own (offsets pointing
                // ahead, reads past its input).
                defer { nextIndex = base &+ count }
                while position < count {
                    // Each block straight into the output when it has room for everything the block encoder reserves
                    // (libzstd writes into the caller's buffer too); otherwise staged, then delivered.
                    output.withFreeCapacity { free, written in
                        free.withUnsafeMutableBytes { room in
                            written = unsafe compressBlock(
                                source, indexBase: &base, position: position, end: count, finishing: true,
                                into: room.baseAddress, capacity: room.count
                            )
                        }
                    }
                    position &+= blockAdvance
                    try deliverAll(into: &output)
                }
            }
        }
        finishFrame()
        try deliverAll(into: &output)
    }

    /// The bytes the last ``compressBlock(_:indexBase:position:end:finishing:)`` consumed.
    private var blockAdvance = 0

    /// Moves the next frame's indices to start at `index`: for tests of the correction that keeps them below 3.5 GB,
    /// which would otherwise need gigabytes of input. Call before a frame starts.
    public mutating func setNextIndex(_ index: Int) {
        nextIndex = index
    }

    /// Delivers all staged output, or throws if it doesn't fit.
    private mutating func deliverAll(into output: inout OutputRawSpan) throws(BytesError) {
        _ = deliver(into: &output)
        guard stagedStart == stagedEnd else { throw .insufficientCapacity }
    }

    /// Copies staged output into `output`, as much as fits.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(stagedEnd &- stagedStart, output.freeCapacity)
        guard count > 0 else { return 0 }
        // Unsafe: a span over staged bytes, `stagedStart..<stagedEnd` of the staging buffer.
        let bytes = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: blocks.stagingPointer + stagedStart, count: count))
        output.append(copying: bytes)
        stagedStart &+= count
        if stagedStart == stagedEnd {
            stagedStart = 0
            stagedEnd = 0
        }
        return count
    }

    // MARK: - Streaming

    /// Encodes as much of `input` as it can, appending to `output`, continuing the current frame.
    ///
    /// Input is copied into the encoder's window and compressed a block at a time, so
    /// ``TransformProgress/consumed`` falls short of `input` only when the output is full (`needsOutput`): pass the
    /// rest again. Keep calling with the same `flush` until the status is `needsInput` (or `finished`, for
    /// ``TransformFlush/finish``).
    ///
    /// A frame whose first call is `.finish` (a whole body at once) states its content size, as
    /// ``compressAll(_:into:)``'s do, and comes out the same; so does one after ``reset(contentSize:)``.
    ///
    /// - Parameters:
    ///   - input: The next bytes to compress.
    ///   - output: Where to append compressed bytes.
    ///   - flush: `.flush` ends a block with what's buffered, so a decoder can produce everything so far; `.finish`
    ///     ends the frame (a frame with no input is still a valid, empty frame).
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError/mismatch`` if the frame ends with another size than ``reset(contentSize:)`` promised.
    public mutating func compress(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush = .none
    ) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        if !frame.started {
            let contentSize = pledgedContentSize ?? (flush == .finish ? input.byteCount : nil)
            startFrame(contentSize: contentSize)
            if includesChecksum { frame.hasher = XXHash64() }
            window.reserve(min(windowCapacity, max(contentSize ?? 0, 64 << 10)), zeroed: false)
            windowIndexBase = nextIndex
        }
        while true {
            produced &+= deliver(into: &output)
            if stagedStart != stagedEnd {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            if frame.finished {
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            }
            let blockSizeMaximum = frameBlockSizeMaximum
            let pending = windowEnd &- windowPosition
            if consumed < input.byteCount {
                if pending >= blockSizeMaximum {
                    compressWindowBlock(finishing: false)
                    continue
                }
                if windowEnd == window.byteCount {
                    makeRoom()
                    continue
                }
                let count = min(window.byteCount &- windowEnd, input.byteCount &- consumed)
                let bytes = input.extracting(consumed..<(consumed &+ count))
                if frame.hasher != nil { frame.hasher!.update(bytes) }
                let destination = unsafe window.base! + windowEnd
                bytes.withUnsafeBytes { buffer in
                    // Unsafe: a copy into the window's free room, `count` bytes after `windowEnd` (within its size).
                    unsafe destination.copyMemory(from: buffer.baseAddress!, byteCount: count)
                }
                windowEnd &+= count
                consumed &+= count
                frame.consumed &+= count
                continue
            }
            switch flush {
            case .none:
                if pending >= blockSizeMaximum {
                    compressWindowBlock(finishing: false)
                    continue
                }
                return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
            case .flush:
                if pending > 0 {
                    compressWindowBlock(finishing: false, flushing: true)
                    continue
                }
                return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
            case .finish:
                if pending > 0 {
                    compressWindowBlock(finishing: true)
                    continue
                }
                if let size = frame.contentSize, size != frame.consumed { throw .mismatch }
                finishFrame()
            }
        }
    }

    /// The frame's largest block: 128 KB, or the window if smaller.
    private var frameBlockSizeMaximum: Int {
        min(Zstd.blockSizeMaximum, frame.parameters!.windowSize)
    }

    /// Compresses the next block of the window.
    private mutating func compressWindowBlock(finishing: Bool, flushing: Bool = false) {
        // Unsafe: the window's memory, `0..<windowEnd` holding bytes.
        var base = windowIndexBase
        let end = finishing || flushing ? windowEnd : windowPosition &+ frameBlockSizeMaximum
        unsafe compressBlock(UnsafeRawPointer(window.base!), indexBase: &base, position: windowPosition, end: end, finishing: finishing)
        windowIndexBase = base
        windowPosition &+= blockAdvance
        nextIndex = windowIndexBase &+ windowEnd
    }

    /// Grows the window, or slides its history to the front.
    private mutating func makeRoom() {
        if window.byteCount < windowCapacity {
            window.grow(to: min(windowCapacity, window.byteCount &* 2), preserving: windowEnd, zeroed: false)
            return
        }
        let keep = min(windowPosition, frame.parameters!.windowSize)
        let shift = windowPosition &- keep
        precondition(shift > 0, "the window holds a window and a block")
        // Unsafe: a move within the window, `shift..<windowEnd` to the front.
        unsafe window.base!.copyMemory(from: window.base! + shift, byteCount: windowEnd &- shift)
        windowEnd &-= shift
        windowPosition &-= shift
        windowIndexBase &+= shift
    }

    // MARK: - Frames

    /// Starts a frame: its parameters, its header staged.
    private mutating func startFrame(contentSize: Int?) {
        let frameParameters = parameters.adjusted(forContentSize: contentSize)
        frame.started = true
        frame.parameters = frameParameters
        frame.contentSize = contentSize
        frame.startIndex = nextIndex
        blocks.startFrame()
        // Unsafe: a span over the header's room: 18 bytes at `stagedEnd` (always 0 here: a frame starts with nothing
        // staged), within the staging buffer's `blockSizeMaximum + 512`; the largest header is 14 bytes. Its stores
        // are checked.
        var output = unsafe MutableRawSpan(_unsafeStart: blocks.stagingPointer + stagedEnd, byteCount: 18)
        let windowSize = frameParameters.windowSize
        let singleSegment = contentSize.map { windowSize >= $0 } ?? false
        var sizeCode = 0
        if let contentSize {
            sizeCode = (contentSize >= 256 ? 1 : 0) &+ (contentSize >= 65536 &+ 256 ? 1 : 0) &+ (contentSize >= 0xFFFF_FFFF ? 1 : 0)
        }
        output.storeBytes(of: Zstd.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
        let descriptor = (includesChecksum ? 1 : 0) &<< 2 | (singleSegment ? 1 : 0) &<< 5 | sizeCode &<< 6
        output.storeBytes(of: UInt8(truncatingIfNeeded: descriptor), toByteOffset: 4, as: UInt8.self)
        var position = 5
        if !singleSegment {
            output.storeBytes(of: UInt8(truncatingIfNeeded: (frameParameters.windowLog &- 10) &<< 3), toByteOffset: position, as: UInt8.self)
            position &+= 1
        }
        if let contentSize {
            switch sizeCode {
            case 0:
                if singleSegment {
                    output.storeBytes(of: UInt8(truncatingIfNeeded: contentSize), toByteOffset: position, as: UInt8.self)
                    position &+= 1
                }
            case 1:
                output.storeBytes(of: UInt16(truncatingIfNeeded: contentSize &- 256).littleEndian, toByteOffset: position, as: UInt16.self)
                position &+= 2
            case 2:
                output.storeBytes(of: UInt32(truncatingIfNeeded: contentSize).littleEndian, toByteOffset: position, as: UInt32.self)
                position &+= 4
            default:
                output.storeBytes(of: UInt64(contentSize).littleEndian, toByteOffset: position, as: UInt64.self)
                position &+= 8
            }
        }
        stagedEnd &+= position
    }

    /// Ends the frame: an empty last block if none was marked last, and the checksum.
    private mutating func finishFrame() {
        // Unsafe: a span over 7 bytes after what's staged, within the staging buffer's slack; its stores are checked.
        var output = unsafe MutableRawSpan(_unsafeStart: blocks.stagingPointer + stagedEnd, byteCount: 7)
        var position = 0
        if !frame.lastBlockWritten {
            output.storeBytes(of: UInt16(1).littleEndian, toByteOffset: 0, as: UInt16.self)
            output.storeBytes(of: UInt8(0), toByteOffset: 2, as: UInt8.self)
            position = 3
        }
        if let digest = frame.digest ?? frame.hasher?.digest {
            output.storeBytes(of: UInt32(truncatingIfNeeded: digest).littleEndian, toByteOffset: position, as: UInt32.self)
            position &+= 4
        }
        stagedEnd &+= position
        frame.finished = true
    }

    // MARK: - Blocks

    /// Compresses the next block of `position..<end` in `source` (whose first byte has index `indexBase`) into
    /// `destination`, or stages it; ``blockAdvance`` says how many bytes it took (`ZSTD_compress_frameChunk`'s loop
    /// body, then `ZSTD_compressBlock_internal`).
    ///
    /// - Parameters:
    ///   - finishing: Whether `end` is the frame's end: the block that reaches it is the last.
    ///   - destination: Where to write the block if `capacity` holds it stored raw, with the bit writers' 8 bytes of
    ///     slack; else (or `nil`) it's staged.
    /// - Returns: The bytes written at `destination` (0 when staged).
    @discardableResult
    private mutating func compressBlock(
        _ source: UnsafeRawPointer, indexBase: inout Int, position: Int, end: Int, finishing: Bool,
        into destination: UnsafeMutableRawPointer? = nil, capacity destinationCapacity: Int = 0
    ) -> Int {
        let frameParameters = frame.parameters!
        let strategy = frameParameters.strategy.rawValue
        let blockSizeMaximum = frameBlockSizeMaximum
        // Unsafe: the source from `position` to `end`, which the caller vouches for, and the workspace's regions.
        let size = unsafe ZstdBlockSplitter.blockSize(
            source + position, remaining: end &- position, blockSizeMaximum: blockSizeMaximum, strategy: strategy,
            savings: frame.savings, scratch: blocks.workspace.pointer(blocks.layout.splitScratch)
        )
        let isLast = finishing && position &+ size == end
        let blockEnd = position &+ size
        correctIndices(&indexBase, blockEnd: blockEnd)

        // The block goes to the destination when it holds every room `entropyCompress` reserves before writing (so its
        // decisions are those the staging buffer's room gives, and the frame is the same): the header (3), raw
        // literals (`size` and a 3-byte header), the sequences' count (4) and modes (1), three table descriptions'
        // worst case (`descriptionBound`, 80 each), and a bit writer's 9. Otherwise to the staging buffer, after what's
        // staged. (With only the raw form's room, a 33-byte block was stored raw where libzstd compresses it.)
        let room = 3 &+ size &+ 3 &+ 4 &+ 1 &+ 3 &* ZstdFSEEncoding.descriptionBound &+ 9
        // Unsafe: a comparison of the optional pointer with `nil`.
        let direct = unsafe destination != nil && destinationCapacity >= room
        // Unsafe: the destination's free room (`destinationCapacity` bytes, the caller's), or the staging buffer.
        let staging = unsafe direct ? destination.unsafelyUnwrapped : blocks.stagingPointer
        let headerPosition = direct ? 0 : stagedEnd
        let contentPosition = headerPosition &+ 3
        var compressedSize = 0
        // Blocks under 7 bytes aren't worth compressing (`ZSTD_buildSeqStore`).
        if size >= 7 {
            let windowSize = frameParameters.windowSize
            let frameStart = frame.startIndex &- indexBase
            let prefixStart = max(frameStart, blockEnd &- windowSize, 0)
            let input = unsafe ZstdMatchInput(
                source: source, indexBase: indexBase, start: position, end: blockEnd, prefixStart: prefixStart,
                frameStart: frameStart, windowSize: windowSize, shortMultiplier: shortMultiplier, longMultiplier: longMultiplier
            )
            var store = blocks.sequenceStore()
            blocks.next.repeats = blocks.previous.repeats
            var repeats: ZstdRepeats = (blocks.next.repeats.0, blocks.next.repeats.1)
            let lastLiterals = findMatches(input, parameters: frameParameters, store: &store, repeats: &repeats)
            blocks.next.repeats.0 = repeats.0
            blocks.next.repeats.1 = repeats.1
            if store.isEmpty {
                // No sequences: the literals are the block's bytes, read where they are (an incompressible block's
                // 128 KB copied once less).
                // Unsafe: a pointer to the block's bytes as the literals, only read (by the entropy coders, within
                // `lastLiterals`, the block's size).
                store = unsafe ZstdSequenceStore(sequences: store.sequences, literals: UnsafeMutableRawPointer(mutating: source + position))
                store.literalCount = lastLiterals
            } else {
                store.copyLastLiterals(input, anchor: input.end &- lastLiterals, count: lastLiterals)
            }
            // The content's room: the destination's less the header (as libzstd's, the caller's buffer's), or the
            // staging buffer's less what's before it and a checksum after.
            let capacity = direct ? destinationCapacity &- 3 : blocks.layout.stagingCapacity &- contentPosition &- 4
            compressedSize = unsafe blocks.entropyCompress(
                store, blockSize: size, into: staging + contentPosition, capacity: capacity, strategy: strategy,
                compressesLiterals: frameParameters.strategy != .fast || frameParameters.targetLength == 0
            )
            // A run, if the block is one and its compressed form is short or none (not as a frame's first block:
            // zstd 1.4.3 and older reject that).
            // Unsafe: the block's bytes.
            if !frame.isFirstBlock && compressedSize < 25 && (unsafe Self.isRun(source + position, count: size)) {
                compressedSize = -1
            }
        }
        let header: Int
        switch compressedSize {
        case 0:
            // Raw.
            unsafe (staging + contentPosition).copyMemory(from: source + position, byteCount: size)
            header = (isLast ? 1 : 0) | size &<< 3
            compressedSize = size
        case -1:
            unsafe staging.storeBytes(of: source.load(fromByteOffset: position, as: UInt8.self), toByteOffset: contentPosition, as: UInt8.self)
            header = (isLast ? 1 : 0) | 1 &<< 1 | size &<< 3
            compressedSize = 1
        default:
            blocks.confirm()
            header = (isLast ? 1 : 0) | 2 &<< 1 | compressedSize &<< 3
        }
        unsafe staging.storeBytes(of: UInt16(truncatingIfNeeded: header).littleEndian, toByteOffset: headerPosition, as: UInt16.self)
        unsafe staging.storeBytes(of: UInt8(truncatingIfNeeded: header &>> 16), toByteOffset: headerPosition &+ 2, as: UInt8.self)
        frame.savings &+= size &- (compressedSize &+ 3)
        frame.isFirstBlock = false
        if isLast { frame.lastBlockWritten = true }
        blockAdvance = size
        if direct { return contentPosition &+ compressedSize }
        stagedEnd = contentPosition &+ compressedSize
        return 0
    }

    /// Runs the strategy's match finder, its copy for the hash length.
    @inline(__always)
    private func findMatches(
        _ input: ZstdMatchInput, parameters: Parameters, store: inout ZstdSequenceStore, repeats: inout ZstdRepeats
    ) -> Int {
        // Unsafe: the workspace's tables, sized for the encoder's (unadjusted) logs, which the frame's don't exceed.
        let table = unsafe blocks.workspace.pointer(blocks.layout.hashTable).assumingMemoryBound(to: UInt32.self)
        let hashLog = parameters.hashLog
        switch parameters.strategy {
        case .fast:
            let target = parameters.targetLength
            if parameters.windowLog < 19 {
                switch parameters.minimumMatchLength {
                case 5: return unsafe ZstdMatchFinder.fastSelect5(input, table, hashLog, target, &store, &repeats)
                case 6: return unsafe ZstdMatchFinder.fastSelect6(input, table, hashLog, target, &store, &repeats)
                case 7: return unsafe ZstdMatchFinder.fastSelect7(input, table, hashLog, target, &store, &repeats)
                default: return unsafe ZstdMatchFinder.fastSelect4(input, table, hashLog, target, &store, &repeats)
                }
            }
            switch parameters.minimumMatchLength {
            case 5: return unsafe ZstdMatchFinder.fast5(input, table, hashLog, target, &store, &repeats)
            case 6: return unsafe ZstdMatchFinder.fast6(input, table, hashLog, target, &store, &repeats)
            case 7: return unsafe ZstdMatchFinder.fast7(input, table, hashLog, target, &store, &repeats)
            default: return unsafe ZstdMatchFinder.fast4(input, table, hashLog, target, &store, &repeats)
            }
        case .doubleFast:
            let short = unsafe blocks.workspace.pointer(blocks.layout.chainTable).assumingMemoryBound(to: UInt32.self)
            let chainLog = parameters.chainLog
            switch parameters.minimumMatchLength {
            case 5: return unsafe ZstdMatchFinder.doubleFast5(input, table, hashLog, short, chainLog, &store, &repeats)
            case 6: return unsafe ZstdMatchFinder.doubleFast6(input, table, hashLog, short, chainLog, &store, &repeats)
            case 7: return unsafe ZstdMatchFinder.doubleFast7(input, table, hashLog, short, chainLog, &store, &repeats)
            default: return unsafe ZstdMatchFinder.doubleFast4(input, table, hashLog, short, chainLog, &store, &repeats)
            }
        }
    }

    /// Whether the `count` bytes at `source` are all the same (`ZSTD_isRLE`).
    private static func isRun(_ source: UnsafeRawPointer, count: Int) -> Bool {
        // Unsafe: loads below `count`.
        let first = unsafe source.load(as: UInt8.self)
        let pattern = UInt64(first) &* 0x0101_0101_0101_0101
        var index = 0
        while index &+ 8 <= count {
            if unsafe source.loadUnaligned(fromByteOffset: index, as: UInt64.self) != pattern { return false }
            index &+= 8
        }
        while index < count {
            if unsafe source.load(fromByteOffset: index, as: UInt8.self) != first { return false }
            index &+= 1
        }
        return true
    }

    /// Keeps indices below libzstd's limit (`ZSTD_CURRENT_MAX`, 3,500 MB): when the block would end past it, every
    /// index moves down so the window's start becomes small, and older entries become 0 (`ZSTD_reduceIndex`).
    private mutating func correctIndices(_ indexBase: inout Int, blockEnd: Int) {
        let limit = 3500 << 20
        guard indexBase &+ blockEnd > limit else { return }
        let windowSize = frame.parameters!.windowSize
        // The lowest index the next blocks can use, moved to 2.
        let lowest = max(indexBase &+ blockEnd &- windowSize &- (Zstd.blockSizeMaximum &* 2), 2)
        let correction = lowest &- 2
        guard correction > 0 else { return }
        let reduction = UInt32(truncatingIfNeeded: correction)
        // Unsafe: every entry of the tables, within their sizes.
        let tables = [(blocks.layout.hashTable, parameters.hashLog)]
            + (parameters.strategy == .doubleFast ? [(blocks.layout.chainTable, parameters.chainLog)] : [])
        for (offset, log) in tables {
            let table = unsafe blocks.workspace.pointer(offset).assumingMemoryBound(to: UInt32.self)
            for index in 0..<(1 &<< log) {
                let entry = unsafe table[index]
                unsafe table[index] = entry < reduction ? 0 : entry &- reduction
            }
        }
        indexBase &-= correction
        frame.startIndex = frame.startIndex > correction ? frame.startIndex &- correction : 1
    }
}
