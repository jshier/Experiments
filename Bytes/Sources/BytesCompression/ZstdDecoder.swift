public import Bytes

/// A Zstandard (RFC 8878) decoder, in one call or as input arrives: `.zst` files, zip's method 93, HTTP's
/// `Content-Encoding: zstd`.
///
/// ```swift
/// var decoder = ZstdDecoder()
/// let consumed = try decoder.decompressAll(compressed, into: &output)   // every frame, straight into `output`
///
/// decoder.reset()                                                      // the next stream, in pieces
/// let progress = try decoder.decompress(chunk, into: &output)
/// ```
///
/// Decodes zstd frames (every header form, raw, RLE, and compressed blocks, every literal and sequence
/// coding) and skips skippable frames; a stream may hold several of each, end to end. Content checksums are
/// verified. Frames that need a dictionary (``ZstdFrameHeader/dictionaryID`` not 0) aren't supported.
///
/// ``decompressAll(_:into:)`` decodes into the caller's buffer, which holds the history, so any window size
/// works and nothing is allocated for it. ``decompress(_:into:)`` keeps a window of its own, up to
/// ``maximumWindowSize`` (frames needing more are rejected before anything is allocated), and copies out;
/// input and output can be split anywhere. Allocations are made once: the tables and literal buffer at
/// creation, the window and an input stash when streaming first needs them, growing only for a larger window.
///
/// The decode loops are libzstd's: four Huffman streams decoded together (with double-symbol tables for
/// well-compressed literals), sequences decoded and executed one at a time with 16- and 32-byte wild copies
/// into slack at the end of the output, and every edge (the end of the output, a wrapped window, corrupt
/// data) in out-of-line careful paths. Malformed input throws; it never reads or writes outside the buffers.
/// Single-threaded, it decodes Silesia files 1.1–1.6x as fast as libzstd 1.5.7 on Apple silicon, one call
/// or streamed (Benchmarks/RESULTS.md, 2026-11-18).
@safe
public struct ZstdDecoder: ~Copyable {
    /// The default ``maximumWindowSize``: 128 MB, what `zstd --long` (window log 27) needs, and libzstd's
    /// default limit.
    public static var defaultMaximumWindowSize: Int { 1 << 27 }

    /// The largest window ``decompress(_:into:)`` allocates. Frames needing more throw
    /// ``BytesError/insufficientCapacity``.
    public let maximumWindowSize: Int

    private var blocks = ZstdBlockDecoder()

    // Streaming state.
    private var window = GrowableWorkspace()
    private var stash = GrowableWorkspace()
    /// Bytes of the current unit (header, block, checksum) kept from earlier calls.
    private var stashCount = 0
    private var stage = Stage.frameHeader
    private var frame = FrameState()
    private var history = ZstdHistory(prefixStart: 0)
    private var windowEnd = 0
    private var windowDelivered = 0
    /// Whether a frame has ended since the stream began: the stream may end here.
    private var hasFinishedFrame = false

    private enum Stage {
        case frameHeader
        case skip(remaining: Int)
        case blockHeader
        case block(type: Int, size: Int, isLast: Bool)
        case checksum
    }

    /// What a frame's header said, and its progress.
    private struct FrameState {
        var contentSize: UInt64?
        var produced: UInt64 = 0
        var blockSizeMaximum = 0
        var hasher: XXHash64?
    }

    /// Creates a decoder, allocating its tables and literal buffer.
    ///
    /// - Parameter maximumWindowSize: The largest window streaming decoding may allocate.
    public init(maximumWindowSize: Int = ZstdDecoder.defaultMaximumWindowSize) {
        self.maximumWindowSize = maximumWindowSize
    }

    /// Prepares to decode a new stream, discarding output not yet delivered. Keeps the allocations.
    public mutating func reset() {
        stage = .frameHeader
        stashCount = 0
        windowEnd = 0
        windowDelivered = 0
        hasFinishedFrame = false
    }

    /// Whether the stream is at the end of a frame with all its output delivered: it may end here, or another
    /// frame may follow.
    public var isFinished: Bool {
        guard case .frameHeader = stage else { return false }
        return hasFinishedFrame && stashCount == 0 && windowDelivered == windowEnd
    }

    // MARK: - One call

    /// Decodes every frame in `input`, from the start of a stream, straight into `output`'s free capacity.
    ///
    /// The fastest way to decode: the output is the history, so there's no window and no copying. Every call starts
    /// a new stream: a decoder used before (by any call) starts over as after ``reset()``, keeping its memory.
    ///
    /// - Parameters:
    ///   - input: One or more frames (skippable frames are skipped), and nothing else.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them. Bytes of its free
    ///     capacity past the decompressed ones may be overwritten.
    /// - Returns: The number of input bytes decoded: all of them.
    /// - Throws: ``BytesError/insufficientData`` for a truncated stream; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/invalidValue`` for corrupt data, trailing bytes that aren't a
    ///   frame, or a frame needing a dictionary; ``BytesError/mismatch`` for a wrong checksum or content size.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        reset()
        guard input.byteCount > 0 else { throw .insufficientData }
        return try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            try span.withUnsafeMutableBytes { outputBuffer throws(BytesError) -> Int in
                // Unsafe: the output's base address (a placeholder for an empty output, never written).
                written = try unsafe decodeFrames(
                    input, into: outputBuffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!, capacity: outputBuffer.count
                )
                return input.byteCount
            }
        }
    }

    /// Decodes whole frames from `input` into `output`.
    ///
    /// - Returns: The bytes written.
    private mutating func decodeFrames(
        _ input: RawSpan, into output: UnsafeMutableRawPointer, capacity: Int
    ) throws(BytesError) -> Int {
        var position = 0
        var end = 0
        let count = input.byteCount
        // Headers through checked loads; blocks' bytes passed on as spans' base addresses, and the output's
        // pointer, each bounded by the checks before it.
        repeat {
            guard let header = try ZstdFrameHeader.parse(input.extracting(droppingFirst: position)) else { throw .insufficientData }
            if header.isSkippable {
                let size = Int(header.contentSize ?? 0)
                guard size <= count &- position &- 8 else { throw .insufficientData }
                position &+= 8 &+ size
                continue
            }
            guard header.dictionaryID == 0 else { throw .invalidValue }
            position &+= header.headerSize
            if let contentSize = header.contentSize, contentSize > UInt64(capacity &- end) {
                throw .insufficientCapacity
            }
            blocks.startFrame()
            let frameStart = end
            var hasher = header.hasChecksum ? XXHash64() : nil
            let blockSizeMaximum = header.blockSizeMaximum
            let history = ZstdHistory(prefixStart: frameStart)
            while true {
                guard count &- position >= 3 else { throw .insufficientData }
                let blockHeader = Int(input.load(fromByteOffset: position, as: UInt8.self))
                    | Int(UInt16(littleEndian: input.load(fromByteOffset: position &+ 1, as: UInt16.self))) &<< 8
                position &+= 3
                let size = blockHeader &>> 3
                let produced: Int
                switch (blockHeader &>> 1) & 3 {
                case 0: // Raw.
                    guard size <= blockSizeMaximum else { throw .invalidValue }
                    guard size <= count &- position else { throw .insufficientData }
                    guard size <= capacity &- end else { throw .insufficientCapacity }
                    input.extracting(position..<(position &+ size)).withUnsafeBytes { block in
                        // Unsafe: a copy into the output, which has room for it (checked above).
                        unsafe (output + end).copyMemory(from: block.baseAddress ?? UnsafeRawPointer(output), byteCount: size)
                    }
                    position &+= size
                    produced = size
                case 1: // RLE.
                    guard size <= blockSizeMaximum else { throw .invalidValue }
                    guard count &- position >= 1 else { throw .insufficientData }
                    guard size <= capacity &- end else { throw .insufficientCapacity }
                    let byte = input.load(fromByteOffset: position, as: UInt8.self)
                    // Unsafe: a fill of the output, which has room for it (checked above).
                    unsafe (output + end).initializeMemory(as: UInt8.self, repeating: byte, count: size)
                    position &+= 1
                    produced = size
                case 2: // Compressed.
                    guard size <= count &- position else { throw .insufficientData }
                    let output = unsafe output
                    produced = try input.extracting(position..<(position &+ size)).withUnsafeBytes { block throws(BytesError) in
                        // Unsafe and safe as `decodeCompressedBlock`: the block's `size` bytes (a placeholder, never
                        // read, for an empty one), and the output up to `capacity`.
                        try unsafe blocks.decodeCompressedBlock(
                            block.baseAddress ?? UnsafeRawPointer(output), count: size, into: output, at: end, limit: capacity,
                            history: history, blockSizeMaximum: blockSizeMaximum
                        )
                    }
                    position &+= size
                default:
                    throw .invalidValue
                }
                if hasher != nil {
                    unsafe hasher!.update(output + end, count: produced)
                }
                end &+= produced
                if blockHeader & 1 != 0 { break }
            }
            if let contentSize = header.contentSize, UInt64(end &- frameStart) != contentSize {
                throw .mismatch
            }
            if let hasher {
                guard count &- position >= 4 else { throw .insufficientData }
                let expected = UInt32(littleEndian: input.load(fromByteOffset: position, as: UInt32.self))
                guard UInt32(truncatingIfNeeded: hasher.digest) == expected else { throw .mismatch }
                position &+= 4
            }
        } while position < count
        return end
    }

    // MARK: - Streaming

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream.
    ///
    /// Input and output can be split anywhere. ``TransformProgress/consumed`` says how much of `input` was
    /// used (a partial header, block, or checksum is kept, and consumed); pass the rest again, followed by
    /// more, on the next call. A frame's blocks are decoded whole, into the decoder's window, and delivered
    /// from there as room allows.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and why it returned: ``TransformStatus/finished`` at the end
    ///   of a frame, with all its output delivered and all of `input` consumed (another frame may follow).
    /// - Throws: ``BytesError/invalidValue`` for corrupt data, bytes that aren't a frame, or a frame needing a
    ///   dictionary; ``BytesError/mismatch`` for a wrong checksum or content size;
    ///   ``BytesError/insufficientCapacity`` for a frame whose window exceeds ``maximumWindowSize``.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        guard input.byteCount > 0 else { return try unsafe step(nil, count: 0, into: &output) }
        return try input.withUnsafeBytes { buffer throws(BytesError) -> TransformProgress in
            // Unsafe: the base address of a nonempty buffer.
            try unsafe step(buffer.baseAddress!, count: buffer.count, into: &output)
        }
    }

    /// The streaming loop over `count` bytes at `input`.
    private mutating func step(
        _ input: UnsafeRawPointer?, count: Int, into output: inout OutputRawSpan
    ) throws(BytesError) -> TransformProgress {
        // Unsafe: each unit (a header, a block, a checksum) is read through a pointer `unit` returns only when
        // all its bytes are there, in the input (`position + size <= count`) or in the stash, which holds a
        // block of the largest size and every header; blocks decode into the window as `decodeBlock` describes.
        var position = 0
        var produced = 0
        while true {
            produced &+= deliver(into: &output)
            guard windowDelivered == windowEnd else {
                return TransformProgress(consumed: position, produced: produced, status: .needsOutput)
            }
            switch stage {
            case .frameHeader:
                if stashCount == 0 && position == count {
                    let status: TransformStatus = hasFinishedFrame ? .finished : .needsInput
                    return TransformProgress(consumed: position, produced: produced, status: status)
                }
                guard let prefix = unsafe unit(5, input, count: count, at: &position) else {
                    // Fewer than 5 bytes: they might still be a skippable frame's (8-byte) header, or garbage.
                    try checkStashedPrefix()
                    return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                }
                let size = try unsafe ZstdFrameHeader.size(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: prefix, count: 5)))!
                guard let bytes = unsafe unit(size, input, count: count, at: &position) else {
                    return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                }
                let header = try unsafe ZstdFrameHeader.parse(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: bytes, count: size)))!
                unsafe finishUnit(size, bytes, input, at: &position)
                try startFrame(header)
            case let .skip(remaining):
                let count = min(remaining, count &- position)
                position &+= count
                if count < remaining {
                    stage = .skip(remaining: remaining &- count)
                    return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                }
                hasFinishedFrame = true
                stage = .frameHeader
            case .blockHeader:
                guard let bytes = unsafe unit(3, input, count: count, at: &position) else {
                    return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                }
                let blockHeader = Int(unsafe bytes.load(as: UInt8.self)) | Int(unsafe bytes.load(fromByteOffset: 1, as: UInt8.self)) &<< 8
                    | Int(unsafe bytes.load(fromByteOffset: 2, as: UInt8.self)) &<< 16
                unsafe finishUnit(3, bytes, input, at: &position)
                let type = (blockHeader &>> 1) & 3
                let size = blockHeader &>> 3
                guard type != 3, size <= frame.blockSizeMaximum else { throw .invalidValue }
                stage = .block(type: type, size: size, isLast: blockHeader & 1 != 0)
            case let .block(type, size, isLast):
                let unitSize = type == 1 ? 1 : size
                guard let bytes = unsafe unit(unitSize, input, count: count, at: &position) else {
                    return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                }
                try unsafe decodeBlock(type: type, size: size, bytes)
                unsafe finishUnit(unitSize, bytes, input, at: &position)
                stage = isLast ? .checksum : .blockHeader
            case .checksum:
                if let contentSize = frame.contentSize, frame.produced != contentSize { throw .mismatch }
                if let hasher = frame.hasher {
                    guard let bytes = unsafe unit(4, input, count: count, at: &position) else {
                        return TransformProgress(consumed: position, produced: produced, status: .needsInput)
                    }
                    let expected = UInt32(littleEndian: unsafe bytes.loadUnaligned(as: UInt32.self))
                    guard UInt32(truncatingIfNeeded: hasher.digest) == expected else { throw .mismatch }
                    unsafe finishUnit(4, bytes, input, at: &position)
                }
                hasFinishedFrame = true
                stage = .frameHeader
            }
        }
    }

    /// Sets up for the frame `header` describes: its window, or skipping it.
    private mutating func startFrame(_ header: ZstdFrameHeader) throws(BytesError) {
        hasFinishedFrame = false
        if header.isSkippable {
            stage = .skip(remaining: Int(header.contentSize ?? 0))
            return
        }
        guard header.dictionaryID == 0 else { throw .invalidValue }
        var windowSize = header.windowSize
        if let contentSize = header.contentSize { windowSize = min(windowSize, contentSize) }
        guard windowSize <= UInt64(maximumWindowSize) else { throw .insufficientCapacity }
        let blockSizeMaximum = header.blockSizeMaximum
        // History, a block, and its wild copies' overrun; see `decodeBlock` for why this keeps the window.
        window.reserve(Int(windowSize) &+ blockSizeMaximum &+ 2 &* Zstd.wildCopyOverrun)
        stash.reserve(Zstd.blockSizeMaximum &+ 64)
        blocks.startFrame()
        frame = FrameState(
            contentSize: header.contentSize, blockSizeMaximum: blockSizeMaximum, hasher: header.hasChecksum ? XXHash64() : nil
        )
        history = ZstdHistory(prefixStart: 0, windowSize: Int(windowSize))
        windowEnd = 0
        windowDelivered = 0
        stage = .blockHeader
    }

    /// Decodes a block whose content (or an RLE block's byte) is at `bytes` into the window.
    ///
    /// The window holds `windowSize + blockSizeMaximum + 64` bytes. When the next block and its overrun might
    /// not fit after the current end, decoding starts again at the front, and the segment written so far
    /// becomes the older history: it ended more than `windowSize + 32` bytes in, so matches (at most
    /// `windowSize` back) read it ahead of anything rewritten, wild copies' overrun included.
    private mutating func decodeBlock(type: Int, size: Int, _ bytes: UnsafeRawPointer) throws(BytesError) {
        let capacity = window.byteCount
        if windowEnd &+ frame.blockSizeMaximum &+ Zstd.wildCopyOverrun > capacity {
            history.dictionaryStart = history.prefixStart
            history.dictionaryEnd = windowEnd
            history.prefixStart = 0
            windowEnd = 0
            windowDelivered = 0
        }
        // Unsafe: writes into the window. Safe: a block (at most `blockSizeMaximum`, checked with its header)
        // plus 32 bytes fits after `windowEnd` (ensured above).
        let base = unsafe window.base!
        let produced: Int
        switch type {
        case 0:
            unsafe (base + windowEnd).copyMemory(from: bytes, byteCount: size)
            produced = size
        case 1:
            unsafe (base + windowEnd).initializeMemory(as: UInt8.self, repeating: bytes.load(as: UInt8.self), count: size)
            produced = size
        default:
            do {
                produced = try unsafe blocks.decodeCompressedBlock(
                    bytes, count: size, into: base, at: windowEnd, limit: capacity, history: history,
                    blockSizeMaximum: frame.blockSizeMaximum
                )
            } catch .insufficientCapacity {
                throw .invalidValue // A block larger than the maximum.
            }
        }
        if frame.hasher != nil {
            unsafe frame.hasher!.update(base + windowEnd, count: produced)
        }
        frame.produced &+= UInt64(produced)
        windowEnd &+= produced
    }

    /// Copies undelivered output from the window into `output`, as much as fits.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(windowEnd &- windowDelivered, output.freeCapacity)
        guard count > 0 else { return 0 }
        // Unsafe: a span over delivered-to-be bytes of the window. Safe: they're below `windowEnd`, within it.
        let bytes = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: window.base! + windowDelivered, count: count))
        output.append(copying: bytes)
        windowDelivered &+= count
        return count
    }

    // MARK: Input units

    /// Throws if the bytes kept from earlier calls already show they don't start a frame.
    private func checkStashedPrefix() throws(BytesError) {
        guard stashCount > 0 else { return }
        // Unsafe: a span over the stash's first `stashCount` bytes, which it holds.
        _ = try ZstdFrameHeader.size(unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: stash.base!, count: stashCount)))
    }

    /// The next `size` bytes of the stream, in the input or the stash; `nil` (having stashed what's there,
    /// and consumed it) if they aren't all here yet. Doesn't consume them: ``finishUnit(_:_:_:at:)`` does.
    private mutating func unit(_ size: Int, _ input: UnsafeRawPointer?, count: Int, at position: inout Int) -> UnsafeRawPointer? {
        let available = count &- position
        // Unsafe: pointers into the input (`position <= count`) and stash (sized for any unit), copies of
        // `available` bytes or fewer.
        if stashCount == 0 {
            if available >= size {
                if let start = unsafe input { return unsafe start + position }
                return unsafe UnsafeRawPointer(stash.base!) // An empty unit, with no input.
            }
            stash.reserve(Zstd.blockSizeMaximum &+ 64)
            if available > 0 {
                unsafe stash.base!.copyMemory(from: input! + position, byteCount: available)
            }
            stashCount = available
            position = count
            return nil
        }
        let needed = size &- stashCount
        if needed > 0 {
            let copied = min(needed, available)
            if copied > 0 {
                unsafe (stash.base! + stashCount).copyMemory(from: input! + position, byteCount: copied)
            }
            stashCount &+= copied
            position &+= copied
            if copied < needed { return nil }
        }
        return unsafe UnsafeRawPointer(stash.base!)
    }

    /// Consumes the unit of `size` bytes ``unit(_:_:count:at:)`` returned at `bytes`.
    private mutating func finishUnit(_ size: Int, _ bytes: UnsafeRawPointer, _ input: UnsafeRawPointer?, at position: inout Int) {
        // Unsafe: comparing pointers only.
        if stashCount > 0, unsafe bytes == UnsafeRawPointer(stash.base!) {
            stashCount &-= size
            precondition(stashCount == 0, "A unit left bytes in the stash")
        } else {
            position &+= size
        }
    }
}

extension ZstdDecoder: ByteTransform {
    public typealias Failure = BytesError

    /// Decodes as ``decompress(_:into:)`` does. At `.finish`, input that ends inside a frame throws
    /// ``BytesError/insufficientData``; otherwise the end of a frame reads as ``TransformStatus/needsInput``,
    /// since another may follow.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var progress = try decompress(input, into: &output)
        if flush == .finish {
            if progress.status == .needsInput && progress.consumed == input.byteCount {
                throw .insufficientData // The input ended inside a frame.
            }
        } else if progress.status == .finished {
            progress.status = .needsInput
        }
        return progress
    }
}

extension ZstdDecoder: ResettableByteTransform {}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it: a worker
// can take a decoder to another thread, as `ByteBuffer` can be.
extension ZstdDecoder: @unchecked Sendable {}

extension ZstdDecoder {
    /// Decodes a whole stream into a new array: one or more frames, sized from their headers when they state
    /// their content size, and grown as needed otherwise.
    ///
    /// - Parameters:
    ///   - input: The compressed stream.
    ///   - maximumSize: The most output to allow, to bound memory for untrusted input.
    /// - Returns: The decompressed bytes.
    /// - Throws: As ``decompressAll(_:into:)``; ``BytesError/insufficientCapacity`` if the output would exceed
    ///   `maximumSize`.
    public static func decompress(_ input: RawSpan, maximumSize: Int = .max) throws(BytesError) -> [UInt8] {
        var decoder = ZstdDecoder()
        // A frame that states its size (the common case: one frame) gets exactly that; otherwise guess, and
        // double until it fits.
        var capacity: Int
        if let header = try ZstdFrameHeader.parse(input), !header.isSkippable, let size = header.contentSize {
            guard size <= UInt64(maximumSize) else { throw .insufficientCapacity }
            capacity = Int(size)
        } else {
            capacity = min(max(input.byteCount &* 4, 1 << 16), maximumSize)
        }
        while true {
            var output = [UInt8](repeating: 0, count: capacity)
            do throws(BytesError) {
                let produced = try output.withOutputRawSpan { span throws(BytesError) -> Int in
                    _ = try decoder.decompressAll(input, into: &span)
                    return span.byteCount
                }
                output.removeLast(capacity &- produced)
                return output
            } catch .insufficientCapacity {
                guard capacity < maximumSize else { throw .insufficientCapacity }
                capacity = capacity > maximumSize / 2 ? maximumSize : max(capacity &* 2, 1 << 16)
            }
        }
    }
}
