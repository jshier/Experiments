import Darwin
public import System

/// What failed writing a tree to disk. Every Disk call throws this (typed throws); its strings are made only when
/// something fails.
public enum DiskError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A path that could lead out of the destination, or that isn't one canonical relative path: absolute, an empty,
    /// `.`, or `..` component, a NUL byte, or `PATH_MAX` bytes or more.
    case unsafePath(String)
    /// The kernel refused to resolve the path within the destination: a symbolic link in it (`ELOOP` from
    /// `O_NOFOLLOW_ANY`), or a way out of it (`ENOTCAPABLE` from `O_RESOLVE_BENEATH`). Nothing was made.
    case escapesDestination(String)
    /// Something is already at the path and the policy is ``ExistingItemPolicy/fail``, or it can't be replaced (a
    /// directory where a file goes).
    case exists(String)
    /// A component of the path exists and isn't a directory (a file or a symbolic link where a directory goes).
    case notADirectory(String)
    /// An entry the options refuse: a device without ``DestinationOptions/allowsDevices``, a symbolic link pointing out
    /// of the destination with ``SymbolicLinkPolicy/withinDestination``.
    case refused(String)
    /// Malformed metadata: an extended-attribute or ACL blob, a file's contents longer or shorter than its size.
    case invalidMetadata(String)
    /// A system call failed: the operation, the entry's path, and the error.
    case system(String, path: String, Errno)
    /// A read reached the end of the file (``InputFile``) before the bytes it asked for: the file is shorter than its
    /// format says, or shrank. The path.
    case endOfFile(String)
    /// A file read whole (``InputFile/contents(of:maximumCount:)``) is longer than the most the caller accepts.
    case tooLarge(String, limit: Int)
    /// The extraction already stopped on another entry's failure: what a planner call throws then. The extraction's
    /// error (``ExtractionError``) is that failure, a source's own included.
    case stopped
    /// The task was cancelled.
    case cancelled

    public var description: String {
        switch self {
        case let .unsafePath(path): "unsafe path: \(path)"
        case let .escapesDestination(path): "path leads out of the destination: \(path)"
        case let .exists(path): "already exists: \(path)"
        case let .notADirectory(path): "not a directory: \(path)"
        case let .refused(what): "refused: \(what)"
        case let .invalidMetadata(what): "invalid metadata: \(what)"
        case let .system(operation, path, errno): "\(operation) \(path): \(errno)"
        case let .endOfFile(path): "the file ends before the bytes read: \(path)"
        case let .tooLarge(path, limit): "larger than \(limit) bytes: \(path)"
        case .stopped: "stopped by another entry's failure"
        case .cancelled: "cancelled"
        }
    }

    /// The error for `operation` failing on `path` with `code`: links in the path and escapes get their own cases, so
    /// callers can tell an attack from a failure.
    static func system(_ operation: String, path: String, code: Int32) -> DiskError {
        switch code {
        case ELOOP, ENOTCAPABLE: .escapesDestination(path)
        case EEXIST: .exists(path)
        case ENOTDIR: .notADirectory(path)
        default: .system(operation, path: path, Errno(rawValue: code))
        }
    }
}
