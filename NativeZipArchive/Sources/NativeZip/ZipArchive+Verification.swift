import Foundation
import Synchronization

public extension ZipArchive {
    /// Decompresses every non-directory entry (in parallel) and checks its size and CRC-32 without writing
    /// anything.
    ///
    /// A failing entry doesn't stop the others. Failures are collected, so this doesn't throw.
    ///
    /// - Parameters:
    ///   - entries: The entries to check; all of the archive's by default.
    ///   - maxConcurrency: The most entries to decompress at once.
    ///   - backend: Which DEFLATE and CRC-32 implementation to use.
    /// - Returns: The entries that failed and why (the errors of ``contents(of:using:_:)``), in the order given.
    ///   Empty means every entry is intact.
    func verify(
        _ entries: [ZipEntry]? = nil,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        backend: ZipDecoder.Backend = .bytes
    ) async -> [(entry: ZipEntry, error: any Error)] {
        let indexed = Array((entries ?? self.entries).filter { $0.kind != .directory }.enumerated())
        let failures = FailureLog()
        // The body never throws (failures are recorded instead), so neither does the loop.
        try? await forEachConcurrently(indexed, maxConcurrency: maxConcurrency, backend: backend, weight: \.element.uncompressedSize) {
            [self] item, decoder in
            do {
                try contents(of: item.element, using: &decoder) { _ in }
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
