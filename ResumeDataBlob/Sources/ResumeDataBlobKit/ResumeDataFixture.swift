import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared helper for producing a real resume data blob to use as a fixture — both the main
/// executable (Part 1 of the experiment) and the benchmark suite need "a real resume data blob
/// captured from Firewalk", so the capture logic lives here instead of being duplicated.
public enum ResumeDataFixture {
    /// Starts a download against Firewalk's `/download/:count` route and cancels it partway
    /// through, returning the resume data blob that produces (or `nil` if none was produced).
    public static func capture(byteCount: Int = Configuration.downloadByteCount,
                                cancelFraction: Double = 0.3) async -> Data? {
        let url = Configuration.baseURL.appendingPathComponent("download/\(byteCount)")
        let delegate = CancellingDownloadDelegate(cancelFraction: cancelFraction)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: URLRequest(url: url))
        let result = await delegate.run(task: task)
        session.finishTasksAndInvalidate()
        return result.resumeData
    }
}
