import Foundation
import Synchronization

/// Memory allocated once, page-aligned, and freed on deinit: segment buffers, read buffers, writer scratch.
///
/// Unsafe throughout, contained here: the pointer is never handed out beyond the object's lifetime by the
/// pipeline (every user holds the object), and concurrent users touch disjoint ranges (see ``SegmentBufferPool``).
@safe
final class RawStorage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) {
        self.byteCount = max(byteCount, 1)
        unsafe base = UnsafeMutableRawPointer.allocate(byteCount: self.byteCount, alignment: 16_384)
    }

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

/// A fixed set of buffers that each hold one decompressed segment, handed out in the order they're asked for
/// and returned when the last job using one finishes.
///
/// Layout of a buffer: a carry region of ``carryCapacity`` bytes, then the segment's bytes. When an entry's
/// header starts at the end of one segment, the parser copies its first bytes into the next buffer's carry
/// region, just before that segment's bytes, so the header is contiguous.
///
/// Memory: `count * (carryCapacity + segmentSize)`, allocated once. The count bounds how far decoding runs
/// ahead of writing: decoders wait for a free buffer.
final class SegmentBufferPool: @unchecked Sendable {
    /// Room for a partial header: headers are at most 65,535 bytes.
    static let carryCapacity = 65_536

    let count: Int
    let segmentCapacity: Int
    let stride: Int
    private let storage: RawStorage
    /// References per buffer: the parser's while it reads the segment, plus one per job using its bytes.
    private let references: [AtomicCounter]
    private let free: Mutex<[Int]>
    private let available: DispatchSemaphore
    /// Buffers in use at once, at most.
    let peakInUse = Atomic<Int>(0)
    private let inUse = Atomic<Int>(0)

    init(count: Int, segmentCapacity: Int) {
        self.count = count
        self.segmentCapacity = segmentCapacity
        // Room past the segment for decoders that copy in 16-byte steps; a multiple of the page size.
        stride = (Self.carryCapacity + segmentCapacity + 64 + 16_383) & ~16_383
        storage = RawStorage(byteCount: stride * count)
        references = (0..<count).map { _ in AtomicCounter() }
        free = Mutex(Array((0..<count).reversed()))
        available = DispatchSemaphore(value: count)
    }

    deinit {
        // Dispatch traps when a semaphore is freed below its starting value: balance it for buffers still out (after
        // a failure). ``buffersInUse`` is 0 after a successful pass; the tests check it.
        for _ in 0..<inUse.load(ordering: .relaxed) { available.signal() }
    }

    /// Buffers acquired and not yet released.
    var buffersInUse: Int { inUse.load(ordering: .relaxed) }

    /// Takes a free buffer, waiting for one, with one reference.
    func acquire() -> Int {
        available.wait()
        let index = free.withLock { $0.removeLast() }
        references[index].value.store(1, ordering: .relaxed)
        let now = inUse.add(1, ordering: .relaxed).newValue
        var peak = peakInUse.load(ordering: .relaxed)
        while now > peak {
            let (exchanged, original) = peakInUse.compareExchange(expected: peak, desired: now, ordering: .relaxed)
            if exchanged { break }
            peak = original
        }
        return index
    }

    func retain(_ index: Int) {
        references[index].value.add(1, ordering: .relaxed)
    }

    /// Drops a reference; the last one returns the buffer to the pool.
    func release(_ index: Int) {
        if references[index].value.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            inUse.subtract(1, ordering: .relaxed)
            free.withLock { $0.append(index) }
            available.signal()
        }
    }

    /// Where `index`'s segment bytes start (after the carry region).
    @inline(__always)
    func segmentBase(_ index: Int) -> UnsafeMutableRawPointer {
        unsafe storage.pointer(index * stride + Self.carryCapacity)
    }
}

/// A blocking first-in, first-out queue with a fixed capacity, for jobs from the parser to the writers.
final class JobQueue<Job: Sendable>: @unchecked Sendable {
    private let lock = NSCondition()
    // Guarded by `lock`.
    private var ring: [Job?]
    private var head = 0
    private var count = 0
    private var closed = false
    /// Nanoseconds producers waited for room.
    let pushWaitNanoseconds = Atomic<Int>(0)

    init(capacity: Int) {
        ring = Array(repeating: nil, count: capacity)
    }

    /// Adds a job, waiting while the queue is full.
    func push(_ job: Job) {
        lock.lock()
        if count == ring.count {
            let start = DispatchTime.now().uptimeNanoseconds
            while count == ring.count { lock.wait() }
            pushWaitNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - start), ordering: .relaxed)
        }
        ring[(head + count) % ring.count] = job
        count += 1
        lock.broadcast()
        lock.unlock()
    }

    /// Takes the oldest job, waiting for one; `nil` once the queue is closed and empty.
    func pop() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        while count == 0 {
            if closed { return nil }
            lock.wait()
        }
        let job = ring[head]
        ring[head] = nil
        head = (head + 1) % ring.count
        count -= 1
        lock.broadcast()
        return job
    }

    /// No more jobs: wakes the writers waiting on an empty queue.
    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }
}

/// An atomic integer with an identity, so arrays can hold them (`Atomic` isn't copyable).
final class AtomicCounter: Sendable {
    let value = Atomic<Int>(0)
}

/// Nanoseconds spent per kind of work across the writers, for finding the bottleneck.
final class WorkTimings: Sendable {
    enum Kind: Int, CaseIterable {
        case wait, open, data, fork, attribute, finish, close, compress, mkdir, symlink, push, largeFileWait, largeFileOpen
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
