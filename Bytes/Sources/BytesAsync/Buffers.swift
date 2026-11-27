public import Bytes

// The asynchronous side of `Bytes`' buffers: filling a `ByteBuffer` or an array from a source that suspends.

public extension [UInt8] {
    /// Appends what an asynchronous `body` writes to an output span over `byteCount` bytes of new capacity: the
    /// `async` counterpart of `append(writingUpTo:_:)`, for writers that suspend (an async pipeline stage), with
    /// nothing zeroed or copied.
    ///
    /// ```swift
    /// let progress = try await output.append(receivingUpTo: 64 << 10) { raw throws(StageError) in
    ///     try await stage.transform(input, into: &raw, flush: .finish)
    /// }
    /// ```
    ///
    /// The array's capacity grows geometrically (at least doubling) when it lacks the room, so appending round after
    /// round stays linear. The span covers that capacity, uninitialized; only what `body` appends is counted.
    ///
    /// Not an `async` overload of `append(writingUpTo:_:)`: with a closure that names its error type, Swift 6.4
    /// finds such a call ambiguous (as with `ByteBuffer.receive`).
    ///
    /// - Parameters:
    ///   - byteCount: The most bytes `body` may write.
    ///   - body: Receives an empty output span over the new capacity.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws; then nothing is appended.
    /// - Precondition: `byteCount` isn't negative, and `body` leaves the output span it was given in place.
    nonisolated(nonsending) mutating func append<R, E: Error>(
        receivingUpTo byteCount: Int, _ body: nonisolated(nonsending) (inout OutputRawSpan) async throws(E) -> R
    ) async throws(E) -> R {
        precondition(byteCount >= 0, "Appending a negative number of bytes")
        let start = count
        // Unique storage with room for `byteCount` more (reserving also copies shared storage), at least doubling.
        reserveCapacity(capacity &- start < byteCount ? Swift.max(start &+ byteCount, capacity &* 2) : start &+ byteCount)
        guard byteCount > 0 else {
            var empty = OutputRawSpan()
            return try await body(&empty)
        }
        // Unsafe: the array's uninitialized capacity after `count`, as a buffer that outlives the closure. Safe: the
        // storage is unique and holds `start + byteCount` bytes (reserved above), and the array is `inout` for this
        // whole call, so nothing else can reach it or move its storage while `body` runs, suspended or not.
        let free = withUnsafeMutableBufferPointer { buffer in
            unsafe UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(buffer.baseAddress!) + start, count: byteCount)
        }
        var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
        let result: R
        do throws(E) {
            result = try await body(&output)
        } catch {
            _ = unsafe output.finalize(for: free)
            throw error
        }
        // Unsafe: checks `body` left the span over `free`, and takes the count it wrote. Safe: it was made over `free`.
        let written = unsafe output.finalize(for: free)
        precondition(capacity &- count >= written, "An array's storage changed while it was lent")
        // Counts as initialized the bytes `body` wrote there: the same storage (its room suffices, so nothing is
        // reallocated), the bytes already in place.
        append(addingCapacity: written) { (span: inout OutputSpan<UInt8>) in
            // Unsafe: sets the initialized count without writing. Safe: the first `written` bytes of this capacity
            // are the ones `body` wrote, and `UInt8` needs no initialization beyond its bytes.
            unsafe span.withUnsafeMutableBufferPointer { _, initializedCount in initializedCount = written }
        }
        return result
    }
}

public extension ByteBuffer {
    /// Appends what an asynchronous source writes to an output span over the free space at the end: a socket
    /// read, which suspends. As ``fill(_:)`` does, on the caller's executor.
    ///
    /// ```swift
    /// let count = try await received.receive { output throws(IOError) in try await connection.read(into: &output) }
    /// ```
    ///
    /// Not an `async` overload of ``fill(_:)``: with a closure that names its error type, Swift 6.4 finds such
    /// a call ambiguous, from async code even when the closure doesn't suspend.
    ///
    /// - Parameter body: Receives an output span over the free space, which may be empty if the buffer is
    ///   full. What it appends is added to the unread bytes, even if it throws.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    /// - Precondition: `body` leaves the output span it was given in place.
    @inlinable
    nonisolated(nonsending) mutating func receive<R, E: Error>(
        _ body: nonisolated(nonsending) (inout OutputRawSpan) async throws(E) -> R
    ) async throws(E) -> R {
        if capacity &- _end < compactionThreshold {
            compact()
        }
        // Unsafe and safe as in the synchronous form. The allocation never moves, so the span stays valid while
        // `body` is suspended.
        let free = unsafe UnsafeMutableRawBufferPointer(rebasing: _storage[_end...])
        var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
        let result: R
        do {
            result = try await body(&output)
        } catch {
            _end &+= unsafe output.finalize(for: free)
            throw error
        }
        _end &+= unsafe output.finalize(for: free)
        return result
    }
}
