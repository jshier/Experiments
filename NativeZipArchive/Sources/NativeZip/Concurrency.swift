import Foundation
import Synchronization

/// A lock-free work queue: workers claim the next index with an atomic increment.
final class WorkQueue: Sendable {
    private let next = Atomic<Int>(0)
    let count: Int

    init(count: Int) { self.count = count }

    func claim() -> Int? {
        let index = next.wrappingAdd(1, ordering: .relaxed).oldValue
        return index < count ? index : nil
    }
}

extension ZipArchive {
    /// Runs `body` for every item using up to `maxConcurrency` child tasks, each with its own decoder.
    ///
    /// Items are processed largest-first (longest-processing-time scheduling), so one big entry
    /// doesn't start last and leave every other worker idle while it finishes. With one worker,
    /// or one item, everything runs inline with no task overhead.
    func forEachConcurrently<Item: Sendable>(
        _ items: [Item],
        maxConcurrency: Int,
        weight: (Item) -> UInt64,
        _ body: @escaping @Sendable (Item, inout ZipDecoder) async throws -> Void
    ) async throws {
        let width = min(max(maxConcurrency, 1), items.count)
        guard width > 1 else {
            var decoder = ZipDecoder()
            for item in items { try await body(item, &decoder) }
            return
        }

        let ordered = items.sorted { weight($0) > weight($1) }
        let queue = WorkQueue(count: ordered.count)
        try await withThrowingDiscardingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    var decoder = ZipDecoder()
                    while !Task.isCancelled, let index = queue.claim() {
                        try await body(ordered[index], &decoder)
                    }
                }
            }
        }
    }
}
