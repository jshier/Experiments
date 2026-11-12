import Foundation
import Synchronization

/// A lock-free work queue: workers claim the next index with an atomic increment.
final class WorkQueue: Sendable {
    private let next = Atomic<Int>(0)
    let count: Int

    init(count: Int) { self.count = count }

    /// Claims the next unclaimed index.
    ///
    /// - Returns: The index, or `nil` once all `count` indexes are claimed.
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
    /// or one item, everything runs inline, in the given order, with no task overhead. If `body` throws,
    /// the group cancels the other workers, which stop claiming items; items already started finish.
    ///
    /// - Parameters:
    ///   - items: The work items.
    ///   - maxConcurrency: The most workers to use; values below 1 count as 1.
    ///   - backend: The backend of each worker's decoder.
    ///   - weight: An item's relative cost, used for the largest-first order.
    ///   - body: Processes one item with its worker's decoder.
    /// - Throws: The first error `body` throws.
    func forEachConcurrently<Item: Sendable>(
        _ items: [Item],
        maxConcurrency: Int,
        backend: ZipDecoder.Backend,
        weight: (Item) -> UInt64,
        _ body: @escaping @Sendable (Item, inout ZipDecoder) async throws -> Void
    ) async throws {
        let width = min(max(maxConcurrency, 1), items.count)
        guard width > 1 else {
            var decoder = ZipDecoder(backend: backend)
            for item in items {
                try await body(item, &decoder)
            }
            return
        }

        let ordered = items.sorted { weight($0) > weight($1) }
        let queue = WorkQueue(count: ordered.count)
        try await withThrowingDiscardingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    var decoder = ZipDecoder(backend: backend)
                    while !Task.isCancelled, let index = queue.claim() {
                        try await body(ordered[index], &decoder)
                    }
                }
            }
        }
    }
}
