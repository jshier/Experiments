import Bytes
import BytesAsync
import Foundation
import Synchronization

// The decoding pipeline's waits (a free buffer, a block job, a decoded chunk) are BytesAsync's: `Mutex` state plus a
// `Continuation` another task resumes, outside the lock, exactly once (`withContinuation`, `WaiterQueue`; the block
// stream's queue is its `AsyncQueue`). Memory made once (segment buffers, read buffers, decoder scratch) is Bytes'
// `RawStorage`, whose `reuse`/`giveBack` keep only a floor of a large read buffer resident between uses. The writers'
// waits are Disk's, built on the same primitives.

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
    /// References per buffer: the parser's while it reads the segment, plus one per job using its bytes. One
    /// allocation for all of them.
    private let references: RelaxedCounters

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
        references = RelaxedCounters(count: count)
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
            index = await withContinuation { (continuation: Continuation<Int?>) in
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
        references.store(1, at: index)
        let now = inUse.add(1, ordering: .relaxed).newValue
        peakInUse.max(now, ordering: .relaxed)
        return index
    }

    func retain(_ index: Int) {
        references.add(at: index)
    }

    /// Drops a reference; the last one hands the buffer to the task waiting longest for one, or returns it to the pool.
    func release(_ index: Int) {
        // The last release publishes every holder's reads of the buffer to its next user: not relaxed.
        if references.withAtomic(at: index, { $0.subtract(1, ordering: .acquiringAndReleasing).newValue }) == 0 {
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
