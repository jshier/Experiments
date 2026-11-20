import Dispatch

// The two ways BytesAsync moves synchronous work off the calling task's executor:
//
// - `@concurrent` functions (`concurrently()`, `ConcurrentTransform`): the work runs on Swift's global concurrent
//   executor, in the calling task. Structured: it inherits the task's priority and task-locals, and a caller that is
//   already on the global executor (any nonisolated task) doesn't change threads at all. The default.
// - A Dispatch queue (`offloaded(to:)`, `compressAll(_:into:on:)`, `decompressAll(_:into:on:)`): the calling task
//   suspends and the work runs on the queue; two thread switches per call, whatever the caller. Kept for callers that
//   must keep long work off the cooperative pool's threads (or on a queue of their own QoS), and for the parallel
//   codecs' `concurrentPerform` form, which Dispatch runs on its own worker threads.
//
// Neither can stop a synchronous stage midway: cancellation is seen between calls, by the caller's loop.

/// Runs `work` on the global concurrent executor, in the calling task: off the caller's actor, if it has one,
/// and without a thread switch if it hasn't.
///
/// - Parameter work: The synchronous work. Non-escaping: no allocation.
/// - Returns: What `work` returns.
@concurrent
func perform<T: Sendable>(_ work: @Sendable () -> T) async -> T {
    work()
}

/// Runs `work` on `queue`, suspending the calling task until it returns.
///
/// The one Dispatch hop BytesAsync's queue forms share. `work` runs exactly once, and the calling task resumes only
/// after it has returned, so `work` may use memory the caller lends for the call.
///
/// - Parameters:
///   - queue: Where `work` runs.
///   - work: The synchronous work.
/// - Returns: What `work` returns.
nonisolated(nonsending) func perform<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
    // Unsafe: an unchecked continuation (a checked one allocates its checker per call). Safe: resumed exactly once,
    // by the block, after `work` returns.
    await unsafe withUnsafeContinuation { continuation in
        queue.async { unsafe continuation.resume(returning: work()) }
    }
}
