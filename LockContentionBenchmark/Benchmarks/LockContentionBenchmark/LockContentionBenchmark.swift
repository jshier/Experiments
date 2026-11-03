import Benchmark
import Dispatch
import Foundation
import os
import Synchronization

// MARK: - Lock abstraction
//
// Every candidate protects a single `Int` counter. `increment(work:)` takes the lock, does `work` rounds of cheap
// arithmetic inside the critical section, bumps the counter, and releases. Callers are generic over `Counter`, so
// each candidate is specialized and no existential/dynamic-dispatch cost is added on top of the lock itself.

protocol Counter: AnyObject, Sendable {
    init()
    func increment(work: Int)
    var value: Int { get }
}

@inline(never)
func criticalSectionWork(_ rounds: Int, _ seed: Int) -> Int {
    var x = seed
    for _ in 0..<rounds { x = x &* 6364136223846793005 &+ 1442695040888963407 }
    return x
}

final class MutexCounter: Counter {
    private let state = Mutex(0)
    init() {}
    @inline(__always) func increment(work: Int) {
        state.withLock { v in
            if work > 0 { blackHole(criticalSectionWork(work, v)) }
            v += 1
        }
    }
    var value: Int { state.withLock { $0 } }
}

final class OSAllocatedUnfairLockCounter: Counter {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    init() {}
    @inline(__always) func increment(work: Int) {
        state.withLock { v in
            if work > 0 { blackHole(criticalSectionWork(work, v)) }
            v += 1
        }
    }
    var value: Int { state.withLock { $0 } }
}

/// The raw C locks need stable addresses, so each lives in a heap block alongside the counter it protects. That keeps
/// lock word and data adjacent (as with `Mutex`, which stores both inline) so cache-line behavior is comparable.
struct Locked<L> {
    var lock: L
    var count: Int
}

final class UnfairLockCounter: Counter, @unchecked Sendable {
    private let block: UnsafeMutablePointer<Locked<os_unfair_lock>> = {
        let p = UnsafeMutablePointer<Locked<os_unfair_lock>>.allocate(capacity: 1)
        p.initialize(to: Locked(lock: os_unfair_lock(), count: 0))
        return p
    }()
    init() {}
    deinit { block.deallocate() }
    @inline(__always) func increment(work: Int) {
        let lock = UnsafeMutableRawPointer(block).assumingMemoryBound(to: os_unfair_lock.self)
        os_unfair_lock_lock(lock)
        if work > 0 { blackHole(criticalSectionWork(work, block.pointee.count)) }
        block.pointee.count += 1
        os_unfair_lock_unlock(lock)
    }
    var value: Int {
        let lock = UnsafeMutableRawPointer(block).assumingMemoryBound(to: os_unfair_lock.self)
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return block.pointee.count
    }
}

final class NSLockCounter: Counter, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        lock.lock()
        if work > 0 { blackHole(criticalSectionWork(work, count)) }
        count += 1
        lock.unlock()
    }
    var value: Int { lock.withLock { count } }
}

final class NSRecursiveLockCounter: Counter, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        lock.lock()
        if work > 0 { blackHole(criticalSectionWork(work, count)) }
        count += 1
        lock.unlock()
    }
    var value: Int { lock.withLock { count } }
}

final class NSConditionCounter: Counter, @unchecked Sendable {
    private let lock = NSCondition()
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        lock.lock()
        if work > 0 { blackHole(criticalSectionWork(work, count)) }
        count += 1
        lock.unlock()
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class PthreadMutexCounter: Counter, @unchecked Sendable {
    private let block: UnsafeMutablePointer<Locked<pthread_mutex_t>> = {
        let p = UnsafeMutablePointer<Locked<pthread_mutex_t>>.allocate(capacity: 1)
        p.initialize(to: Locked(lock: pthread_mutex_t(), count: 0))
        pthread_mutex_init(UnsafeMutableRawPointer(p).assumingMemoryBound(to: pthread_mutex_t.self), nil)
        return p
    }()
    init() {}
    deinit {
        pthread_mutex_destroy(UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_mutex_t.self))
        block.deallocate()
    }
    @inline(__always) func increment(work: Int) {
        let mutex = UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_mutex_t.self)
        pthread_mutex_lock(mutex)
        if work > 0 { blackHole(criticalSectionWork(work, block.pointee.count)) }
        block.pointee.count += 1
        pthread_mutex_unlock(mutex)
    }
    var value: Int {
        let mutex = UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_mutex_t.self)
        pthread_mutex_lock(mutex); defer { pthread_mutex_unlock(mutex) }
        return block.pointee.count
    }
}

final class PthreadRWLockCounter: Counter, @unchecked Sendable {
    private let block: UnsafeMutablePointer<Locked<pthread_rwlock_t>> = {
        let p = UnsafeMutablePointer<Locked<pthread_rwlock_t>>.allocate(capacity: 1)
        p.initialize(to: Locked(lock: pthread_rwlock_t(), count: 0))
        pthread_rwlock_init(UnsafeMutableRawPointer(p).assumingMemoryBound(to: pthread_rwlock_t.self), nil)
        return p
    }()
    init() {}
    deinit {
        pthread_rwlock_destroy(UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_rwlock_t.self))
        block.deallocate()
    }
    @inline(__always) func increment(work: Int) {
        let lock = UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_rwlock_t.self)
        pthread_rwlock_wrlock(lock)
        if work > 0 { blackHole(criticalSectionWork(work, block.pointee.count)) }
        block.pointee.count += 1
        pthread_rwlock_unlock(lock)
    }
    var value: Int {
        let lock = UnsafeMutableRawPointer(block).assumingMemoryBound(to: pthread_rwlock_t.self)
        pthread_rwlock_rdlock(lock); defer { pthread_rwlock_unlock(lock) }
        return block.pointee.count
    }
}

final class SerialQueueCounter: Counter, @unchecked Sendable {
    private let queue = DispatchQueue(label: "counter")
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        queue.sync {
            if work > 0 { blackHole(criticalSectionWork(work, count)) }
            count += 1
        }
    }
    var value: Int { queue.sync { count } }
}

/// Fire-and-forget `async` onto a serial queue; the final `value` read (a `sync`) drains the queue.
final class SerialQueueAsyncCounter: Counter, @unchecked Sendable {
    private let queue = DispatchQueue(label: "counter.async")
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        queue.async { [self] in
            if work > 0 { blackHole(criticalSectionWork(work, count)) }
            count += 1
        }
    }
    var value: Int { queue.sync { count } }
}

final class SemaphoreCounter: Counter, @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 1)
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) {
        sem.wait()
        if work > 0 { blackHole(criticalSectionWork(work, count)) }
        count += 1
        sem.signal()
    }
    var value: Int { sem.wait(); defer { sem.signal() }; return count }
}

/// Lock-free reference point: no critical-section work is possible, so it only models the "short" scenario fairly.
final class AtomicCounter: Counter {
    private let state = Atomic<Int>(0)
    init() {}
    @inline(__always) func increment(work: Int) {
        if work > 0 { blackHole(criticalSectionWork(work, 0)) }
        state.wrappingAdd(1, ordering: .relaxed)
    }
    var value: Int { state.load(ordering: .relaxed) }
}

/// Baseline with no lock at all: the cost of the wrapper class every candidate is created inside of.
final class NoLockCounter: Counter, @unchecked Sendable {
    private var count = 0
    init() {}
    @inline(__always) func increment(work: Int) { count += 1 }
    var value: Int { count }
}

// MARK: - Workload

final class Box<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class StartGate: Sendable {
    let arrived = Atomic<Int>(0)
    let go = Atomic<Bool>(false)
    let finished = Atomic<Int>(0)
    let allFinished = DispatchSemaphore(value: 0)
}

/// Every benchmark thread (the caller and the workers) runs at the same QoS so core placement is consistent between
/// samples rather than left to the default class.
let benchmarkQoS = QOS_CLASS_USER_INTERACTIVE

func setCallerQoS() {
    pthread_set_qos_class_self_np(benchmarkQoS, 0)
}

/// Creates `threads` pthreads that spin on a gate until released together, so every thread begins hammering the lock
/// at (nearly) the same instant. Each thread performs `opsPerThread` increments, and the last one to finish signals
/// the caller. The measured region runs from the gate opening until the final `value` read, which for the async
/// candidate drains the queue so it is timed to completion like the locks. Thread creation, exit and join are all
/// outside the region. Returns the final counter value.
func runContended<C: Counter>(_ type: C.Type, threads: Int, opsPerThread: Int, work: Int,
                              measure: (start: () -> Void, stop: () -> Void)) -> Int {
    setCallerQoS()
    let counter = C()
    let gate = StartGate()
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_set_qos_class_np(&attr, benchmarkQoS, 0)
    defer { pthread_attr_destroy(&attr) }
    var handles: [pthread_t] = []
    for _ in 0..<threads {
        let body: @Sendable () -> Void = {
            gate.arrived.add(1, ordering: .acquiringAndReleasing)
            while !gate.go.load(ordering: .acquiring) {}
            for _ in 0..<opsPerThread { counter.increment(work: work) }
            if gate.finished.add(1, ordering: .acquiringAndReleasing).newValue == threads {
                gate.allFinished.signal()
            }
        }
        let box = Unmanaged.passRetained(Box(body))
        var tid: pthread_t?
        pthread_create(&tid, &attr, { arg in
            let b = Unmanaged<Box<@Sendable () -> Void>>.fromOpaque(arg).takeRetainedValue()
            b.value()
            return nil
        }, box.toOpaque())
        handles.append(tid!)
    }
    while gate.arrived.load(ordering: .acquiring) < threads { sched_yield() }
    measure.start()
    gate.go.store(true, ordering: .releasing)
    gate.allFinished.wait()
    let value = counter.value
    measure.stop()
    for h in handles { pthread_join(h, nil) }
    return value
}

/// Single-threaded, no contention: measures the raw acquire/release cost on the calling thread. Construction is
/// outside the measured region; the final `value` read is inside it, so the async candidate is timed to completion.
func runUncontended<C: Counter>(_ type: C.Type, ops: Int, measure: (start: () -> Void, stop: () -> Void)) -> Int {
    setCallerQoS()
    let counter = C()
    // Escape the counter so the optimizer must assume the opaque lock calls can observe the protected state. Without
    // this, a counter that never leaves this function lets it sink the increment out of the loop for locks whose
    // lock word and state are separate fields (`OSAllocatedUnfairLock`), so those candidates do less work per op.
    blackHole(counter)
    measure.start()
    for _ in 0..<ops { counter.increment(work: 0) }
    let value = counter.value
    measure.stop()
    return value
}

// MARK: - Registration

/// Specialized per candidate so no closure or metatype dispatch sits between the loop and `init`.
@inline(never)
func runCreate<C: Counter>(_ type: C.Type, count: Int) {
    for _ in 0..<count { blackHole(C()) }
}

struct Candidate {
    let name: String
    let run: @Sendable (_ threads: Int, _ ops: Int, _ work: Int, _ measure: (start: () -> Void, stop: () -> Void)) -> Int
    let uncontended: @Sendable (_ ops: Int, _ measure: (start: () -> Void, stop: () -> Void)) -> Int
    let create: @Sendable (_ count: Int) -> Void
    static func make<C: Counter>(_ name: String, _ type: C.Type) -> Candidate {
        Candidate(name: name,
                  run: { runContended(type, threads: $0, opsPerThread: $1, work: $2, measure: $3) },
                  uncontended: { runUncontended(type, ops: $0, measure: $1) },
                  create: { runCreate(type, count: $0) })
    }
}

let candidates: [Candidate] = [
    .make("Mutex", MutexCounter.self),
    .make("OSAllocatedUnfairLock", OSAllocatedUnfairLockCounter.self),
    .make("os_unfair_lock", UnfairLockCounter.self),
    .make("pthread_mutex", PthreadMutexCounter.self),
    .make("NSLock", NSLockCounter.self),
    .make("NSRecursiveLock", NSRecursiveLockCounter.self),
    .make("NSCondition", NSConditionCounter.self),
    .make("pthread_rwlock(write)", PthreadRWLockCounter.self),
    .make("DispatchQueue.sync", SerialQueueCounter.self),
    .make("DispatchQueue.async", SerialQueueAsyncCounter.self),
    .make("DispatchSemaphore", SemaphoreCounter.self),
    .make("Atomic(reference)", AtomicCounter.self),
]

// Total operations are held constant across thread counts so wall-clock times are directly comparable.
let totalOps = 200_000
let threadCounts = [1, 2, 4, 8, 32]
let scenarios: [(label: String, work: Int)] = [("short", 0), ("long", 100)]

func verifyCandidates() {
    for c in candidates {
        let got = c.run(4, 1000, 0, ({}, {}))
        precondition(got == 4000, "\(c.name) lost updates: \(got)")
    }
}

/// The benchmark package's malloc interposer wraps every allocation in the process (adding a size header) whenever it
/// is linked, even for benchmarks that don't request malloc metrics. So timing and allocation counting are separate
/// builds: `BENCHMARK_DISABLE_MALLOC_INTERPOSER=1` builds without it and registers only the timing benchmarks; the
/// default build registers only the `alloc` benchmarks. The interposer ships as a dylib, so its presence is detected
/// from an exported symbol rather than trusting the environment or a possibly stale module on disk.
let mallocInterposerLoaded = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                   "malloc_interposer_global_hooks_installed") != nil

let benchmarks: @Sendable () -> Void = {
    verifyCandidates()

    let creationCandidates = [Candidate.make("no lock (wrapper only)", NoLockCounter.self)] + candidates

    guard !mallocInterposerLoaded else {
        registerAllocationBenchmarks(creationCandidates)
        return
    }

    // The slowest candidates take ~0.4 to 0.7 s per contended sample; 10 s gives them at least ~15 samples while the
    // fast ones stop at `maxIterations`.
    let config = Benchmark.Configuration(
        metrics: [.wallClock, .cpuTotal, .contextSwitches],
        warmupIterations: 2,
        maxDuration: .seconds(10),
        maxIterations: 30
    )

    for scenario in scenarios {
        for threads in threadCounts {
            for c in candidates {
                if c.name.hasPrefix("Atomic") && scenario.work > 0 { continue }
                let ops = totalOps / threads
                let work = scenario.work
                Benchmark("\(scenario.label) CS, \(String(format: "%02d", threads)) threads - \(c.name)",
                          configuration: config) { benchmark in
                    for _ in benchmark.scaledIterations {
                        blackHole(c.run(threads, ops, work, (benchmark.startMeasurement, benchmark.stopMeasurement)))
                    }
                }
            }
        }
    }

    let uncontendedConfig = Benchmark.Configuration(
        metrics: [.wallClock, .cpuTotal, .instructions],
        warmupIterations: 2,
        maxDuration: .seconds(10),
        maxIterations: 50
    )
    // At ~3 s per sample, the async queue only gets 4 samples in 10 s; give it 30 s for a steadier p50.
    var asyncUncontendedConfig = uncontendedConfig
    asyncUncontendedConfig.maxDuration = .seconds(30)
    for c in candidates {
        let config = c.name == "DispatchQueue.async" ? asyncUncontendedConfig : uncontendedConfig
        Benchmark("uncontended - \(c.name)", configuration: config) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(c.uncontended(1_000_000, (benchmark.startMeasurement, benchmark.stopMeasurement)))
            }
        }
    }

    // Creation cost: each candidate is built inside a small wrapper class, so `no lock (wrapper only)` is the
    // baseline to subtract. Lock initialization happens in `init`, and deallocation is included.
    let creationConfig = Benchmark.Configuration(
        metrics: [.wallClock, .cpuTotal, .instructions],
        warmupIterations: 2,
        maxDuration: .seconds(1),
        maxIterations: 50
    )
    for c in creationCandidates {
        Benchmark("create - \(c.name)", configuration: creationConfig) { benchmark in
            setCallerQoS()
            benchmark.startMeasurement()
            c.create(100_000)
            benchmark.stopMeasurement()
        }
    }
}

/// Allocation counts only. Counts don't vary between samples, so a few iterations and smaller op counts suffice.
func registerAllocationBenchmarks(_ creationCandidates: [Candidate]) {
    let config = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxDuration: .seconds(10),
        maxIterations: 5
    )
    for c in candidates {
        Benchmark("alloc contended short CS, 04 threads - \(c.name)", configuration: config) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(c.run(4, totalOps / 4, 0, (benchmark.startMeasurement, benchmark.stopMeasurement)))
            }
        }
        Benchmark("alloc uncontended - \(c.name)", configuration: config) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(c.uncontended(100_000, (benchmark.startMeasurement, benchmark.stopMeasurement)))
            }
        }
    }

    let creationConfig = Benchmark.Configuration(
        metrics: [.mallocCountTotal, .mallocBytesCount, .freeCountTotal],
        warmupIterations: 1,
        maxDuration: .seconds(10),
        maxIterations: 5
    )
    for c in creationCandidates {
        Benchmark("alloc create - \(c.name)", configuration: creationConfig) { benchmark in
            benchmark.startMeasurement()
            c.create(100_000)
            benchmark.stopMeasurement()
        }
    }
}
