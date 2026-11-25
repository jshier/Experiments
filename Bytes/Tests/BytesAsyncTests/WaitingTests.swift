import Bytes
import BytesAsync
import Synchronization
import Testing

/// The waiting primitives: limits, the bounded queue, the handoff, and their waiters' storage.
@Suite struct WaitingTests {
    /// The waiter ring keeps order through wrapping, growth, and removal from the middle.
    @Test func waiterQueueKeepsOrder() {
        var queue = WaiterQueue<Int>(capacity: 2)
        #expect(queue.isEmpty && queue.popFirst() == nil)
        queue.append(1)
        queue.append(2)
        #expect(queue.popFirst() == 1)
        // Wraps, then grows past its capacity with the head mid-ring.
        for value in 3...9 {
            queue.append(value)
        }
        #expect(queue.count == 8)
        #expect(queue.removeFirst { $0 == 5 } == 5)
        #expect(queue.removeFirst { $0 == 100 } == nil)
        #expect(queue.removeAll() == [2, 3, 4, 6, 7, 8, 9])
        #expect(queue.isEmpty)
    }

    /// Never more tasks inside than permits, and every task gets in.
    @Test(arguments: [1, 3, 8]) func limiterBoundsTheSection(permits: Int) async {
        let limiter = AsyncLimiter(permits, waiters: 2)
        let inside = Atomic<Int>(0), peak = Atomic<Int>(0), entered = Atomic<Int>(0)
        await withDiscardingTaskGroup { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<50 {
                        await limiter.acquire()
                        peak.max(inside.add(1, ordering: .relaxed).newValue, ordering: .relaxed)
                        entered.add(1, ordering: .relaxed)
                        await Task.yield()
                        inside.subtract(1, ordering: .relaxed)
                        limiter.release()
                    }
                }
            }
        }
        #expect(entered.load(ordering: .relaxed) == 64 * 50)
        #expect(peak.load(ordering: .relaxed) <= permits && inside.load(ordering: .relaxed) == 0)
    }

    /// An index is held by one task at a time; waiters get released indexes.
    @Test func indexPoolHandsOutEachIndexOnce() async {
        let pool = AsyncIndexPool(count: 4, waiters: 1)
        let holders = (0..<4).map { _ in Counter() }
        let clashes = Atomic<Int>(0), taken = Atomic<Int>(0)
        await withDiscardingTaskGroup { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<50 {
                        let index = await pool.acquire()
                        if holders[index].value.add(1, ordering: .relaxed).newValue != 1 { clashes.add(1, ordering: .relaxed) }
                        taken.add(1, ordering: .relaxed)
                        await Task.yield()
                        holders[index].value.subtract(1, ordering: .relaxed)
                        pool.release(index)
                    }
                }
            }
        }
        #expect(clashes.load(ordering: .relaxed) == 0 && taken.load(ordering: .relaxed) == 32 * 50)
        // Everything is back: four acquisitions without waiting, each index once.
        var indexes: Set<Int> = []
        for _ in 0..<4 {
            await indexes.insert(pool.acquire())
        }
        #expect(indexes == [0, 1, 2, 3])
    }

    /// The latch's waiter goes on only after the last arrival; a latch of none doesn't wait.
    @Test func latchWaitsForEveryArrival() async {
        await AsyncLatch(count: 0).wait()
        let latch = AsyncLatch(count: 16)
        let arrived = Atomic<Int>(0)
        await withDiscardingTaskGroup { group in
            for _ in 0..<16 {
                group.addTask {
                    await Task.yield()
                    arrived.add(1, ordering: .relaxed)
                    latch.arrive()
                }
            }
            await latch.wait()
            #expect(arrived.load(ordering: .relaxed) == 16)
        }
        await latch.wait() // Again, at once.
    }

    /// Every element pushed is popped once, in order per producer, through a queue much smaller than the work.
    @Test(arguments: [1, 2, 64]) func queueDeliversEverythingOnce(capacity: Int) async {
        let queue = AsyncQueue<Int>(capacity: capacity, waiters: 2)
        let producers = 4, perProducer = 2_000
        let sum = Atomic<Int>(0), count = Atomic<Int>(0), disorder = Atomic<Int>(0)
        await withDiscardingTaskGroup { group in
            for _ in 0..<6 {
                group.addTask {
                    var last = [Int](repeating: -1, count: producers)
                    while let value = await queue.pop() {
                        let producer = value / perProducer
                        if value <= last[producer] { disorder.add(1, ordering: .relaxed) }
                        last[producer] = value
                        sum.add(value, ordering: .relaxed)
                        count.add(1, ordering: .relaxed)
                    }
                }
            }
            await withDiscardingTaskGroup { inner in
                for producer in 0..<producers {
                    inner.addTask {
                        for index in 0..<perProducer {
                            let pushed = await queue.push(producer * perProducer + index)
                            #expect(pushed)
                        }
                    }
                }
            }
            queue.close()
        }
        let total = producers * perProducer
        #expect(count.load(ordering: .relaxed) == total && sum.load(ordering: .relaxed) == total * (total - 1) / 2)
        #expect(disorder.load(ordering: .relaxed) == 0)
    }

    /// Closing wakes a producer waiting for room (its push fails) and consumers waiting for elements; what's queued
    /// can still be drained.
    @Test func closingAQueueWakesItsWaiters() async {
        let queue = AsyncQueue<Int>(capacity: 1)
        #expect(await queue.push(1))
        await withDiscardingTaskGroup { group in
            group.addTask {
                let pushed = await queue.push(2) // Full: waits, until the close.
                #expect(!pushed)
            }
            await Task.yield()
            queue.close()
        }
        #expect(await queue.push(3) == false)
        var drained: [Int] = []
        queue.drain { drained.append($0) }
        #expect(drained == [1])
        #expect(await queue.pop() == nil)

        let empty = AsyncQueue<Int>(capacity: 4)
        await withDiscardingTaskGroup { group in
            for _ in 0..<3 {
                group.addTask {
                    let value = await empty.pop()
                    #expect(value == nil)
                }
            }
            await Task.yield()
            empty.close()
        }
    }

    /// The handoff delivers in order, and `send` returns only once the consumer has asked for the next element.
    @Test func handoffAlternates() async {
        let handoff = AsyncHandoff<Int>()
        let consumed = Atomic<Int>(0)
        let early = Atomic<Int>(0)
        await withDiscardingTaskGroup { group in
            group.addTask {
                defer { handoff.close() }
                for value in 0..<2_000 {
                    guard await handoff.send(value) else { return }
                    // The consumer took `value`, so it finished everything before it.
                    if consumed.load(ordering: .relaxed) < value { early.add(1, ordering: .relaxed) }
                }
            }
            var expected = 0
            while let value = await handoff.receive() {
                #expect(value == expected)
                expected += 1
                if value % 7 == 0 { await Task.yield() }
                consumed.store(value + 1, ordering: .relaxed)
            }
            #expect(expected == 2_000)
        }
        #expect(early.load(ordering: .relaxed) == 0)
        #expect(await handoff.receive() == nil)
    }

    /// A consumer that fails refuses the producer's waiting element and every later one.
    @Test func handoffRefusesAfterAFailure() async {
        let handoff = AsyncHandoff<Int>()
        await withDiscardingTaskGroup { group in
            group.addTask {
                var sent = 0
                while await handoff.send(sent) {
                    sent += 1
                }
                #expect(sent == 3)
                #expect(await handoff.send(99) == false)
            }
            for expected in 0..<3 {
                let value = await handoff.receive()
                #expect(value == expected)
            }
            handoff.fail()
        }
    }

    /// Storage keeps what's written below the resident floor across `giveBack` and `reuse`, and its accessors agree.
    @Test func rawStorageKeepsItsFloor() {
        let storage = RawStorage(byteCount: 4 << 20)
        #expect(storage.byteCount == 4 << 20)
        // Unsafe throughout: the storage's own pointer. Safe: every offset is below `byteCount`, and `storage` is alive.
        let address = unsafe UInt(bitPattern: storage.base)
        #expect(address % UInt(RawStorage.pageSize) == 0)
        let distance = unsafe storage.pointer(100) - storage.base
        #expect(distance == 100)
        storage.reuse(storage.byteCount)
        for offset in stride(from: 0, to: storage.byteCount, by: 4_096) {
            unsafe storage.base.storeBytes(of: UInt8(truncatingIfNeeded: offset >> 12), toByteOffset: offset, as: UInt8.self)
        }
        storage.giveBack(storage.byteCount)
        storage.reuse(storage.byteCount)
        var kept = true
        for offset in stride(from: 0, to: RawStorage.residentFloor, by: 4_096) {
            let byte = unsafe storage.base.load(fromByteOffset: offset, as: UInt8.self)
            if byte != UInt8(truncatingIfNeeded: offset >> 12) { kept = false }
        }
        #expect(kept)
        // Past the floor the contents are undefined, but the memory is writable again.
        unsafe storage.base.storeBytes(of: 7, toByteOffset: storage.byteCount - 1, as: UInt8.self)
        let last = unsafe storage.base.load(fromByteOffset: storage.byteCount - 1, as: UInt8.self)
        #expect(last == 7)
        // Small storage: no advice (below the floor), malloc's alignment.
        let small = RawStorage(byteCount: 0, alignment: RawStorage.small)
        #expect(small.byteCount == 1)
        small.reuse(1)
        small.giveBack(1)
    }
}

private final class Counter: Sendable {
    let value = Atomic<Int>(0)
}
