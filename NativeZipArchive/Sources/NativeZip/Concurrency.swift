internal import BytesAsync
import Foundation

extension ZipArchive {
    /// Runs `body` for every item using up to `maxConcurrency` child tasks, each with its own decoder.
    ///
    /// Items are processed largest-first (longest-processing-time scheduling), so one big entry
    /// doesn't start last and leave every other worker idle while it finishes. With one worker,
    /// or one item, everything runs inline, in the given order, with no task overhead. If `body` throws,
    /// the group cancels the other workers, which stop claiming items; items already started finish. So does
    /// cancelling the calling task.
    ///
    /// `nonisolated(nonsending)`: the inline path runs on the caller's executor. `body` is a `@Sendable` closure
    /// (several workers call it), so it runs on the global executor, where the workers already are.
    ///
    /// - Parameters:
    ///   - items: The work items.
    ///   - maxConcurrency: The most workers to use; values below 1 count as 1.
    ///   - weight: An item's relative cost, used for the largest-first order.
    ///   - body: Processes one item with its worker's decoder.
    /// - Throws: The first error `body` throws.
    nonisolated(nonsending) func forEachConcurrently<Item: Sendable>(
        _ items: [Item],
        maxConcurrency: Int,
        weight: (Item) -> UInt64,
        _ body: @escaping @concurrent @Sendable (Item, inout ZipDecoder) async throws -> Void
    ) async throws {
        let width = min(max(maxConcurrency, 1), items.count)
        guard width > 1 else {
            var decoder = ZipDecoder()
            for item in items {
                if Task.isCancelled { return }
                try await body(item, &decoder)
            }
            return
        }

        let ordered = items.sorted { weight($0) > weight($1) }
        let next = RelaxedCounter()
        try await withThrowingDiscardingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    var decoder = ZipDecoder()
                    while !Task.isCancelled, let index = next.claim(below: ordered.count) {
                        try await body(ordered[index], &decoder)
                    }
                }
            }
        }
    }
}
