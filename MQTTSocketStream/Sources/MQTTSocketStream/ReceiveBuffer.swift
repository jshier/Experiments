import PlatformExecutors

/// A receiver's buffer for reassembling packets from a byte stream: reads append at the end, parsing consumes
/// from the start, and a partial packet left at the end moves to the front before the buffer fills.
///
/// Unsafe inside: one raw allocation. A read fills the buffer across a suspension point (the `await` in
/// `TCPConnection.read(into:)`), where no safe container's span can stay borrowed, and the memory must
/// not move while the read is in flight. It's owned uniquely and freed in `deinit`; `start` and `end`
/// bound every span handed out.
@safe
struct ReceiveBuffer: ~Copyable {
    private let storage: UnsafeMutableRawBufferPointer
    private let capacity: Int
    /// The unparsed bytes are `start..<end`.
    private var start = 0
    private var end = 0

    init(capacity: Int) {
        unsafe storage = .allocate(byteCount: capacity, alignment: 64)
        self.capacity = capacity
    }

    deinit {
        unsafe storage.deallocate()
    }

    /// The bytes received but not yet consumed.
    var unread: RawSpan {
        @_lifetime(borrow self)
        get {
            let span = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: storage[start..<end]))
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    var isEmpty: Bool { start == end }

    /// Drops the first `count` unread bytes, which were parsed.
    mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= end - start)
        start += count
        if start == end { (start, end) = (0, 0) } // Empty: start over at the front, for free.
    }

    /// Reads once from `connection` into the free space, returning the bytes read (0 at the end of the
    /// stream). First moves a partial packet to the front if less than half the buffer is free, so reads
    /// stay large without moving bytes on every read.
    nonisolated(nonsending) mutating func read(from connection: inout TCPConnection) async throws(IOError) -> Int {
        if capacity - end < capacity / 2, start > 0 {
            // `copyMemory` is `memmove`: the ranges can overlap.
            unsafe storage.baseAddress!.copyMemory(from: storage.baseAddress! + start, byteCount: end - start)
            (start, end) = (0, end - start)
        }
        precondition(end < capacity, "A packet larger than the receive buffer")
        let free = unsafe UnsafeMutableRawBufferPointer(rebasing: storage[end...])
        var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
        let count = try await connection.read(into: &output)
        _ = unsafe output.finalize(for: free)
        end += count
        return count
    }
}
