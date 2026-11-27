public import Bytes

// `Bytes`' scoped lending (`withLentBytes`, `withLentFreeCapacity`) for asynchronous work: a task group, or a
// continuation resumed from another queue. The rule is the same: the work must finish before the call returns,
// which awaiting it ensures.
//
// Named apart from the synchronous forms: with one name, Swift 6.4 finds a call whose closure names its error type
// ambiguous between the two, from async code even when the closure doesn't suspend (as `ByteBuffer.receive` is named
// apart from `fill`).

public extension RawSpan {
    /// Runs `body` with these bytes lent as a `Sendable` value, for asynchronous work that ends before `body`
    /// returns: child tasks of a task group it awaits, a continuation it awaits.
    ///
    /// - Parameter body: Receives the lent bytes. Work using them must finish before it returns.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    nonisolated(nonsending) func withLentBytesAsync<R, E: Error>(
        _ body: nonisolated(nonsending) (LentBytes) async throws(E) -> R
    ) async throws(E) -> R {
        // Unsafe: the pointer outlives `withUnsafeBytes`' closure. Safe: the span is borrowed for this whole
        // call, so its memory stays put while `body` (and the work it awaits) uses it.
        let buffer = withUnsafeBytes { unsafe $0 }
        return try await unsafe body(LentBytes(buffer: buffer))
    }
}

public extension OutputRawSpan {
    /// Runs `body` with this output's free capacity lent as a `Sendable` value, then counts as initialized the
    /// first bytes `body` reports writing: output written by asynchronous work it awaits.
    ///
    /// - Parameter body: Receives the free capacity; writes a prefix of it (in work finished before it
    ///   returns) and returns that prefix's length.
    /// - Returns: The bytes `body` wrote.
    /// - Throws: What `body` throws; then nothing is counted.
    /// - Precondition: `body` returns at most the free capacity.
    @inlinable
    @_lifetime(self: copy self)
    nonisolated(nonsending) mutating func withLentFreeCapacityAsync<E: Error>(
        _ body: nonisolated(nonsending) (LentMutableBytes) async throws(E) -> Int
    ) async throws(E) -> Int {
        // Unsafe: the pointer outlives `withUnsafeMutableBytes`' closure, and counting bytes as initialized.
        // Safe: the output is `inout` for this whole call, so its memory stays put; `body` finishes with it and
        // reports the prefix it initialized, which the precondition bounds.
        let free = unsafe withUnsafeMutableBytes { buffer, initializedCount in
            unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...])
        }
        let written = try await unsafe body(LentMutableBytes(buffer: free))
        precondition(written >= 0 && written <= free.count, "More bytes reported than lent")
        unsafe withUnsafeMutableBytes { _, initializedCount in initializedCount &+= written }
        return written
    }
}
