# Plan: BytesAsync on the SDK's `Continuation`, scoped permits, buffer leases (2026-11-25)

Open items 6, 22, and 26 of `Open-Items-2026-11-25.md`. Probes: `~/Scratch/async-leases.noindex/probe` (a package on
Bytes by path: a noncopyable ring, a limiter on the SDK's continuation, a lease; `probe-check` runs 200 tasks through a
3-permit limiter, checks the ring's order across growth, and a lease's return; `probe-drop` drops a continuation).

## What the probes and the SDK show

- **The SDK's type** (macOS 27, `_Concurrency.swiftinterface:1628`): `@frozen struct Continuation<Success: ~Copyable,
  Failure: Error>: ~Copyable, @unchecked Sendable`, `consuming func resume(…)`, an opaque `deinit`, and
  `nonisolated(nonsending) withContinuation(of:_:)` / `withContinuation(of:throwing:_:)`. BytesAsync's own
  `Continuation<T>` and `withContinuation(_:)` (`Waiting.swift`) shadow them: a `CheckedContinuation` in debug, a
  wrapped `UnsafeContinuation` in release.
- **Exactly once, in every build.** A second resume doesn't compile; a continuation dropped unresumed traps
  (`probe-drop`: "Continuation was deinitialized without being resumed", debug and release). Today a release build
  hangs the task instead, and a debug build only logs the leak.
- **A closure can't consume a captured noncopyable parameter**, so the continuation can't go into `Mutex.withLock`'s
  closure directly: move it into a local `Optional` first and `take()` it inside (`var held = Optional(consume c)`). Not
  boxed: `Tools/calls` finds no `swift_allocObject` in `acquire`/`release`. `Mutex.withLock`'s `Result` may be
  `~Copyable`, so a continuation comes out of the lock as an `Optional`.
- **A noncopyable ring on `UniqueArray<Element?>`** (`take()` through its `mutate` subscript, wrap by compare): no
  `%`, no copy-on-write check. `AsyncLimiter.release`'s locked closure: 54 instructions → 25 (the old one also calls
  `_ArrayBuffer._consumeAndCreateNew` for the `[Element?]` ring's uniqueness check).

## Changes

### Item 6: BytesAsync on the SDK's continuation (Bytes)

- Delete BytesAsync's `Continuation<T>` and `withContinuation(_:)`; every primitive and client uses
  `_Concurrency.Continuation<T, Never>` and `withContinuation(of:_:)`. `Waiting.swift`'s header keeps the pattern (fast
  path under the lock, store-or-resume in the same critical section, resume outside the lock) and says what the
  compiler and runtime now check.
- `WaiterQueue<Element: ~Copyable>: ~Copyable`, on `UniqueArray<Element?>`, wrap by compare, growth by moving. Its
  `removeAll()` returns the waiters as a `WaiterQueue` (moved out, the queue left empty with capacity 1) for the caller
  to resume outside the lock; `removeFirst(where:)` stays if a client uses it, else goes.
- `AsyncLimiter`, `AsyncIndexPool`, `AsyncLatch`, `AsyncHandoff`, `AsyncQueue`: states `~Copyable` where they hold
  continuations; the enums that carry a continuation out of the lock (`Offer`, `Send`, `Receive`) become `~Copyable`
  and are matched with `switch consume`. `AsyncQueue`'s element ring: `UniqueArray<Element?>`, no `%`; its waiting
  producers a `~Copyable` struct (continuation and element) instead of a tuple.
- Clients' own waits move to the SDK type: Disk `JobQueue.swift` (its write queue) and `Extraction.swift` (the
  large-file turn), NativeAEA `Payload.swift` (the runner), BytesCompressionAsync `ParallelBlockDecoder.swift` (the
  consumer) and `BlockBufferPool.swift`, NativeZip `ZipContentSource.swift` (a `CheckedContinuation` in an `Array`,
  allocating per wait: onto `WaiterQueue`).

### Item 22: scoped resources (Bytes, Disk)

- `AsyncLimiter.withPermit(_:)`: `nonisolated(nonsending)`, a `nonisolated(nonsending)` body, typed throws, a
  `~Copyable` result. Disk's Writer adopts it at its five `acquire()` / `defer { release() }` pairs (not at the
  acquire in one function and release in another, `Writer.swift:783/817`).
- **A closable pool**: `AsyncIndexPool` gains `close()` (waiters and later acquires get `nil`: `acquire() -> Int?`)
  and late activation (`init(count:active:)`, `activateAll()`), so `BlockBufferPool` builds its buffer handout on it
  instead of a copy of the same waiting code (free list, waiters, closed, active). Disk's `freeLargeFiles` handles the
  `nil` it never gets (it never closes the pool) with a precondition.
- **Not done: an `AsyncIndexPool` lease.** Its one client, Disk's large-file slots, holds an index in the planner and
  in every piece job, freed by whichever drops an atomic count to zero (`Planner.swift:505–613`, `Writer.swift:819`): a
  unique lease can't model that, and a public type with no client goes against the access rule. Recorded in the
  open-items list.

### Item 26: block buffers as leases (BytesCompression, NativeAEA)

- `BlockBufferPool.Buffer: ~Copyable, Sendable` (the pool and an index): `deinit` drops its reference;
  `borrowing func share() -> Buffer` adds one (today's `retain`); `consuming func detach() -> Int` gives the reference
  up as an index, for holders in copyable values (Disk's job contents), which still `release(_ index:)`. `acquire()`
  and `tryAcquire()` return `Buffer?`. `bytes`, `withMutableBytes`, `carry` take a `borrowing Buffer`, with the index
  forms kept for detached holders.
- `DecodedBlock: ~Copyable` holds its `Buffer`; `OrderedBlockSource.nextBlock()` returns `DecodedBlock?`. A block is
  released by being dropped: the walkers' `previousBuffer = -1` / `if previousBuffer >= 0 { pool.release(…) }`
  (`ArchiveWalker.swift:43–64`, `CpioWalker.swift:106–119`), `Decrypt.swift:54`'s `defer`, and `UpstreamReader`'s
  hand-ordered `block = nil; release(…)` (its comment records a double release this ordering avoids) become a
  `var previous: DecodedBlock?` and moves.
- The engine: `decodeTask` and `produce` hold a `Buffer` until they publish it; the slot table and the staging job
  (copyable) take `detach()`ed indices, which `next(_:taking:)` turns back into a lease for the consumer.
- NativeAEA's `SegmentContents` (Disk job contents): `share().detach()` per job; `release` as today.

## Tests

- `WaitingTests`: the ring in order across growth with noncopyable elements, `removeAll` order, `withPermit` under
  contention (most inside = permits) and when the body throws (the permit comes back), `AsyncIndexPool.close()`
  waking waiters with `nil`, late activation handing indexes to waiters first.
- A stress test (`@Suite(.bulk)`): many tasks through limiter, queue, handoff, and index pool for a few seconds,
  checking counts and that nothing is left waiting (the open items' "BytesAsync stress test").
- Leases: a dropped `Buffer` returns to the pool; `share()` then two drops; `detach()` then `release(index)`;
  `BlockDecoderTests` and NativeAEA's suites (cancellation, conformance on the synthetic set) unchanged and passing;
  the pools' leak checks (`pools`, `buffersInUse == 0` after `finish`).
- Each new path broken once to see its test fail.

## Measuring

Before any change: new BytesAsync rows in `BytesBenchmarks` (uncontended limiter acquire/release, a handoff
ping-pong between two tasks, an `AsyncQueue` of 1 M elements through 4 consumers; instructions, mallocs 0) saved as
`async-before`, and Disk's `Small files`, `Queue`, and `Workers` rows as `async-before` (`FileWriter-1000-small-files`'s
zero-malloc threshold stays). After: `async-after`, `Tools/bench-table`. Codegen: `Tools/calls --callee
'swift_allocObject|swift_beginAccess|_consumeAndCreateNew'` over BytesAsync's clients (none expected in the wait
paths); SocketStream with its PR toolchain (`Tools/toolchain SocketStream`).

## Review (2026-11-25), and what changed

An adversarial review (read-only agent, probes in `~/Scratch/async-leases-review.noindex/probe`, built and run with
Xcode 27.3 and SocketStream's PR toolchain, pr-91981) confirmed the SDK type on both toolchains, noncopyable optionals
and enums out of `Mutex.withLock`, a noncopyable `DecodedBlock?` from an `async throws(F)` requirement through `any
P<F>`, `withPermit`, no allocation in the wait paths, and the ring's order; and that merging `BlockBufferPool`'s
handout into `AsyncIndexPool` and skipping the index lease are sound. Accepted, superseding the plan above:

1. **`Buffer.detach()` can't `discard self`** while the lease holds its pool strongly ("can only 'discard' type
   'Buffer' if it contains trivially-destroyed stored properties"): a sentinel index instead (`detach()` sets it to −1,
   `deinit` releases only `>= 0`). Not `unowned(unsafe)` (a lease outliving its pool would be a use-after-free).
2. **No tuples or arrays of noncopyable values**: structs, or a `WaiterQueue`, at every site: `AsyncLatch.state`,
   `AsyncHandoff`'s producer, `AsyncQueue.take()` and `close()`, Disk's `Turn.waiters` and `JobQueue.close()`,
   `ParallelBlockDecoder.fail`'s pair, `BlockBufferPool.activateAll` and `close()`.
3. **Assigning a lease across an `await` holds the old one until the call returns** (`block = try await
   nextBlock()`): with a listing's 2-buffer pool (1 decoder + 1 consumer) the decoder would find no buffer. Keep the
   explicit `block = nil` before each such `await` (`UpstreamReader.advance`); a test on the smallest pool. The walkers'
   `previous = consume chunk` at the end of the loop body is fine (released before the next `await`).
4. **`peek()`** (`next(_:taking: false)`, `Payload.swift:127`) must not adopt the slot's reference (a second release, a
   decoder overwriting a block still read): it `share()`s. The adopting initializer is `package`, used in one place.
5. **The `held.take()!` pattern fails only at run time** (a path returning before `take()` traps when it runs): written
   once, as a `Waiting.swift` helper that takes the continuation and either stores it or hands it back to be resumed;
   each re-check path tested deterministically.
6. **`removeAll()`** returns early without allocating when empty and keeps the queue's capacity (Disk reuses a
   large-file slot's turn queue); growth from 0 is clamped to 1.
7. **Benchmarks**: the new BytesAsync rows check results in setup only and count mallocs only where one task runs
   (the contended rows' instructions depend on scheduling: compare their times within a run); a row grows the waiter
   queue past its reservation. Added NativeAEA's synthetic list and extract rows (`async-before`), which run the
   engine and walkers item 26 changes. A `swift_retain` per block in `nextBlock` (the lease's pool reference) is
   expected.
8. `switch consume` needs storage: switch on the `withLock` call's result directly.
9. **`perform(on:)`** (`Offloading.swift:37`) stays on `UnsafeContinuation`: it resumes from an escaping
   `DispatchQueue.async` closure, which can't consume a captured noncopyable value.
10. Misuse that hung now traps: `precondition(state.waiter == nil, "one task waits")` where one waiter is the rule
    (`AsyncLatch`, `AsyncHandoff`, NativeAEA's runner), so the message says what went wrong.
11. ZipContentSource: a test with three copies of one path (one waiter per tag is what makes `removeFirst(where:)`
    equivalent to waking every waiter with the tag).
12. Also: Bytes.docc `UnderstandingTheTypes.md:22`, Disk's and NativeAEA's Package.swift comments, NativeAEA's
    `CancellationTests` wrapper source, `BlockDecoderTests`' `tryAcquire` arrays. `ArchiveSink`'s `buffer: Int` stays (a
    `share().detach()` there is today's `retain`). `AsyncIndexPool`'s `tryAcquire`, active count, and waiter count
    become public for BytesCompression.

## Outcome (2026-11-25)

Implemented as revised above; the implementation's adversarial review (probes in
`~/Scratch/async-leases-review.noindex`: lease lifetimes at `-O`, a 2,000-trial ring fuzz against an array model,
stress runs of the index pool and queue with `close`/`activateAll` racing, region-isolation smuggling attempts) found
no defects. Taken from its notes: a named precondition for a second `ParallelBlockDecoder` consumer, and
`activateAll()` allocating nothing when nobody waits. Not taken: `withPermit`'s per-call partial apply across modules
(its five uses each wrap a syscall).

- Finding 3 (a deadlock if `advance` held the old block across its wait) didn't reproduce: `smallestPoolsFinish`
  passes with the break, since a decoder takes its buffer before its block. The explicit `block = nil` stays: the
  buffer is free sooner.
- Added on the way: `WaiterQueue.removeAll(where:)` (NativeZip's per-tag wake; allocates only on a match), and
  `Sendable` on `WaiterQueue` (conditional) and on `AsyncQueue`'s carriers, which SocketStream's PR toolchain needs to
  return them from `withLock`.
- Breaks seen to fail: `removeAll(where:)` without the move (wrong order), `withPermit` releasing only on success
  (hangs), NativeZip's wake skipped (hangs), `peek` adopting (`peekingKeepsTheConsumersReference`).
- Compiler bugs: `~/Scratch/swift-bugs/` 29 (optional chain on a noncopyable `let`) and 30 (IRGen on a generic
  `Continuation??`).

## Risks

- `~Copyable` through `Mutex`, enums, `Optional`, and `async` protocol requirements on Swift 6.4 and SocketStream's PR
  toolchain: build every client with both.
- A lease dropped too early (a `Buffer` consumed into a slot, then used): the compiler forbids use after consume; the
  remaining risk is the index forms, unchanged from today.
- `AsyncIndexPool.acquire()` returning `Int?` changes its clients' code: Disk only.
