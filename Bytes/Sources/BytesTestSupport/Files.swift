public import Foundation
import Synchronization

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
    /// - Parameter resolvingSymbolicLinks: Whether ``url`` is the directory's real path, with every symbolic link
    ///   resolved: `/private/var/folders/…` rather than `/var/folders/…`, for tests comparing it with paths the file
    ///   system reports (`realpath`, `F_GETPATH`, an app's open panel).
    /// - Throws: What creating it throws.
    public init(prefix: String = "BytesTests", indexed: Bool = false, resolvingSymbolicLinks: Bool = false) throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)\(indexed ? "" : ".noindex")")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Not `URL.resolvingSymlinksInPath()`: it takes `/private` off the paths it resolves, giving `/var/…` back.
        self.url = resolvingSymbolicLinks ? Self.realPath(url) : url
    }

    /// `url`'s path with every symbolic link resolved, by `realpath(3)`; `url` itself if that fails.
    private static func realPath(_ url: URL) -> URL {
        // Unsafe: `realpath` with no buffer allocates the result, freed below. Safe: the path argument is a C string
        // valid for the call; the result is read once, as a C string, then freed.
        guard let resolved = unsafe realpath(url.path(percentEncoded: false), nil) else { return url }
        defer { unsafe free(resolved) }
        return URL(filePath: unsafe String(cString: resolved), directoryHint: .isDirectory)
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

    /// Where `name` is installed: Homebrew's prefix (`HOMEBREW_PREFIX`, else `/opt/homebrew`), then `/usr/local`,
    /// then the system's `/usr/bin` and `/bin`. So Homebrew's OpenSSL wins over the system's LibreSSL, and a newer
    /// `xz` or `zstd` over none.
    ///
    /// ```swift
    /// let openssl = ExternalTool.locate("openssl")
    /// @Test(.enabled(if: openssl != nil)) func crossCheck() throws { … }
    /// ```
    ///
    /// - Parameter name: The tool's file name.
    /// - Returns: Its absolute path, or `nil` if it isn't in any of them.
    public static func locate(_ name: String) -> String? {
        let homebrew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "/opt/homebrew"
        return ["\(homebrew)/bin", "/usr/local/bin", "/usr/bin", "/bin"].lazy
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `executable` with `arguments` and waits for it.
    ///
    /// - Parameters:
    ///   - executable: The tool's absolute path.
    ///   - arguments: Its arguments.
    ///   - directory: The working directory, or `nil` for this process's.
    ///   - input: Bytes for its standard input, or `nil` for none (the null device).
    /// - Returns: Its standard output and standard error, interleaved, as UTF-8.
    /// - Throws: ``Failure`` (with that output) if it exits with a nonzero status; what launching it throws.
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String], in directory: URL? = nil, input: [UInt8]? = nil
    ) throws -> String {
        let pipe = Pipe()
        let process = try launch(executable, arguments, in: directory, input: input, output: pipe, errors: pipe)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(executable) \(arguments.joined(separator: " ")): \(output)")
        }
        return output
    }

    /// Runs `executable` with `arguments`, waits for it, and returns what it wrote to its standard output: for
    /// tools whose output is data (a reference encoder's stream, a key, a certificate).
    ///
    /// ```swift
    /// let compressed = try ExternalTool.output(xz, ["-9", "--stdout"], input: data)
    /// ```
    ///
    /// - Parameters:
    ///   - executable: The tool's absolute path.
    ///   - arguments: Its arguments.
    ///   - directory: The working directory, or `nil` for this process's.
    ///   - input: Bytes for its standard input, or `nil` for none (the null device).
    /// - Returns: Its standard output's bytes. Its standard error is kept only for a failure's description.
    /// - Throws: ``Failure`` (with its standard error) if it exits with a nonzero status; what launching it throws.
    public static func output(
        _ executable: String, _ arguments: [String], in directory: URL? = nil, input: [UInt8]? = nil
    ) throws -> [UInt8] {
        let output = Pipe(), errors = Pipe()
        let process = try launch(executable, arguments, in: directory, input: input, output: output, errors: errors)
        // Both pipes read to the end before waiting, so neither fills and blocks the tool: standard error on another
        // thread, handed back through the semaphore's ordering.
        let errorText = ErrorText()
        let done = DispatchSemaphore(value: 0)
        let reader = errors.fileHandleForReading
        Thread.detachNewThread {
            errorText.set(String(decoding: reader.readDataToEndOfFile(), as: UTF8.self))
            done.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(executable) \(arguments.joined(separator: " ")): \(errorText.get())")
        }
        return [UInt8](data)
    }

    /// Standard error's text, written by the reading thread before it signals and read after the wait.
    private final class ErrorText: Sendable {
        private let text = Mutex("")
        func set(_ value: String) { text.withLock { $0 = value } }
        func get() -> String { text.withLock { $0 } }
    }

    /// Starts `executable`, writing `input` (if any) to its standard input from another thread: a tool that writes as
    /// it reads would block on a full output pipe. With no input, its standard input is the null device.
    private static func launch(
        _ executable: String, _ arguments: [String], in directory: URL?, input: [UInt8]?, output: Pipe, errors: Pipe
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = errors
        let inputPipe = input.map { _ in Pipe() }
        // No input: the null device, so a tool that reads its standard input sees its end rather than waiting on the
        // test runner's.
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        try process.run()
        if let inputPipe, let input {
            let writer = inputPipe.fileHandleForWriting
            Thread.detachNewThread {
                writer.write(Data(input))
                try? writer.close()
            }
        }
        return process
    }
}
