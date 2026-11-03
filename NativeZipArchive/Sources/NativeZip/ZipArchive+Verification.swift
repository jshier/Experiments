import Foundation
import Synchronization

extension ZipArchive {
    /// Decompresses every entry (in parallel) and checks its size and CRC-32 without writing anything.
    ///
    /// - Returns: The entries that failed and why, in archive order. Empty means the archive is intact.
    public func verify(
        _ entries: [ZipEntry]? = nil,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async -> [(entry: ZipEntry, error: any Error)] {
        let indexed = Array((entries ?? self.entries).filter { $0.kind != .directory }.enumerated())
        let failures = FailureLog()
        // The body never throws (failures are recorded instead), so neither does the loop.
        try? await forEachConcurrently(indexed, maxConcurrency: maxConcurrency, weight: \.element.uncompressedSize) {
            [self] item, decoder in
            do {
                try self.contents(of: item.element, using: &decoder) { _ in }
            } catch {
                failures.record(index: item.offset, entry: item.element, error: error)
            }
        }
        return failures.sorted()
    }
}

private final class FailureLog: Sendable {
    private let failures = Mutex<[(index: Int, entry: ZipEntry, error: any Error)]>([])

    func record(index: Int, entry: ZipEntry, error: any Error) {
        failures.withLock { $0.append((index, entry, error)) }
    }

    func sorted() -> [(entry: ZipEntry, error: any Error)] {
        failures.withLock { $0.sorted { $0.index < $1.index }.map { ($0.entry, $0.error) } }
    }
}
