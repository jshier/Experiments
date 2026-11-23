public import System
import Darwin

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
    /// The source of a file's contents failed (decoding, a checksum): its own error, as it threw it.
    case source(any Error)
    /// The task was cancelled.
    case cancelled

    /// Equal cases with equal payloads. Sources' errors compare as their own type does when it's `Equatable`, else by
    /// description.
    public static func == (lhs: DiskError, rhs: DiskError) -> Bool {
        switch (lhs, rhs) {
        case (.unsafePath(let a), .unsafePath(let b)), (.escapesDestination(let a), .escapesDestination(let b)),
             (.exists(let a), .exists(let b)), (.notADirectory(let a), .notADirectory(let b)), (.refused(let a), .refused(let b)),
             (.invalidMetadata(let a), .invalidMetadata(let b)), (.endOfFile(let a), .endOfFile(let b)):
            a == b
        case (.tooLarge(let a, let limitA), .tooLarge(let b, let limitB)):
            a == b && limitA == limitB
        case (.system(let a, let pathA, let errnoA), .system(let b, let pathB, let errnoB)):
            a == b && pathA == pathB && errnoA == errnoB
        case (.source(let a), .source(let b)):
            Self.sourcesEqual(a, b)
        case (.cancelled, .cancelled):
            true
        default:
            false
        }
    }

    private static func sourcesEqual(_ lhs: any Error, _ rhs: any Error) -> Bool {
        func equal<E: Equatable>(_ lhs: E, _ rhs: any Error) -> Bool { (rhs as? E) == lhs }
        if let lhs = lhs as? any Equatable { return equal(lhs, rhs) }
        return String(describing: lhs) == String(describing: rhs)
    }

    /// The source's error, if this is ``source(_:)``.
    package var sourceError: (any Error)? {
        if case .source(let error) = self { error } else { nil }
    }

    /// Any error as Disk's: a `DiskError` as it is, `CancellationError` as ``cancelled``, anything else as the
    /// ``source(_:)`` that threw it. What a ``ContentSource`` throws from code that throws other errors.
    public init(wrapping error: any Error) {
        switch error {
        case let error as DiskError: self = error
        case is CancellationError: self = .cancelled
        default: self = .source(error)
        }
    }

    /// The error a client that throws untyped errors hands on: a ``source(_:)``'s own error, `CancellationError` for
    /// ``cancelled``, and this error for anything else. The inverse of ``init(wrapping:)``.
    public var unwrapped: any Error {
        switch self {
        case .source(let error): error
        case .cancelled: CancellationError()
        default: self
        }
    }

    /// Whether `error` says the work was cancelled: `CancellationError`, ``cancelled``, a ``source(_:)`` that does, or
    /// a ``CancellationReporting`` error (a client's own cancellation case) that says so. One check for a caller that
    /// meets several packages' errors.
    public static func isCancellation(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError: true
        case let error as DiskError:
            switch error {
            case .cancelled: true
            case .source(let error): isCancellation(error)
            default: false
            }
        case let error as any CancellationReporting: error.isCancellation
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unsafePath(let path): "unsafe path: \(path)"
        case .escapesDestination(let path): "path leads out of the destination: \(path)"
        case .exists(let path): "already exists: \(path)"
        case .notADirectory(let path): "not a directory: \(path)"
        case .refused(let what): "refused: \(what)"
        case .invalidMetadata(let what): "invalid metadata: \(what)"
        case .system(let operation, let path, let errno): "\(operation) \(path): \(errno)"
        case .endOfFile(let path): "the file ends before the bytes read: \(path)"
        case .tooLarge(let path, let limit): "larger than \(limit) bytes: \(path)"
        case .source(let error): "\(error)"
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

/// An error with a cancellation case of its own (a client's `.cancelled`), for ``DiskError/isCancellation(_:)``.
public protocol CancellationReporting: Error {
    /// Whether this error says the work was cancelled.
    var isCancellation: Bool { get }
}
