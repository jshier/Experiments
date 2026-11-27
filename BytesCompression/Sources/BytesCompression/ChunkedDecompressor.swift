public import Bytes

/// A stream decoded a chunk (at most ``chunkSize`` bytes) at a time into one of two buffers it owns, so a consumer can
/// read one buffer's chunk while the next is decoded into the other: the pump between a container's entries and
/// ``Decompressor`` (NativeZip's entries, written to disk while the next chunk decodes).
///
/// ```swift
/// var chunks = ChunkedDecompressor()
/// unsafe chunks.borrowInput(payload)                    // the whole compressed stream, borrowed
/// try chunks.start(.bzip2, decodedSize: size)
/// var target = 0
/// while true {
///     switch try unsafe chunks.nextChunk(into: target) {
///     case let .chunk(bytes, finished):
///         consume(bytes)                                 // valid until the next call into this buffer
///         if finished { break loop }
///         target ^= 1
///     case .needsInput:                                  // only for staged input
///         _ = try chunks.fillInput { decryptNext(into: &$0) } // adding nothing ends the input
///     }
/// }
/// ```
///
/// How a stream decodes depends on what's known:
/// - **Whole:** borrowed input and a decoded size of at most a chunk: one ``Decompressor/decompressAll(_:into:decodedSize:)``
///   into the buffer, no window, the size checked.
/// - **History:** DEFLATE and Deflate64 (``DecompressionFormat/historySize``) decode straight into the buffers, after
///   the last 32 or 64 KB of the previous chunk moved to the buffer's front.
/// - **Stream:** the others, through the format's own window, a chunk at a time.
///
/// Input is either **borrowed** (``borrowInput(_:)``: all of it, in memory the caller keeps valid) or **staged**
/// (``stageInput()``: the caller appends pieces with ``fillInput(_:)`` as the decoder drains them, into a buffer made on
/// first use, ``stagingCapacity(for:)`` bytes; ``nextChunk(into:)`` returns ``Step/needsInput`` when it has consumed
/// them, and continues the same chunk after the caller refills). Staged input is how a container decrypts as it
/// decodes, with no decryption here. A stream's end is final only once the staged input has ended (``fillInput(_:)``
/// added nothing, or ``endInput()``): for formats that concatenate (``DecompressionFormat/allowsConcatenation``), staged
/// bytes that end exactly where one stream does may be followed by another, so that end returns ``Step/needsInput``
/// too. After the input has ended, ``nextChunk(into:)`` finishes the stream or throws ``BytesError/insufficientData``;
/// it never asks for more.
///
/// Its buffers are allocated once (each ``historyCapacity`` + ``chunkSize``; the second's pages are touched only when
/// chunks alternate), and each format's decoder on its first stream. It's `~Copyable` because it owns them.
@safe
public struct ChunkedDecompressor: ~Copyable {
    /// The most output a chunk holds: 1 MiB.
    static var chunkSize: Int { 1 << 20 }
    /// The most history a buffer holds before its chunk: Deflate64's 64 KB window (DEFLATE uses 32 KB of it).
    static var historyCapacity: Int { 64 << 10 }
    /// The staged input's least size: 256 KB, made by the first ``stageInput()``.
    static var minimumStagingCapacity: Int { 256 << 10 }

    /// The staged input's size for streams of `format`: twice the most unconsumed input its decoder may need to make
    /// progress (``DecompressionFormat/maximumUnitByteCount``), and at least 256 KB, which is every format's now (the
    /// largest unit is xz's, a 65,542-byte LZMA2 chunk). ``start(_:decodedSize:)`` grows the buffer to it. Public for
    /// tests that place a stream's end where a fill ends.
    public static func stagingCapacity(for format: DecompressionFormat) -> Int {
        max(minimumStagingCapacity, 2 &* (format.maximumUnitByteCount ?? 0))
    }

    /// What ``nextChunk(into:)`` did.
    @unsafe
    public enum Step {
        /// A chunk of output (without history), in the buffer asked for, valid until the next call into that buffer;
        /// and whether the stream ended with it.
        case chunk(UnsafeRawBufferPointer, finished: Bool)
        /// The staged input is used up mid-chunk: append more (``fillInput(_:)``) and call again with the same buffer.
        case needsInput
    }

    /// How the current stream decodes.
    private enum Mode {
        /// One call straight into the output buffer, no window, checked against the size.
        case whole(size: Int)
        /// Straight into the output buffers, after this much of the last output as history.
        case history(Int)
        /// Through the format's own window, a chunk at a time.
        case stream
    }

    /// Every format's decoder, each format's state made on its first stream.
    private var decompressor = Decompressor()
    /// The two output buffers, each history plus a chunk. Raw allocations rather than arrays because chunks of them
    /// cross tasks and suspensions (a span or an `Array`'s storage can't); freed in `deinit`, never reallocated.
    private let buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)
    /// Borrowed input, and how much of it the decoder has consumed.
    private var input = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    private var consumed = 0
    /// Staged input, made on the first ``stageInput()`` (it grows for a format that needs more).
    private var staging: ByteBuffer?
    private var isStaged = false
    /// No more input will come: always for borrowed input; for staged input, once ``fillInput(_:)`` added nothing or
    /// ``endInput()`` was called.
    private var inputEnded = true
    /// The current stream's format (its end rule: ``DecompressionFormat/endIsFinal(unconsumed:inputEnded:)``).
    private var format: DecompressionFormat?
    /// The open chunk stopped at a stream's end that more input may continue (another gzip member, Zstandard frame, xz
    /// or bzip2 stream): the next call ends it if the input has ended, or decodes on.
    private var atTentativeEnd = false
    /// The input the decoder left at that end, to tell whether any was added since.
    private var unconsumedAtEnd = 0
    private var mode = Mode.stream
    /// Where the last chunk's output ended, and in which buffer: the next chunk's history.
    private var lastBuffer = 0
    private var lastEnd = 0
    /// A chunk left unfinished by ``Step/needsInput``: its buffer (-1: none), its history (history mode), and where its
    /// output ends so far (history mode: from the buffer's start; stream mode: from the chunk's).
    private var openBuffer = -1
    private var openHistory = 0
    private var openEnd = 0

    /// Creates a decompressor and allocates its two buffers (about 2 MB; the second's pages are touched only when
    /// chunks alternate).
    public init() {
        let size = Self.historyCapacity + Self.chunkSize
        unsafe buffers = (.allocate(byteCount: size, alignment: 16), .allocate(byteCount: size, alignment: 16))
    }

    deinit {
        unsafe buffers.0.deallocate()
        unsafe buffers.1.deallocate()
    }

    // MARK: Input

    /// Takes the next stream's compressed bytes: all of `input`, which the caller keeps valid until the stream ends
    /// (or the next ``borrowInput(_:)`` or ``stageInput()``).
    @unsafe
    public mutating func borrowInput(_ input: UnsafeRawBufferPointer) {
        unsafe self.input = input
        consumed = 0
        isStaged = false
        inputEnded = true
    }

    /// Takes the next stream's compressed bytes in pieces, from ``fillInput(_:)``: the staged input starts empty (and is
    /// made, 256 KB, the first time; ``start(_:decodedSize:)`` grows it for a format that needs more).
    public mutating func stageInput() {
        if staging == nil {
            staging = ByteBuffer(capacity: Self.minimumStagingCapacity)
        } else {
            staging!.removeAll()
        }
        isStaged = true
        inputEnded = false
    }

    /// Appends staged input: `body` writes into the free space (after the unconsumed bytes are moved to the front) and
    /// returns how many bytes it wrote. When it writes none, the input has ended (as ``endInput()``): the stream must
    /// finish with what's staged.
    ///
    /// - Returns: The bytes added: 0 when `body` had nothing more.
    /// - Throws: ``BytesError/insufficientCapacity`` when the staged bytes fill the buffer: the decoder holds more
    ///   unconsumed input than the buffer takes, so it can't make progress (no format's unit is that large).
    public mutating func fillInput(_ body: (inout MutableRawSpan) -> Int) throws(BytesError) -> Int {
        precondition(isStaged, "input is staged (stageInput)")
        _ = staging!.compact()
        // Nothing more fits: 0 here would read as the input's end.
        // A `~Copyable` optional: borrowed with `switch` (`staging!` would consume it).
        let full = switch staging {
        case let .some(buffer): buffer.isFull
        case .none: preconditionFailure("Staged input has a staging buffer")
        }
        guard !full else { throw .insufficientCapacity }
        let added = staging!.withFreeCapacity { span, written in
            written = body(&span)
            return written
        }
        if added == 0 { inputEnded = true }
        return added
    }

    /// Says no more staged input will come (what ``fillInput(_:)`` adding nothing says): the stream must finish with
    /// what's staged, or ``nextChunk(into:)`` throws ``BytesError/insufficientData``.
    public mutating func endInput() {
        inputEnded = true
    }

    /// The input the decoder hasn't consumed yet: the rest of the borrowed input, or the staged bytes.
    ///
    /// Unsafe: the bytes outlive any borrow of their owner. Valid until ``consumeInput(_:)``, ``fillInput(_:)``, or the
    /// next decoding call: read them before those.
    @unsafe
    public var pendingInput: UnsafeRawBufferPointer {
        guard isStaged else { return unsafe UnsafeRawBufferPointer(rebasing: input[consumed...]) }
        switch staging {
        case let .some(buffer): return buffer.unread.withUnsafeBytes { unsafe $0 }
        case .none: preconditionFailure("Staged input has a staging buffer")
        }
    }

    /// Marks `count` bytes of ``pendingInput`` consumed: a container header before the stream (ZIP's LZMA properties).
    public mutating func consumeInput(_ count: Int) {
        if isStaged { staging!.consume(count) } else { consumed &+= count }
    }

    /// Frees every format's decoder state and the staged input's buffer, as ``Decompressor/releaseMemory()`` does: for
    /// a decompressor that will sit idle, or after a stream with a large window. Keeps its two chunk buffers. It
    /// discards a stream in progress and any input; set input and call ``start(_:decodedSize:)`` before decoding again.
    public mutating func releaseMemory() {
        decompressor.releaseMemory()
        staging = nil
        isStaged = false
        unsafe input = UnsafeRawBufferPointer(start: nil, count: 0)
        consumed = 0
        inputEnded = true
        format = nil
        atTentativeEnd = false
        mode = .stream
        lastEnd = 0
        openBuffer = -1
    }

    // MARK: Decoding

    /// Starts decoding a stream of `format` from the input (borrowed or staged, set first).
    ///
    /// - Parameters:
    ///   - format: The stream's format.
    ///   - decodedSize: What the container says it decodes to, if it says. With borrowed input and at most a chunk, the
    ///     stream decodes in one call and must decode to exactly this size (``BytesError/mismatch``).
    /// - Throws: ``Decompressor/reset(for:)``'s errors.
    public mutating func start(_ format: DecompressionFormat, decodedSize: Int?) throws(BytesError) {
        try decompressor.reset(for: format)
        self.format = format
        // Grown keeping the staged bytes (a container's header may be among them).
        if isStaged { staging?.reserveCapacity(Self.stagingCapacity(for: format)) }
        atTentativeEnd = false
        lastEnd = 0
        openBuffer = -1
        if !isStaged, let decodedSize, decodedSize <= Self.chunkSize {
            mode = .whole(size: decodedSize)
        } else if let history = format.historySize {
            mode = .history(history)
        } else {
            mode = .stream
        }
    }

    /// Where a chunk goes in buffer `index` (0 or 1): its ``chunkSize`` bytes after the history room. For containers that
    /// fill a chunk themselves (a stored entry decrypted straight into the buffer).
    ///
    /// Unsafe: the decompressor's memory, valid while it lives, written by the next decoding call into this buffer.
    @unsafe
    public func chunkRoom(_ index: Int) -> UnsafeMutableRawBufferPointer {
        unsafe UnsafeMutableRawBufferPointer(rebasing: buffer(index)[..<Self.chunkSize])
    }

    /// Decodes the stream's next chunk into buffer `index` (0 or 1).
    ///
    /// A chunk stays valid until the next call into the same buffer. Decoding into one buffer reads the other's last 32
    /// or 64 KB as history, so a consumer may read one buffer's chunk while the next is decoded into the other (both
    /// only read the first).
    ///
    /// - Returns: The chunk and whether the stream ended; or, with staged input used up mid-chunk,
    ///   ``Step/needsInput`` (call again with the same `index` after ``fillInput(_:)``).
    /// - Throws: The decoder's errors; ``BytesError/insufficientData`` for borrowed input that ends before the stream.
    @unsafe
    public mutating func nextChunk(into index: Int) throws(BytesError) -> Step {
        let output = unsafe buffer(index)
        switch mode {
        case let .whole(size):
            // Unsafe: spans over this decompressor's buffer (all of it: a decoder may write past the content, into free
            // capacity) and the pending input (see `pendingInput`); the output span is finalized before return.
            var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
            _ = try unsafe decompressor.decompressAll(RawSpan(_unsafeBytes: pendingInput), into: &span, decodedSize: size)
            let produced = unsafe span.finalize(for: output)
            return unsafe .chunk(UnsafeRawBufferPointer(rebasing: output[..<produced]), finished: true)
        case let .history(historySize):
            return try unsafe historyStep(into: index, output, historySize: historySize)
        case .stream:
            return try unsafe streamStep(into: index, UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize]))
        }
    }

    /// Whether the decoder's report of a stream's end, with `unconsumed` input left, ends the data (see
    /// ``DecompressionFormat/endIsFinal(unconsumed:inputEnded:)``).
    private func endIsFinal(unconsumed: Int) -> Bool {
        format?.endIsFinal(unconsumed: unconsumed, inputEnded: inputEnded) ?? true
    }

    /// At the start of a call continuing a chunk left at a tentative end: whether the data ended there (the input
    /// has ended since, with nothing more to decode). Otherwise decoding goes on into what was added.
    private mutating func resumesAtFinalEnd() -> Bool {
        guard atTentativeEnd else { return false }
        atTentativeEnd = false
        // Final only if nothing was added since the decoder looked: bytes it hasn't seen may start another stream.
        // Unsafe: only the pending input's count is read.
        return unsafe inputEnded && pendingInput.count == unconsumedAtEnd
    }

    /// Buffer `index`, history room and chunk.
    @unsafe
    private func buffer(_ index: Int) -> UnsafeMutableRawBufferPointer {
        unsafe index == 0 ? buffers.0 : buffers.1
    }

    /// Decodes the next chunk straight into buffer `index`, after the last window of the previous chunk's output,
    /// moved to its front as history (or continues the open chunk).
    @unsafe
    private mutating func historyStep(into index: Int, _ output: UnsafeMutableRawBufferPointer, historySize: Int) throws(BytesError) -> Step {
        let history: Int
        var end: Int
        if openBuffer >= 0 {
            precondition(openBuffer == index, "an unfinished chunk continues in its own buffer")
            history = openHistory
            end = openEnd
        } else {
            history = min(historySize, lastEnd)
            if history > 0 {
                let previous = unsafe buffer(lastBuffer)
                unsafe output.baseAddress!.copyMemory(from: previous.baseAddress! + (lastEnd - history), byteCount: history)
            }
            end = history
        }
        // Unsafe: a span over this decompressor's buffer, allocated for its lifetime; it ends with this call.
        var span = unsafe MutableRawSpan(_unsafeBytes: output)
        var finished = resumesAtFinalEnd()
        while !finished {
            // Unsafe: the pending input, used before it's consumed or refilled (see `pendingInput`).
            let source = unsafe RawSpan(_unsafeBytes: pendingInput)
            let progress = try decompressor.decompress(source, into: &span, historyCount: end)
            consumeInput(progress.consumed)
            end &+= progress.produced
            if progress.status == .needsOutput { break }
            if progress.status == .finished {
                // Unsafe: only the pending input's count is read.
                if endIsFinal(unconsumed: unsafe pendingInput.count) { finished = true; break }
                atTentativeEnd = true
                unconsumedAtEnd = unsafe pendingInput.count // Unsafe: only the count is read.
            } else {
                // Needs input: the caller stages more, or the stream was cut short.
                guard isStaged, !inputEnded else { throw .insufficientData }
            }
            openBuffer = index
            openHistory = history
            openEnd = end
            return unsafe .needsInput
        }
        openBuffer = -1
        lastBuffer = index
        lastEnd = end
        return unsafe .chunk(UnsafeRawBufferPointer(rebasing: output[history..<end]), finished: finished)
    }

    /// Runs the stream's decoder until `output` (a chunk of buffer `index`) is full or the stream ends (or continues the
    /// open chunk).
    @unsafe
    private mutating func streamStep(into index: Int, _ output: UnsafeMutableRawBufferPointer) throws(BytesError) -> Step {
        var start = 0
        if openBuffer >= 0 {
            precondition(openBuffer == index, "an unfinished chunk continues in its own buffer")
            start = openEnd
        }
        // Unsafe: an output span over this decompressor's buffer. Safe: it covers exactly `output`, whose first `start`
        // bytes this stream wrote, and is finalized before the call returns.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: start)
        var finished = resumesAtFinalEnd()
        while !finished, span.freeCapacity > 0 {
            // Unsafe: the pending input, used before it's consumed or refilled (see `pendingInput`).
            let source = unsafe RawSpan(_unsafeBytes: pendingInput)
            let progress = try decompressor.decompress(source, into: &span)
            consumeInput(progress.consumed)
            if progress.status == .needsOutput { break }
            if progress.status == .finished {
                // Unsafe: only the pending input's count is read.
                if endIsFinal(unconsumed: unsafe pendingInput.count) { finished = true; break }
                atTentativeEnd = true
                unconsumedAtEnd = unsafe pendingInput.count // Unsafe: only the count is read.
            } else {
                // Needs input: the caller stages more, or the stream was cut short.
                guard isStaged, !inputEnded else { throw .insufficientData }
            }
            openBuffer = index
            openEnd = unsafe span.finalize(for: output)
            return unsafe .needsInput
        }
        openBuffer = -1
        let produced = unsafe span.finalize(for: output)
        return unsafe .chunk(UnsafeRawBufferPointer(rebasing: output[..<produced]), finished: finished)
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension ChunkedDecompressor: @unchecked Sendable {}
