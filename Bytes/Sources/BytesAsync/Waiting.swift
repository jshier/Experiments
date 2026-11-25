// How BytesAsync's primitives (and their clients' own) make a task wait. Every wait suspends the task on a
// continuation that another task resumes, outside the lock that queued it, exactly once: a waiter is removed from its
// queue under the lock before it's resumed, and closing a primitive resumes every waiter it still holds. The pattern:
//
// - A synchronous fast path under the lock: take what's there and return without suspending.
// - No lost wakeups: the slow path stores its continuation in the same critical section that checks again, and the
//   side that would wake it looks for a waiter under the same lock.
// - Resume outside the lock.
//
// Debug builds check the "exactly once" with `CheckedContinuation`; release builds use `UnsafeContinuation`, which
// allocates nothing (a checked one allocates a canary object per wait, and a file writer waits about once per file).

#if DEBUG
/// A suspended task, to be resumed exactly once: checked in debug builds, unchecked (and allocation-free) in release.
public typealias Continuation<T> = CheckedContinuation<T, Never>

/// Suspends the calling task until the continuation given to `body` is resumed.
///
/// - Parameter body: Stores the continuation where exactly one resume will find it, or resumes it at once. Runs
///   synchronously, before the task suspends.
/// - Returns: The value the continuation is resumed with.
@inlinable @inline(__always)
public nonisolated(nonsending) func withContinuation<T>(_ body: (Continuation<T>) -> Void) async -> T {
    await withCheckedContinuation(body)
}
#else
/// A suspended task, to be resumed exactly once: checked in debug builds, unchecked (and allocation-free) in release.
///
/// An `UnsafeContinuation`, its unsafety contained by the rule above, which every primitive here follows (and debug
/// builds check).
@safe @frozen
public struct Continuation<T>: Sendable {
    @usableFromInline let base: UnsafeContinuation<T, Never>

    @inlinable @inline(__always)
    init(_ base: UnsafeContinuation<T, Never>) {
        // Unsafe: stores an unchecked continuation. Safe: resumed exactly once, by this type's users (see above).
        unsafe self.base = base
    }

    /// Resumes the task with `value`.
    @inlinable @inline(__always)
    public func resume(returning value: sending T) {
        // Unsafe: an unchecked resume. Safe: the one resume of this continuation (the type's contract).
        unsafe base.resume(returning: value)
    }

    /// Resumes the task.
    @inlinable @inline(__always)
    public func resume() where T == Void {
        // Unsafe and safe as above.
        unsafe base.resume()
    }
}

/// Suspends the calling task until the continuation given to `body` is resumed.
///
/// - Parameter body: Stores the continuation where exactly one resume will find it, or resumes it at once. Runs
///   synchronously, before the task suspends.
/// - Returns: The value the continuation is resumed with.
@inlinable @inline(__always)
public nonisolated(nonsending) func withContinuation<T>(_ body: (Continuation<T>) -> Void) async -> T {
    // Unsafe: an unchecked continuation. Safe: it goes to `body` wrapped, to be resumed exactly once.
    await unsafe withUnsafeContinuation { unsafe body(Continuation($0)) }
}
#endif

/// Suspended tasks' continuations (and what they carry), first in, first out, in storage reserved up front: it grows
/// (doubling) only past its capacity, so a steady state allocates nothing.
///
/// Not synchronized: state inside its owner's lock.
@frozen
public struct WaiterQueue<Element> {
    @usableFromInline var slots: [Element?]
    @usableFromInline var head = 0
    @usableFromInline var _count = 0

    /// A queue with room for `capacity` elements before it grows.
    @inlinable
    public init(capacity: Int) {
        slots = Array(repeating: nil, count: max(1, capacity))
    }

    /// The elements waiting.
    @inlinable
    public var count: Int { _count }

    /// Whether nothing waits.
    @inlinable
    public var isEmpty: Bool { _count == 0 }

    /// Adds `element` at the end.
    @inlinable
    public mutating func append(_ element: Element) {
        if _count == slots.count {
            // Past the reserved capacity: unroll into a larger ring, oldest first.
            var grown: [Element?] = Array(repeating: nil, count: slots.count * 2)
            for index in 0..<_count {
                grown[index] = slots[(head + index) % slots.count]
            }
            slots = grown
            head = 0
        }
        slots[(head + _count) % slots.count] = element
        _count += 1
    }

    /// Removes and returns the oldest element, or `nil` if there's none.
    @inlinable
    public mutating func popFirst() -> Element? {
        guard _count > 0 else { return nil }
        let element = slots[head]
        slots[head] = nil
        head = (head + 1) % slots.count
        _count -= 1
        return element
    }

    /// Removes and returns the oldest element matching `predicate`, keeping the others in order.
    @inlinable
    public mutating func removeFirst(where predicate: (Element) -> Bool) -> Element? {
        var found: Element?
        for _ in 0..<_count {
            let element = popFirst()!
            if found == nil, predicate(element) { found = element } else { append(element) }
        }
        return found
    }

    /// Removes everything, oldest first (an allocation: for closing, once).
    @inlinable
    public mutating func removeAll() -> [Element] {
        var all: [Element] = []
        all.reserveCapacity(count)
        while let element = popFirst() {
            all.append(element)
        }
        return all
    }
}
