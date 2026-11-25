import BytesTestSupport
import Foundation
import NativeZip
import System
import Testing

/// Cancellation reaches the worker pools: extraction throws ``ZipError/cancelled`` (never a damaged entry's error),
/// verification doesn't report unchecked entries as intact. The calling task is cancelled before the call, so the
/// outcome doesn't depend on timing.
@Suite(.diskLifetimes) struct CancellationTests {
    /// Cancels the current task (the test's own child task), then runs `body`.
    private static func cancelled<R: Sendable>(_ body: @escaping @Sendable () async throws(ZipError) -> R) async -> Result<R, ZipError> {
        let task = Task { () async -> Result<R, ZipError> in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(ZipError) {
                return try await .success(body())
            } catch {
                return .failure(error)
            }
        }
        return await task.value
    }

    /// A large entry (decoded in a child task while it's written) and the extraction itself: cancellation.
    @Test(arguments: ["zstd-large.zip", "deflate64-large.zip", "large-zipcrypto-stored.zip"])
    func extractionThrowsCancelled(name: String) async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: name))
        let directory = try TemporaryDirectory(prefix: "NativeZipCancellation")
        defer { directory.remove() }
        let out = FilePath(directory.path("out").path)
        let result = await Self.cancelled { () async throws(ZipError) in
            var options = ZipExtractionOptions()
            options.password = "secret"
            try await archive.extract(to: out, options: options)
        }
        #expect(throws: ZipError.cancelled) { try result.get() }
    }

    /// Failures collected rather than thrown: cancellation still ends the extraction, and isn't any entry's failure.
    @Test func collectingExtractionThrowsCancelled() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        let directory = try TemporaryDirectory(prefix: "NativeZipCancellation")
        defer { directory.remove() }
        let out = FilePath(directory.path("out").path)
        let result = await Self.cancelled { () async throws(ZipError) in
            try await ZipExtractor.extract(into: out, stopOnFirstError: false) { extractor async throws(ZipError) in
                try await extractor.add(archive)
            }
        }
        #expect(throws: ZipError.cancelled) { _ = try result.get() }
        #expect(ZipError.cancelled.isCancellation)
    }

    /// Cancelled midway, while the writers are busy (the app's cancel button): `.cancelled`, every time, and the
    /// extractor's decoders are torn down cleanly whatever state cancellation left them in.
    @Test(.timeLimit(.minutes(1))) func cancellingMidwayThrowsCancelled() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipCancellation")
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = Data(repeating: 0x61, count: 2_000)
        for index in 0..<3_000 {
            try contents.write(to: source.appending(path: "file-\(index).txt"))
        }
        let url = directory.path("Many.zip")
        try ExternalTool.run("/usr/bin/zip", ["-q", "-r", "-1", url.path, "."], in: source)
        let archive = try ZipArchive(url: url)
        for round in 0..<8 {
            let out = FilePath(directory.path("out\(round)").path)
            let task = Task { () async -> ZipError? in
                do throws(ZipError) {
                    try await archive.extract(to: out)
                    return nil
                } catch {
                    return error
                }
            }
            try await Task.sleep(for: .milliseconds(5 + round * 3))
            task.cancel()
            let error = await task.value
            // A round may finish before the cancel lands; one that doesn't is cancelled, never anything else.
            if let error { #expect(error == .cancelled, "round \(round): \(error)") }
        }
    }

    @Test func verificationReportsUncheckedEntries() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        let files = archive.entries.filter { $0.kind != .directory }
        let failures = try await Self.cancelled { await archive.verify().map(\.error) }.get()
        #expect(failures == Array(repeating: .cancelled, count: files.count))
    }

    /// Not cancelled: every entry is checked and intact.
    @Test func verificationChecksEverything() async throws {
        let archive = try ZipArchive(url: TestData.file(set: "nativezip-formats", name: "zstd-large.zip"))
        #expect(await archive.verify().isEmpty)
    }
}
