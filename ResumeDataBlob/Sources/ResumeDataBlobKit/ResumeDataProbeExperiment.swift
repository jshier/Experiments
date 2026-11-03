import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Part 4: mutate individual fields of a fresh blob and observe how `downloadTask(withResumeData:)`
/// reacts. Each probe captures its own blob because a resume consumes the partial temp file.
/// Pair with a server that logs request headers to see the `Range`/`If-Range` values sent.
public enum ResumeDataProbeExperiment {
    struct Probe: Sendable {
        let name: String
        let mutate: @Sendable (inout [String: Any]) -> Void
    }

    static let probes: [Probe] = [
        .init(name: "control (unmodified)") { _ in },
        .init(name: "BytesReceived = 1_000_000 (file is larger)") { $0["NSURLSessionResumeBytesReceived"] = 1_000_000 },
        .init(name: "BytesReceived = 9_999_999 (file is smaller)") { $0["NSURLSessionResumeBytesReceived"] = 9_999_999 },
        .init(name: "BytesReceived removed") { $0["NSURLSessionResumeBytesReceived"] = nil },
        .init(name: "InfoVersion = 99") { $0["NSURLSessionResumeInfoVersion"] = 99 },
        .init(name: "InfoVersion removed") { $0["NSURLSessionResumeInfoVersion"] = nil },
        .init(name: "TempFileName points at missing file") { $0["NSURLSessionResumeInfoTempFileName"] = "CFNetworkDownload_missing.tmp" },
        .init(name: "TempFileName removed") { $0["NSURLSessionResumeInfoTempFileName"] = nil },
        .init(name: "CurrentRequest removed (Original used)") { $0["NSURLSessionResumeCurrentRequest"] = nil },
        .init(name: "Current+Original removed (DownloadURL used)") {
            $0["NSURLSessionResumeCurrentRequest"] = nil
            $0["NSURLSessionResumeOriginalRequest"] = nil
        },
        .init(name: "ServerDownloadDate changed") { $0["NSURLSessionResumeServerDownloadDate"] = "Tue, 02 Jan 2001 12:00:00 GMT" },
        .init(name: "ServerDownloadDate removed") { $0["NSURLSessionResumeServerDownloadDate"] = nil },
        .init(name: "EntityTag added") { $0["NSURLSessionResumeEntityTag"] = "\"abc\"" },
        .init(name: "Response removed") { $0["NSURLSessionResumeResponse"] = nil },
        .init(name: "Redirect to /download/2000000, temp file intact") { dict in
            let url = Configuration.baseURL.appendingPathComponent("download/2000000")
            for key in ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"] {
                guard let data = dict[key] as? Data, var request = ArchivedRequestCodec.decodeRequest(from: data) else { continue }
                request.url = url
                dict[key] = ArchivedRequestCodec.encodeRequest(request)
            }
            dict["NSURLSessionDownloadURL"] = url.absoluteString
        },
        .init(name: "Current request carries Range: bytes=5-9") { dict in
            guard let data = dict["NSURLSessionResumeCurrentRequest"] as? Data,
                  var request = ArchivedRequestCodec.decodeRequest(from: data) else { return }
            request.setValue("bytes=5-9", forHTTPHeaderField: "Range")
            dict["NSURLSessionResumeCurrentRequest"] = ArchivedRequestCodec.encodeRequest(request)
        },
        .init(name: "Original request carries Range: bytes=5-9") { dict in
            guard let data = dict["NSURLSessionResumeOriginalRequest"] as? Data,
                  var request = ArchivedRequestCodec.decodeRequest(from: data) else { return }
            request.setValue("bytes=5-9", forHTTPHeaderField: "Range")
            dict["NSURLSessionResumeOriginalRequest"] = ArchivedRequestCodec.encodeRequest(request)
        },
    ]

    public static func run() async {
        for probe in probes {
            print("\n--- probe: \(probe.name)")
            guard let blob = await ResumeDataFixture.capture(),
                  var dict = KeyedArchiveCodec.decodeTopLevelDictionary(from: blob) else {
                print("  could not capture/decode blob")
                continue
            }
            probe.mutate(&dict)
            let data = KeyedArchiveCodec.encodeTopLevelDictionary(dict)
            let delegate = ProbeDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(withResumeData: data)
            let outcome = await delegate.run(task: task)
            print("  result: \(outcome)")
            session.finishTasksAndInvalidate()
        }
    }
}

private final class ProbeDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var done = false
    private var resumeOffset: Int64?

    func run(task: URLSessionDownloadTask) async -> String {
        await withCheckedContinuation { c in
            lock.lock(); continuation = c; lock.unlock()
            task.resume()
        }
    }

    private func finish(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: s)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.lock(); resumeOffset = fileOffset; lock.unlock()
        print("  didResumeAtOffset \(fileOffset) expectedTotal \(expectedTotalBytes)")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? -1
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        finish("completed, file \(size) bytes, status \(status)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            finish("error \((error as NSError).domain) \((error as NSError).code), status \(status)")
        }
    }
}
