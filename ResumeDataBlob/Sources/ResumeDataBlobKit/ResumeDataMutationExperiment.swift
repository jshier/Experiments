import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Part 3 of the experiment: mutate a resume data blob so it resumes against a *different* URL,
/// then see whether `URLSession.downloadTask(withResumeData:)` honors the switch.
public enum ResumeDataMutationExperiment {
    /// Path (relative to `Configuration.baseURL`) to redirect the mutated resume data toward.
    public static let redirectPath = "download/2000000"

    public static func run(originalResumeData: Data) async throws {
        guard var dict = KeyedArchiveCodec.decodeTopLevelDictionary(from: originalResumeData) else {
            print("Could not unarchive resume data as an NSKeyedArchiver dictionary; skipping mutation experiment.")
            return
        }

        let version = (dict[ResumeDataSchema.versionKey] as? NSNumber)?.intValue
        let schema = ResumeDataSchema.resolve(version)

        guard let requestData = dict[schema.currentRequestKey] as? Data,
              let originalRequest = ArchivedRequestCodec.decodeRequest(from: requestData) else {
            print("No embedded NSURLRequest found under '\(schema.currentRequestKey)'; can't attempt redirection.")
            return
        }

        print("Found archived request under key '\(schema.currentRequestKey)':")
        print(ArchivedRequestCodec.describe(originalRequest))

        guard let newURL = URL(string: redirectPath, relativeTo: Configuration.baseURL) else { return }

        guard let mutatedRequestData = ArchivedRequestCodec.encodeRequest(redirected(originalRequest, to: newURL)) else {
            print("Failed to re-archive the mutated request.")
            return
        }
        dict[schema.currentRequestKey] = mutatedRequestData
        dict[schema.downloadURLKey] = newURL.absoluteString
        // Without a temp file name URLSession cannot reopen the partial file, so it discards the resume
        // state and restarts from byte 0 with no Range header. Leaving it in place (and the file intact)
        // makes URLSession send `Range: bytes=<BytesReceived>-` to the new URL.
        dict["NSURLSessionResumeInfoTempFileName"] = nil

        // Keep the original (un-ranged) request consistent too, if present and distinct.
        if schema.originalRequestKey != schema.currentRequestKey,
           let originalRequestBlob = dict[schema.originalRequestKey] as? Data,
           let originalRequestParsed = ArchivedRequestCodec.decodeRequest(from: originalRequestBlob),
           let reencoded = ArchivedRequestCodec.encodeRequest(redirected(originalRequestParsed, to: newURL)) {
            dict[schema.originalRequestKey] = reencoded
        }

        let mutatedResumeData = KeyedArchiveCodec.encodeTopLevelDictionary(dict)

        let mutatedURL = Configuration.outputDirectory.appendingPathComponent("resume-data-mutated.plist")
        try mutatedResumeData.write(to: mutatedURL)
        print("Wrote mutated resume data to \(mutatedURL.path) (redirected to \(newURL.absoluteString))")

        print("\nAttempting to resume the *original* resume data (control / sanity check)...")
        // A resume consumes the partial temp file, so the control needs its own freshly captured blob.
        let controlData = await ResumeDataFixture.capture() ?? originalResumeData
        await attemptResume(resumeData: controlData, label: "original", destinationName: "resumed-original.bin")

        print("\nAttempting to resume the *mutated* resume data (redirected URL)...")
        await attemptResume(resumeData: mutatedResumeData, label: "mutated", destinationName: "resumed-redirected.bin")
    }

    /// Points `request` at `url`, dropping `Range`/`If-Range` headers, which refer to byte
    /// offsets and validators of the *original* resource and are meaningless for a new one.
    private static func redirected(_ request: URLRequest, to url: URL) -> URLRequest {
        var request = request
        request.url = url
        request.setValue(nil, forHTTPHeaderField: "Range")
        request.setValue(nil, forHTTPHeaderField: "If-Range")
        return request
    }

    private static func attemptResume(resumeData: Data, label: String, destinationName: String) async {
        let delegate = ResumingDownloadDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(withResumeData: resumeData)

        let outcome = await delegate.run(task: task)

        switch outcome {
        case let .success(location):
            let destination = Configuration.outputDirectory.appendingPathComponent(destinationName)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: location, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
                print("[\(label)] Resume succeeded. Final file: \(destination.path) (\(size ?? -1) bytes)")
            } catch {
                print("[\(label)] Resume succeeded but failed to copy result file: \(error)")
            }
        case let .failure(error):
            print("[\(label)] Resume failed: \(error)")
            let nsError = error as NSError
            if let partial = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                print("[\(label)] A *new* resume data blob (\(partial.count) bytes) was returned alongside the failure.")
            }
        }
        session.finishTasksAndInvalidate()
    }
}

/// Minimal delegate that resumes a download task started from resume data and reports success
/// (with the final file location) or failure (with the error).
private final class ResumingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let box = ResultBox()

    func run(task: URLSessionDownloadTask) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            box.continuation = continuation
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Copy immediately: the temp file is deleted as soon as this delegate method returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: staged)
            box.resume(with: .success(staged))
        } catch {
            box.resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            box.resume(with: .failure(error))
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<Result<URL, Error>, Never>?
    private var resumed = false

    var continuation: CheckedContinuation<Result<URL, Error>, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func resume(with result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let continuation = stored else { return }
        resumed = true
        continuation.resume(returning: result)
    }
}
