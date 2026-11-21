public import Synchronization

// Limits for tasks: a count of permits, a set of indexes, a countdown. Each is `Mutex` state plus continuations
// (Waiting.swift): nothing suspends that doesn't have to wait, and a steady state allocates nothing.

/// At most a fixed number of tasks at once in a section: a task beyond them suspends until one leaves, and each
/// permit returned goes straight to the task waiting longest.
///
/// ```swift
/// let fileSystem = AsyncLimiter(6)
/// await fileSystem.acquire()
/// defer { fileSystem.release() }
/// ```
///
/// Waits aren't cancellable: a holder always releases, so a waiter always gets its permit.
public final class AsyncLimiter: Sendable {
    @usableFromInline
    struct State {
        @usableFromInline var available: Int
        @usableFromInline var waiters: WaiterQueue<Continuation<Void>>

        @inlinable
        init(available: Int, waiters: WaiterQueue<Continuation<Void>>) {
            self.available = available
            self.waiters = waiters
        }
    }

    @usableFromInline let state: Mutex<State>

    /// - Parameters:
    ///   - permits: Tasks inside at once (at least 1).
    ///   - waiters: Tasks expected to wait at once, reserved for (more grow the storage once).
    @inlinable
    public init(_ permits: Int, waiters: Int = 32) {
        state = Mutex(State(available: max(1, permits), waiters: WaiterQueue(capacity: waiters)))
    }

    /// Takes a permit, suspending until one is released if none is free.
    @inlinable
    public nonisolated(nonsending) func acquire() async {
        let now = state.withLock { state in
            guard state.available > 0 else { return false }
            state.available -= 1
            return true
        }
        if now { return }
        await withContinuation { (continuation: Continuation<Void>) in
            // Checked again under the lock `release` takes: no wakeup is lost.
            let ready = state.withLock { state in
                if state.available > 0 {
                    state.available -= 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Returns a permit: to the task waiting longest, if any.
    @inlinable
    public func release() {
        let waiter: Continuation<Void>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter } // The permit passes to it.
            state.available += 1
            return nil
        }
        waiter?.resume()
    }
}

/// A fixed set of indexes (slots of a table, buffers of a pool), handed out one at a time: a task asking when none is
/// free suspends until one is released, which goes straight to the task waiting longest. The last released is the
/// first handed out (its memory is the warmest).
public final class AsyncIndexPool: Sendable {
    @usableFromInline
    struct State {
        @usableFromInline var free: [Int]
        @usableFromInline var waiters: WaiterQueue<Continuation<Int>>

        @inlinable
        init(free: [Int], waiters: WaiterQueue<Continuation<Int>>) {
            self.free = free
            self.waiters = waiters
        }
    }

    @usableFromInline let state: Mutex<State>

    /// - Parameters:
    ///   - count: The indexes: `0..<count`, handed out from 0 up at first.
    ///   - waiters: Tasks expected to wait at once, reserved for.
    @inlinable
    public init(count: Int, waiters: Int = 4) {
        var free = Array((0..<count).reversed())
        free.reserveCapacity(count)
        state = Mutex(State(free: free, waiters: WaiterQueue(capacity: waiters)))
    }

    /// Takes a free index, suspending until one is released if there's none.
    @inlinable
    public nonisolated(nonsending) func acquire() async -> Int {
        if let index = state.withLock({ $0.free.popLast() }) { return index }
        return await withContinuation { (continuation: Continuation<Int>) in
            let ready: Int? = state.withLock { state in
                if let index = state.free.popLast() { return index }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Returns `index`: to the task waiting longest, if any.
    ///
    /// - Precondition: `index` was acquired and not yet released.
    @inlinable
    public func release(_ index: Int) {
        let waiter: Continuation<Int>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter }
            state.free.append(index)
            return nil
        }
        waiter?.resume(returning: index)
    }
}

/// A count of tasks still to finish, and one task that waits for them all.
public final class AsyncLatch: Sendable {
    @usableFromInline let state: Mutex<(remaining: Int, waiter: Continuation<Void>?)>

    /// - Parameter count: The arrivals ``wait()`` waits for.
    @inlinable
    public init(count: Int) {
        state = Mutex((max(0, count), nil))
    }

    /// One task has finished; the last arrival resumes the waiting task.
    @inlinable
    public func arrive() {
        let waiter: Continuation<Void>? = state.withLock { state in
            state.remaining -= 1
            guard state.remaining == 0 else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Suspends until every arrival has come (at once if they have). One task waits.
    @inlinable
    public nonisolated(nonsending) func wait() async {
        if state.withLock({ $0.remaining <= 0 }) { return }
        await withContinuation { (continuation: Continuation<Void>) in
            let done = state.withLock { state in
                if state.remaining <= 0 { return true }
                state.waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }
}
