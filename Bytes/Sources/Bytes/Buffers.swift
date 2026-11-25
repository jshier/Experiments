// Moving bytes between spans and buffers without unsafe code in the caller: copies into a span or an output
// span, a span over an output's free capacity, an output span over an existing array, and a buffer that
// fills at its end and drains from its front.
//
// The standard library (Swift 6.4) has no safe copy from a `RawSpan` into a `MutableRawSpan` or an
// `OutputRawSpan`, and no safe access to an output span's free capacity, so every codec, pipeline stage, and
// socket buffer here wrote its own `withUnsafeMutableBytes` and `copyMemory`. These do it once, checked.

// MARK: - Copying into spans

public extension MutableRawSpan {
    /// Copies all of `source` into these bytes, starting at `offset`.
    ///
    /// ```swift
    /// var span = window.mutableSpan
    /// span.copyBytes(from: input.extracting(consumed..<(consumed + count)), toByteOffset: windowEnd)
    /// ```
    ///
    /// Short copies (up to 64 bytes) are inline loads and stores, longer ones `memmove`, as
    /// ``GenericBytesWriter/write(_:)-(RawSpan)`` does.
    ///
    /// - Parameters:
    ///   - source: The bytes to copy.
    ///   - offset: Where the copy starts.
    /// - Precondition: `offset` is 0 or more, and `source` fits from there.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func copyBytes(from source: RawSpan, toByteOffset offset: Int) {
        precondition(offset >= 0 && source.byteCount <= byteCount &- offset, "Copying past the end of a span")
        // Unsafe: unchecked stores. Safe: the precondition covers `offset ..< offset + source.byteCount`.
        unsafe BytesWriter._copyBytes(source, to: &self, at: offset)
    }

    /// Copies the bytes in `range` to `offset`, within these bytes. The two ranges may overlap: moving a
    /// buffer's unread bytes to its front, or a window's history.
    ///
    /// ```swift
    /// span.copyBytes(within: (windowEnd - history)..<windowEnd, toByteOffset: 0)
    /// ```
    ///
    /// - Parameters:
    ///   - range: The bytes to copy.
    ///   - offset: Where the copy starts.
    /// - Precondition: `range` is within the span, and `range.count` bytes fit from `offset`.
    @inlinable
    @_lifetime(self: copy self)
    mutating func copyBytes(within range: Range<Int>, toByteOffset offset: Int) {
        precondition(range.lowerBound >= 0 && range.upperBound <= byteCount, "Copying from outside a span")
        precondition(offset >= 0 && range.count <= byteCount &- offset, "Copying past the end of a span")
        guard !range.isEmpty else { return }
        // Unsafe: `memmove` within the span. Safe: both ranges are inside it (checked above), and `copyMemory`
        // allows them to overlap.
        withUnsafeMutableBytes { buffer in
            unsafe buffer.baseAddress!.advanced(by: offset)
                .copyMemory(from: buffer.baseAddress!.advanced(by: range.lowerBound), byteCount: range.count)
        }
    }
}

public extension MutableSpan where Element == UInt8 {
    /// Copies all of `source` into these bytes, starting at `offset`: as
    /// ``Swift/MutableRawSpan/copyBytes(from:toByteOffset:)``, for an array's or a `UniqueArray`'s
    /// `mutableSpan`.
    ///
    /// - Parameters:
    ///   - source: The bytes to copy.
    ///   - offset: Where the copy starts.
    /// - Precondition: `offset` is 0 or more, and `source` fits from there.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func copyBytes(from source: RawSpan, toByteOffset offset: Int) {
        var bytes = MutableRawSpan(mutating: &self)
        bytes.copyBytes(from: source, toByteOffset: offset)
    }

    /// Copies the bytes in `range` to `offset`, within these bytes; the ranges may overlap. As
    /// ``Swift/MutableRawSpan/copyBytes(within:toByteOffset:)``.
    ///
    /// - Parameters:
    ///   - range: The bytes to copy.
    ///   - offset: Where the copy starts.
    /// - Precondition: `range` is within the span, and `range.count` bytes fit from `offset`.
    @inlinable
    @_lifetime(self: copy self)
    mutating func copyBytes(within range: Range<Int>, toByteOffset offset: Int) {
        var bytes = MutableRawSpan(mutating: &self)
        bytes.copyBytes(within: range, toByteOffset: offset)
    }
}

// MARK: - Output spans

public extension OutputRawSpan {
    /// Appends all of `bytes`.
    ///
    /// ```swift
    /// let count = min(pending.byteCount, output.freeCapacity)
    /// output.append(copying: pending.extracting(0..<count))
    /// ```
    ///
    /// Short copies (up to 64 bytes) are inline loads and stores, longer ones `memmove`.
    ///
    /// - Parameter bytes: The bytes to append.
    /// - Precondition: `bytes` fits the free capacity.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func append(copying bytes: RawSpan) {
        precondition(bytes.byteCount <= freeCapacity, "Appending more bytes than an output span has room for")
        // Unsafe: a span over the free capacity, which no safe API exposes, and unchecked stores into it. Safe:
        // the span covers exactly the free capacity and ends with the closure, `bytes` fits it (checked above),
        // and exactly its bytes are counted as initialized.
        unsafe withUnsafeMutableBytes { buffer, initializedCount in
            var free = unsafe MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...]))
            unsafe BytesWriter._copyBytes(bytes, to: &free, at: 0)
            initializedCount &+= bytes.byteCount
        }
    }

    /// Appends all of `bytes`.
    ///
    /// - Parameter bytes: The bytes to append.
    /// - Precondition: `bytes` fits the free capacity.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func append(copying bytes: Span<UInt8>) {
        append(copying: bytes.bytes)
    }

    /// Runs `body` with a span over the free capacity (or its first `byteCount` bytes), then appends the
    /// bytes `body` reports writing at the span's start: for code that writes through a `MutableRawSpan`, such
    /// as a decoder writing at its own offsets, or a cipher that encrypts in place and keeps fewer bytes than
    /// it was given.
    ///
    /// ```swift
    /// let consumed = try output.withFreeCapacity { span, written throws(BytesError) in
    ///     let result = try stream.run(input, into: &span, at: 0)
    ///     written = result.end
    ///     return result.consumed
    /// }
    /// ```
    ///
    /// The span's bytes start out uninitialized: write before reading. For writing fields in order,
    /// ``withBytesWriter(bitOrder:_:)`` is simpler.
    ///
    /// - Parameters:
    ///   - byteCount: The size of the span: at most ``Swift/OutputRawSpan/freeCapacity``. `nil`, the default,
    ///     for all of it.
    ///   - body: Receives the span, and the number of bytes written at its start, 0: set it to what was
    ///     written. If `body` throws, nothing is appended.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    /// - Precondition: `byteCount` fits the free capacity; `body` reports between 0 and the span's size, and
    ///   leaves the span it was given in place.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func withFreeCapacity<R: ~Copyable, E: Error>(
        byteCount: Int? = nil, _ body: (inout MutableRawSpan, _ written: inout Int) throws(E) -> R
    ) throws(E) -> R {
        let count = byteCount ?? freeCapacity
        precondition(count >= 0 && count <= freeCapacity, "Asking for more than an output span's free capacity")
        // Unsafe: a span over the free capacity, which no safe API exposes. Safe: the span covers `count` bytes
        // of it (checked above) and ends with the closure; `body` must leave that span in place (checked
        // below), and only the bytes it reports writing, within the span, are counted as initialized.
        return try unsafe withUnsafeMutableBytes { buffer, initializedCount throws(E) -> R in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount..<(initializedCount &+ count)])
            var span = unsafe MutableRawSpan(_unsafeBytes: free)
            var written = 0
            let result = try body(&span, &written)
            precondition(written >= 0 && written <= count, "Reporting more bytes written than an output span's free capacity")
            precondition(
                span.byteCount == count && span.withUnsafeBytes { unsafe $0.baseAddress == UnsafeRawPointer(free.baseAddress) },
                "Replacing the span over an output span's free capacity"
            )
            initializedCount &+= written
            return result
        }
    }
}

public extension MutableRawSpan {
    /// Runs `body` with an empty output span over these bytes from `offset`: what it appends overwrites them.
    /// For streaming into a buffer that already exists, such as a pipeline's output into a reused array.
    ///
    /// ```swift
    /// let produced = try bytes.withOutputRawSpan { output throws(BytesError) in
    ///     _ = try pipeline.transform(input, into: &output, flush: .flush)
    ///     return output.byteCount
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - offset: Where the output span starts, 0 through `byteCount`.
    ///   - body: Receives the output span. The bytes it appends stay written when it returns or throws.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    /// - Precondition: `offset` is within the span, and `body` leaves the output span it was given in place.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withOutputRawSpan<R, E: Error>(
        overwritingFrom offset: Int = 0, _ body: (inout OutputRawSpan) throws(E) -> R
    ) throws(E) -> R {
        precondition(offset >= 0 && offset <= byteCount, "An output span starting outside a span")
        // Unsafe: an output span over these bytes. Safe: it covers `offset...` (checked above) and ends with the
        // closure; `finalize` checks that `body` left it in place.
        return try withUnsafeMutableBytes { buffer throws(E) -> R in
            let region = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[offset...])
            var output = unsafe OutputRawSpan(buffer: region, initializedCount: 0)
            let result = try body(&output)
            _ = unsafe output.finalize(for: region)
            return result
        }
    }
}

public extension MutableSpan where Element == UInt8 {
    /// Runs `body` with an empty output span over these bytes from `offset`, as
    /// ``Swift/MutableRawSpan/withOutputRawSpan(overwritingFrom:_:)`` does.
    ///
    /// - Parameters:
    ///   - offset: Where the output span starts, 0 through `count`.
    ///   - body: Receives the output span.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withOutputRawSpan<R, E: Error>(
        overwritingFrom offset: Int = 0, _ body: (inout OutputRawSpan) throws(E) -> R
    ) throws(E) -> R {
        var bytes = MutableRawSpan(mutating: &self)
        return try bytes.withOutputRawSpan(overwritingFrom: offset, body)
    }
}

// MARK: - Arrays

public extension [UInt8] {
    /// Creates an array with a copy of `bytes`: the byte counterpart of `String(copying:)`, for keeping
    /// what a span read from ``BytesReader`` borrows.
    ///
    /// - Parameter bytes: The bytes to copy.
    @inlinable
    init(copying bytes: RawSpan) {
        // Unsafe: the span's memory as a buffer pointer. Safe: it's only read, within the closure, by the
        // standard library's `Array` initializer (a `memcpy`). Not `init(unsafeUninitializedCapacity:)`
        // with a `memcpy`: that called an unspecialized allocator, `ContiguousArray._allocateBufferUninitialized`,
        // and copying an MQTT packet's payload took about 590 instructions more per packet.
        self = bytes.withUnsafeBytes { buffer in unsafe Array(buffer) }
    }

    /// Appends a copy of `bytes`: the appending counterpart of ``init(copying:)``.
    ///
    /// - Parameter bytes: The bytes to copy.
    @inlinable
    mutating func append(copying bytes: RawSpan) {
        // Unsafe: the span's memory as a buffer pointer. Safe: it's only read, within the closure, by the
        // standard library's bulk append (a `memcpy`). Through a `BytesWriter` instead, it measured 37
        // instructions against 13, with a trap path for an error that can't happen.
        bytes.withUnsafeBytes { buffer in unsafe append(contentsOf: buffer) }
    }

    /// Appends the low `T.byteCount` bytes of `value` in `byteOrder`: for building small headers and test
    /// data in an array, where a ``BytesWriter`` would need its capacity up front.
    ///
    /// ```swift
    /// var header: [UInt8] = []
    /// header.append(UInt32(size), as: Byte4.self, .littleEndian)
    /// header.append(length, as: Byte3.self, .bigEndian)
    /// ```
    ///
    /// The same code as `withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }`, written out.
    ///
    /// - Parameters:
    ///   - value: The integer to append.
    ///   - type: The ``ByteGroup`` type, which sets the width.
    ///   - byteOrder: The order to append the bytes in.
    /// - Precondition: `value` fits in `T.byteCount` bytes (no check for the groups whose integer is exactly
    ///   their width).
    @inlinable @inline(__always)
    mutating func append<T: ByteGroup>(_ value: T.Integer, as type: T.Type, _ byteOrder: ByteOrder) {
        precondition(value <= T._mask, "\(value) doesn't fit in \(T.byteCount) bytes")
        // The integer's little-endian representation is the group's bytes in memory order on any host.
        Swift.withUnsafeBytes(of: T(value, byteOrder).littleEndian.littleEndian) { buffer in
            // Unsafe: appends the closure's raw buffer. Safe: its first `T.byteCount` bytes are the local's
            // (an `Integer` holds at least that many), valid inside the closure; the array copies them before it
            // returns.
            unsafe append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[..<T.byteCount]))
        }
    }

    /// Runs `body` with an empty output span over the array's bytes from `offset`: what it appends overwrites
    /// them, and the array's count doesn't change. For streaming into a reused buffer.
    ///
    /// ```swift
    /// var wire = [UInt8](repeating: 0, count: 1 << 20)
    /// let progress = try wire.withOutputRawSpan { output throws(BytesError) in
    ///     try pipeline.transform(batch.span.bytes, into: &output, flush: .flush)
    /// }
    /// try await connection.write(from: wire.span.bytes.extracting(0..<progress.produced))
    /// ```
    ///
    /// Typed throws pass through: unlike `withUnsafeMutableBytes`, which rethrows `any Error`, this keeps
    /// `body`'s error type. (A `throws(E)` closure passed to the array's own method also miscompiles with
    /// Swift 6.4.2, swiftlang/swift#90291.)
    ///
    /// - Parameters:
    ///   - offset: Where the output span starts, 0 through `count`.
    ///   - body: Receives the output span.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    mutating func withOutputRawSpan<R, E: Error>(
        overwritingFrom offset: Int = 0, _ body: (inout OutputRawSpan) throws(E) -> R
    ) throws(E) -> R {
        var span = mutableSpan
        return try span.withOutputRawSpan(overwritingFrom: offset, body)
    }
}

// MARK: - ByteBuffer

/// A buffer that fills at its end and drains from its front: a socket's received bytes waiting to be
/// parsed, a pipeline's bytes between two stages, a decoder's output waiting for room.
///
/// Fill it through an output span over the free space at the end with ``fill(_:)`` (or `receive(_:)`, in
/// `BytesAsync`, from an asynchronous source); read what's there with ``unread``, and ``consume(_:)`` what was used. A partial
/// unit at the end (a packet, a record, a code) stays unread until more arrives; before the space at the end
/// runs low, a fill moves the unread bytes to the front (``compact()``), so fills stay large without moving
/// bytes every time.
///
/// ```swift
/// var received = ByteBuffer(capacity: 256 << 10)
/// while try await received.receive({ output throws(IOError) in try await connection.read(into: &output) }) > 0 {
///     received.consume(try parser.parse(received.unread))
/// }
/// ```
///
/// One allocation, made by the initializer and never moved or grown, so a fill can suspend (a socket read)
/// with its output span in place: no `Array`'s span can stay borrowed across a suspension point.
///
/// `Sendable`: it owns its memory, and being `~Copyable`, only one owner can use it.
@safe @frozen
public struct ByteBuffer: ~Copyable, @unchecked Sendable {
    @usableFromInline package let _storage: UnsafeMutableRawBufferPointer
    /// The buffer's size in bytes. It never grows.
    public let capacity: Int
    /// ``fill(_:)`` compacts first when fewer bytes than this are free at the end.
    public let compactionThreshold: Int
    /// The unread bytes are `_start ..< _end`.
    @usableFromInline var _start = 0
    @usableFromInline package var _end = 0

    /// Creates an empty buffer.
    ///
    /// - Parameters:
    ///   - capacity: The buffer's size in bytes; it never grows. More than 0.
    ///   - compactionThreshold: ``fill(_:)`` moves the unread bytes to the front first when fewer than this
    ///     many bytes are free at the end: by default, half the capacity. Lower means fewer moves and smaller
    ///     fills.
    @inlinable
    public init(capacity: Int, compactingBelow compactionThreshold: Int? = nil) {
        precondition(capacity > 0, "A buffer needs room")
        unsafe _storage = .allocate(byteCount: capacity, alignment: 64)
        self.capacity = capacity
        self.compactionThreshold = compactionThreshold ?? capacity &>> 1
    }

    @inlinable
    deinit {
        unsafe _storage.deallocate()
    }

    /// The bytes filled but not yet consumed.
    @inlinable
    public var unread: RawSpan {
        @_lifetime(borrow self)
        get {
            // Unsafe: a span over the allocation. Safe: `_start ..< _end` is always within it and initialized,
            // and the span borrows `self`, which owns the memory.
            let span = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: _storage[_start..<_end]))
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    /// The number of unread bytes.
    @inlinable
    public var unreadByteCount: Int { _end &- _start }

    /// Whether no unread bytes remain.
    @inlinable
    public var isEmpty: Bool { _start == _end }

    /// Whether the unread bytes fill the buffer: no fill can add anything, even after compacting.
    @inlinable
    public var isFull: Bool { _end &- _start == capacity }

    /// The bytes free at the end: what a fill can add without compacting.
    @inlinable
    public var freeCapacity: Int { capacity &- _end }

    /// Drops the first `byteCount` unread bytes, which were used. Once none remain, the next fill starts at
    /// the front, with nothing to move.
    ///
    /// - Parameter byteCount: How many bytes to drop.
    /// - Precondition: `byteCount` is between 0 and ``unreadByteCount``.
    @inlinable
    public mutating func consume(_ byteCount: Int) {
        precondition(byteCount >= 0 && byteCount <= _end &- _start, "Consuming more than a buffer's unread bytes")
        _start &+= byteCount
        if _start == _end {
            _start = 0
            _end = 0
        }
    }

    /// Drops every unread byte.
    @inlinable
    public mutating func removeAll() {
        _start = 0
        _end = 0
    }

    /// Moves the unread bytes to the front, freeing everything after them.
    ///
    /// - Returns: Whether anything moved: `false` if the unread bytes were already at the front.
    @inlinable
    @discardableResult
    public mutating func compact() -> Bool {
        guard _start > 0 else { return false }
        let count = _end &- _start
        // Unsafe: `memmove` within the allocation. Safe: both ranges are inside it, and `copyMemory` allows
        // them to overlap.
        unsafe _storage.baseAddress!.copyMemory(from: _storage.baseAddress!.advanced(by: _start), byteCount: count)
        _start = 0
        _end = count
        return true
    }

    /// Appends what `body` writes to an output span over the free space at the end. First compacts if less
    /// than ``compactionThreshold`` bytes are free there.
    ///
    /// ```swift
    /// let progress = try buffer.fill { output throws(BytesError) in
    ///     try decoder.transform(input, into: &output, flush: .none)
    /// }
    /// ```
    ///
    /// - Parameter body: Receives an output span over the free space, which may be empty if the buffer is
    ///   full. What it appends is added to the unread bytes, even if it throws.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    /// - Precondition: `body` leaves the output span it was given in place.
    @inlinable
    public mutating func fill<R: ~Copyable, E: Error>(_ body: (inout OutputRawSpan) throws(E) -> R) throws(E) -> R {
        if capacity &- _end < compactionThreshold {
            compact()
        }
        // Unsafe: an output span over the free space. Safe: it covers exactly `_end...` of the allocation and
        // ends with this call; `finalize` checks that `body` left it in place, and counts what it appended.
        let free = unsafe UnsafeMutableRawBufferPointer(rebasing: _storage[_end...])
        var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
        let result: R
        do throws(E) {
            result = try body(&output)
        } catch {
            _end &+= unsafe output.finalize(for: free)
            throw error
        }
        _end &+= unsafe output.finalize(for: free)
        return result
    }
}
