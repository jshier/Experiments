import Benchmark
import Bytes
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

    // `AsyncByteTransform.transform(_:appending:)`: its own cost around the cheapest stages (a copy, and a 4x expansion
    // that takes several rounds at the default growth), into an array kept between iterations (its capacity reused).
    let appended = Benchmark.Configuration(
        metrics: [.wallClock, .instructions, .mallocCountTotal], warmupIterations: 1, scalingFactor: .one,
        maxDuration: .seconds(1), maxIterations: 100
    )
    Benchmark("Async append: copy stage, 4 MB in one call", configuration: appended) { benchmark async in
        var output: [UInt8] = []
        let input = appendInput
        for _ in benchmark.scaledIterations {
            output.removeAll(keepingCapacity: true)
            await blackHole(appendThrough(CopyStage(), input.span.bytes, into: &output, pieces: 1))
        }
    } setup: {
        var output: [UInt8] = []
        _ = await appendThrough(CopyStage(), appendInput.span.bytes, into: &output, pieces: 1)
        precondition(output == appendInput)
    }
    Benchmark("Async append: copy stage, 1 MB in 64 KB calls", configuration: appended) { benchmark async in
        var output: [UInt8] = []
        let input = appendInput
        for _ in benchmark.scaledIterations {
            output.removeAll(keepingCapacity: true)
            await blackHole(appendThrough(CopyStage(), input.span.bytes.extracting(0..<(1 << 20)), into: &output, pieces: 16))
        }
    } setup: {
        var output: [UInt8] = []
        _ = await appendThrough(CopyStage(), appendInput.span.bytes.extracting(0..<(1 << 20)), into: &output, pieces: 16)
        precondition(output[...] == appendInput[..<(1 << 20)])
    }
    Benchmark("Async append: 4x stage, 1 MB in one call", configuration: appended) { benchmark async in
        var output: [UInt8] = []
        let input = appendInput
        for _ in benchmark.scaledIterations {
            output.removeAll(keepingCapacity: true)
            await blackHole(appendThrough(ExpandingStage(), input.span.bytes.extracting(0..<(1 << 20)), into: &output, pieces: 1))
        }
    } setup: {
        var output: [UInt8] = []
        _ = await appendThrough(ExpandingStage(), appendInput.span.bytes.extracting(0..<(1 << 20)), into: &output, pieces: 1)
        precondition(output.count == 4 << 20 && output[4 * 12_345] == appendInput[12_345])
    }
}

/// The append rows' input: 4 MB of varied bytes, made on first use.
let appendInput: [UInt8] = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }

/// Appends `input`, in `pieces` calls, through `stage` (made synchronous: the calls don't suspend, so the row is the
/// append's own work); returns the bytes produced.
@inline(never)
func appendThrough<Stage: ByteTransform & ~Copyable>(
    _ stage: consuming Stage, _ input: RawSpan, into output: inout [UInt8], pieces: Int
) async -> Int where Stage.Failure == Never {
    var transform = stage.synchronously()
    let size = (input.byteCount + pieces - 1) / pieces
    var produced = 0
    var offset = 0
    while offset < input.byteCount {
        let end = min(input.byteCount, offset + size)
        let flush: TransformFlush = end == input.byteCount ? .finish : .none
        let progress = await transform.transform(input.extracting(offset..<end), appending: &output, flush: flush)
        produced += progress.produced
        offset = end
    }
    return produced
}

/// Copies its input: the cheapest stage.
struct CopyStage: ByteTransform {
    typealias Failure = Never

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        let count = min(input.byteCount, output.freeCapacity)
        output.append(copying: input.extracting(0..<count))
        let done = count == input.byteCount
        return TransformProgress(
            consumed: count, produced: count, status: !done ? .needsOutput : flush == .finish ? .finished : .needsInput
        )
    }
}

/// Writes each input byte four times: output four times its input, as a decoder's, so an append takes several rounds.
struct ExpandingStage: ByteTransform {
    typealias Failure = Never

    static var minimumOutputCapacity: Int { 4 }

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        let count = min(input.byteCount, output.freeCapacity / 4)
        for index in 0..<count {
            let byte = UInt32(input.load(fromByteOffset: index, as: UInt8.self)) &* 0x0101_0101
            output.append(byte, as: UInt32.self)
        }
        let done = count == input.byteCount
        return TransformProgress(
            consumed: count, produced: count &* 4, status: !done ? .needsOutput : flush == .finish ? .finished : .needsInput
        )
    }
}
