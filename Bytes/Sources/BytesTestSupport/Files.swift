public import Foundation

/// A fresh temporary directory, for one test's files.
///
/// Remove it with ``remove()``, explicitly (`defer { directory.remove() }`), not in `deinit`: Swift may end an
/// object's life after its last use, before the files in it are used.
public final class TemporaryDirectory: Sendable {
    /// The directory.
    public let url: URL

    /// Makes a directory in the user's temporary directory.
    ///
    /// - Parameter prefix: The start of its name (a test target's, say); a UUID follows.
    /// - Parameter indexed: Whether Spotlight may index it: by default it's named `….noindex`, so indexing what a
    ///   test writes doesn't load the machine.
    /// - Throws: What creating it throws.
    public init(prefix: String = "BytesTests", indexed: Bool = false) throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)\(indexed ? "" : ".noindex")")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `name` in the directory.
    ///
    /// - Parameter name: A path relative to the directory.
    /// - Returns: Its URL.
    public func path(_ name: String) -> URL { url.appending(path: name) }

    /// Removes the directory and everything in it, including read-only files and directories and ones whose ACLs
    /// deny deleting (extracted archives have both): if removing fails, drops the ACLs and makes everything
    /// writable, then tries again.
    public func remove() {
        if (try? FileManager.default.removeItem(at: url)) != nil { return }
        _ = try? ExternalTool.run("/bin/chmod", ["-R", "-N", url.path(percentEncoded: false)])
        _ = try? ExternalTool.run("/bin/chmod", ["-R", "u+w", url.path(percentEncoded: false)])
        try? FileManager.default.removeItem(at: url)
    }
}

/// Running a command-line tool (a reference implementation, `openssl`, `zip`, `aa`) from a test.
public enum ExternalTool {
    /// A tool that exited with a nonzero status.
    public struct Failure: Error, CustomStringConvertible {
        /// The command line and what it printed.
        public var description: String

        /// A failure described by `description`.
        ///
        /// - Parameter description: The command line and what it printed.
        public init(description: String) {
            self.description = description
        }
    }

    /// Runs `executable` with `arguments` and waits for it.
    ///
    /// - Parameters:
    ///   - executable: The tool's absolute path.
    ///   - arguments: Its arguments.
    ///   - directory: The working directory, or `nil` for this process's.
    ///   - input: Bytes for its standard input, or `nil` for none.
    /// - Returns: Its standard output and standard error, interleaved, as UTF-8.
    /// - Throws: ``Failure`` (with that output) if it exits with a nonzero status; what launching it throws.
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String], in directory: URL? = nil, input: [UInt8]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        try process.run()
        if let inputPipe, let input {
            // Written from another thread: a tool that writes as it reads would block on a full output pipe.
            let writer = inputPipe.fileHandleForWriting
            Thread.detachNewThread {
                writer.write(Data(input))
                try? writer.close()
            }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(executable) \(arguments.joined(separator: " ")): \(output)")
        }
        return output
    }
}
