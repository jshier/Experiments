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

/// Runs `operation` in a child task at `priority` and returns its result: for work that must run at a priority of its
/// own whatever the caller's, such as a command-line tool's main task (which runs at the default priority, not
/// user-initiated) or a GUI app that may be in the background (where its work would run at background QoS, on the
/// efficiency cores).
///
/// ```swift
/// func run() async throws {
///     try await withPriority(.userInitiated) { try await command.work() }
/// }
/// ```
///
/// Child tasks `operation` starts inherit the priority. Being a child task, it keeps the caller's cancellation and
/// task-locals; its error type passes through.
///
/// - Parameters:
///   - priority: The child task's priority.
///   - operation: The work.
/// - Returns: What `operation` returns.
/// - Throws: What `operation` throws.
@inlinable
public nonisolated(nonsending) func withPriority<T: Sendable, E: Error>(
    _ priority: TaskPriority, operation: sending @escaping () async throws(E) -> T
) async throws(E) -> T {
    // Unchecked: the region checker can't see that `operation`, sent here, goes on to the child task through the group's
    // body closure. Safe: the child is its only user, and the caller gave it up (`sending`).
    nonisolated(unsafe) let operation = operation
    // A `Result` through a non-throwing group: `withThrowingTaskGroup` would turn `E` into `any Error`.
    let result = await withTaskGroup(of: Result<T, E>.self) { group in
        group.addTask(priority: priority) {
            do throws(E) { return .success(try await unsafe operation()) } catch { return .failure(error) }
        }
        // One child: `next()` returns its result.
        return await group.next()!
    }
    return try result.get()
}
