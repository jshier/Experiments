public import Synchronization

// Limits for tasks: a count of permits, a set of indexes, a countdown. Each is `Mutex` state plus continuations
// (Waiting.swift): nothing suspends that doesn't have to wait, and a steady state allocates nothing.

/// At most a fixed number of tasks at once in a section: a task beyond them suspends until one leaves, and each
/// permit returned goes straight to the task waiting longest.
///
/// ```swift
/// let fileSystem = AsyncLimiter(6)
/// try await fileSystem.withPermit { try write(file) }
/// ```
///
/// Waits aren't cancellable: a holder always releases, so a waiter always gets its permit.
public final class AsyncLimiter: Sendable {
    @usableFromInline
    struct State: ~Copyable {
        @usableFromInline var available: Int
        @usableFromInline var waiters: WaiterQueue<Continuation<Void, Never>>

        @inlinable
        init(available: Int, waiters: consuming WaiterQueue<Continuation<Void, Never>>) {
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

    /// Takes a permit, suspending until one is released if none is free. Pair it with ``release()``; or let
    /// ``withPermit(_:)`` do both.
    @inlinable
    public nonisolated(nonsending) func acquire() async {
        let now = state.withLock { state in
            guard state.available > 0 else { return false }
            state.available -= 1
            return true
        }
        if now { return }
        await wait(in: state) { state, continuation in
            // Checked again under the lock `release` takes: no wakeup is lost.
            if state.available > 0 {
                state.available -= 1
                return ()
            }
            state.waiters.append(continuation.take()!)
            return nil
        }
    }

    /// Returns a permit: to the task waiting longest, if any.
    @inlinable
    public func release() {
        let waiter: Continuation<Void, Never>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter } // The permit passes to it.
            state.available += 1
            return nil
        }
        waiter?.resume()
    }

    /// Runs `body` holding a permit, released when it returns or throws.
    ///
    /// - Parameter body: The section. Runs on the caller's isolation.
    /// - Returns: What `body` returns.
    @inlinable
    public nonisolated(nonsending) func withPermit<Result: ~Copyable, Failure: Error>(
        _ body: nonisolated(nonsending) () async throws(Failure) -> Result
    ) async throws(Failure) -> Result {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// A fixed set of indexes (slots of a table, buffers of a pool), handed out one at a time: a task asking when none is
/// free suspends until one is released, which goes straight to the task waiting longest. The last released is the
/// first handed out (its memory is the warmest).
///
/// A pool can hand out only some of its indexes at first (``init(count:active:waiters:)``), the rest from
/// ``activateAll()`` on, and can be closed (``close()``): its waiters, and later requests, get `nil`.
public final class AsyncIndexPool: Sendable {
    @usableFromInline
    struct State: ~Copyable {
        /// Free indexes, last released on top.
        @usableFromInline var free: [Int]
        @usableFromInline var waiters: WaiterQueue<Continuation<Int?, Never>>
        /// Indexes `active..<count` aren't handed out until ``activateAll()``.
        @usableFromInline var active: Int
        /// No more indexes are handed out; releases still return them.
        @usableFromInline var closed = false

        @inlinable
        init(free: [Int], waiters: consuming WaiterQueue<Continuation<Int?, Never>>, active: Int) {
            self.free = free
            self.waiters = waiters
            self.active = active
        }
    }

    /// The indexes: `0..<count`.
    public let count: Int
    @usableFromInline let state: Mutex<State>

    /// - Parameters:
    ///   - count: The indexes: `0..<count`, handed out from 0 up at first.
    ///   - active: The indexes handed out until ``activateAll()`` (`0..<active`; all of them if `nil`).
    ///   - waiters: Tasks expected to wait at once, reserved for.
    @inlinable
    public init(count: Int, active: Int? = nil, waiters: Int = 4) {
        self.count = count
        let active = max(min(1, count), min(count, active ?? count))
        var free = Array((0..<active).reversed())
        free.reserveCapacity(count)
        state = Mutex(State(free: free, waiters: WaiterQueue(capacity: waiters), active: active))
    }

    /// The indexes handed out now: all of them once ``activateAll()`` has run.
    @inlinable
    public var activeCount: Int { state.withLock { $0.active } }

    /// Tasks waiting in ``acquire()``.
    @inlinable
    public var waiting: Int { state.withLock { $0.waiters.count } }

    /// A free index now, or `nil` if there's none or the pool is closed.
    @inlinable
    public func tryAcquire() -> Int? {
        state.withLock { state in state.closed ? nil : state.free.popLast() }
    }

    /// Takes a free index, suspending until one is released if there's none.
    ///
    /// - Returns: `nil` once the pool is closed.
    @inlinable
    public nonisolated(nonsending) func acquire() async -> Int? {
        // `.some(nil)`: closed; `nil`: wait.
        let now: Int?? = state.withLock { state in
            if state.closed { return .some(nil) }
            if let index = state.free.popLast() { return .some(index) }
            return nil
        }
        if let now { return now }
        return await wait(in: state) { state, continuation in
            // Checked again under the lock `release` holds while it decides where an index goes: no wakeup is lost.
            if state.closed { return .some(nil) }
            if let index = state.free.popLast() { return .some(index) }
            state.waiters.append(continuation.take()!)
            return nil
        }
    }

    /// Returns `index`: to the task waiting longest, if any.
    ///
    /// - Precondition: `index` was acquired and not yet released.
    @inlinable
    public func release(_ index: Int) {
        let waiter: Continuation<Int?, Never>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter }
            state.free.append(index)
            return nil
        }
        waiter?.resume(returning: index)
    }

    /// Hands out every index from now on: the inactive ones go to tasks waiting, then to the bottom of the free list
    /// (indexes released recently, whose memory is warm, stay first).
    @inlinable
    public func activateAll() {
        var handed = state.withLock { state -> WaiterQueue<Handed> in
            guard state.active < count else { return WaiterQueue() }
            // Storage only when someone waits (it's usually nobody).
            var handed = state.waiters.isEmpty ? WaiterQueue<Handed>() : WaiterQueue(capacity: min(state.waiters.count, count &- state.active))
            var added: [Int] = []
            for index in state.active..<count {
                // Waiters first (a closed pool has none: closing resumed them).
                if let waiter = state.waiters.popFirst() {
                    handed.append(Handed(waiter: waiter, index: index))
                } else {
                    added.append(index)
                }
            }
            state.free.insert(contentsOf: added.reversed(), at: 0)
            state.active = count
            return handed
        }
        while let next = handed.popFirst() {
            next.waiter.resume(returning: next.index)
        }
    }

    /// A waiter and the index it's handed, out of the lock.
    @usableFromInline
    struct Handed: ~Copyable {
        @usableFromInline var waiter: Continuation<Int?, Never>
        @usableFromInline var index: Int

        @inlinable
        init(waiter: consuming Continuation<Int?, Never>, index: Int) {
            self.waiter = waiter
            self.index = index
        }
    }

    /// Stops handing out indexes: tasks waiting in ``acquire()`` get `nil`, and so do later calls. Released indexes
    /// still come back.
    @inlinable
    public func close() {
        var waiters = state.withLock { state -> WaiterQueue<Continuation<Int?, Never>> in
            guard !state.closed else { return WaiterQueue() }
            state.closed = true
            return state.waiters.removeAll()
        }
        while let waiter = waiters.popFirst() {
            waiter.resume(returning: nil)
        }
    }
}

/// A count of tasks still to finish, and one task that waits for them all.
public final class AsyncLatch: Sendable {
    @usableFromInline
    struct State: ~Copyable {
        @usableFromInline var remaining: Int
        @usableFromInline var waiter: Continuation<Void, Never>?

        @inlinable
        init(remaining: Int) {
            self.remaining = remaining
            waiter = nil
        }
    }

    @usableFromInline let state: Mutex<State>

    /// - Parameter count: The arrivals ``wait()`` waits for.
    @inlinable
    public init(count: Int) {
        state = Mutex(State(remaining: max(0, count)))
    }

    /// One task has finished; the last arrival resumes the waiting task.
    @inlinable
    public func arrive() {
        let waiter: Continuation<Void, Never>? = state.withLock { state in
            state.remaining -= 1
            guard state.remaining == 0 else { return nil }
            return state.waiter.take()
        }
        waiter?.resume()
    }

    /// Suspends until every arrival has come (at once if they have). One task waits.
    @inlinable
    public nonisolated(nonsending) func wait() async {
        if state.withLock({ $0.remaining <= 0 }) { return }
        await BytesAsync.wait(in: state) { state, continuation in
            if state.remaining <= 0 { return () }
            precondition(state.waiter == nil, "AsyncLatch: one task waits")
            state.waiter = continuation.take()
            return nil
        }
    }
}
