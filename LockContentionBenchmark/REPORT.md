# Lock performance on macOS in Swift 6: creation, uncontended and contended

Compares the cost of protecting a single `Int` counter with each locking construct available on macOS, using the [ordo-one/benchmark](https://github.com/ordo-one/benchmark) framework. The package builds in Swift 6 language mode (`swiftLanguageModes: [.v6]`).

- Machine: Apple M3 Ultra, 32 cores, 256 GB, macOS 27.0.1, Swift 6.4.2 (Xcode 27.2), release build.
- Every number below is the **p50**. Contended runs take up to 30 samples and uncontended/creation up to 50, each capped at 10 s per benchmark (creation 1 s). The slowest contended cases get 16 to 30 samples. Uncontended `DispatchQueue.async` (about 3 s per sample) is capped at 30 s instead and gets 12.
- Results are from baselines `v4-timing`, `v4-uncontended` (the uncontended table, re-run after the escape fix below), `v4-uncontended-async` (its `DispatchQueue.async` row, re-run with the 30 s cap) and `v4-alloc` in `.benchmarkBaselines/`. Revision v4 tightened the measurement (see [Changes in v4](#changes-in-v4)); numbers are not directly comparable with `v3`.

## Reproduce

Timing and allocation counting are **two separate builds**, because the framework's malloc interposer wraps every allocation in the process whenever it is linked (see Methodology). The benchmark detects which build it is running in and registers only the matching benchmarks.

```sh
# Timing, CPU, instructions, context switches (about 7 minutes). Separate scratch path so the two builds
# never share stale modules.
BENCHMARK_DISABLE_MALLOC_INTERPOSER=1 swift package --scratch-path .build-nointerposer \
    --allow-writing-to-package-directory benchmark baseline update v4-timing

# Allocation counts (default build, about 1 minute)
swift package --allow-writing-to-package-directory benchmark baseline update v4-alloc
```

Single case: add `--filter "short CS, 08 threads - Mutex"` (timing build) or `--filter "alloc create - Mutex"` (default build).

## Constructs tested

| Name | What it is |
|---|---|
| `Mutex` | `Synchronization.Mutex` (`withLock`) |
| `OSAllocatedUnfairLock` | `os.OSAllocatedUnfairLock` (`withLock`) |
| `os_unfair_lock` | Raw C lock, in a heap block next to the counter |
| `pthread_mutex` | Default (non-recursive) `pthread_mutex_t`, in a heap block next to the counter |
| `pthread_rwlock(write)` | `pthread_rwlock_t`, in a heap block next to the counter, write-locked every time |
| `NSLock`, `NSRecursiveLock`, `NSCondition` | Foundation locks |
| `DispatchQueue.sync` | Serial queue, `sync { }` per operation |
| `DispatchQueue.async` | Serial queue, `async { }` per operation, timed until the queue has drained (not a lock; see below) |
| `DispatchSemaphore` | Binary semaphore (`wait`/`signal`) |
| `Atomic(reference)` | `Synchronization.Atomic<Int>.wrappingAdd`. Not a lock; a lower bound for the "short" case |

## Methodology

- **Creation:** 100,000 create-and-release cycles per sample, reported per creation. Each lock is built inside the small wrapper class used by every other benchmark, so the `no lock (wrapper only)` row (the wrapper alone: 1 allocation) is the baseline to subtract. Deallocation is included.
- **Uncontended:** one thread, 1,000,000 lock/increment/unlock cycles per sample, reported per operation. Construction is outside the measured region. The counter is passed to `blackHole` before the loop so it escapes; otherwise the optimizer can prove the protected state is unobservable and drop work for some candidates (see the uncontended results). The final `value` read is inside it, so `DispatchQueue.async` is timed until every enqueued block has run; for the locks that read is one more uncontended acquisition and adds nothing measurable.
- **Contended:** N threads (1, 2, 4, 8, 32; raw `pthread`s) share one counter. The threads are created first and spin on an atomic gate; once all have arrived, measurement starts and the gate opens, so all threads begin hammering the lock within nanoseconds of each other. The last thread to finish its operations signals a semaphore; the caller wakes, reads the final `value` (draining the async queue) and stops measurement. **Thread creation, exit and join are all outside the measured region.** The total is fixed at **200,000 operations**, split evenly across threads, so wall times are comparable across thread counts.
  - **short** critical section: just the increment.
  - **long** critical section: increment plus 100 iterations of dependent integer math, plus the call to `blackHole` that keeps it from being optimized away (about 65 ns held under the lock). That overhead is identical for every lock.
- **QoS:** the calling thread and every worker run at `QOS_CLASS_USER_INTERACTIVE`, so core placement is consistent between samples instead of being left to the default class.
- **Two builds.** The framework's malloc interposer, when linked, routes every allocation in the process through a wrapper that adds a size header. This happens even for benchmarks that don't request malloc metrics, and turning counting on adds further per-allocation cost. All timing, CPU, instruction and context-switch numbers therefore come from a build with the interposer compiled out (`BENCHMARK_DISABLE_MALLOC_INTERPOSER=1`); the binary is checked to not link `libMallocInterposerSwift.dylib`. Allocation counts come from the default build. The benchmark detects the interposer at run time (an exported symbol of the dylib) rather than trusting the environment.
- The hot loops were checked in the release binary's disassembly: each candidate's thread loop is specialized, with no retain/release, no witness-table calls and no closure calls. `Mutex` compiles to direct `os_unfair_lock_lock`/`unlock` calls.
- The raw C locks (`os_unfair_lock`, `pthread_mutex`, `pthread_rwlock`) live in the same heap block as the counter, like `Mutex`, which stores both inline, so lock and data share a cache line.
- A correctness check (no lost updates) runs for every lock before benchmarking.
- Metrics: wall clock, total CPU time (process-wide), context switches (contended), instructions (uncontended and creation). Allocation build: malloc count, plus malloc bytes and free count for creation. All benchmarks run 2 warmup iterations (1 in the allocation build).
- Caveats: the contended measured region includes one semaphore wake-up of the caller (a few microseconds). The 32-thread case saturates all 32 cores, so it includes efficiency/performance core placement effects. Instruction counts are exported in whole millions, so per-create values are ±10 instructions.

## Results: creation

| Lock | ns/create | instructions | mallocs | bytes | Extra mallocs vs baseline |
|---|---:|---:|---:|---:|---:|
| `Mutex` | 16.0 | 400 | 1 | 32 | 0 |
| `Atomic` (reference) | 16.2 | 400 | 1 | 24 | 0 |
| `no lock` (wrapper only) | 17.5 | 400 | 1 | 24 | - |
| `os_unfair_lock` | 27.5 | 680 | 2 | 40 | 1 |
| `pthread_rwlock(write)` | 32.6 | 830 | 2 | 250 | 1 |
| `pthread_mutex` | 33.2 | 830 | 2 | 100 | 1 |
| `OSAllocatedUnfairLock` | 34.0 | 850 | 2 | 52 | 1 |
| `NSLock` | 42.3 | 990 | 2 | 130 | 1 |
| `NSRecursiveLock` | 43.7 | 1,050 | 2 | 240 | 1 |
| `NSCondition` | 49.0 | 1,100 | 2 | 160 | 1 |
| `DispatchSemaphore` | 50.8 | 1,120 | 2 | 110 | 1 |
| `DispatchQueue.sync` | 180 | 4,160 | 4 | 210 | 3 |
| `DispatchQueue.async` | 180 | 4,180 | 4 | 220 | 3 |

(`DispatchQueue.sync` and `.async` share the same creation code, `DispatchQueue(label:)`.)

- `Mutex` is the only lock with **no allocation of its own**: it is stored inline in its owner, so creating it costs the same as having no lock (the 1.5 ns difference from the baseline row is noise).
- `OSAllocatedUnfairLock` always heap-allocates its state (one extra allocation, about +17 ns).
- `os_unfair_lock`, `pthread_mutex` and `pthread_rwlock` need stable memory, so here they cost an extra malloc for the pointer (+10 to +16 ns). That is an artifact of this benchmark's design; embedding them (for example via `ManagedBuffer`) would remove the allocation but is more code.
- The Foundation locks and `DispatchSemaphore` are one extra object each, about +25 to +33 ns. `NSCondition` and `NSRecursiveLock` also allocate larger bodies (160 and 240 bytes).
- A serial `DispatchQueue` is by far the heaviest: 4 allocations and about 10 times the baseline time.

## Results: uncontended (single thread)

| Lock | ns/op | instructions/op | mallocs/op |
|---|---:|---:|---:|
| `OSAllocatedUnfairLock` | 1.75 | 30 | 0 |
| `Mutex` | 1.75 | 29 | 0 |
| `os_unfair_lock` | 1.75 | 30 | 0 |
| `Atomic` (reference) | 1.76 | 4 | 0 |
| `DispatchSemaphore` | 3.56 | 42 | 0 |
| `pthread_mutex` | 4.33 | 84 | 0 |
| `NSCondition` | 5.95 | 145 | 0 |
| `pthread_rwlock(write)` | 6.00 | 87 | 0 |
| `NSLock` | 6.48 | 155 | 0 |
| `NSRecursiveLock` | 13 | 297 | 0 |
| `DispatchQueue.sync` | 78 | 1,797 | 3 |
| `DispatchQueue.async` (to completion) | 2,710 | ~28,000 | 3 |

`Mutex`, `OSAllocatedUnfairLock` and `os_unfair_lock` all run at the cost of a single atomic operation on this machine (equal to the lock-free counter), because the fast path is one compare-and-swap to acquire and one to release. Everything else costs 2 to 45 times more (the async queue far more). `DispatchQueue.sync` allocates 3 times per call.

The `DispatchQueue.async` row is approximate. Each sample runs about 30 billion instructions, which the tool reports in whole billions, so the per-op count is only resolved to the nearest 1,000. Its 12 samples also vary widely (18 to 32 billion instructions, 1.7 to 3.1 µs/op wall), most likely depending on how often the consumer thread goes idle and has to be woken.

The counter is passed to `blackHole` before the timed loop so that it escapes the function (see Methodology). Without that, `OSAllocatedUnfairLock` measured 25 instructions/op: its lock word and its state are separate fields, and only the lock word's address is passed to `os_unfair_lock_lock`. So when the counter never left the function, the optimizer proved the C calls couldn't observe the state and moved the increment out of the loop, doing 4 fewer instructions per operation than the others. Wall time was the same either way. With the counter escaped, every candidate keeps the full load, increment and store inside the lock. `OSAllocatedUnfairLock` and `os_unfair_lock` also reload their storage pointer from the class each iteration (one instruction more than `Mutex`, which is stored inline), as real code holding a lock in a class property would.

## Results: contended

### Short critical section: wall time for 200k operations (ms, p50; lower is better)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Atomic` (reference) | 0.37 | 0.67 | 1.1 | 2.3 | 15 |
| `Mutex` | 0.43 | 1.9 | 1.8 | 1.4 | 1.2 |
| `OSAllocatedUnfairLock` | 0.41 | 1.9 | 1.8 | 1.4 | 1.2 |
| `os_unfair_lock` | 0.41 | 1.9 | 1.8 | 1.3 | 1.1 |
| `pthread_mutex` | 0.87 | 1.3 | 3.4 | 2.4 | 2.1 |
| `NSCondition` | 1.3 | 1.8 | 4.9 | 3.6 | 3.0 |
| `NSLock` | 1.3 | 2.1 | 5.8 | 3.9 | 3.3 |
| `NSRecursiveLock` | 2.6 | 3.9 | 9.8 | 6.5 | 6.0 |
| `pthread_rwlock(write)` | 1.2 | 363 | 361 | 365 | 398 |
| `DispatchSemaphore` | 0.71 | 349 | 355 | 357 | 361 |
| `DispatchQueue.sync` | 16 | 501 | 652 | 659 | 630 |
| `DispatchQueue.async` | 628 | 29 | 31 | 50 | 214 |

The fast locks (`Mutex`, the unfair locks, `pthread_mutex`, the Foundation locks) finish in a few milliseconds, while `DispatchSemaphore`, `pthread_rwlock` and `DispatchQueue.sync` take 100 to 500 times longer. The 2-thread case is slower than the 8 to 32 thread cases for the unfair locks: with exactly two threads the lock ping-pongs between two cores on every operation, whereas with more threads a running owner often reacquires the lock.

### Short critical section: context switches during the measured region (p50)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Atomic` (reference) | 1 | 1 | 1 | 1 | 62 |
| `Mutex` | 1 | 1 | 16 | 16 | 15 |
| `OSAllocatedUnfairLock` | 1 | 1 | 14 | 13 | 15 |
| `os_unfair_lock` | 1 | 2 | 7 | 14 | 17 |
| `pthread_mutex` | 1 | 464 | 1,848 | 716 | 231 |
| `NSCondition` | 1 | 640 | 2,615 | 1,025 | 359 |
| `NSLock` | 1 | 763 | 2,615 | 1,077 | 358 |
| `NSRecursiveLock` | 1 | 1,574 | 5,343 | 1,621 | 567 |
| `pthread_rwlock(write)` | 1 | 198,000 | 200,000 | 200,000 | 200,000 |
| `DispatchSemaphore` | 1 | 194,000 | 200,000 | 200,000 | 200,000 |
| `DispatchQueue.sync` | 1 | 199,000 | 200,000 | 200,000 | 200,000 |
| `DispatchQueue.async` | 371,000 | 594 | 10 | 23 | 902 |

### Short critical section: total CPU time (ms, p50)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Atomic` (reference) | 0.39 | 1.3 | 4.0 | 16 | 430 |
| `Mutex` | 0.44 | 3.8 | 7.2 | 8.6 | 39 |
| `OSAllocatedUnfairLock` | 0.43 | 3.7 | 7.1 | 8.7 | 54 |
| `os_unfair_lock` | 0.43 | 3.8 | 7.0 | 8.2 | 36 |
| `pthread_mutex` | 0.88 | 2.1 | 10 | 15 | 59 |
| `NSCondition` | 1.3 | 2.9 | 14 | 24 | 91 |
| `NSLock` | 1.4 | 3.4 | 18 | 26 | 83 |
| `NSRecursiveLock` | 2.6 | 6.3 | 29 | 45 | 168 |
| `pthread_rwlock(write)` | 1.2 | 380 | 377 | 381 | 437 |
| `DispatchSemaphore` | 0.72 | 373 | 380 | 381 | 418 |
| `DispatchQueue.sync` | 16 | 581 | 758 | 754 | 738 |
| `DispatchQueue.async` | 781 | 85 | 141 | 363 | 5,956 |

### Long critical section (~65 ns held): wall time for 200k operations (ms, p50)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Mutex` | 13 | 38 | 25 | 25 | 29 |
| `OSAllocatedUnfairLock` | 13 | 38 | 24 | 24 | 28 |
| `os_unfair_lock` | 13 | 38 | 24 | 27 | 28 |
| `pthread_mutex` | 14 | 18 | 35 | 30 | 28 |
| `NSCondition` | 14 | 18 | 34 | 30 | 29 |
| `NSLock` | 13 | 19 | 34 | 31 | 29 |
| `NSRecursiveLock` | 14 | 18 | 37 | 32 | 30 |
| `pthread_rwlock(write)` | 14 | 374 | 375 | 395 | 438 |
| `DispatchSemaphore` | 13 | 359 | 356 | 352 | 349 |
| `DispatchQueue.sync` | 28 | 619 | 657 | 645 | 622 |
| `DispatchQueue.async` | 84 | 39 | 48 | 68 | 230 |

### Long critical section: context switches (p50)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Mutex` | 1 | 33 | 299 | 314 | 97 |
| `OSAllocatedUnfairLock` | 1 | 80 | 363 | 267 | 96 |
| `os_unfair_lock` | 1 | 42 | 325 | 326 | 81 |
| `pthread_mutex` | 2 | 4,603 | 18,000 | 5,347 | 1,708 |
| `NSCondition` | 2 | 4,723 | 15,000 | 5,663 | 1,830 |
| `NSLock` | 1 | 4,827 | 18,000 | 5,743 | 1,870 |
| `NSRecursiveLock` | 1 | 5,003 | 18,000 | 5,727 | 1,883 |
| `pthread_rwlock(write)` | 3 | 199,000 | 200,000 | 200,000 | 200,000 |
| `DispatchSemaphore` | 1 | 199,000 | 200,000 | 200,000 | 200,000 |
| `DispatchQueue.sync` | 2 | 199,000 | 200,000 | 200,000 | 200,000 |
| `DispatchQueue.async` | 28,000 | 20 | 34 | 75 | 911 |

### Long critical section: total CPU time (ms, p50)

| Lock | 1 thread | 2 | 4 | 8 | 32 |
|---|---:|---:|---:|---:|---:|
| `Mutex` | 13 | 74 | 96 | 168 | 755 |
| `OSAllocatedUnfairLock` | 13 | 75 | 91 | 144 | 690 |
| `os_unfair_lock` | 13 | 76 | 95 | 178 | 758 |
| `pthread_mutex` | 14 | 25 | 103 | 211 | 707 |
| `NSCondition` | 14 | 25 | 102 | 216 | 711 |
| `NSLock` | 13 | 27 | 102 | 217 | 743 |
| `NSRecursiveLock` | 14 | 25 | 110 | 224 | 769 |
| `pthread_rwlock(write)` | 14 | 388 | 392 | 418 | 489 |
| `DispatchSemaphore` | 13 | 376 | 374 | 368 | 395 |
| `DispatchQueue.sync` | 28 | 703 | 757 | 740 | 719 |
| `DispatchQueue.async` | 130 | 109 | 199 | 455 | 6,174 |

### Allocations

- Creation allocations are listed in the creation table above.
- Per operation, all the lock types (`Mutex`, `OSAllocatedUnfairLock`, `os_unfair_lock`, `pthread_*`, `NS*`, `DispatchSemaphore`) allocate **nothing**: 0 mallocs for 100,000 uncontended operations.
- `DispatchQueue.sync` and `DispatchQueue.async` allocate **3 times per operation** (300,000 for 100,000 uncontended operations; 600,000 for 200,000 contended).
- With 4 contended threads, every candidate (the lock-free `Atomic` included) shows the same 20 mallocs in the measured region on top of that. These come from the measurement scaffolding, not the locks. Their source wasn't investigated further; earlier revisions attributed them to thread exit, but thread exit is now outside the region and they remain.

## Findings

1. **`Mutex`, `OSAllocatedUnfairLock` and `os_unfair_lock` are the best general-purpose choice.** They are effectively equivalent at run time: 1.75 ns and 29 to 30 instructions uncontended (the cost of one atomic operation), no allocation per operation, and by far the fewest context switches under contention (about 15 vs 230 to 570 for the next best at 32 threads, short section; about 80 to 100 vs 1,700 to 1,900 for long). Prefer `Mutex` (`~Copyable`, `Sendable`, safe API; the only lock that is free to create, so it suits many short-lived or per-object locks) or `OSAllocatedUnfairLock` (works on older OS versions, one allocation to create) over raw `os_unfair_lock`, which needs manual stable storage and gives no measurable gain.
2. **`pthread_mutex`, `NSLock` and `NSCondition` are 2.5 to 3.7 times slower uncontended** and cause roughly 15 to 450 times more context switches under contention, because they park waiting threads instead of using the kernel's priority-donating unfair lock. They remain fine for light use. `NSRecursiveLock` is the slowest of the Foundation locks (13 ns uncontended); only use it when re-entrancy is needed.
3. **`DispatchSemaphore` is fast only when uncontended** (3.6 ns). With two or more threads actually competing, it falls apart: nearly every operation was a context switch (about 200,000 for 200,000 operations) and wall time was about 350 ms vs about 1 to 2 ms for `Mutex`. Do not use a binary semaphore as a mutex on a hot path.
4. **`pthread_rwlock` used as a plain mutex is bad**: 6.0 ns uncontended, and it also blocked and context switched on every contended acquisition (about 360 to 440 ms). Use a reader/writer lock only when reads dominate and the critical sections are long enough to pay for it; this benchmark deliberately only measures its write path.
5. **`DispatchQueue.sync` is the most expensive way to protect state**: about 78 ns uncontended, 3 allocations per call, and a context switch per contended operation (500 to 660 ms for 200,000). It earns its place when you want queue semantics (ordering, QoS, target queues), not as a lock.
6. **`DispatchQueue.async` is a different tool, but is now timed to completion** so its numbers are comparable. With 2 to 8 producers it finishes 200k operations in 29 to 50 ms (short) and 39 to 68 ms (long): 15 to 35 times slower than `Mutex` in the short case, and roughly equal to it at 2 producers in the long case, where the serialized work dominates. It allocates 3 times per call, and its CPU time balloons at 32 producers (about 6 s CPU for 200k operations, mostly worker wake-ups and queue management). With one producer it is pathologically slow (about 630 ms, 371,000 context switches, about 2.7 µs per operation uncontended) because the consumer drains faster than the producer enqueues and is woken for nearly every item.
7. **Critical-section length changes little in the ranking.** With ~65 ns held, `Mutex` and the unfair locks still lead on context switches. The wall-time gap with `pthread_mutex`/`NSLock` closes at 8 to 32 threads (24 to 29 ms vs 28 to 32 ms) because the serialized work dominates. At 4 threads the unfair locks are still about 1.4 times faster (24 to 25 vs 34 to 37 ms).
8. **Fairness is not measured**: the unfair locks can starve a thread. This benchmark measures throughput only.
9. **Two threads is the worst case for the unfair locks** (about 1.9 ms short and 38 ms long, vs 1.1 to 1.2 and 28 to 29 ms at 32 threads): with exactly two threads the lock line bounces between cores on every operation. `pthread_mutex` and the Foundation locks are faster than them in the 2-thread long case (18 to 19 ms vs 38 ms) because they let one thread run a batch of operations while the other sleeps.

## Changes in v4

The measurement was tightened after a review of the harness. The changes, and their observed effect compared with v3:

| Change | Effect |
|---|---|
| Timing taken from a build without the malloc interposer (previously linked into every run) | The largest effect. Creation dropped from about 30 to 17 ns for the baseline, and from 760 to 400 instructions, with every row falling by a similar amount. `DispatchQueue.sync` dropped from 124 to 77 ns/op uncontended (3,038 to 1,796 instructions) and from 26 to 16 ms in the 1-thread contended case. Locks that don't allocate per operation were unaffected. |
| Thread exit and join moved out of the contended measured region | Small: the short section at 32 threads went from about 1.2 to 1.15 ms for the unfair locks. That is within run-to-run variation, so the old numbers weren't materially distorted. |
| `DispatchQueue.async` timed until the queue drains, in both modes | Makes it comparable with the locks. 32 producers went from 182 to 214 ms (short); 2 producers from 35 to 29 ms, now without the interposer's cost. |
| `maxDuration` raised from 2 s (1 s uncontended) to 10 s | The slow contended cases now get 16 to 30 samples instead of about 3 to 5. |
| All benchmark threads run at `QOS_CLASS_USER_INTERACTIVE` | Consistent core placement. No ranking changed. |
| Uncontended counter escaped via `blackHole` before the loop | `OSAllocatedUnfairLock` went from 25 to 30 instructions/op (the increment had been moved out of its loop); other candidates rose by 1 to 5 instructions from reloading class fields. No wall-time change. |
| Separate `create-clean` pass removed | Unnecessary now that the timing build has no interposer at all. |

## Limitations

- The workload is one hot lock with all threads hammering it continuously, which is a worst case. Real code usually has much lower contention, where the uncontended numbers matter more.
- Results are from one machine (Apple M3 Ultra, 32 cores); lock behavior under contention varies with core count and core type. Results varied by a few percent between runs; differences smaller than about 10% between locks should not be considered significant.
- Uncontended `DispatchQueue.async` has 12 samples within its 30 s cap and a wide spread between them; its row is approximate.
- Creation numbers include the wrapper class and are for locks that go out of scope immediately; they do not reflect first-use or contention costs.
- Not tested: reader/writer workloads, lock-ordering/fairness, recursion, `async`/actor-based isolation, and other platforms. `OSAllocatedUnfairLock` requires macOS 13+ and `Mutex` requires macOS 15+.
