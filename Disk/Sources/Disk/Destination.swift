import Bytes
import Darwin
public import System

/// What to do when something is already where an entry goes.
public enum ExistingItemPolicy: Sendable, Hashable {
    /// Fail with ``DiskError/exists(_:)`` (the default: `open` with `O_EXCL`, no check beforehand).
    case fail
    /// Remove it and make the entry. A directory is never removed (a file where one is fails); an existing directory
    /// is reused for a directory entry whatever the policy.
    case replace
    /// Keep it and skip the entry (counted in ``ExtractionReport/skipped``).
    case skip
}

/// How an entry's permissions are applied.
public enum PermissionPolicy: Sendable, Hashable {
    /// The archived mode less the process's umask (read with `getumask()`, never set), as `tar` and `cp` apply it.
    case umask
    /// The archived mode exactly, as `aa extract` and `xip --expand` restore it.
    case exact
}

/// Which symbolic links are made.
public enum SymbolicLinkPolicy: Sendable, Hashable {
    /// Any target (a link is only a name: nothing is ever written through one, see ``Destination``).
    case anyTarget
    /// Only targets that stay inside the destination, resolved lexically from the link's directory: no absolute
    /// targets, and no `..` that climbs above the destination. Others fail with ``DiskError/refused(_:)``.
    case withinDestination
}

/// How directories are named in the calls that make their contents.
public enum DirectoryResolution: Sendable, Hashable {
    /// Paths from the destination's descriptor, every call with `O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH` (the
    /// default: fewer calls; see Disk/RESULTS.md).
    case paths
    /// Each directory opened once (`O_NOFOLLOW`) and its contents made relative to its descriptor: one component per
    /// call, at the cost of an `open` per directory and a descriptor each (falling back to paths at the limit).
    case descriptors
}

/// How a ``Destination`` makes entries.
public struct DestinationOptions: Sendable, Hashable {
    public init() {}

    public var existingItems = ExistingItemPolicy.fail
    public var permissions = PermissionPolicy.umask
    /// Keep setuid, setgid, and sticky bits (stripped by default).
    public var keepsSpecialBits = false
    /// Restore owners and groups: only when running as root, otherwise ignored.
    public var restoresOwnership = false
    /// Restore BSD flags (`UF_HIDDEN`, `UF_IMMUTABLE`, …; `SF_` flags only as root).
    var restoresFlags = true
    /// Make character and block devices (as root; otherwise they're skipped and counted). Off: refused.
    public var allowsDevices = false
    public var symbolicLinks = SymbolicLinkPolicy.anyTarget
    /// The quarantine attribute every entry gets (`Quarantine(copyingFrom: archive)`), or `nil`.
    public var quarantine: Quarantine?
    /// Whether the destination directory itself gets ``quarantine`` (`aa extract` does for an `.aar`, not an `.aea`).
    public var quarantinesDestination = false
    public var directoryResolution = DirectoryResolution.paths
    /// Ask the kernel to keep every path beneath the destination (`O_RESOLVE_BENEATH`, `AT_RESOLVE_BENEATH`), on top of
    /// ``EntryPath``'s checks and `O_NOFOLLOW_ANY`. On by default; measured free (Disk/RESULTS.md).
    package var resolvesBeneath = true
}

/// A special file's kind.
public enum SpecialFileKind: Sendable, Hashable {
    case fifo
    case characterDevice(UInt64)
    case blockDevice(UInt64)
}

/// A directory that entries are written into, opened once: every entry is made relative to its descriptor.
///
/// ## Security
///
/// - Entry paths are ``EntryPath``s: relative, canonical, no `..`.
/// - Every call that resolves a path refuses symbolic links anywhere in it (`O_NOFOLLOW_ANY`,
///   `AT_SYMLINK_NOFOLLOW_ANY`, `FSOPT_NOFOLLOW_ANY`) and asks the kernel to stay beneath the destination
///   (`O_RESOLVE_BENEATH`). Calls that take no flags (`mkdirat`, `symlinkat`, `mkfifoat`) get a parent directory
///   opened that way, or one this destination made or checked (`fstatat` without following links) before.
/// - Symbolic links are made after everything else, so nothing is written through one an archive made; files are
///   created with `O_EXCL`, so nothing is written through one that was there.
/// - Files are created owner-writable and get their final mode last (setting an extended attribute checks the file's
///   mode, not the descriptor); setuid, setgid, sticky, and owners are kept only when the options say so.
public final class Destination: Sendable {
    /// The destination's descriptor.
    let root: Int32
    /// Where it is (as given).
    public let path: FilePath
    public let options: DestinationOptions
    /// The process's umask, read once without setting it (`getumask()`): setting and restoring it raced between
    /// concurrent extractions (NativeAEA, 2026-11-19).
    let umask: mode_t
    let isRoot: Bool
    /// The destination's absolute path, resolved (`F_GETPATH`), for the calls that take only a path.
    let resolvedPath: [UInt8]
    /// `O_RESOLVE_BENEATH` and `AT_RESOLVE_BENEATH` if the options ask.
    let openBeneath: Int32
    let atBeneath: Int32
    /// A staging directory: its name in `stagingParent`, to publish or discard.
    let staging: (parent: Int32, name: [UInt8])?

    /// Opens `directory` (made, with its parents, if it isn't there) as a destination.
    ///
    /// - Parameters:
    ///   - directory: The directory. Its own path may contain symbolic links (the caller chose it).
    ///   - options: How entries are made.
    /// - Throws: ``DiskError/system(_:path:_:)`` if it can't be made or opened.
    public convenience init(_ directory: FilePath, options: DestinationOptions = .init()) throws(DiskError) {
        try Self.makeDirectories(directory)
        // Unsafe: `withPlatformString`'s C string to `openat`. Safe: NUL-terminated and valid inside the closure, which
        // the call returns within.
        let root = unsafe directory.withPlatformString { unsafe Sys.openat(AT_FDCWD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard root >= 0 else { throw .system("open", path: directory.string, code: errno) }
        try self.init(root: root, path: directory, options: options, staging: nil)
    }

    private init(root: Int32, path: FilePath, options: DestinationOptions, staging: (parent: Int32, name: [UInt8])?) throws(DiskError) {
        self.root = root
        self.path = path
        self.options = options
        self.staging = staging
        umask = getumask()
        isRoot = geteuid() == 0
        openBeneath = options.resolvesBeneath ? O_RESOLVE_BENEATH : 0
        atBeneath = options.resolvesBeneath ? AT_RESOLVE_BENEATH : 0
        var resolved = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        // Unsafe: the array's buffer to `fcntl(F_GETPATH)`, which writes the descriptor's path there. Safe: `MAXPATHLEN`
        // bytes, the most `F_GETPATH` writes (so not `nil`), valid inside `withUnsafeMutableBytes`.
        let got = resolved.withUnsafeMutableBytes { unsafe fcntl(root, F_GETPATH, $0.baseAddress!) }
        resolvedPath = got == 0 ? Array(resolved.prefix { $0 != 0 }) : []
        if options.quarantinesDestination, let quarantine = options.quarantine {
            do {
                try quarantine.apply(root, path: .none)
            } catch {
                Sys.close(root)
                throw error
            }
        }
    }

    /// A copy of `original` on a descriptor of its own, with other options; see ``reopened(with:)``.
    private init(reopening original: Destination, root: Int32, options: DestinationOptions) {
        self.root = root
        path = original.path
        self.options = options
        staging = nil
        umask = original.umask
        isRoot = original.isRoot
        resolvedPath = original.resolvedPath
        openBeneath = options.resolvesBeneath ? O_RESOLVE_BENEATH : 0
        atBeneath = options.resolvesBeneath ? AT_RESOLVE_BENEATH : 0
    }

    /// The same directory with other options: what a client that writes a format's entries (NativeAEA, NativeZip)
    /// makes of the destination its caller opened, to apply its format's policies (existing items, permissions,
    /// owners) to the directory the caller chose, a staging directory included.
    ///
    /// The directory isn't looked up again: the result has a duplicate of this destination's descriptor (one `fcntl`),
    /// so a rename or a link along its path since it was opened changes nothing. It doesn't own a staging directory
    /// (``publish(as:uniquing:)``, ``publishUnwrapped(as:)``, and ``discard()`` stay this one's), and it doesn't apply
    /// ``DestinationOptions/quarantinesDestination`` (the directory was this one's to quarantine when it was opened).
    ///
    /// Clients keep their caller's ``DestinationOptions/quarantine``: the caller's options say what everything
    /// extracted gets.
    ///
    /// - Throws: ``DiskError/system(_:path:_:)`` if the descriptor can't be duplicated (the process is out of them).
    public func reopened(with options: DestinationOptions) throws(DiskError) -> Destination {
        Sys.countOther()
        let duplicate = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw .system("dup", path: path.string, code: errno) }
        return Destination(reopening: self, root: duplicate, options: options)
    }

    deinit {
        Sys.close(root)
        if let staging { Sys.close(staging.parent) }
    }

    /// `mkdir -p`: the directory and its missing parents (following links in it: the caller's own path).
    static func makeDirectories(_ directory: FilePath) throws(DiskError) {
        var made = FilePath(directory.root?.string ?? "")
        for component in directory.components {
            made.append(component)
            // Unsafe: `withPlatformString`'s C string to `mkdirat`. Safe: NUL-terminated and valid inside the closure,
            // which the call returns within.
            let result = unsafe made.withPlatformString { unsafe Sys.mkdirat(AT_FDCWD, $0, 0o755) }
            if result != 0, errno != EEXIST { throw .system("mkdir", path: made.string, code: errno) }
        }
    }

    // MARK: Staging

    /// A hidden staging directory beside `final` (`.NAME.partial-XXXXXX` in its parent), for extracting where nothing
    /// is visible until ``publish(as:uniquing:)`` renames it into place: what an app shows the user only when complete.
    ///
    /// - Parameters:
    ///   - final: Where the result will go (its parent must exist).
    ///   - options: How entries are made.
    public static func staging(for final: FilePath, options: DestinationOptions = .init()) throws(DiskError) -> Destination {
        let parentPath = final.removingLastComponent()
        // Unsafe: `withPlatformString`'s C string to `openat`. Safe: NUL-terminated and valid inside the closure, which
        // the call returns within.
        let parent = unsafe parentPath.withPlatformString { unsafe Sys.openat(AT_FDCWD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard parent >= 0 else { throw .system("open", path: parentPath.string, code: errno) }
        let base = final.lastComponent?.string ?? "Extracted"
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<64 {
            let suffix = String(generator.next() & 0xFF_FFFF, radix: 16)
            let name = Array(".\(base).partial-\(suffix)".utf8)
            // Unsafe: `CString.with`'s pointer to `mkdirat`. Safe: its NUL-terminated copy of `name`, valid inside
            // the body, which the call returns within.
            let made = unsafe CString.with(name.span.bytes) { unsafe Sys.mkdirat(parent, $0, 0o700) }
            if made != 0 {
                if errno == EEXIST { continue }
                let code = errno
                Sys.close(parent)
                throw .system("mkdir", path: parentPath.string, code: code)
            }
            // Unsafe: `CString.with`'s pointer to `openat`. Safe: its NUL-terminated copy of `name`, as above.
            let root = unsafe CString.with(name.span.bytes) { unsafe Sys.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard root >= 0 else {
                let code = errno
                Sys.close(parent)
                throw .system("open", path: parentPath.string, code: code)
            }
            var path = parentPath
            path.append(String(decoding: name, as: UTF8.self))
            return try Destination(root: root, path: path, options: options, staging: (parent, name))
        }
        Sys.close(parent)
        throw .exists(final.string)
    }

    /// Moves a staging destination into place as `final` (in the same parent), atomically and without replacing
    /// anything (`renameatx_np` with `RENAME_EXCL`). With `uniquing`, a taken name becomes `NAME 2`, `NAME 3`, … as the
    /// Finder and Archive Utility name them.
    ///
    /// - Returns: Where it went.
    @discardableResult
    public func publish(as final: FilePath, uniquing: Bool = true) throws(DiskError) -> FilePath {
        guard let staging else { throw .refused("publish: not a staging destination") }
        let base = final.lastComponent?.stem ?? "Extracted"
        let ext = final.lastComponent?.extension.map { ".\($0)" } ?? ""
        for attempt in 1...10_000 {
            let name = attempt == 1 ? (final.lastComponent?.string ?? base) : "\(base) \(attempt)\(ext)"
            // Unsafe (both lines): two C strings to `renameatx_np`. Safe: `from` is `CString.with`'s NUL-terminated copy
            // of the staging name and `$0` is `withCString`'s; each is valid inside its closure; the call is in both.
            let moved = unsafe CString.with(staging.name.span.bytes) { from in
                name.withCString { unsafe Sys.renameatx(staging.parent, from, staging.parent, $0, UInt32(RENAME_EXCL)) }
            }
            if moved == 0 { return final.removingLastComponent().appending(name) }
            let code = errno
            guard code == EEXIST, uniquing else { throw .system("rename", path: final.string, code: code) }
        }
        throw .exists(final.string)
    }

    /// Publishes a staging destination as Archive Utility publishes an expansion (measured, 2026-11-21): one top-level
    /// item is moved out under its own name, into the staging directory's parent, and the staging directory removed;
    /// anything else (several items, or none) is published together as the folder `final`
    /// (``publish(as:uniquing:)``). Nothing is ever replaced: a taken name becomes `NAME 2`, `NAME 3`, … (`NAME
    /// 2.ext` for a name with an extension).
    ///
    /// The folder keeps the staging directory's mode (0700, as Archive Utility's folders have) unless an entry set it
    /// (an archive's entry for its root); the quarantine it gets is the options' (``DestinationOptions/quarantinesDestination``).
    /// A single item keeps everything its entries gave it.
    ///
    /// - Returns: Where the item or folder went.
    @discardableResult
    public func publishUnwrapped(as final: FilePath) throws(DiskError) -> FilePath {
        guard let staging else { throw .refused("publish: not a staging destination") }
        guard let name = try onlyItem() else { return try publish(as: final, uniquing: true) }
        let text = String(decoding: name, as: UTF8.self)
        let component = FilePath.Component(text)
        let base = component?.stem ?? text
        let ext = component?.extension.map { ".\($0)" } ?? ""
        let parentPath = final.removingLastComponent()
        var lentWrite: mode_t?
        for attempt in 1...10_000 {
            let candidate = attempt == 1 ? text : "\(base) \(attempt)\(ext)"
            // Unsafe (both lines): two C strings to `renameatx_np`. Safe: `from` is `CString.with`'s NUL-terminated copy
            // of the item's name and `$0` is `withCString`'s; each is valid inside its closure; the call is in both.
            var moved = unsafe CString.with(name.span.bytes) { from in
                candidate.withCString { unsafe Sys.renameatx(root, from, staging.parent, $0, UInt32(RENAME_EXCL)) }
            }
            var code = errno
            if moved != 0, code == EACCES, lentWrite == nil {
                // A directory moved to another parent needs write permission on itself (its `..` changes): lend a
                // read-only one the owner's write bit for the rename.
                var info = stat()
                // Unsafe (the next two): the item's name to `fstatat` (which fills `info`) and to `fchmodat`. Safe:
                // `CString.with`'s NUL-terminated copy, valid inside each body; `info` is a local `stat`.
                let found = unsafe CString.with(name.span.bytes) { unsafe Sys.fstatat(root, $0, &info, AT_SYMLINK_NOFOLLOW) }
                guard found == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & S_IWUSR == 0,
                      unsafe CString.with(name.span.bytes, { unsafe fchmodat(root, $0, (info.st_mode & 0o7777) | S_IWUSR, 0) }) == 0
                else { throw .system("rename", path: path.appending(text).string, code: EACCES) }
                lentWrite = info.st_mode & 0o7777
                // Unsafe: as for the first rename.
                moved = unsafe CString.with(name.span.bytes) { from in
                    candidate.withCString { unsafe Sys.renameatx(root, from, staging.parent, $0, UInt32(RENAME_EXCL)) }
                }
                code = errno
            }
            if moved == 0 {
                // Unsafe: the new name to `fchmodat`. Safe: `withCString`'s, valid inside the closure.
                if let lentWrite { _ = candidate.withCString { unsafe fchmodat(staging.parent, $0, lentWrite, 0) } }
                discard()
                return parentPath.appending(candidate)
            }
            guard code == EEXIST else {
                // Unsafe: the item's name to `fchmodat`. Safe: `CString.with`'s NUL-terminated copy, valid in the body.
                if let lentWrite { _ = unsafe CString.with(name.span.bytes) { unsafe fchmodat(root, $0, lentWrite, 0) } }
                throw .system("rename", path: path.appending(text).string, code: code)
            }
        }
        throw .exists(parentPath.appending(text).string)
    }

    /// The name of the destination's only item, or `nil` if it holds none or several.
    func onlyItem() throws(DiskError) -> [UInt8]? {
        // `fdopendir` takes the descriptor it's given (and `closedir` closes it): a second one, so `root` stays open.
        // Unsafe: a literal's C string to `openat`. Safe: NUL-terminated, read only during the call.
        let directory = unsafe Sys.openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw .system("open", path: path.string, code: errno) }
        // Unsafe: `fdopendir` returns a stream pointer. Safe: checked for `nil`; used only in this function, which
        // closes it once (the `defer`) on every path after this guard.
        guard let stream = unsafe fdopendir(directory) else {
            let code = errno
            Sys.close(directory)
            throw .system("opendir", path: path.string, code: code)
        }
        // Unsafe: `closedir` on the stream. Safe: open until then, closed exactly once, and not used after.
        defer { unsafe closedir(stream) }
        var only: [UInt8]?
        // Unsafe: `readdir` on the stream, returning a pointer to an entry. Safe: the open stream; the entry is the
        // stream's, valid until the next `readdir` or `closedir` on it, and used only in this iteration's body.
        while let entry = unsafe readdir(stream) {
            // Unsafe: a pointer to the entry's `d_name`, through `entry.pointee`. Safe: the entry is valid for this
            // iteration, and the pointer is used only inside the closure, which copies the name's bytes (to its NUL,
            // within the record) into an array.
            let name: [UInt8] = unsafe withUnsafePointer(to: entry.pointee.d_name) { tuple in
                // Unsafe: rebinds the tuple of `CChar`s to bytes and measures the name. Safe: a homogeneous tuple of
                // `CChar` is laid out as an array of them; `d_name` is NUL-terminated within it.
                let bytes = unsafe UnsafeRawPointer(tuple)
                return unsafe Array(UnsafeRawBufferPointer(start: bytes, count: strlen(bytes.assumingMemoryBound(to: CChar.self))))
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            if only != nil { return nil }
            only = name
        }
        return only
    }

    /// Removes a staging destination and everything in it (after a failure or cancellation).
    public func discard() {
        guard let staging else { return }
        TreeRemoval.remove(name: staging.name, in: staging.parent)
    }

    // MARK: Modes

    /// The mode an entry ends with: the archived mode (or the kind's default), special bits stripped unless kept, the
    /// umask applied unless exact.
    @inline(__always)
    func finalMode(_ mode: UInt16?, default fallback: mode_t) -> mode_t {
        var result = mode.map { mode_t($0) & 0o7777 } ?? fallback
        if !options.keepsSpecialBits { result &= 0o777 }
        if options.permissions == .umask { result &= ~umask }
        return result
    }

    /// The mode a file is created with: owner-writable (and readable) whatever its final mode.
    @inline(__always)
    func creationMode(_ final: mode_t) -> mode_t { (final & 0o777) | 0o600 }

    /// What `open`/`mkdir` leaves for `requested` (the kernel applies the umask).
    @inline(__always)
    func createdMode(_ requested: mode_t) -> mode_t { requested & ~umask & 0o777 }

    /// The flags to set: `UF_COMPRESSED` from the writer, the archived flags if restored (`SF_` only as root).
    @inline(__always)
    func finalFlags(_ flags: UInt32, compressed: Bool) -> UInt32 {
        var result: UInt32 = 0
        if options.restoresFlags {
            result = flags & ~UInt32(UF_COMPRESSED)
            if !isRoot { result &= 0x0000_FFFF }
        }
        if compressed { result |= UInt32(UF_COMPRESSED) }
        return result
    }

    @inline(__always)
    func finalOwner(_ owner: Owner?) -> Owner? {
        options.restoresOwnership && isRoot ? owner : nil
    }

    /// The one `fsetattrlist` that finishes an entry, or an empty list if there's nothing to change.
    ///
    /// - Parameter created: The mode the entry has now.
    func attributes(_ metadata: EntryMetadata, mode final: mode_t, created: mode_t, compressed: Bool) -> AttributeList {
        let flags = finalFlags(metadata.flags, compressed: compressed)
        return AttributeList(
            times: metadata.times, owner: finalOwner(metadata.owner), mode: final != created ? final : nil,
            flags: flags != 0 ? flags : nil
        )
    }

    // MARK: Primitives

    /// Creates a file for writing: `name` in `directory` (a path from the destination, or a name in an open parent),
    /// never through a symbolic link.
    ///
    /// - Returns: The descriptor, or -1 if it exists and the policy is ``ExistingItemPolicy/skip``.
    func createFile(_ directory: Int32, _ name: UnsafePointer<CChar>, mode: mode_t, path: PathRef) throws(DiskError) -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY | openBeneath
        // Unsafe: `name` to `openat`. Safe: the caller's NUL-terminated name, valid and unchanged for this call (the
        // parameter's contract); read only during the call.
        var descriptor = unsafe Sys.openat(directory, name, flags, mode)
        if descriptor >= 0 { return descriptor }
        var code = errno
        if code == EEXIST {
            switch options.existingItems {
            case .fail: throw .exists(path.string)
            case .skip: return -1
            case .replace:
                // A file or link (not a directory: `unlinkat` without `AT_REMOVEDIR` leaves those), the name itself.
                // Unsafe (the next two): `name` to `unlinkat` and to `openat` again. Safe: the caller's NUL-terminated
                // name, as above; read only during each call.
                if unsafe Sys.unlinkat(directory, name, AT_SYMLINK_NOFOLLOW_ANY | atBeneath) == 0 {
                    descriptor = unsafe Sys.openat(directory, name, flags, mode)
                    if descriptor >= 0 { return descriptor }
                }
                code = errno
                if code == EPERM || code == EISDIR { throw .exists(path.string) }
            }
        }
        throw .system("open", path: path, code: code)
    }

    /// Sets the quarantine and the attributes on an open entry: the last calls before `close`.
    @inline(__always)
    func finish(_ descriptor: Int32, attributes: inout AttributeList, path: PathRef) throws(DiskError) {
        if let quarantine = options.quarantine { try quarantine.apply(descriptor, path: path) }
        if attributes.apply(descriptor) != 0 { throw .system("setattrlist", path: path, code: errno) }
    }

    /// Opens `path`'s parent without following links (or uses the destination for a single name) and calls `body`
    /// with it and the last component, for the calls that take no flags: `mkdirat`, `symlinkat`, `mkfifoat`, `mknodat`.
    ///
    /// - Parameter path: NUL-terminated, valid.
    func withParent<R>(of path: UnsafePointer<CChar>, count: Int, _ body: (Int32, UnsafePointer<CChar>) throws(DiskError) -> R) throws(DiskError) -> R {
        // The caller's contract: `path` has `count` bytes and then a NUL, valid and unchanged for this call.
        var slash = count - 1
        // Unsafe: reads byte `slash` of `path`. Safe: `0 <= slash < count` (tested first), within the path's bytes.
        while slash >= 0, unsafe path.advanced(by: slash).pointee != 0x2F { slash -= 1 }
        // Unsafe: `path` to `body`, as the name. Safe: the caller's NUL-terminated path, valid for this call, which
        // `body` (non-escaping) returns within.
        guard slash > 0 else { return try unsafe body(root, path) }
        // Unsafe (the next two lines): the path's first `slash` bytes to `CString.with`, and its NUL-terminated copy
        // to `openat`. Safe: `slash < count`, within the path; the copy is valid inside the body, where the call is.
        let parent = unsafe CString.with(UnsafeRawPointer(path), count: slash) {
            unsafe Sys.openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | openBeneath)
        }
        // Unsafe: a `PathRef` over the path's first `slash` bytes. Safe: within the caller's path; read at once, into
        // the error's string.
        guard parent >= 0 else { throw unsafe .system("open", path: PathRef(UnsafeRawPointer(path), count: slash), code: errno) }
        defer { Sys.close(parent) }
        // Unsafe: a pointer past the slash to `body`, as the name. Safe: `slash + 1 <= count`, so it points into the
        // path or at its NUL: a NUL-terminated string, valid for this call, which `body` returns within.
        return try unsafe body(parent, path + slash + 1)
    }

    /// Makes the directory `name` in `directory` (a checked parent), owner-writable while its contents go in; reuses
    /// one that's there.
    ///
    /// - Returns: Whether it was made (`false`: it was there).
    func makeDirectory(_ directory: Int32, _ name: UnsafePointer<CChar>, mode: mode_t, path: PathRef) throws(DiskError) -> Bool {
        // The caller's contract: `name` is a NUL-terminated name, valid and unchanged for this call.
        // Unsafe: `name` to `mkdirat`. Safe: as above; read only during the call.
        if unsafe Sys.mkdirat(directory, name, mode | 0o700) == 0 { return true }
        let code = errno
        guard code == EEXIST else { throw .system("mkdir", path: path, code: code) }
        var info = stat()
        // Unsafe: `name` to `fstatat`, which fills `info`. Safe: `name` as above; `info` is a local `stat`.
        guard unsafe Sys.fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW_ANY | atBeneath) == 0 else {
            throw .system("stat", path: path, code: errno)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            if info.st_mode & 0o700 != 0o700 {
                // Unsafe: `name` to `fchmodat`. Safe: the caller's NUL-terminated name; read only during the call.
                _ = unsafe fchmodat(directory, name, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW_ANY | atBeneath)
                Sys.countOther()
            }
            return false
        }
        // A file or link where a directory goes.
        // Unsafe (the next two lines): `name` to `unlinkat` and `mkdirat`. Safe: the caller's NUL-terminated name;
        // read only during each call.
        guard options.existingItems == .replace, unsafe Sys.unlinkat(directory, name, AT_SYMLINK_NOFOLLOW_ANY | atBeneath) == 0,
              unsafe Sys.mkdirat(directory, name, mode | 0o700) == 0
        else { throw .notADirectory(path.string) }
        return true
    }

    /// Makes every missing directory of `path`'s parent, from the top, checking each that was there (a directory, not a
    /// link): the slow path, after a create found no parent.
    func makeParents(of path: UnsafePointer<CChar>, count: Int) throws(DiskError) {
        // The caller's contract: `path` has `count` bytes and then a NUL, valid and unchanged for this call.
        var index = 0
        while index < count {
            // Unsafe: reads byte `index` of `path`. Safe: `index < count` (the loop's condition).
            if unsafe path.advanced(by: index).pointee == 0x2F {
                // Unsafe (the next two lines): the path's first `index` bytes to `CString.with`; its NUL-terminated
                // copy (`prefix`) to `makeDirectory`, with a `PathRef` over the same bytes of `path`. Safe: `index <
                // count`, within the path; the copy is valid inside the body, and the reference is read only
                // during `makeDirectory`, while the caller keeps `path`.
                try unsafe CString.with(UnsafeRawPointer(path), count: index) { (prefix) throws(DiskError) in
                    _ = try unsafe makeDirectory(root, prefix, mode: 0o755, path: PathRef(UnsafeRawPointer(path), count: index))
                }
            }
            index += 1
        }
    }

    // MARK: Synchronous entries

    /// Makes a directory (and missing parents), and applies its metadata. A directory with read-only permissions is
    /// made owner-writable: call ``finishDirectory(_:metadata:)`` after its contents (the scheduler does).
    package func makeDirectory(_ path: EntryPath, metadata: EntryMetadata = .init()) throws(DiskError) {
        guard !path.isRoot else { return }
        // Unsafe: `CString.with` hands the body a pointer. Safe: its NUL-terminated copy of the path's bytes (an
        // `EntryPath` has no NUL, so `byteCount` bytes before it), valid inside the body, which keeps nothing.
        try unsafe CString.with(path.bytes) { (name) throws(DiskError) in
            let count = path.bytes.byteCount
            // Unsafe: `name` to `makeParents`. Safe: `count` bytes and a NUL (above), valid for the call.
            try unsafe makeParents(of: name, count: count)
            // Unsafe: `name` to `makeDirectory`, and as a `PathRef`. Safe: NUL-terminated, valid for the call, the
            // only time the reference is read.
            _ = try unsafe makeDirectory(root, name, mode: finalMode(metadata.mode, default: 0o755) & 0o777, path: PathRef(cString: name))
        }
    }

    /// Applies a directory's metadata (after its contents): quarantine, mode, times, flags.
    package func finishDirectory(_ path: EntryPath, metadata: EntryMetadata) throws(DiskError) {
        // Unsafe: `CString.with` hands the body a pointer. Safe: its NUL-terminated copy of the path's bytes (just a NUL
        // for the destination itself), valid inside the body, which keeps nothing.
        try unsafe CString.with(path.bytes) { (name) throws(DiskError) in
            // Unsafe (the next two lines): a C string to `openat`. Safe: a literal's, or `name` (NUL-terminated,
            // valid in this body); read only during the call.
            let descriptor = path.isRoot
                ? unsafe Sys.openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                : unsafe Sys.openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | openBeneath)
            // Unsafe: `name` as a `PathRef`. Safe: NUL-terminated, valid in this body; read at once, into the error.
            guard descriptor >= 0 else { throw unsafe .system("open", path: PathRef(cString: name), code: errno) }
            defer { Sys.close(descriptor) }
            var attributes = AttributeList(
                times: metadata.times, owner: finalOwner(metadata.owner), mode: finalMode(metadata.mode, default: 0o755),
                flags: options.restoresFlags ? finalFlags(metadata.flags, compressed: false) : nil
            )
            if !path.isRoot || options.quarantinesDestination, let quarantine = options.quarantine {
                // Unsafe: `name` as a `PathRef`. Safe: as above; read only during `apply`, inside this body.
                try unsafe quarantine.apply(descriptor, path: PathRef(cString: name))
            }
            // Unsafe: `name` as a `PathRef`. Safe: as above; read at once, into the error.
            if attributes.apply(descriptor) != 0 { throw unsafe .system("setattrlist", path: PathRef(cString: name), code: errno) }
        }
    }

    /// Makes a symbolic link, with its mode and times (on the link itself).
    package func makeSymbolicLink(_ path: EntryPath, to target: RawSpan, metadata: EntryMetadata = .init()) throws(DiskError) {
        guard !path.isRoot else { throw .unsafePath("") }
        // Unsafe (the next two lines): `CString.with` hands each body a pointer. Safe: NUL-terminated copies of the
        // path's bytes (`byteCount` of them before the NUL: an `EntryPath` has none) and of the target's, each valid
        // inside its body; nothing below keeps either.
        try unsafe CString.with(path.bytes) { (name) throws(DiskError) in
            try unsafe CString.with(target) { (target) throws(DiskError) in
                // Unsafe: `name` to `makeParents`. Safe: `byteCount` bytes and a NUL (above), valid for the call.
                try unsafe makeParents(of: name, count: path.bytes.byteCount)
                // Unsafe: `name` and `target` to `makeSymbolicLink`. Safe: both NUL-terminated and valid for the call,
                // inside both bodies.
                try unsafe makeSymbolicLink(name, count: path.bytes.byteCount, target: target, metadata: metadata, attributes: nil)
            }
        }
    }

    /// Whether a link at `path` (NUL-terminated, `count` bytes) pointing at `target` stays inside the destination.
    static func targetStaysInside(_ path: UnsafePointer<CChar>, count: Int, target: UnsafePointer<CChar>) -> Bool {
        // The caller's contract: `path` has `count` bytes and then a NUL; `target` is NUL-terminated; both valid for
        // the call.
        // Unsafe: `strlen` reads `target` to its NUL. Safe: NUL-terminated (above).
        let targetCount = unsafe strlen(target)
        // Unsafe: reads `target`'s first byte. Safe: `targetCount > 0` here (tested first): a byte of the string.
        if targetCount == 0 || (unsafe target.pointee) == 0x2F { return false }
        // Depth of the link's directory, then walk the target's components.
        var depth = 0
        // Unsafe: reads byte `index` of `path`. Safe: `index < count`, within the path's bytes.
        for index in 0..<count where unsafe path.advanced(by: index).pointee == 0x2F { depth += 1 }
        var start = 0
        for index in 0...targetCount {
            // Unsafe: reads byte `index` of `target`. Safe: only when `index < targetCount` (the condition before it).
            let byte = index < targetCount ? unsafe target.advanced(by: index).pointee : 0x2F
            guard byte == 0x2F else { continue }
            let length = index - start
            // Unsafe (this line and the `else if`): reads the component's first byte, and its second when it has two.
            // Safe: `length > 0` where the first is read and `length == 2` where the second is, and the component
            // ends at `index <= targetCount`, so `start` (and `start + 1`) are under `targetCount`.
            if length == 2, unsafe target.advanced(by: start).pointee == 0x2E, unsafe target.advanced(by: start + 1).pointee == 0x2E {
                depth -= 1
                if depth < 0 { return false }
            } else if length > 0, !(length == 1 && (unsafe target.advanced(by: start).pointee) == 0x2E) {
                depth += 1
            }
            start = index + 1
        }
        return true
    }

    /// Makes one symbolic link `path` (NUL-terminated, valid) pointing at `target`, in its parent opened without
    /// following links, then its mode and times on the link, its extended attributes and the quarantine through
    /// `O_SYMLINK`.
    ///
    /// - Returns: `false` if something was there and the policy is ``ExistingItemPolicy/skip``.
    @discardableResult
    func makeSymbolicLink(_ path: UnsafePointer<CChar>, count: Int, target: UnsafePointer<CChar>, metadata: EntryMetadata, attributes blob: RawSpan?) throws(DiskError) -> Bool {
        // The caller's contract: `path` has `count` bytes and then a NUL, and `target` is NUL-terminated; both valid and
        // unchanged for this call. Every `PathRef` of `path` below is read before this returns (into an error's
        // string, or by the call it's passed to).
        // Unsafe: both strings to `targetStaysInside`. Safe: as above; it only reads them, during the call.
        if options.symbolicLinks == .withinDestination, !(unsafe Self.targetStaysInside(path, count: count, target: target)) {
            // Unsafe: `path` as a `PathRef` (`strlen`, then its bytes). Safe: NUL-terminated; read at once.
            throw .refused("a symbolic link out of the destination: \(unsafe PathRef(cString: path).string)")
        }
        // Unsafe: `path` to `withParent`, which hands the body `name`. Safe: `count` bytes and a NUL, as above; `name`
        // is NUL-terminated (a pointer into `path`, or the whole of it), valid inside the body.
        return try unsafe withParent(of: path, count: count) { (directory, name) throws(DiskError) -> Bool in
            // Unsafe: `target` and `name` to `symlinkat`. Safe: both NUL-terminated, valid in this body; read only
            // during the call.
            var created = unsafe Sys.symlinkat(target, directory, name) == 0
            if !created, errno == EEXIST {
                switch options.existingItems {
                // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error's string.
                case .fail: throw .exists(unsafe PathRef(cString: path).string)
                case .skip: return false
                case .replace:
                    // Unsafe: `name` to `unlinkat`, then `target` and `name` to `symlinkat`. Safe: as for the first
                    // `symlinkat`.
                    created = unsafe Sys.unlinkat(directory, name, 0) == 0 && Sys.symlinkat(target, directory, name) == 0
                }
            }
            // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error.
            guard created else { throw .system("symlink", path: unsafe PathRef(cString: path), code: errno) }
            // Links get 0755 whatever the umask; the archived mode otherwise (umask and special bits as for files).
            let mode = finalMode(metadata.mode, default: 0o755) & 0o777
            if options.quarantine != nil || blob != nil {
                // Unsafe: `name` to `openat`. Safe: NUL-terminated, valid in this body; read only during the call.
                let descriptor = unsafe Sys.openat(directory, name, O_RDONLY | O_SYMLINK | O_CLOEXEC)
                // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error.
                guard descriptor >= 0 else { throw .system("open", path: unsafe PathRef(cString: path), code: errno) }
                defer { Sys.close(descriptor) }
                // Unsafe (the next two): `path` as a `PathRef`, to `apply` and `applyExtendedAttributes`. Safe:
                // NUL-terminated; each reads the reference only while it runs, inside this call.
                if let quarantine = options.quarantine { try unsafe quarantine.apply(descriptor, path: PathRef(cString: path)) }
                if let blob { try unsafe EntryAttributes.applyExtendedAttributes(descriptor, blob, path: PathRef(cString: path)) }
            }
            var attributes = AttributeList(
                times: metadata.times, owner: finalOwner(metadata.owner), mode: mode != 0o755 ? mode : nil,
                flags: nil
            )
            // Unsafe: `name` to `apply` (`setattrlistat`), and `path` as a `PathRef`. Safe: both NUL-terminated, valid
            // in this body; `name` is read during the call, the reference at once, into the error.
            if unsafe attributes.apply(directory, name) != 0 { throw .system("setattrlist", path: unsafe PathRef(cString: path), code: errno) }
            return true
        }
    }

    /// Makes `path` another name of the file at `existing`, both inside the destination, following no link in either
    /// path (`AT_SYMLINK_NOFOLLOW_ANY`, `AT_RESOLVE_BENEATH`).
    package func makeHardLink(_ path: EntryPath, to existing: EntryPath) throws(DiskError) {
        guard !path.isRoot, !existing.isRoot else { throw .unsafePath("") }
        // Unsafe (the next two lines): `CString.with` hands each body a pointer. Safe: NUL-terminated copies of the
        // two paths' bytes (`byteCount` of them before the NUL: an `EntryPath` has none), each valid inside its body;
        // nothing below keeps either.
        try unsafe CString.with(path.bytes) { (name) throws(DiskError) in
            try unsafe CString.with(existing.bytes) { (target) throws(DiskError) in
                // Unsafe: `name` to `makeParents`. Safe: `byteCount` bytes and a NUL (above), valid for the call.
                try unsafe makeParents(of: name, count: path.bytes.byteCount)
                // Unsafe: `name` and `target` to `makeHardLink`. Safe: both NUL-terminated and valid for the call,
                // inside both bodies.
                try unsafe makeHardLink(name, to: target)
            }
        }
    }

    /// One `linkat`, both paths from the destination.
    @discardableResult
    func makeHardLink(_ path: UnsafePointer<CChar>, to target: UnsafePointer<CChar>) throws(DiskError) -> Bool {
        // The caller's contract: `path` and `target` are NUL-terminated, valid and unchanged for this call.
        let flags = AT_SYMLINK_NOFOLLOW_ANY | atBeneath
        // Unsafe: both strings to `linkat`. Safe: as above; read only during the call.
        if unsafe Sys.linkat(root, target, root, path, flags) == 0 { return true }
        // Unsafe: `path` as a `PathRef` (`strlen`, then its bytes). Safe: NUL-terminated; read at once, into the error.
        guard errno == EEXIST else { throw .system("link", path: unsafe PathRef(cString: path), code: errno) }
        switch options.existingItems {
        // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error's string.
        case .fail: throw .exists(unsafe PathRef(cString: path).string)
        case .skip: return false
        case .replace:
            // Unsafe (both on this line): `path` to `unlinkat`, then both strings to `linkat`. Safe: NUL-terminated,
            // the caller's; read only during each call.
            if unsafe Sys.unlinkat(root, path, flags) == 0, unsafe Sys.linkat(root, target, root, path, flags) == 0 { return true }
            // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error.
            throw .system("link", path: unsafe PathRef(cString: path), code: errno)
        }
    }

    /// Makes a FIFO or (as root, with ``DestinationOptions/allowsDevices``) a device.
    ///
    /// - Returns: `false` if a device was skipped (not root).
    @discardableResult
    package func makeSpecialFile(_ path: EntryPath, _ kind: SpecialFileKind, metadata: EntryMetadata = .init()) throws(DiskError) -> Bool {
        guard !path.isRoot else { throw .unsafePath("") }
        // Unsafe: `CString.with` hands the body a pointer. Safe: its NUL-terminated copy of the path's bytes
        // (`byteCount` of them before the NUL: an `EntryPath` has none), valid inside the body, which keeps nothing.
        return try unsafe CString.with(path.bytes) { (name) throws(DiskError) -> Bool in
            // Unsafe: `name` to `makeParents`. Safe: `byteCount` bytes and a NUL (above), valid for the call.
            try unsafe makeParents(of: name, count: path.bytes.byteCount)
            // Unsafe: `name` to `makeSpecialFile`. Safe: the same string, valid for the call.
            return try unsafe makeSpecialFile(name, count: path.bytes.byteCount, kind, metadata: metadata)
        }
    }

    func makeSpecialFile(_ path: UnsafePointer<CChar>, count: Int, _ kind: SpecialFileKind, metadata: EntryMetadata) throws(DiskError) -> Bool {
        // The caller's contract: `path` has `count` bytes and then a NUL, valid and unchanged for this call. Every
        // `PathRef` of it below is read before this returns (into an error).
        if case .fifo = kind {} else {
            // Unsafe: `path` as a `PathRef` (`strlen`, then its bytes). Safe: NUL-terminated; read at once.
            guard options.allowsDevices else { throw .refused("a device: \(unsafe PathRef(cString: path).string)") }
            guard isRoot else { return false }
        }
        let mode = finalMode(metadata.mode, default: 0o644)
        // Unsafe: `path` to `withParent`, which hands the body `name`. Safe: `count` bytes and a NUL, as above; `name`
        // is NUL-terminated (a pointer into `path`, or the whole of it), valid inside the body.
        return try unsafe withParent(of: path, count: count) { (directory, name) throws(DiskError) -> Bool in
            func make() -> Int32 {
                // Unsafe (the three calls): `name` to `mkfifoat` or `mknodat`. Safe: NUL-terminated, valid in the
                // body, where `make` is called; read only during the call.
                switch kind {
                case .fifo: unsafe Sys.mkfifoat(directory, name, mode & 0o777)
                case .characterDevice(let device): unsafe Sys.mknodat(directory, name, S_IFCHR | (mode & 0o777), dev_t(truncatingIfNeeded: device))
                case .blockDevice(let device): unsafe Sys.mknodat(directory, name, S_IFBLK | (mode & 0o777), dev_t(truncatingIfNeeded: device))
                }
            }
            var result = make()
            if result != 0, errno == EEXIST {
                switch options.existingItems {
                // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error's string.
                case .fail: throw .exists(unsafe PathRef(cString: path).string)
                case .skip: return false
                // Unsafe: `name` to `unlinkat`. Safe: NUL-terminated, valid in this body; read only during the call.
                case .replace: if unsafe Sys.unlinkat(directory, name, 0) == 0 { result = make() }
                }
            }
            // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated; read at once, into the error.
            guard result == 0 else { throw .system("mknod", path: unsafe PathRef(cString: path), code: errno) }
            var attributes = AttributeList(
                times: metadata.times, owner: finalOwner(metadata.owner), mode: mode != createdMode(mode) ? mode : nil,
                flags: nil
            )
            // Unsafe: `name` to `apply` (`setattrlistat`), and `path` as a `PathRef`. Safe: both NUL-terminated, valid
            // in this body; `name` is read during the call, the reference at once, into the error.
            if unsafe attributes.apply(directory, name) != 0 { throw .system("setattrlist", path: unsafe PathRef(cString: path), code: errno) }
            return true
        }
    }

    /// What's at a path, for a client's own policies (NativeZip's freshen, update, and "replace?" questions).
    public struct ExistingItem: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case file, directory, symbolicLink, other }
        public var kind: Kind
        public var size: Int
        public var modification: Timestamp
    }

    /// The item at `path`, not following a link at its end or anywhere before it, or `nil` if there's none.
    ///
    /// - Throws: ``DiskError/escapesDestination(_:)`` if the path goes through a link.
    public func existingItem(at path: EntryPath) throws(DiskError) -> ExistingItem? {
        // Unsafe: `CString.with` hands the body a pointer. Safe: its NUL-terminated copy of the path's bytes (just a NUL
        // for the destination itself), valid inside the body, which keeps nothing.
        try unsafe CString.with(path.bytes) { (name) throws(DiskError) -> ExistingItem? in
            var info = stat()
            // Unsafe (the next two lines): a C string to `fstatat`, which fills `info`. Safe: a literal's, or `name`
            // (NUL-terminated, valid in this body); `info` is a local `stat`.
            let result = path.isRoot
                ? unsafe Sys.fstatat(root, ".", &info, 0)
                : unsafe Sys.fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | atBeneath)
            if result != 0 {
                if errno == ENOENT { return nil }
                // Unsafe: `name` as a `PathRef`. Safe: NUL-terminated, valid in this body; read at once, into the error.
                throw .system("stat", path: unsafe PathRef(cString: name), code: errno)
            }
            let kind: ExistingItem.Kind = switch info.st_mode & S_IFMT {
            case S_IFREG: .file
            case S_IFDIR: .directory
            case S_IFLNK: .symbolicLink
            default: .other
            }
            return ExistingItem(
                kind: kind, size: Int(info.st_size),
                modification: Timestamp(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: UInt32(info.st_mtimespec.tv_nsec))
            )
        }
    }
}
