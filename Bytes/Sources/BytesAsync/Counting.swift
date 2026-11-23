public import Synchronization
#if canImport(Darwin)
public import Darwin
#else
public import Dispatch
#endif

// Counting across tasks and threads: a counter with an identity (an `Atomic` can't be copied, so arrays and
// captures can't hold one), the claim-the-next-index pattern work queues share, and the clock their timings read.

/// An integer that several tasks or threads add to, read with relaxed ordering: statistics (calls made, bytes
/// written, nanoseconds waited) and the next index of a work queue. A class, so arrays and closures can hold one:
/// `Atomic` isn't copyable.
///
/// ```swift
/// let next = RelaxedCounter()
/// // In each worker:
/// while let index = next.claim(below: items.count) { process(items[index]) }
/// ```
///
/// Relaxed ordering makes no promise about other memory: a count read while others add is some recent value, and
/// a claimed index says nothing about what its claimer wrote. For anything that publishes memory, such as a
/// reference count whose last release frees a buffer, use ``atomic`` with the ordering it needs.
public final class RelaxedCounter: Sendable {
    /// The counter itself, for orderings other than relaxed.
    public let atomic: Atomic<Int>

    /// Creates a counter.
    ///
    /// - Parameter value: The starting value.
    @inlinable
    public init(_ value: Int = 0) {
        atomic = Atomic(value)
    }

    /// The current value.
    @inlinable
    public var value: Int {
        @inline(__always) get { atomic.load(ordering: .relaxed) }
    }

    /// Adds `count` (wrapping on overflow).
    ///
    /// - Parameter count: The amount to add; negative to subtract.
    /// - Returns: The value after adding.
    @inlinable @inline(__always) @discardableResult
    public func add(_ count: Int = 1) -> Int {
        atomic.wrappingAdd(count, ordering: .relaxed).newValue
    }

    /// Replaces the value.
    ///
    /// - Parameter value: The new value.
    @inlinable @inline(__always)
    public func store(_ value: Int) {
        atomic.store(value, ordering: .relaxed)
    }

    /// Claims the next index below `limit`: each of 0 through `limit - 1` goes to exactly one caller, in order,
    /// when every caller passes the same `limit` and the counter started at 0.
    ///
    /// - Parameter limit: How many indexes there are.
    /// - Returns: The index, or `nil` once all are claimed. (The counter keeps counting past `limit`.)
    @inlinable @inline(__always)
    public func claim(below limit: Int) -> Int? {
        atomic.claim(below: limit)
    }
}

/// A fixed number of ``RelaxedCounter``s in one allocation: one count per buffer, per kind of work, or per call kind,
/// where an array of counter objects would allocate each.
///
/// ```swift
/// let references = RelaxedCounters(count: buffers)
/// references.store(1, at: buffer)
/// // Releasing, with the ordering a last release needs:
/// let left = references.withAtomic(at: buffer) { $0.subtract(1, ordering: .acquiringAndReleasing).newValue }
/// ```
///
/// A value with reference semantics: copies share the counters. Each index is checked against ``count`` (one
/// unsigned compare).
@frozen
public struct RelaxedCounters: @unchecked Sendable {
    // Unchecked: the storage holds only `Atomic`s, made in `init` and never moved; every access is atomic.
    // (`ManagedBuffer` is explicitly not `Sendable`, so the storage class can't be.)

    /// The counters, after a header holding their count, in one allocation.
    @usableFromInline
    final class Storage: ManagedBuffer<Int, Atomic<Int>> {
        deinit {
            // Unsafe: the elements' pointer, to end their lifetimes. Safe: `header` counters were initialized by
            // `init` and nothing uses them once the storage is released.
            _ = unsafe withUnsafeMutablePointers { count, counters in unsafe counters.deinitialize(count: count.pointee) }
        }
    }

    @usableFromInline
    let storage: Storage

    /// Creates `count` counters.
    ///
    /// - Parameters:
    ///   - count: How many.
    ///   - value: Each one's starting value.
    @inlinable
    public init(count: Int, value: Int = 0) {
        precondition(count >= 0, "A negative counter count")
        let buffer = Storage.create(minimumCapacity: count) { _ in count }
        // Unsafe: the elements' pointer, to initialize them. Safe: `count` elements of capacity (at least what
        // was asked for), each initialized once, before the storage is shared.
        unsafe buffer.withUnsafeMutablePointerToElements { counters in
            for index in 0..<count { unsafe (counters + index).initialize(to: Atomic(value)) }
        }
        // Unsafe: an unchecked downcast. Safe: `Storage.create` makes an instance of `Storage` itself.
        storage = unsafe unsafeDowncast(buffer, to: Storage.self)
    }

    /// How many counters there are.
    @inlinable
    public var count: Int {
        @inline(__always) get { storage.header }
    }

    /// Runs `body` with counter `index` itself, for orderings other than relaxed.
    ///
    /// - Parameters:
    ///   - index: The counter, from 0 to ``count`` − 1.
    ///   - body: Receives the atomic.
    /// - Returns: What `body` returns.
    @inlinable @inline(__always)
    public func withAtomic<R, E: Error>(at index: Int, _ body: (borrowing Atomic<Int>) throws(E) -> R) throws(E) -> R {
        precondition(UInt(bitPattern: index) < UInt(bitPattern: storage.header), "Counter index out of range")
        // Unsafe: a pointer to counter `index`. Safe: below `count` (checked), initialized by `init`, and the storage
        // is kept alive by `self` for the call.
        return try unsafe storage.withUnsafeMutablePointerToElements { counters throws(E) -> R in try body(unsafe counters[index]) }
    }

    /// Counter `index`'s current value.
    @inlinable @inline(__always)
    public func value(at index: Int) -> Int {
        withAtomic(at: index) { $0.load(ordering: .relaxed) }
    }

    /// Adds `count` (wrapping) to counter `index`.
    ///
    /// - Returns: The value after adding.
    @inlinable @inline(__always) @discardableResult
    public func add(_ count: Int = 1, at index: Int) -> Int {
        withAtomic(at: index) { $0.wrappingAdd(count, ordering: .relaxed).newValue }
    }

    /// Replaces counter `index`'s value.
    @inlinable @inline(__always)
    public func store(_ value: Int, at index: Int) {
        withAtomic(at: index) { $0.store(value, ordering: .relaxed) }
    }
}

public extension Atomic where Value == Int {
    /// Claims the next index below `limit`, as ``RelaxedCounter/claim(below:)``: for a counter that's a local or a
    /// stored property rather than a ``RelaxedCounter``.
    ///
    /// ```swift
    /// let next = Atomic(0)
    /// DispatchQueue.concurrentPerform(iterations: lanes) { _ in
    ///     while let index = next.claim(below: chunkCount) { compress(index) }
    /// }
    /// ```
    ///
    /// - Parameter limit: How many indexes there are.
    /// - Returns: The index, or `nil` once all are claimed.
    @inlinable @inline(__always)
    func claim(below limit: Int) -> Int? {
        let index = wrappingAdd(1, ordering: .relaxed).oldValue
        return index < limit ? index : nil
    }
}

/// The monotonic clock, in nanoseconds, for timing intervals: it doesn't jump with the wall clock, and doesn't
/// advance while the machine sleeps.
///
/// ```swift
/// let started = MonotonicClock.now
/// try extract()
/// statistics.seconds = MonotonicClock.seconds(since: started)
/// ```
public enum MonotonicClock {
    /// Nanoseconds since an arbitrary point (on Darwin, boot): meaningful only as a difference.
    @inlinable
    public static var now: Int {
        @inline(__always) get {
            #if canImport(Darwin)
            Int(truncatingIfNeeded: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            #else
            Int(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
            #endif
        }
    }

    /// Nanoseconds since `start`.
    ///
    /// - Parameter start: An earlier ``now``.
    /// - Returns: The interval in nanoseconds.
    @inlinable @inline(__always)
    public static func nanoseconds(since start: Int) -> Int {
        now &- start
    }

    /// Seconds since `start`.
    ///
    /// - Parameter start: An earlier ``now``.
    /// - Returns: The interval in seconds.
    @inlinable @inline(__always)
    public static func seconds(since start: Int) -> Double {
        Double(now &- start) / 1e9
    }
}
