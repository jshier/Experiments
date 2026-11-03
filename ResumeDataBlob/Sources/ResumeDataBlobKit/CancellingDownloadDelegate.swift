import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of a single "start a download, then cancel it partway through" experiment run.
public struct CancelledDownloadResult: @unchecked Sendable {
    /// The resume data blob produced by `cancel(byProducingResumeData:)`, if any.
    public var resumeData: Data?
    /// Number of bytes written to disk before the task was cancelled.
    public var bytesWrittenBeforeCancel: Int64
    /// Total number of bytes the response declared it would send.
    public var totalBytesExpected: Int64
    /// Any error surrounded the cancellation/completion callback.
    public var completionError: Error?
}

/// A `URLSessionDownloadDelegate` that cancels its task (producing resume data) once a
/// configurable fraction of the download has been written to disk, then resolves an async
/// continuation with the captured results.
///
/// This bridges the callback-based `URLSessionDownloadTask` resume-data API — which has no
/// `async`/`await` equivalent — back into structured concurrency.
public final class CancellingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let cancelFraction: Double
    private let continuationBox = ContinuationBox()
    private var hasCancelled = false
    private let lock = NSLock()

    public init(cancelFraction: Double) {
        self.cancelFraction = cancelFraction
    }

    /// Runs the download and returns once resume data has been captured (or the task finished
    /// normally, in which case `resumeData` is `nil`).
    public func run(task: URLSessionDownloadTask) async -> CancelledDownloadResult {
        await withCheckedContinuation { continuation in
            continuationBox.continuation = continuation
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasCancelled, totalBytesExpectedToWrite > 0 else { return }

        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction >= cancelFraction else { return }

        hasCancelled = true
        downloadTask.cancel { [weak self] resumeData in
            guard let self else { return }
            self.finish(CancelledDownloadResult(resumeData: resumeData,
                                                 bytesWrittenBeforeCancel: totalBytesWritten,
                                                 totalBytesExpected: totalBytesExpectedToWrite,
                                                 completionError: nil))
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The task completed before we got a chance to cancel it; move the finished file into
        // our output directory so it isn't deleted when the temp file is cleaned up.
        lock.lock()
        let alreadyCancelled = hasCancelled
        lock.unlock()
        guard !alreadyCancelled else { return }

        let destination = Configuration.outputDirectory.appendingPathComponent("completed-download.bin")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: location, to: destination)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let alreadyCancelled = hasCancelled
        lock.unlock()

        guard !alreadyCancelled else { return }

        // Finished (successfully or with a non-cancellation error) before we intervened.
        finish(CancelledDownloadResult(resumeData: nil,
                                       bytesWrittenBeforeCancel: 0,
                                       totalBytesExpected: 0,
                                       completionError: error))
    }

    private func finish(_ result: CancelledDownloadResult) {
        continuationBox.resume(with: result)
    }
}

/// Small box so the `CheckedContinuation` (which is not `Sendable`-friendly to store directly in
/// a class touched from delegate callback threads) can be resumed exactly once, safely.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<CancelledDownloadResult, Never>?
    private var resumed = false

    var continuation: CheckedContinuation<CancelledDownloadResult, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func resume(with result: CancelledDownloadResult) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let continuation = stored else { return }
        resumed = true
        continuation.resume(returning: result)
    }
}
