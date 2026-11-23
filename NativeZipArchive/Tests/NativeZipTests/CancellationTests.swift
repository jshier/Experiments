import BytesTestSupport
import Foundation
import NativeZip
import System
import Testing

/// Cancellation reaches the worker pools: extraction throws, verification doesn't report unchecked entries as
/// intact. The calling task is cancelled before the call, so the outcome doesn't depend on timing.
@Suite struct CancellationTests {
    /// Cancels the current task (the test's own child task), then runs `body`.
    private static func cancelled<R: Sendable>(_ body: @escaping @Sendable () async throws -> R) async throws -> R {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await body()
        }
        return try await task.value
    }

    @Test func extractionThrowsWhenCancelled() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        let directory = try TemporaryDirectory(prefix: "NativeZipCancellation")
        defer { directory.remove() }
        let out = FilePath(directory.path("out").path)
        await #expect(throws: CancellationError.self) {
            try await Self.cancelled { try await archive.extract(to: out) }
        }
    }

    @Test func verificationReportsUncheckedEntries() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        let files = archive.entries.filter { $0.kind != .directory }
        let failures = try await Self.cancelled { await archive.verify().map { ($0.entry.path, $0.error is CancellationError) } }
        #expect(failures.count == files.count)
        let allCancelled = failures.allSatisfy { $0.1 }
        #expect(allCancelled)
    }

    /// Not cancelled: every entry is checked and intact.
    @Test func verificationChecksEverything() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        #expect(await archive.verify().isEmpty)
    }
}
