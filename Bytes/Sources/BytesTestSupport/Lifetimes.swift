import Darwin
public import Foundation
import Synchronization

// Lifetime checks for tests: what a test opens under its own temporary directories must be closed by the time the
// directory is removed (or the test ends). Paths are per test, so the check holds with tests running in parallel.
// `BytesTesting`'s `LifetimeChecks` trait installs a `LifetimeRecord` for each test and reports what it finds.

/// The open descriptors of this process, by path.
public enum OpenFiles {
    /// Paths of this process's open files and directories under `directory` (the kernel's paths, symbolic links
    /// resolved: `directory` is resolved the same way before comparing).
    public static func paths(under directory: URL) -> [String] {
        let pid = getpid()
        // With no buffer, `proc_pidinfo` returns the size it needs.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        // Room for a few more, opened meanwhile.
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        // Unsafe: the array's storage to `proc_pidinfo`. Safe: `capacity` entries, the byte count passed.
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        let count = min(capacity, Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        let prefix = resolved(directory).path(percentEncoded: false)
        let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
        var found: [String] = []
        for index in 0..<count where descriptors[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            // Unsafe: `info` to `proc_pidfdinfo`. Safe: a local of the size passed, filled by the call.
            let size = unsafe proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                             Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard size == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            // Unsafe: the path tuple's bytes as a C string. Safe: the kernel NUL-terminates it within `MAXPATHLEN`.
            let path = withUnsafeBytes(of: info.pvip.vip_path) { unsafe String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if path == prefix || path.hasPrefix(base) { found.append("\(path) (descriptor \(descriptors[index].proc_fd))") }
        }
        return found
    }

    /// `url` with symbolic links resolved (`/var` → `/private/var`), as the kernel reports paths.
    static func resolved(_ url: URL) -> URL {
        // Unsafe: `realpath` allocates its result, freed below. Safe: the argument is a C string valid for the call.
        guard let resolved = unsafe realpath(url.path(percentEncoded: false), nil) else { return url }
        defer { unsafe free(resolved) }
        return URL(filePath: unsafe String(cString: resolved), directoryHint: .isDirectory)
    }
}

/// One test's lifetime findings: the temporary directories it made, and anything left open in them.
public final class LifetimeRecord: Sendable {
    private let directories = Mutex<[TemporaryDirectory]>([])
    private let problems = Mutex<[String]>([])

    public init() {}

    func add(_ directory: TemporaryDirectory) {
        directories.withLock { $0.append(directory) }
    }

    /// Checks `directory` (being removed): anything still open in it is reported.
    func check(_ directory: TemporaryDirectory, when: String) {
        let open = OpenFiles.paths(under: directory.url)
        if !open.isEmpty {
            problems.withLock { $0.append("still open \(when): " + open.joined(separator: ", ")) }
        }
    }

    func removed(_ directory: TemporaryDirectory) {
        directories.withLock { $0.removeAll { $0 === directory } }
    }

    /// Checks the directories never removed, then returns everything found (and lets the directories go).
    public func finish() -> [String] {
        let remaining = directories.withLock { list in
            defer { list.removeAll() }
            return list
        }
        for directory in remaining { check(directory, when: "when the test ended") }
        return problems.withLock { $0 }
    }
}

extension TemporaryDirectory {
    /// The current test's lifetime record (set by `BytesTesting`'s `LifetimeChecks` trait), or `nil` outside one.
    ///
    /// A fixture shared by tests (a `static let` made lazily, from inside whichever test reads it first) makes its
    /// directory with this set to `nil` (`$lifetimeRecord.withValue(nil) { … }`): otherwise that first test is held to
    /// account for files other tests, running in parallel, have open in it.
    @TaskLocal public static var lifetimeRecord: LifetimeRecord?
}
