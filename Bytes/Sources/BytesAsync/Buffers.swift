public import Bytes

// The asynchronous side of `Bytes`' buffers: filling a `ByteBuffer` from a source that suspends.

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
