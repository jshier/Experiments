import BytesAsync
import Dispatch
import Synchronization
import Testing

/// The counter, the claiming pattern, the clock, and running at a priority.
@Suite struct CountingTests {
    /// Adds from many threads all land; `add` returns the new value, `store` replaces it.
    @Test func counterAddsFromThreads() {
        let counter = RelaxedCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1_000 {
                counter.add()
            }
            counter.add(5)
            counter.add(-5)
        }
        #expect(counter.value == 8_000)
        #expect(counter.add(2) == 8_002)
        counter.store(7)
        #expect(counter.value == 7)
        #expect(RelaxedCounter(-3).value == -3)
    }

    /// Several counters in one allocation: each counts on its own from many threads, copies share them, and other
    /// orderings go through `withAtomic`.
    @Test func countersAddFromThreads() {
        let counters = RelaxedCounters(count: 5, value: 3)
        #expect(counters.count == 5)
        #expect((0..<5).allSatisfy { counters.value(at: $0) == 3 })
        let copy = counters
        DispatchQueue.concurrentPerform(iterations: 8) { lane in
            for _ in 0..<1_000 {
                copy.add(at: lane % 5)
            }
        }
        // Lanes 0–7 over 5 counters: indexes 0, 1, 2 get two lanes each, 3 and 4 one.
        #expect((0..<5).map { counters.value(at: $0) } == [2_003, 2_003, 2_003, 1_003, 1_003])
        counters.store(1, at: 4)
        #expect(counters.withAtomic(at: 4) { $0.subtract(1, ordering: .acquiringAndReleasing).newValue } == 0)
        #expect(counters.add(-3, at: 0) == 2_000)
        #expect(RelaxedCounters(count: 0).isEmpty)
    }

    /// Every index below the limit is claimed exactly once, across threads, then `nil` for everyone.
    @Test(arguments: [0, 1, 37, 1_000]) func claimsEachIndexOnce(limit: Int) {
        let counter = RelaxedCounter()
        let local = Atomic(0)
        let claims = Mutex([Int: Int]())
        let localClaims = Mutex([Int: Int]())
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            while let index = counter.claim(below: limit) {
                claims.withLock { $0[index, default: 0] += 1 }
            }
            while let index = local.claim(below: limit) {
                localClaims.withLock { $0[index, default: 0] += 1 }
            }
        }
        for found in [claims.withLock { $0 }, localClaims.withLock { $0 }] {
            #expect(found.count == limit)
            #expect(found.keys.allSatisfy { $0 >= 0 && $0 < limit })
            #expect(found.values.allSatisfy { $0 == 1 })
        }
        #expect(counter.claim(below: limit) == nil)
        #expect(local.claim(below: limit) == nil)
    }

    /// The clock moves forward, and the interval helpers agree with it.
    @Test func clockIsMonotonic() {
        let start = MonotonicClock.now
        var previous = start
        for _ in 0..<1_000 {
            let now = MonotonicClock.now
            #expect(now >= previous)
            previous = now
        }
        let elapsed = MonotonicClock.nanoseconds(since: start)
        #expect(elapsed >= previous - start)
        let seconds = MonotonicClock.seconds(since: start)
        #expect(seconds >= Double(elapsed) / 1e9 && seconds < 60)
    }

    /// The operation runs at the priority asked for, returns its value, and its typed error passes through.
    @Test(arguments: [TaskPriority.utility, .userInitiated, .high]) func runsAtPriority(priority: TaskPriority) async throws {
        let seen = await withPriority(priority) { Task.basePriority }
        #expect(seen == priority)
        // Child tasks of the operation inherit it.
        let inherited = await withPriority(priority) {
            await withTaskGroup { group in
                group.addTask { Task.basePriority }
                return await group.next()!
            }
        }
        #expect(inherited == priority)

        struct Failure: Error, Equatable { let code: Int }
        let thrown = await #expect(throws: Failure.self) {
            _ = try await withPriority(priority) { () throws(Failure) -> Int in throw Failure(code: 3) }
        }
        #expect(thrown == Failure(code: 3))
    }

    /// The child task sees the caller's cancellation.
    @Test func priorityTaskKeepsCancellation() async {
        let task = Task {
            await withPriority(.utility) {
                // Waits for cancellation (bounded, so a failure doesn't hang the suite).
                for _ in 0..<2_000 where !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return Task.isCancelled
            }
        }
        task.cancel()
        #expect(await task.value)
    }
}
