internal import BytesAsync
import Foundation

extension ZipArchive {
    /// Runs `body` for every item using up to `maxConcurrency` child tasks, each with its own decoder.
    ///
    /// Items are processed largest-first (longest-processing-time scheduling), so one big entry
    /// doesn't start last and leave every other worker idle while it finishes. With one worker,
    /// or one item, everything runs inline, in the given order, with no task overhead. Cancelling the calling task
    /// stops the workers claiming items; items already started finish. `body` records its own failures (it doesn't
    /// throw), so one item's failure doesn't stop the others.
    ///
    /// `nonisolated(nonsending)`: the inline path runs on the caller's executor. `body` is a `@Sendable` closure
    /// (several workers call it), so it runs on the global executor, where the workers already are.
    ///
    /// - Parameters:
    ///   - items: The work items.
    ///   - maxConcurrency: The most workers to use; values below 1 count as 1.
    ///   - weight: An item's relative cost, used for the largest-first order.
    ///   - body: Processes one item with its worker's decoder.
    nonisolated(nonsending) func forEachConcurrently<Item: Sendable>(
        _ items: [Item],
        maxConcurrency: Int,
        weight: (Item) -> UInt64,
        _ body: @escaping @concurrent @Sendable (Item, inout ZipDecoder) async -> Void
    ) async {
        let width = min(max(maxConcurrency, 1), items.count)
        guard width > 1 else {
            var decoder = ZipDecoder()
            for item in items {
                if Task.isCancelled { return }
                await body(item, &decoder)
            }
            return
        }

        let ordered = items.sorted { weight($0) > weight($1) }
        let next = RelaxedCounter()
        // The throwing group, though nothing throws (its `any Error` is the standard library's, never made): the
        // non-throwing `withDiscardingTaskGroup` measured 10 more mallocs per call (`Verify 2,000 small files`, p50
        // 137 → 147 on 10 cores; Benchmarks/RESULTS.md, 2026-11-23).
        try? await withThrowingDiscardingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    var decoder = ZipDecoder()
                    while !Task.isCancelled, let index = next.claim(below: ordered.count) {
                        await body(ordered[index], &decoder)
                    }
                }
            }
        }
    }
}
