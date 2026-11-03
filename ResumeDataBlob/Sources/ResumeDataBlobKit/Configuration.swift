import Foundation

/// Shared configuration for the experiment.
public enum Configuration {
    /// Base URL of the local Firewalk server.
    public static let baseURL = URL(string: "http://127.0.0.1:8080")!

    /// Directory (next to the executable's working directory) where downloaded files, resume
    /// data blobs, and derived artifacts are written so they can be inspected after the run.
    public static let outputDirectory: URL = {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Output", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Number of bytes requested for the primary "cancel mid-flight" experiment. Must be a
    /// multiple of 10 and <= 10_000_000, per Firewalk's `/download/:count` route.
    public static let downloadByteCount = 10_000_000
}
