import Benchmark
import BytesAsync

// BytesAsync's waiting primitives: the uncontended fast paths (no suspension), and contended ones where tasks wait and
// are resumed. Each iteration makes its own primitive and tasks, so a row is the primitive's work plus a few task
// starts; mallocs counted (a steady state allocates nothing but the tasks themselves).

/// Acquires and releases an uncontended limiter `count` times: the fast path, under its lock alone.
@inline(never)
func limiterUncontended(_ limiter: AsyncLimiter, count: Int) async -> Int {
    var done = 0
    for _ in 0..<count {
        await limiter.acquire()
        done &+= 1
        limiter.release()
    }
    return done
}

/// `tasks` tasks each taking `rounds` turns through a limiter of `permits` (waiter storage for `reserved`, all of
/// them by default): waits and hand-offs.
func limiterContended(tasks: Int, rounds: Int, permits: Int, reserved: Int? = nil) async -> Int {
    let limiter = AsyncLimiter(permits, waiters: reserved ?? tasks)
    return await withTaskGroup(of: Int.self) { group in
        for _ in 0..<tasks {
            group.addTask {
                var done = 0
                for _ in 0..<rounds {
                    await limiter.acquire()
                    done &+= 1
                    limiter.release()
                }
                return done
            }
        }
        return await group.reduce(0, +)
    }
}

/// `tasks` tasks each taking `rounds` indexes from a pool of `count`.
func indexPoolContended(tasks: Int, rounds: Int, count: Int) async -> Int {
    let pool = AsyncIndexPool(count: count, waiters: tasks)
    return await withTaskGroup(of: Int.self) { group in
        for _ in 0..<tasks {
            group.addTask {
                var sum = 0
                for _ in 0..<rounds {
                    // (`Int?` since 2026-11-25: `nil` once a pool is closed; this one never is.)
                    guard let index = await pool.acquire() else { return sum }
                    sum &+= index
                    pool.release(index)
                }
                return sum
            }
        }
        return await group.reduce(0, +)
    }
}

/// One task sends `count` elements to another through a handoff: a suspension and a resume per element.
func handoffPingPong(count: Int) async -> Int {
    let handoff = AsyncHandoff<Int>()
    return await withTaskGroup(of: Int.self) { group in
        group.addTask {
            defer { handoff.close() }
            for value in 0..<count {
                guard await handoff.send(value) else { return 0 }
            }
            return 0
        }
        group.addTask {
            var sum = 0
            while let value = await handoff.receive() {
                sum &+= value
            }
            return sum
        }
        return await group.reduce(0, +)
    }
}

/// One producer pushes `count` elements through a queue of `capacity` to `consumers` tasks.
func queueFanOut(count: Int, capacity: Int, consumers: Int) async -> Int {
    let queue = AsyncQueue<Int>(capacity: capacity, waiters: consumers)
    return await withTaskGroup(of: Int.self) { group in
        group.addTask {
            for value in 0..<count {
                await queue.push(value)
            }
            queue.close()
            return 0
        }
        for _ in 0..<consumers {
            group.addTask {
                var sum = 0
                while let value = await queue.pop() {
                    sum &+= value
                }
                return sum
            }
        }
        return await group.reduce(0, +)
    }
}

func registerAsyncBenchmarks() {
    // Mallocs counted only where one task runs (the interposer's rule: AGENTS.md, Benchmarks). The contended rows'
    // instructions depend on scheduling: compare their times within one run, and judge the primitives by the
    // uncontended row and the handoff.
    let timed = Benchmark.Configuration(
        metrics: [.wallClock, .instructions], warmupIterations: 1, scalingFactor: .one, maxDuration: .milliseconds(500),
        maxIterations: 100
    )
    var counted = timed
    counted.metrics = [.wallClock, .instructions, .mallocCountTotal]
    Benchmark("Async: limiter, uncontended (x10,000)", configuration: counted) { benchmark async in
        let limiter = AsyncLimiter(4)
        for _ in benchmark.scaledIterations {
            await blackHole(limiterUncontended(limiter, count: 10_000))
        }
    }
    Benchmark("Async: limiter, 8 tasks x 1,250 through 2 permits", configuration: timed) { benchmark async in
        for _ in benchmark.scaledIterations {
            await blackHole(limiterContended(tasks: 8, rounds: 1_250, permits: 2))
        }
    } setup: {
        let done = await limiterContended(tasks: 8, rounds: 1_250, permits: 2)
        precondition(done == 10_000)
    }
    Benchmark("Async: index pool, 8 tasks x 1,250 over 2 indexes", configuration: timed) { benchmark async in
        for _ in benchmark.scaledIterations {
            await blackHole(indexPoolContended(tasks: 8, rounds: 1_250, count: 2))
        }
    }
    // More waiters than the reserved storage (2): the waiter queue grows once per iteration.
    Benchmark("Async: limiter, 32 tasks x 300 through 1 permit, 2 waiters reserved", configuration: timed) { benchmark async in
        for _ in benchmark.scaledIterations {
            await blackHole(limiterContended(tasks: 32, rounds: 300, permits: 1, reserved: 2))
        }
    } setup: {
        let done = await limiterContended(tasks: 32, rounds: 300, permits: 1, reserved: 2)
        precondition(done == 9_600)
    }
    Benchmark("Async: handoff, 10,000 elements", configuration: timed) { benchmark async in
        for _ in benchmark.scaledIterations {
            await blackHole(handoffPingPong(count: 10_000))
        }
    } setup: {
        let sum = await handoffPingPong(count: 10_000)
        precondition(sum == 10_000 * 9_999 / 2)
    }
    Benchmark("Async: queue, 100,000 elements to 4 consumers", configuration: timed) { benchmark async in
        for _ in benchmark.scaledIterations {
            await blackHole(queueFanOut(count: 100_000, capacity: 64, consumers: 4))
        }
    } setup: {
        let sum = await queueFanOut(count: 100_000, capacity: 64, consumers: 4)
        precondition(sum == 100_000 * 99_999 / 2)
    }
}
