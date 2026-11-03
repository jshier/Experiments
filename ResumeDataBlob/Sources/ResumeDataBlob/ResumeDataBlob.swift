import Foundation
import ResumeDataBlobKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct ResumeDataBlob {
    static func main() async throws {
        if CommandLine.arguments.contains("--capture-only") {
            let data = await ResumeDataFixture.capture()
            let dict = data.flatMap { KeyedArchiveCodec.decodeTopLevelDictionary(from: $0) }
            let keys = (dict?.keys.sorted() ?? []).map { $0.replacingOccurrences(of: "NSURLSession", with: "") }
            print("capture-only: \(data == nil ? "NO resume data" : "resume data, keys \(keys)")")
            return
        }
        print("== Part 1: Capture resume data from a cancelled download ==")
        let result = try await captureResumeData()

        guard let resumeData = result.resumeData else {
            print("No resume data was produced (error: \(String(describing: result.completionError))).")
            print("This can happen if the task finished before we could cancel it, or if the")
            print("server/response doesn't support resumable downloads. Try again or lower the")
            print("`cancelFraction` in Configuration.")
            return
        }

        print("Captured \(resumeData.count) bytes of resume data after writing " +
            "\(result.bytesWrittenBeforeCancel)/\(result.totalBytesExpected) bytes.")

        let resumeDataURL = Configuration.outputDirectory.appendingPathComponent("resume-data.plist")
        try resumeData.write(to: resumeDataURL)
        print("Wrote raw resume data blob to \(resumeDataURL.path)")

        print("\n== Part 2: Explore & decode the resume data blob ==")
        try ResumeDataInspector.explore(resumeData: resumeData)

        print("\n== Part 3: Attempt to mutate the resume data and redirect the download ==")
        try await ResumeDataMutationExperiment.run(originalResumeData: resumeData)

        if CommandLine.arguments.contains("--probes") {
            print("\n== Part 4: Field-by-field resume probes ==")
            await ResumeDataProbeExperiment.run()
        }
    }

    private static func captureResumeData() async throws -> CancelledDownloadResult {
        let url = Configuration.baseURL.appendingPathComponent("download/\(Configuration.downloadByteCount)")
        let delegate = CancellingDownloadDelegate(cancelFraction: 0.3)
        let taskSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = taskSession.downloadTask(with: URLRequest(url: url))
        let result = await delegate.run(task: task)
        taskSession.finishTasksAndInvalidate()
        return result
    }
}
