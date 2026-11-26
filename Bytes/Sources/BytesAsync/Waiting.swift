public import Synchronization

// How BytesAsync's primitives (and their clients' own) make a task wait. Every wait suspends the task on a continuation
// (the standard library's noncopyable `Continuation<T, Never>`) that another task resumes, outside the lock that queued
// it, exactly once:
//
// - A synchronous fast path under the lock: take what's there and return without suspending.
// - No lost wakeups: the slow path stores its continuation in the same critical section that checks again
//   (``wait(in:_:)``), and the side that would wake it looks for a waiter under the same lock.
// - Resume outside the lock: a waiter leaves the lock as a value (a `Continuation?`, or a ``WaiterQueue`` of them).
// - Leave a noncopyable optional by unwrapping it (`if let x = consume y { x.resume() }`), not by optional chaining a
//   consuming call through a field (`y?.continuation.resume()`), and don't `take()` a doubly optional one in an async
//   function: Swift 6.4 calls the first a "copy of noncopyable typed value" compiler bug and crashed in IRGen on the
//   second. Return a small `~Copyable` enum from the lock and `switch` on the call instead.
//
// "Exactly once" is checked in every build: a continuation is noncopyable and `resume` consumes it, so a second resume
// doesn't compile, and one dropped without a resume traps ("Continuation was deinitialized without being resumed"). (Until
// 2026-11-25 BytesAsync had its own `Continuation`: a `CheckedContinuation` in debug builds, an unchecked one in release,
// where a lost continuation hung its task.) Nothing is allocated per wait.

/// Suspends the calling task until it's resumed, deciding under `mutex` whether it must wait at all: `decide` gets the
/// state and the task's continuation, and either keeps the continuation (takes it out of the optional, to store
/// where exactly one resume will find it) and returns `nil`, or leaves it and returns the value to resume with now.
///
/// ```swift
/// await wait(in: state) { state, continuation in
///     if state.available > 0 { state.available -= 1; return () }   // Free after all: no wait.
///     state.waiters.append(continuation.take()!)
///     return nil
/// }
/// ```
///
/// The one place a continuation goes into a lock: a closure can't consume a parameter it captures, so the continuation
/// reaches `decide` in an optional, and a path that neither keeps it nor answers traps here, with that message, rather
/// than as a dropped continuation.
///
/// - Parameters:
///   - mutex: The lock and state the wait depends on: the same lock under which a resume finds the stored continuation.
///   - decide: Runs once, under `mutex`, before the task suspends.
/// - Returns: The value the task is resumed with.
@inlinable
public nonisolated(nonsending) func wait<Value, State: ~Copyable>(
    in mutex: borrowing Mutex<State>, _ decide: (inout sending State, inout Continuation<Value, Never>?) -> Value?
) async -> Value {
    await withContinuation(of: Value.self) { continuation in
        var held = Optional(consume continuation)
        let now: Value? = mutex.withLock { state in decide(&state, &held) }
        if let continuation = held.take() {
            guard let now else { preconditionFailure("wait(in:): the continuation was neither kept nor answered") }
            continuation.resume(returning: now)
        } else {
            precondition(now == nil, "wait(in:): the continuation was kept and answered")
        }
    }
}

/// Suspended tasks' continuations (and what they carry), first in, first out, in storage reserved up front: it grows
/// (doubling) only past its capacity, so a steady state allocates nothing. Noncopyable, as its elements may be.
///
/// Not synchronized: state inside its owner's lock.
@frozen
public struct WaiterQueue<Element: ~Copyable>: ~Copyable {
    /// The ring: `head..<head + count`, wrapping, holds the elements; the other slots are `nil`.
    @usableFromInline var slots: UniqueArray<Element?>
    @usableFromInline var head = 0
    @usableFromInline var _count = 0

    /// A queue with room for `capacity` elements before it grows.
    @inlinable
    public init(capacity: Int) {
        slots = Self.emptySlots(max(1, capacity))
    }

    /// A queue with no storage: what ``removeAll()`` returns when nothing waits (it allocates nothing).
    @inlinable
    init() {
        slots = UniqueArray()
    }

    @inlinable
    static func emptySlots(_ capacity: Int) -> UniqueArray<Element?> {
        UniqueArray(capacity: capacity) { output in
            for _ in 0..<capacity {
                output.append(nil)
            }
        }
    }

    /// The elements waiting.
    @inlinable
    public var count: Int { _count }

    /// Whether nothing waits.
    @inlinable
    public var isEmpty: Bool { _count == 0 }

    /// The slot `offset` places after the head, wrapped by a compare (no division).
    @inlinable @inline(__always)
    func slot(_ offset: Int) -> Int {
        let index = head &+ offset
        return index >= slots.count ? index &- slots.count : index
    }

    /// Adds `element` at the end.
    @inlinable
    public mutating func append(_ element: consuming Element) {
        if _count == slots.count { grow() }
        slots[slot(_count)] = consume element
        _count &+= 1
    }

    /// Past the reserved capacity: the elements moved, oldest first, into a ring twice as large.
    @usableFromInline
    mutating func grow() {
        let old = slots.count
        let capacity = max(1, old &* 2)
        var grown = UniqueArray<Element?>(capacity: capacity)
        for offset in 0..<_count {
            grown.append(slots[slot(offset)].take())
        }
        for _ in _count..<capacity {
            grown.append(nil)
        }
        slots = grown
        head = 0
    }

    /// Removes and returns the oldest element, or `nil` if there's none.
    @inlinable
    public mutating func popFirst() -> Element? {
        guard _count > 0 else { return nil }
        let element = slots[head].take()
        head &+= 1
        if head == slots.count { head = 0 }
        _count &-= 1
        return element
    }

    /// Removes and returns the oldest element matching `predicate`, keeping the others in order.
    @inlinable
    public mutating func removeFirst(where predicate: (borrowing Element) -> Bool) -> Element? {
        var found = -1
        for offset in 0..<_count {
            let matched = switch slots[slot(offset)] {
            case let .some(element): predicate(element)
            case .none: false
            }
            if matched {
                found = offset
                break
            }
        }
        guard found >= 0 else { return nil }
        let element = slots[slot(found)].take()
        // The later elements move up one, in order.
        for offset in found..<(_count &- 1) {
            slots[slot(offset)] = slots[slot(offset &+ 1)].take()
        }
        _count &-= 1
        return element
    }

    /// Removes every element matching `predicate`, to resume outside the lock: those in a queue of their own, oldest
    /// first, and the others kept in order. Allocates only when one matches.
    @inlinable
    public mutating func removeAll(where predicate: (borrowing Element) -> Bool) -> WaiterQueue<Element> {
        var removed = WaiterQueue()
        var kept = 0
        for offset in 0..<_count {
            let matched = switch slots[slot(offset)] {
            case let .some(element): predicate(element)
            case .none: false
            }
            if matched {
                removed.append(slots[slot(offset)].take()!)
            } else {
                // Moves up over the removed ones; the slots past the kept ones end empty.
                if kept != offset { slots[slot(kept)] = slots[slot(offset)].take() }
                kept &+= 1
            }
        }
        _count = kept
        return removed
    }

    /// Removes everything, to resume outside the lock: the elements in a queue of their own, oldest first, and this
    /// queue empty with the same capacity. Allocates only when something waits (for closing, once).
    @inlinable
    public mutating func removeAll() -> WaiterQueue<Element> {
        guard _count > 0 else { return WaiterQueue() }
        var all = WaiterQueue(capacity: slots.count)
        swap(&self, &all)
        return all
    }
}

/// Sendable when its elements are (continuations are): waiters taken out of a lock (``WaiterQueue/removeAll()``) are
/// returned from it, which other compilers' region checks accept only for a `Sendable` result.
extension WaiterQueue: Sendable where Element: Sendable & ~Copyable {}
