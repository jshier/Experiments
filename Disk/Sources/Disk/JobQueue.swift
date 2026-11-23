import Bytes
import BytesAsync
import Darwin
import Synchronization

// Disk's waits (a job, room in the queue, a file system permit, a large-file slot, a fork's turn, the writers' end) are
// BytesAsync's: `Mutex` state plus a `Continuation`, taken synchronously under the lock when nothing has to wait.
// `AsyncLimiter`, `AsyncIndexPool`, `AsyncLatch`, and `WaiterQueue` are used as they are; the write queue below is
// Disk's own, for its path ring and low-water mark. Scratch memory is Bytes' `RawStorage`.

/// A path for error messages: NUL-terminated bytes the caller keeps valid while it may throw, made into a string only
/// when something fails (no allocation on the way that doesn't).
@safe
struct PathRef {
    private let pointer: UnsafeRawPointer?
    private let count: Int

    /// `count` bytes at `pointer` (not necessarily NUL-terminated).
    init(_ pointer: UnsafeRawPointer, count: Int) {
        // Unsafe: stores the pointer. Safe: read only by `string`, while the caller keeps the bytes (the type's contract).
        unsafe self.pointer = pointer
        self.count = count
    }

    /// A NUL-terminated path.
    init(cString pointer: UnsafePointer<CChar>) {
        // Unsafe: stores the pointer. Safe: as above.
        unsafe self.pointer = UnsafeRawPointer(pointer)
        // Unsafe: `strlen` reads to the NUL. Safe: the caller's string is NUL-terminated (the parameter's contract).
        count = unsafe strlen(pointer)
    }

    /// No path (the destination itself).
    static var none: PathRef { PathRef() }

    private init() {
        // Unsafe: an optional pointer's assignment. Safe: `nil`, never read.
        unsafe pointer = nil
        count = 0
    }

    var string: String {
        // Unsafe: reads the stored pointer. Safe: only its value, compared with `nil`.
        guard let pointer = unsafe pointer else { return "" }
        // Unsafe: a buffer over the caller's bytes. Safe: `count` bytes the caller keeps valid while an error is made.
        return unsafe String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }
}

extension DiskError {
    /// ``system(_:path:code:)`` with the path made only now.
    static func system(_ operation: String, path: PathRef, code: Int32) -> DiskError {
        system(operation, path: path.string, code: code)
    }
}

// MARK: - The write queue

/// A first-in, first-out queue of jobs and their paths between the planner and the writers, with a fixed capacity:
/// `push` suspends while it's full and `pop` while it's empty.
///
/// Each job's path is copied into a ring of bytes the queue owns (no allocation per job), and out again by `pop`
/// into the writer's own buffer, NUL-terminated: jobs leave in order, so the ring's tail is always the oldest path.
/// The job ring, the path ring, and the waiters' storage are allocated once. The job ring isn't initialized: a slot is
/// initialized by `push` and moved out by `pop`, so its pages are touched only as far as jobs fill it (initializing
/// 16,384 slots up front cost about 8 M instructions per extraction).
///
/// A producer waiting for room is woken at a low-water mark, once the queue has drained to half its jobs and half its
/// path bytes (or is empty), not by every pop: then it refills the queue in one run instead of waking once per job.
/// (BytesAsync's `AsyncQueue` is the general queue: it hands each element to a waiting consumer and wakes a producer
/// per pop, and carries no bytes beside its elements.)
@safe
final class JobQueue<Job: Sendable>: @unchecked Sendable {
    // Unchecked: `ring` and `paths` are written by the pusher and read by poppers only under `state`'s lock (their
    // heads and tails are in the state); `state` itself is a `Mutex`.
    private struct Slot {
        var job: Job
        var pathStart: Int
        var pathCount: Int
    }

    private struct State {
        var head = 0
        var count = 0
        /// The path ring: bytes `tail..<head` (wrapping) are in use.
        var pathHead = 0
        var pathTail = 0
        var pathUsed = 0
        var closed = false
        var consumers: WaiterQueue<Continuation<Void>>
        var producers: WaiterQueue<Continuation<Void>>
    }

    private let state: Mutex<State>
    /// `capacity` slots, uninitialized but for the jobs queued: `head..<head + count` (wrapping), in the state.
    private let ring: UnsafeMutablePointer<Slot>
    private let capacity: Int
    private let paths: RawStorage
    private let pathCapacity: Int
    /// Nanoseconds producers waited for room.
    let pushWaitNanoseconds = Atomic<Int>(0)
    /// Times a producer suspended for room (each one a wake-up).
    let pushWaits = Atomic<Int>(0)

    /// - Parameters:
    ///   - capacity: Jobs held at once.
    ///   - pathBytes: Bytes of paths held at once (at least `PATH_MAX`).
    ///   - waiters: Consumers expected to wait at once, reserved for.
    init(capacity: Int, pathBytes: Int, waiters: Int) {
        self.capacity = max(1, capacity)
        // Unsafe: a raw allocation of slots. Safe: owned by the queue and freed in `deinit`; a slot is initialized
        // only while it holds a job (`offer`, `pop`, `deinit`).
        unsafe ring = .allocate(capacity: self.capacity)
        pathCapacity = max(pathBytes, Int(PATH_MAX) * 2)
        paths = RawStorage(byteCount: pathCapacity, alignment: RawStorage.small)
        state = Mutex(State(consumers: WaiterQueue(capacity: waiters), producers: WaiterQueue(capacity: 2)))
    }

    deinit {
        let (head, count) = state.withLock { ($0.head, $0.count) }
        // Unsafe: deinitializes slots. Safe: the jobs still queued (none after an extraction: the writers take every
        // one) are exactly the initialized slots `head..<head + count`, wrapping.
        for index in 0..<count { unsafe (ring + (head + index) % capacity).deinitialize(count: 1) }
        // Unsafe: frees the ring. Safe: `init`'s allocation, every slot uninitialized now.
        unsafe ring.deallocate()
    }

    /// Where `count` path bytes go, wrapping to the start when they don't fit before the end; `nil` if there's no room.
    private func reservePath(_ count: Int, _ state: inout State) -> Int? {
        if state.pathUsed == 0 {
            state.pathHead = 0
            state.pathTail = 0
        }
        // In use: tail..<head, or, wrapped, tail..<capacity and 0..<head. Room is taken only while it leaves a byte
        // between head and tail, so head == tail never means full.
        if state.pathHead >= state.pathTail {
            // Free: head..<capacity, then 0..<tail.
            if pathCapacity - state.pathHead >= count { return state.pathHead }
            return state.pathTail > count ? 0 : nil
        }
        // Wrapped. Free: head..<tail.
        return state.pathTail - state.pathHead > count ? state.pathHead : nil
    }

    private enum Take {
        case job(Job, Int, Continuation<Void>?)
        case done
        case wait
    }

    private enum Offer {
        case added(Continuation<Void>?)
        case full
        case closed
    }

    private func offer(_ job: Job, _ address: UInt, _ pathCount: Int, _ state: inout State) -> Offer {
        if state.closed { return .closed }
        guard state.count < capacity, let start = reservePath(pathCount, &state) else { return .full }
        let slot = (state.head + state.count) % capacity
        // Unsafe: initializes a slot. Safe: the slot after the queued ones, within the ring and uninitialized, under
        // the lock.
        unsafe (ring + slot).initialize(to: Slot(job: job, pathStart: start, pathCount: pathCount))
        // Unsafe: the caller's path, from its address, into the ring. Safe: `pathCount` bytes the caller keeps valid
        // until `push` returns, into the room just reserved (`start..<start + pathCount`, within the ring).
        if pathCount > 0, let base = unsafe UnsafeRawPointer(bitPattern: address) { unsafe (paths.base + start).copyMemory(from: base, byteCount: pathCount) }
        state.pathHead = start + pathCount
        state.pathUsed += pathCount
        state.count += 1
        return .added(state.consumers.popFirst())
    }

    /// Adds a job and its path, suspending while the queue is full.
    ///
    /// - Returns: `false` if the queue was closed instead (the job isn't added: its resources are the caller's).
    @discardableResult
    nonisolated(nonsending) func push(_ job: Job, path: UnsafeRawBufferPointer) async -> Bool {
        // The path as an address and a count (the closures below are checked for sendability): `offer` reads it while
        // the caller keeps its bytes valid, until this returns.
        let address = UInt(bitPattern: path.baseAddress), pathCount = path.count
        while true {
            switch state.withLock({ offer(job, address, pathCount, &$0) }) {
            case .added(let consumer):
                consumer?.resume()
                return true
            case .closed:
                return false
            case .full:
                let start = MonotonicClock.now
                // Suspend until a pop makes room (checked again under the lock: no lost wakeup), then retry.
                await withContinuation { (continuation: Continuation<Void>) in
                    let wait = state.withLock { state in
                        if state.closed || (state.count < capacity && reservePath(pathCount, &state) != nil) { return false }
                        state.producers.append(continuation)
                        return true
                    }
                    if !wait { continuation.resume() }
                }
                pushWaitNanoseconds.add(MonotonicClock.nanoseconds(since: start), ordering: .relaxed)
                pushWaits.add(1, ordering: .relaxed)
            }
        }
    }

    /// Takes the oldest job, copying its path into `pathBuffer` (at least `PATH_MAX` bytes) with a NUL after it;
    /// suspends while the queue is empty. `nil` once it's closed and empty.
    nonisolated(nonsending) func pop(pathInto pathBuffer: UnsafeMutableRawPointer) async -> (job: Job, pathCount: Int)? {
        while true {
            let take: Take = state.withLock { state in
                guard state.count > 0 else { return state.closed ? .done : .wait }
                // Unsafe: moves a slot out. Safe: the oldest queued slot, initialized by `offer`; uninitialized again
                // after, as the state's new head records.
                let slot = unsafe (ring + state.head).move()
                let start = slot.pathStart, count = slot.pathCount
                // Unsafe: the path's bytes from the ring into the caller's buffer. Safe: written by `offer` under this
                // lock, under `PATH_MAX` bytes; the buffer holds `PATH_MAX` and the NUL (the caller's contract).
                unsafe pathBuffer.copyMemory(from: paths.base + start, byteCount: count)
                // Unsafe: the NUL after them. Safe: within the caller's buffer, as above.
                unsafe pathBuffer.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
                let job = slot.job
                state.head = (state.head + 1) % capacity
                state.count -= 1
                state.pathTail = start + count
                state.pathUsed -= count
                // A waiting producer is woken at the low-water mark. Some pop reaches it: an empty queue meets it.
                guard !state.producers.isEmpty, state.count <= capacity / 2, state.pathUsed <= pathCapacity / 2 else {
                    return .job(job, count, nil)
                }
                return .job(job, count, state.producers.popFirst())
            }
            switch take {
            case .job(let job, let count, let producer):
                producer?.resume()
                return (job, count)
            case .done:
                return nil
            case .wait:
                await withContinuation { (continuation: Continuation<Void>) in
                    let wait = state.withLock { state in
                        if state.count > 0 || state.closed { return false }
                        state.consumers.append(continuation)
                        return true
                    }
                    if !wait { continuation.resume() }
                }
            }
        }
    }

    /// No more jobs: waiting consumers finish once the queue is empty, and waiting producers give up.
    func close() {
        let (consumers, producers) = state.withLock { state -> ([Continuation<Void>], [Continuation<Void>]) in
            guard !state.closed else { return ([], []) }
            state.closed = true
            return (state.consumers.removeAll(), state.producers.removeAll())
        }
        for consumer in consumers { consumer.resume() }
        for producer in producers { producer.resume() }
    }
}
