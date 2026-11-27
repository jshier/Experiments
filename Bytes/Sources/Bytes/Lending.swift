// Spans lent to other threads for the length of one call: parallel work over a caller's input and output.
//
// A span can't cross threads (it's `~Escapable`, so no task or `concurrentPerform` closure can capture it).
// These types carry its memory as a `Sendable` pointer instead, made only by the scoped functions below, which
// state the one rule that makes them safe: the work that uses them must finish before the function returns.
// `concurrentPerform` and a task group both do; `BytesAsync` has the `async` forms (`withLentBytesAsync`,
// `withLentFreeCapacityAsync`).
//
// ```swift
// let total = input.withLentBytes { bytes in
//     let sums = Mutex([Int](repeating: 0, count: 8))
//     DispatchQueue.concurrentPerform(iterations: 8) { lane in
//         let piece = unsafe bytes.span.extracting(…)        // this lane's part
//         sums.withLock { $0[lane] = checksum(piece) }
//     }
//     return sums.withLock { $0.reduce(0, +) }
// }
// ```

/// Bytes lent to other threads: a span's memory as a `Sendable` pointer, from `RawSpan.withLentBytes(_:)`.
///
/// Unsafe: it's a pointer, valid only until the lending call returns. Use it only in work that ends before
/// then, and only to read.
@unsafe @frozen
public struct LentBytes: @unchecked Sendable {
    /// The memory.
    public let buffer: UnsafeRawBufferPointer

    /// Lends `buffer`.
    ///
    /// - Parameter buffer: Memory that stays valid, and unwritten, for as long as the value is used.
    @inlinable
    public init(buffer: UnsafeRawBufferPointer) {
        unsafe self.buffer = buffer
    }

    /// The bytes as a span, for the work using them.
    @inlinable
    public var span: RawSpan {
        @_lifetime(borrow self)
        get { unsafe RawSpan(_unsafeBytes: buffer) }
    }
}

/// Output memory lent to other threads: an output span's free capacity as a `Sendable` pointer, from
/// `OutputRawSpan.withLentFreeCapacity(_:)`.
///
/// Unsafe: it's a pointer, valid only until the lending call returns, and uninitialized: each byte is to be
/// written by one thread only, and the lending call counts as initialized only the prefix its body reports.
@unsafe @frozen
public struct LentMutableBytes: @unchecked Sendable {
    /// The memory.
    public let buffer: UnsafeMutableRawBufferPointer

    /// Lends `buffer`.
    ///
    /// - Parameter buffer: Memory that stays valid for as long as the value is used.
    @inlinable
    public init(buffer: UnsafeMutableRawBufferPointer) {
        unsafe self.buffer = buffer
    }
}

/// Bytes lent to other threads to read and write in place: a mutable span's memory as a `Sendable` pointer, from
/// `MutableRawSpan.withLentBytes(_:)`.
///
/// Unlike ``LentMutableBytes`` (an output's free capacity: uninitialized, only to be written), this memory is
/// initialized: work may read it as well as write it.
///
/// Unsafe: it's a pointer, valid only until the lending call returns. Use it only in work that ends before then, and
/// give each byte one thread at a time: no byte written by one thread while another reads or writes it.
@unsafe @frozen
public struct LentMutableSpan: @unchecked Sendable {
    /// The memory.
    public let buffer: UnsafeMutableRawBufferPointer

    /// Lends `buffer`.
    ///
    /// - Parameter buffer: Initialized memory that stays valid for as long as the value is used.
    @inlinable
    public init(buffer: UnsafeMutableRawBufferPointer) {
        unsafe self.buffer = buffer
    }
}

public extension RawSpan {
    /// Runs `body` with these bytes lent as a `Sendable` value, for work on other threads that ends before
    /// `body` returns (`concurrentPerform`, a task group).
    ///
    /// - Parameter body: Receives the lent bytes. Work using them must finish before it returns.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    func withLentBytes<R: ~Copyable, E: Error>(_ body: (LentBytes) throws(E) -> R) throws(E) -> R {
        // Unsafe: a pointer to the span's memory. Safe: the span is borrowed for this whole call, and `body`
        // must finish with the pointer before returning (the rule `LentBytes` states).
        try withUnsafeBytes { buffer throws(E) -> R in try unsafe body(LentBytes(buffer: buffer)) }
    }
}

public extension MutableRawSpan {
    /// Runs `body` with these bytes lent as a `Sendable` value, to read and write in place in work on other threads
    /// that ends before `body` returns (`concurrentPerform`, a task group).
    ///
    /// - Parameter body: Receives the lent bytes. Work using them must finish before it returns.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withLentBytes<R: ~Copyable, E: Error>(_ body: (LentMutableSpan) throws(E) -> R) throws(E) -> R {
        // Unsafe: a pointer to the span's memory. Safe: the span is `inout` for this whole call, so nothing else
        // reaches its memory, and `body` must finish with the pointer before returning (the rule `LentMutableSpan`
        // states).
        try withUnsafeMutableBytes { buffer throws(E) -> R in try unsafe body(LentMutableSpan(buffer: buffer)) }
    }
}

public extension OutputRawSpan {
    /// Runs `body` with this output's free capacity lent as a `Sendable` value, then counts as initialized the
    /// first bytes of it that `body` reports writing: output written by other threads.
    ///
    /// - Parameter body: Receives the free capacity; writes a prefix of it (from other threads, finished
    ///   before it returns) and returns that prefix's length.
    /// - Returns: The bytes `body` wrote.
    /// - Throws: What `body` throws; then nothing is counted.
    /// - Precondition: `body` returns at most the free capacity.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withLentFreeCapacity<E: Error>(_ body: (LentMutableBytes) throws(E) -> Int) throws(E) -> Int {
        // Unsafe: a pointer to the free capacity, and counting bytes as initialized. Safe: the output is
        // borrowed for this whole call; `body` finishes with the pointer before returning and reports the
        // prefix it initialized, which the precondition bounds.
        try unsafe withUnsafeMutableBytes { buffer, initializedCount throws(E) -> Int in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...])
            let written = try unsafe body(LentMutableBytes(buffer: free))
            precondition(written >= 0 && written <= free.count, "More bytes reported than lent")
            initializedCount &+= written
            return written
        }
    }
}
