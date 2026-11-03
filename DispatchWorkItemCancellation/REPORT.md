# DispatchWorkItem Cancellation Behavior

Swift 6 language mode executable package; 22 experiments. Run with `swift run` from this directory.
Tested on macOS 27 / Xcode 27.0 (Swift 6.4), debug and release builds (results identical except where noted).

## Short answers

| Question | Answer |
|---|---|
| Is a cancelled item executed? | **No**, if `cancel()` happens before the queue starts it. The block is skipped (Exp 1, 9, 17, 18, 19). |
| Cancel while the block is running? | **Nothing is interrupted.** The block runs to completion. `isCancelled` flips to `true` and the block must poll it itself (Exp 2, 13, 22). |
| Cancel after it finished? | Harmless; only sets `isCancelled = true` (Exp 3). |
| Cancel racing the start? | Atomic: either the block runs fully or is skipped, never partial. No crashes or hangs (Exp 20). |
| Drop the last reference while pending? | **Still runs, not cancelled.** The queue retains the item's *block*, not the item object (Exp 4, 5). |
| Does deinit cancel? | **No.** Deallocating the item does not cancel anything. You just lose the ability to cancel it later. |

## Details

### Cancellation before start
- Cancelled items enqueued behind a blocked serial queue never run their block (Exp 1), including on a suspended queue after `resume()` (19), concurrent queues (16: exactly the 10 even-indexed items ran), and `asyncAfter` (18).
- Cancellation is **sticky**. An item cancelled before being enqueued is skipped when enqueued later, and there's no un-cancel (Exp 9).
- `perform()` on a cancelled item is also a no-op (Exp 7).

### Cancellation during execution
- Cooperative only. In Exp 2 the cancel arrived after ~80ms; the block kept running all 5 steps and `isCancelled` read `true` from step 2 onward.
- A block can cancel its own item and keeps running (Exp 13).
- `wait()` after a mid-run cancel still blocks until the body returns (Exp 22).
- Pattern: capture the item weakly (or via a holder) and check `isCancelled` between units of work.

### What "skipped" does to the surrounding machinery
- `wait()` on an item cancelled before start **still returns** (success) once the queue reaches and skips it. It does not hang (Exp 10). While the queue is still busy, `wait(timeout:)` correctly times out.
- `notify(queue:)` **fires even for a skipped item**, and also after a mid-run cancel once the block returns (Exp 11, 12). Don't treat notify as "work completed successfully"; check `isCancelled` inside it.
- A `DispatchGroup` entered via `queue.async(group:execute:)` is still left correctly, so `group.wait()` completes (Exp 17).
- `wait(timeout:)` on an item that was **never enqueued** times out, cancelled or not (Exp 21); an untimed `wait()` would presumably block forever (not tested). Cancelling a never-submitted item doesn't release waiters.

### Reference lifetime
- **The queue retains the block, not the `DispatchWorkItem`.** After the last strong reference was dropped, a `weak` reference was already `nil` while the item was still pending, yet the block ran later with its captures intact (Exp 4, 5).
- Consequence: dropping the reference is *not* a way to cancel, and there is no auto-cancel on deinit. To cancel later, you must keep the item alive.
- The item keeps its block alive after it runs or is skipped. Captured objects were released only when the item itself was released (Exp 6), not when the queue finished with it.
- Therefore a block capturing its own item (strongly, directly or via a box) forms a permanent retain cycle even after the work ran (Exp 14). Capture it weakly.
- A never-enqueued item deallocates cleanly, releasing its block and never running it (Exp 15).

### Re-use
- A `DispatchWorkItem` is **not** one-shot. `perform()` twice or enqueueing twice ran the block each time (Exp 8: 4 runs), unless cancelled. Cancellation is the only state that stops it.

### Race behavior (Exp 20)
Cancel after a busy-wait delay following `queue.async` on a concurrent queue, 500 trials each (debug / release):

| Delay | Ran (debug) | Ran (release) |
|---|---|---|
| ~0 µs | ~1 | 0 |
| ~20 µs | ~499 | ~485 |
| ≥ 50 µs | 500 | 500 |

Thread start-up latency is ~20–50 µs; before that, cancellation reliably wins. Exact numbers vary by run.

## Implementation gotcha (Swift 6)
Closures written in top-level `main.swift` code are inferred `@MainActor`. Passing them to `DispatchWorkItem` and running on another queue **traps** (`_dispatch_assert_queue_fail`). The experiments live in a `nonisolated` function (`Experiments.swift`) to avoid this.

## Practical guidance
1. `cancel()` is advisory for running work. Poll `isCancelled` inside long blocks.
2. Hold the item strongly for as long as you might cancel it (debounce/timeout patterns). Dropping it means the work will still happen.
3. Don't rely on `notify` to mean success. Check `isCancelled`.
4. Don't `wait()` on items that may never be enqueued.
5. Capture the item weakly inside its own block.
