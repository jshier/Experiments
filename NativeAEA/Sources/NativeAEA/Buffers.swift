import Foundation
import Synchronization

/// Memory allocated once and freed on deinit: segment buffers, read buffers, writer scratch.
///
/// Unsafe throughout, contained here: the pointer is never handed out beyond the object's lifetime by the
/// pipeline (every user holds the object), and concurrent users touch disjoint ranges (see ``SegmentBufferPool``).
@safe
final class RawStorage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let byteCount: Int

    /// - Parameter alignment: Page-aligned (16 KiB) by default, for large buffers (whose pages are given back:
    ///   ``giveBack(_:)``); small ones (paths, tables, headers) take less, so they come from malloc's small blocks.
    init(byteCount: Int, alignment: Int = 16_384) {
        self.byteCount = max(byteCount, 1)
        unsafe base = UnsafeMutableRawPointer.allocate(byteCount: self.byteCount, alignment: alignment)
    }

    /// The alignment for small buffers: 16 bytes, malloc's own (no padding, no page of their own).
    static let small = 16

    deinit {
        unsafe base.deallocate()
    }

    /// A pointer `offset` bytes in.
    ///
    /// - Precondition: `offset` is within the storage.
    @inline(__always)
    func pointer(_ offset: Int) -> UnsafeMutableRawPointer {
        unsafe base + offset
    }
}

extension RawStorage {
    /// What a read buffer keeps resident between uses: pages past it are given back after each use that touched them.
    /// Measured on Xcode's archives (interleaved, 3 rounds each): 2 MiB took extraction's peak footprint from 1,398 to
    /// 1,228 MB (xip) and 1,597 to 1,363 MB (`.aea`), with system time unchanged; 0 and 1 MiB saved 15–35 MB more and
    /// cost 0.1 s more system time in listings; 4 and 8 MiB saved less.
    static let residentFloor = 2 << 20

    /// Before writing `count` bytes from the start: takes back the pages past ``residentFloor`` that ``giveBack(_:)``
    /// gave away (their contents are undefined; the kernel may have taken them).
    @inline(__always)
    func reuse(_ count: Int) {
        guard count > Self.residentFloor else { return }
        let end = min(byteCount, (count + 16_383) & ~16_383)
        // Within the storage, from a page boundary (the base and the floor are multiples of 16 KiB): safe.
        _ = unsafe madvise(base + Self.residentFloor, end - Self.residentFloor, MADV_FREE_REUSE)
    }

    /// After using `count` bytes from the start: gives back the pages past ``residentFloor`` (the process's footprint
    /// drops at once; the kernel takes them only when it needs memory). Call ``reuse(_:)`` before writing them again.
    @inline(__always)
    func giveBack(_ count: Int) {
        guard count > Self.residentFloor else { return }
        let end = min(byteCount, (count + 16_383) & ~16_383)
        // Same range as `reuse`: safe.
        _ = unsafe madvise(base + Self.residentFloor, end - Self.residentFloor, MADV_FREE_REUSABLE)
    }
}

// MARK: - Suspending

// The pipeline's waits (a free buffer, a job, room in a queue, a file system permit, a fork's turn, a decoded chunk)
// suspend the task on a continuation that another task resumes, outside the lock that queued it, exactly once: each
// waiter is removed from its queue under the lock before it's resumed, and a closed primitive resumes every waiter it
// still holds. Debug builds check that with `CheckedContinuation`; release builds use `UnsafeContinuation`, which
// allocates nothing (a checked one allocates a canary object per wait: a writer waits for the file system once per
// file, about 150,000 times for Xcode).
#if DEBUG
typealias Continuation<T> = CheckedContinuation<T, Never>

/// Suspends until `body`'s continuation is resumed.
@inline(__always)
nonisolated(nonsending) func suspend<T>(_ body: (Continuation<T>) -> Void) async -> T {
    await withCheckedContinuation(body)
}
#else
/// An `UnsafeContinuation`, its unsafety contained here: every one is resumed exactly once (see above).
@safe
struct Continuation<T>: Sendable {
    private let base: UnsafeContinuation<T, Never>

    @inline(__always)
    init(_ base: UnsafeContinuation<T, Never>) {
        unsafe self.base = base
    }

    @inline(__always)
    func resume(returning value: sending T) {
        unsafe base.resume(returning: value)
    }

    @inline(__always)
    func resume() where T == Void {
        unsafe base.resume()
    }
}

/// Suspends until `body`'s continuation is resumed.
@inline(__always)
nonisolated(nonsending) func suspend<T>(_ body: (Continuation<T>) -> Void) async -> T {
    await unsafe withUnsafeContinuation { unsafe body(Continuation($0)) }
}
#endif

/// Suspended tasks' continuations (and what they carry), first in, first out, in storage reserved up front: it grows
/// (doubling) only past its capacity, so a steady state allocates nothing.
struct WaiterQueue<Element> {
    private var slots: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        slots = Array(repeating: nil, count: max(1, capacity))
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ element: Element) {
        if count == slots.count {
            // Past the reserved capacity: unroll into a larger ring, oldest first.
            var grown: [Element?] = Array(repeating: nil, count: slots.count * 2)
            for index in 0..<count { grown[index] = slots[(head + index) % slots.count] }
            slots = grown
            head = 0
        }
        slots[(head + count) % slots.count] = element
        count += 1
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = slots[head]
        slots[head] = nil
        head = (head + 1) % slots.count
        count -= 1
        return element
    }

    /// Removes and returns the oldest element matching `predicate`, keeping the others in order.
    mutating func removeFirst(where predicate: (Element) -> Bool) -> Element? {
        var found: Element?
        for _ in 0..<count {
            let element = popFirst()!
            if found == nil, predicate(element) {
                found = element
            } else {
                append(element)
            }
        }
        return found
    }

    /// Removes everything (an allocation: for closing, once).
    mutating func removeAll() -> [Element] {
        var all: [Element] = []
        all.reserveCapacity(count)
        while let element = popFirst() { all.append(element) }
        return all
    }
}

// MARK: - Buffers

/// A fixed set of buffers that each hold one decompressed segment, handed out in the order they're asked for
/// and returned when the last job using one finishes.
///
/// Layout of a buffer: a carry region of ``carryCapacity`` bytes, then the segment's bytes. When an entry's
/// header starts at the end of one segment, the parser copies its first bytes into the next buffer's carry
/// region, just before that segment's bytes, so the header is contiguous.
///
/// Memory: `count * (carryCapacity + segmentSize)`, allocated once. The count bounds how far decoding runs
/// ahead of writing: decoders suspend until a buffer is free.
final class SegmentBufferPool: Sendable {
    /// Room for a partial header: headers are at most 65,535 bytes.
    static let carryCapacity = 65_536

    let count: Int
    let segmentCapacity: Int
    let stride: Int
    private let storage: RawStorage
    /// References per buffer: the parser's while it reads the segment, plus one per job using its bytes.
    private let references: [AtomicCounter]

    private struct State {
        /// Free buffers, last freed on top.
        var free: [Int]
        /// Tasks suspended in ``acquire()``: each released buffer goes to the longest waiting.
        var waiters: WaiterQueue<Continuation<Int?>>
        /// No more buffers are handed out (``close()``); releases still return them.
        var closed = false
        /// Buffers `active..<count` aren't handed out until ``activateAll()``.
        var active: Int
    }

    private let state: Mutex<State>
    /// Buffers in use at once, at most.
    let peakInUse = Atomic<Int>(0)
    private let inUse = Atomic<Int>(0)

    /// - Parameter active: Buffers handed out until ``activateAll()`` (all of them if `nil`): for a pool sized before
    ///   its consumer is known (``AEAPayload``). The others are never touched until then, so their pages never become
    ///   resident if they're never activated.
    init(count: Int, segmentCapacity: Int, active: Int? = nil) {
        self.count = count
        self.segmentCapacity = segmentCapacity
        // Room past the segment for decoders that copy in 16-byte steps; a multiple of the page size.
        stride = (Self.carryCapacity + segmentCapacity + 64 + 16_383) & ~16_383
        storage = RawStorage(byteCount: stride * count)
        references = (0..<count).map { _ in AtomicCounter() }
        let active = max(1, min(count, active ?? count))
        var free = Array((0..<active).reversed())
        free.reserveCapacity(count)
        // Everyone who can wait for a buffer holds none of the others: at most `count` waiters.
        state = Mutex(State(free: free, waiters: WaiterQueue(capacity: count), active: active))
    }

    /// Hands out every buffer from now on: the inactive ones go to tasks waiting for a buffer, then to the bottom of the
    /// free list (recently freed buffers, whose pages are resident, stay first).
    func activateAll() {
        let handed: [(Continuation<Int?>, Int)] = state.withLock { state in
            guard state.active < count else { return [] }
            var handed: [(Continuation<Int?>, Int)] = []
            var added: [Int] = []
            for index in state.active..<count {
                // Waiters first (a closed pool has none: closing resumed them).
                if let waiter = state.waiters.popFirst() { handed.append((waiter, index)) } else { added.append(index) }
            }
            state.free.insert(contentsOf: added.reversed(), at: 0)
            state.active = count
            return handed
        }
        for (waiter, index) in handed { waiter.resume(returning: index) }
    }

    /// Buffers acquired and not yet released.
    var buffersInUse: Int { inUse.load(ordering: .relaxed) }

    /// Tasks waiting in ``acquire()`` (for tests).
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// A free buffer now, with one reference: `nil` if there's none, or the pool is closed.
    func tryAcquire() -> Int? {
        let index: Int? = state.withLock { state in state.closed ? nil : state.free.popLast() }
        return index.map(taken)
    }

    /// Takes a free buffer with one reference, suspending the task until one is released if none is free.
    ///
    /// - Returns: `nil` once the pool is closed.
    nonisolated(nonsending) func acquire() async -> Int? {
        // `.some(nil)`: closed; `nil`: wait.
        let now: Int?? = state.withLock { state in
            if state.closed { return .some(nil) }
            if let index = state.free.popLast() { return .some(index) }
            return nil
        }
        let index: Int?
        if let now {
            index = now
        } else {
            index = await suspend { (continuation: Continuation<Int?>) in
                // Checked again under the lock `release` holds while it decides where a buffer goes: no wakeup is lost.
                let ready: Int?? = state.withLock { state in
                    if state.closed { return .some(nil) }
                    if let index = state.free.popLast() { return .some(index) }
                    state.waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
        return index.map(taken)
    }

    private func taken(_ index: Int) -> Int {
        references[index].value.store(1, ordering: .relaxed)
        let now = inUse.add(1, ordering: .relaxed).newValue
        peakInUse.max(now, ordering: .relaxed)
        return index
    }

    func retain(_ index: Int) {
        references[index].value.add(1, ordering: .relaxed)
    }

    /// Drops a reference; the last one hands the buffer to the task waiting longest for one, or returns it to the pool.
    func release(_ index: Int) {
        if references[index].value.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            inUse.subtract(1, ordering: .relaxed)
            let waiter: Continuation<Int?>? = state.withLock { state in
                if let waiter = state.waiters.popFirst() { return waiter }
                state.free.append(index)
                return nil
            }
            waiter?.resume(returning: index)
        }
    }

    /// Stops handing out buffers: tasks waiting in ``acquire()`` get `nil`, and so do later calls. Buffers still go back
    /// to the pool when released.
    func close() {
        let waiters = state.withLock { state -> [Continuation<Int?>] in
            guard !state.closed else { return [] }
            state.closed = true
            return state.waiters.removeAll()
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    /// Where `index`'s segment bytes start (after the carry region).
    @inline(__always)
    func segmentBase(_ index: Int) -> UnsafeMutableRawPointer {
        unsafe storage.pointer(index * stride + Self.carryCapacity)
    }
}

// MARK: - Queues and limits

/// A first-in, first-out queue with a fixed capacity, between tasks: `push` suspends while it's full and `pop` while
/// it's empty. A job pushed while a consumer waits goes straight to it; a consumer taking from a full queue moves a
/// waiting producer's job in. The ring and the waiters' storage are allocated once.
final class JobQueue<Job: Sendable>: Sendable {
    private struct State {
        var ring: [Job?]
        var head = 0
        var count = 0
        var closed = false
        /// Jobs taken so far (see ``JobQueue/waitUntilPopped(_:)``).
        var popped = 0
        /// Consumers waiting on an empty queue, and producers on a full one, each with the job it brings.
        var consumers: WaiterQueue<Continuation<Job?>>
        var producers: WaiterQueue<(Continuation<Bool>, Job)>
        /// Tasks waiting for `popped` to reach a count, and whether those waits are over for good (a failure).
        var watchers: WaiterQueue<(Int, Continuation<Void>)>
        var watchersReleased = false

        /// Takes the oldest job, moving a waiting producer's in behind it.
        mutating func take() -> (job: Job, producer: Continuation<Bool>?, watcher: Continuation<Void>?)? {
            guard count > 0 else { return nil }
            let job = ring[head]!
            ring[head] = nil
            head = (head + 1) % ring.count
            count -= 1
            var producer: Continuation<Bool>?
            if let (waiting, waitingJob) = producers.popFirst() {
                ring[(head + count) % ring.count] = waitingJob
                count += 1
                producer = waiting
            }
            return (job, producer, taken())
        }

        /// Counts a job taken; a watcher it satisfies (one per job: each later job wakes the next).
        mutating func taken() -> Continuation<Void>? {
            popped += 1
            guard !watchers.isEmpty else { return nil }
            let target = popped
            return watchers.removeFirst { $0.0 <= target }?.1
        }

        /// Watchers to wake now that every job is taken and no more will come (the queue is closed and empty).
        mutating func drainedWatchers() -> [Continuation<Void>] {
            closed && count == 0 && !watchers.isEmpty ? watchers.removeAll().map(\.1) : []
        }
    }

    private let state: Mutex<State>
    /// Nanoseconds producers waited for room.
    let pushWaitNanoseconds = Atomic<Int>(0)

    /// - Parameter waiters: Tasks expected to wait at once, reserved for (more grow the storage once).
    init(capacity: Int, waiters: Int = 32) {
        state = Mutex(State(
            ring: Array(repeating: nil, count: capacity), consumers: WaiterQueue(capacity: waiters),
            producers: WaiterQueue(capacity: 4), watchers: WaiterQueue(capacity: 4)
        ))
    }

    private enum Offer {
        case added
        case handed(Continuation<Job?>, watcher: Continuation<Void>?)
        case full
        case closed
    }

    /// Adds a job, suspending while the queue is full.
    ///
    /// - Returns: `false` if the queue was closed instead (the job isn't added: its resources are the caller's).
    @discardableResult
    nonisolated(nonsending) func push(_ job: Job) async -> Bool {
        switch state.withLock({ Self.offer(job, &$0) }) {
        case .added: return true
        case .closed: return false
        case .handed(let consumer, let watcher):
            consumer.resume(returning: job)
            watcher?.resume()
            return true
        case .full:
            let start = DispatchTime.now().uptimeNanoseconds
            defer { pushWaitNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - start), ordering: .relaxed) }
            return await suspend { (continuation: Continuation<Bool>) in
                // A consumer moves the job in and resumes this one with `true`; closing resumes it with `false`.
                let offer = state.withLock { state in
                    let offer = Self.offer(job, &state)
                    if case .full = offer { state.producers.append((continuation, job)) }
                    return offer
                }
                switch offer {
                case .full: break
                case .added: continuation.resume(returning: true)
                case .closed: continuation.resume(returning: false)
                case .handed(let consumer, let watcher):
                    consumer.resume(returning: job)
                    watcher?.resume()
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private static func offer(_ job: Job, _ state: inout State) -> Offer {
        if state.closed { return .closed }
        if let consumer = state.consumers.popFirst() {
            // Only waiting on an empty queue: the job goes straight to it.
            return .handed(consumer, watcher: state.taken())
        }
        guard state.count < state.ring.count else { return .full }
        state.ring[(state.head + state.count) % state.ring.count] = job
        state.count += 1
        return .added
    }

    /// Takes the oldest job, suspending while the queue is empty; `nil` once it's closed and empty.
    nonisolated(nonsending) func pop() async -> Job? {
        // `.some(nil)`: closed and empty; `nil`: wait.
        let now: (job: Job, producer: Continuation<Bool>?, watcher: Continuation<Void>?, drained: [Continuation<Void>])?? = state.withLock { state in
            if let taken = state.take() { return .some((taken.job, taken.producer, taken.watcher, state.drainedWatchers())) }
            return state.closed ? .some(nil) : nil
        }
        if let now {
            guard let now else { return nil }
            now.producer?.resume(returning: true)
            now.watcher?.resume()
            for watcher in now.drained { watcher.resume() }
            return now.job
        }
        return await suspend { (continuation: Continuation<Job?>) in
            let ready: (job: Job, producer: Continuation<Bool>?, watcher: Continuation<Void>?, drained: [Continuation<Void>])?? = state.withLock { state in
                if let taken = state.take() { return .some((taken.job, taken.producer, taken.watcher, state.drainedWatchers())) }
                if state.closed { return .some(nil) }
                state.consumers.append(continuation)
                return nil
            }
            guard let ready else { return }
            guard let ready else {
                continuation.resume(returning: nil)
                return
            }
            ready.producer?.resume(returning: true)
            ready.watcher?.resume()
            for watcher in ready.drained { watcher.resume() }
            continuation.resume(returning: ready.job)
        }
    }

    /// Takes every job left without waiting (after the tasks using the queue have ended).
    func drain(_ body: (Job) -> Void) {
        while let taken = state.withLock({ $0.take() }) {
            taken.producer?.resume(returning: true)
            taken.watcher?.resume()
            body(taken.job)
        }
    }

    /// Suspends until `count` jobs have been taken, or the queue is closed and empty, or ``releaseWatchers()`` was
    /// called.
    nonisolated(nonsending) func waitUntilPopped(_ count: Int) async {
        let done = state.withLock { state in state.popped >= count || state.watchersReleased || (state.closed && state.count == 0) }
        if done { return }
        await suspend { (continuation: Continuation<Void>) in
            let ready = state.withLock { state in
                if state.popped >= count || state.watchersReleased || (state.closed && state.count == 0) { return true }
                state.watchers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Ends every wait in ``waitUntilPopped(_:)``, now and later (after a failure).
    func releaseWatchers() {
        let watchers = state.withLock { state -> [Continuation<Void>] in
            state.watchersReleased = true
            return state.watchers.removeAll().map(\.1)
        }
        for watcher in watchers { watcher.resume() }
    }

    /// No more jobs: consumers waiting on an empty queue get `nil`, and producers waiting for room get `false`.
    func close() {
        let (consumers, producers, watchers) = state.withLock { state -> ([Continuation<Job?>], [Continuation<Bool>], [Continuation<Void>]) in
            guard !state.closed else { return ([], [], []) }
            state.closed = true
            return (state.consumers.removeAll(), state.producers.removeAll().map(\.0), state.drainedWatchers())
        }
        for consumer in consumers { consumer.resume(returning: nil) }
        for producer in producers { producer.resume(returning: false) }
        for watcher in watchers { watcher.resume() }
    }
}

/// At most a fixed number of tasks at once in a section: a task beyond them suspends until one leaves, and each
/// permit returned goes straight to the longest waiting.
final class AsyncLimiter: Sendable {
    private struct State {
        var available: Int
        var waiters: WaiterQueue<Continuation<Void>>
    }

    private let state: Mutex<State>

    /// - Parameter waiters: Tasks expected to wait at once, reserved for.
    init(_ permits: Int, waiters: Int = 32) {
        state = Mutex(State(available: max(1, permits), waiters: WaiterQueue(capacity: waiters)))
    }

    nonisolated(nonsending) func acquire() async {
        let now = state.withLock { state in
            guard state.available > 0 else { return false }
            state.available -= 1
            return true
        }
        if now { return }
        await suspend { (continuation: Continuation<Void>) in
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

    func release() {
        let waiter: Continuation<Void>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter } // The permit passes to it.
            state.available += 1
            return nil
        }
        waiter?.resume()
    }

    /// Runs `body` (synchronous: no suspension holds a permit) with a permit.
    @inline(__always)
    nonisolated(nonsending) func withPermit<R, E: Error>(_ body: () throws(E) -> R) async throws(E) -> R {
        await acquire()
        defer { release() }
        return try body()
    }
}

/// A fixed set of indexes (slots of some table), handed out one at a time: a task asking when none is free suspends
/// until one is released, and each released index goes straight to the longest waiting.
final class AsyncIndexPool: Sendable {
    private struct State {
        var free: [Int]
        var waiters: WaiterQueue<Continuation<Int>>
    }

    private let state: Mutex<State>

    init(count: Int, waiters: Int = 32) {
        var free = Array((0..<count).reversed())
        free.reserveCapacity(count)
        state = Mutex(State(free: free, waiters: WaiterQueue(capacity: waiters)))
    }

    nonisolated(nonsending) func acquire() async -> Int {
        if let index = state.withLock({ $0.free.popLast() }) { return index }
        return await suspend { (continuation: Continuation<Int>) in
            let ready: Int? = state.withLock { state in
                if let index = state.free.popLast() { return index }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func release(_ index: Int) {
        let waiter: Continuation<Int>? = state.withLock { state in
            if let waiter = state.waiters.popFirst() { return waiter }
            state.free.append(index)
            return nil
        }
        waiter?.resume(returning: index)
    }
}

/// A count of tasks still to finish, and one task that waits for them all (the walker waiting for the writers).
final class AsyncLatch: Sendable {
    private let state: Mutex<(remaining: Int, waiter: Continuation<Void>?)>

    init(count: Int) {
        state = Mutex((max(0, count), nil))
    }

    /// One more has finished; the last resumes the waiter.
    func arrive() {
        let waiter: Continuation<Void>? = state.withLock { state in
            state.remaining -= 1
            guard state.remaining == 0 else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Suspends until all have finished.
    nonisolated(nonsending) func wait() async {
        if state.withLock({ $0.remaining <= 0 }) { return }
        await suspend { (continuation: Continuation<Void>) in
            let done = state.withLock { state in
                if state.remaining <= 0 { return true }
                state.waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// The first error of work spread over tasks.
final class FirstFailure: Sendable {
    private let stored = Mutex<AEAError?>(nil)

    func record(_ error: AEAError) {
        stored.withLock { if $0 == nil { $0 = error } }
    }

    var error: AEAError? { stored.withLock { $0 } }
}

/// An atomic integer with an identity, so arrays can hold them (`Atomic` isn't copyable).
final class AtomicCounter: Sendable {
    let value = Atomic<Int>(0)
}

/// Nanoseconds spent per kind of work across the writers, for finding the bottleneck.
final class WorkTimings: Sendable {
    enum Kind: Int, CaseIterable {
        case wait, open, data, fork, attribute, finish, close, compress, mkdir, symlink, push, largeFileWait, largeFileOpen, link, linkWait
    }

    private let counters = (0..<Kind.allCases.count).map { _ in AtomicCounter() }

    @inline(__always)
    func measure<R, E: Error>(_ kind: Kind, _ body: () throws(E) -> R) throws(E) -> R {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { counters[kind.rawValue].value.add(Int(DispatchTime.now().uptimeNanoseconds - start), ordering: .relaxed) }
        return try body()
    }

    var seconds: [String: Double] {
        Dictionary(uniqueKeysWithValues: Kind.allCases.map { ("\($0)", Double(counters[$0.rawValue].value.load(ordering: .relaxed)) / 1e9) })
    }
}

extension WorkTimings {
    @inline(__always)
    func add(_ kind: Kind, since start: UInt64) {
        counters[kind.rawValue].value.add(Int(DispatchTime.now().uptimeNanoseconds - start), ordering: .relaxed)
    }
}
