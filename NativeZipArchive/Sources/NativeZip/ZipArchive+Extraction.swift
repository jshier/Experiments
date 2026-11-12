import Foundation
import System

/// Something that happened while extracting, for progress reporting. Events arrive in archive order.
public enum ExtractionEvent {
    /// A directory is being created.
    case creatingDirectory(ZipEntry, path: FilePath)
    /// A file is about to be decompressed and written. Files are written in parallel, so this precedes the
    /// write, not its completion.
    case extracting(ZipEntry, path: FilePath)
    /// A symbolic link is being created, pointing at `destination`.
    case linking(ZipEntry, path: FilePath, destination: String)
    /// An existing item was kept, so the entry wasn't extracted.
    case skipped(ZipEntry, path: FilePath)
}

/// What to do when an item already exists at an entry's destination.
public enum OverwritePolicy {
    /// Replace existing items without asking. (An existing directory is never removed to make room for a file.)
    case always
    /// Keep existing items and skip their entries.
    case never
    /// Ask per item; return `true` to replace it. Called serially, in archive order.
    case ask((_ entry: ZipEntry, _ path: FilePath) -> Bool)
}

/// Settings for ``ZipArchive/extract(_:to:options:)``.
public struct ExtractionOptions {
    /// Creates options with the defaults below.
    public init() {}

    /// Flatten the archive: write every file into the destination root and skip directory entries.
    public var junkPaths = false
    /// Apply the archive's modification dates to extracted items.
    public var restoreTimestamps = true
    /// What to do when an item already exists. The default is ``OverwritePolicy/always``.
    public var overwrite = OverwritePolicy.always
    /// Progress reporting. Paths are relative to the destination.
    public var onEvent: ((ExtractionEvent) -> Void)?
    /// The most files that may be decompressed and written at once. Extraction uses fewer when
    /// that's faster (see ``ZipArchive/extract(_:to:options:)``).
    public var maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
    /// Which DEFLATE implementation decompresses.
    public var backend = ZipDecoder.Backend.bytes
}

/// Permissions and timestamps to apply to an extracted item.
struct ItemMetadata: Sendable {
    var permissions: Int?
    var modificationDate: Date?

    var isEmpty: Bool { permissions == nil && modificationDate == nil }
}

private struct FileJob: Sendable {
    let entry: ZipEntry
    let target: FilePath
    let metadata: ItemMetadata
}

extension ZipArchive {
    /// Extracts `entries` (all of them by default) beneath `destination`.
    ///
    /// Planning (path validation, directory creation, overwrite decisions, events) runs serially in
    /// archive order; regular files are then decompressed and written in parallel, then symlinks are
    /// created, then directory permissions and timestamps are applied, deepest first.
    ///
    /// Paths that are absolute or would leave `destination` (`..` traversal) are refused, and files are never
    /// written through symlinks. Parallelism is capped at 8 workers plus one per entry of 1 MB or more,
    /// and by `options.maxConcurrency`. Deflated entries of 4 MB or more overlap decoding with writing. A file
    /// that fails to extract is deleted; files extracted before the error stay.
    ///
    /// - Parameters:
    ///   - entries: The entries to extract; all of the archive's by default.
    ///   - destination: The directory to extract into, created if needed. A relative path is resolved
    ///     against the current directory.
    ///   - options: Path flattening, timestamps, overwrite policy, progress events, and concurrency.
    /// - Throws: ``ZipError/unsafePath(_:)`` for a path that escapes `destination` (checked during planning,
    ///   before any file is written); the errors of ``contents(of:using:_:)`` for damaged entries;
    ///   `Errno` or `CocoaError` for file system failures.
    public func extract(_ entries: [ZipEntry]? = nil, to destination: FilePath, options: ExtractionOptions = .init()) async throws {
        let root = (destination.isAbsolute ? destination : FilePath(FileManager.default.currentDirectoryPath).pushing(destination))
            .lexicallyNormalized()
        var directories = DirectoryCache()
        try directories.create(root)

        var files: [FileJob] = []
        var symlinks: [(entry: ZipEntry, relative: FilePath, target: FilePath)] = []
        var directoryMetadata: [(path: FilePath, metadata: ItemMetadata)] = []

        for entry in entries ?? self.entries {
            if options.junkPaths, entry.kind == .directory { continue }
            let relative = try Self.relativePath(for: entry, junkPaths: options.junkPaths)
            let target = try Self.resolve(relative, in: root, entry: entry)
            let metadata = ItemMetadata(
                permissions: entry.posixPermissions,
                modificationDate: options.restoreTimestamps ? entry.modificationDate : nil
            )

            switch entry.kind {
            case .directory:
                options.onEvent?(.creatingDirectory(entry, path: relative))
                try directories.create(target)
                // Applied last, so read-only directories and mtimes aren't disturbed by their contents.
                directoryMetadata.append((target, metadata))

            case .symlink:
                // Created after every file, so no entry can be written *through* an archive-supplied link.
                symlinks.append((entry, relative, target))

            case .file:
                try directories.create(target.removingLastComponent())
                guard try Self.clearExisting(entry, relative: relative, at: target, options: options) else { continue }
                options.onEvent?(.extracting(entry, path: relative))
                files.append(FileJob(entry: entry, target: target, metadata: metadata))
            }
        }

        // Creating files contends inside the filesystem beyond ~8 concurrent writers (measured: 8 workers
        // 106 ms, 32 workers 311 ms for 2,000 small files), while decompressing large entries scales
        // with cores. So use up to 8 workers, plus one per large entry beyond that.
        let largeFiles = files.count { $0.entry.uncompressedSize >= Self.largeEntrySize }
        let width = min(options.maxConcurrency, max(Self.fileCreationWidth, largeFiles))
        try await forEachConcurrently(files, maxConcurrency: width, backend: options.backend, weight: \.entry.uncompressedSize) {
            [self] job, decoder in try await write(job, using: &decoder)
        }

        for (entry, relative, link) in symlinks {
            try directories.create(link.removingLastComponent())
            guard try Self.clearExisting(entry, relative: relative, at: link, options: options) else { continue }
            let destination = try String(decoding: contents(of: entry, backend: options.backend), as: UTF8.self)
            options.onEvent?(.linking(entry, path: relative, destination: destination))
            // System has no symlink(2) wrapper, and Foundation's would normalize the name, so use Darwin.
            // Unsafe: C strings. Safe: both are NUL-terminated and valid for the call only.
            let status = unsafe link.withPlatformString { link in
                destination.withCString { unsafe symlink($0, link) }
            }
            guard status == 0 else { throw Errno(rawValue: errno) }
        }

        // Deepest first, so setting a parent's attributes isn't undone by changes to its children.
        for (directory, metadata) in directoryMetadata.sorted(by: { $0.path.components.count > $1.path.components.count })
            where !metadata.isEmpty {
            let descriptor = try FileDescriptor.open(directory, .readOnly, options: [.directory, .noFollow, .closeOnExec])
            try descriptor.closeAfter { try descriptor.apply(metadata) }
        }
    }

    static let fileCreationWidth = 8
    static let largeEntrySize: UInt64 = 1 << 20
    /// Deflated entries at least this big overlap decoding with writing (several chunks' worth).
    static let pipelineThreshold: UInt64 = 4 << 20

    /// Decompresses one file into place and applies its permissions and timestamp. Runs concurrently with
    /// other jobs.
    ///
    /// A partial file is deleted if anything fails.
    ///
    /// - Parameters:
    ///   - job: The entry, its target path, and its metadata.
    ///   - decoder: This worker's decoder.
    /// - Throws: `Errno` or `CocoaError` for file system failures, or the errors of
    ///   ``contents(of:using:_:)``.
    private func write(_ job: FileJob, using decoder: inout ZipDecoder) async throws {
        let options: FileDescriptor.OpenOptions = [.create, .truncate, .noFollow, .closeOnExec]
        let descriptor: FileDescriptor
        do {
            // FilePath passes the archive's name bytes through untouched (Foundation would normalize them).
            descriptor = try FileDescriptor.open(job.target, .writeOnly, options: options, permissions: [.ownerReadWrite, .groupRead, .otherRead])
        } catch let error as Errno where error == .tooManySymbolicLinkLevels {
            // `.noFollow` refused an existing symlink; overwriting means replacing the link, not its target.
            try FileManager.default.removeItem(atPath: job.target.string)
            descriptor = try FileDescriptor.open(job.target, .writeOnly, options: options, permissions: [.ownerReadWrite, .groupRead, .otherRead])
        }

        do {
            if job.entry.method == Method.deflated, job.entry.uncompressedSize >= Self.pipelineThreshold {
                // Write chunk N in a child task while chunk N+1 inflates. Unsafe: the chunk is a pointer into
                // the decoder's buffer, sent across tasks. Safe: the decoder doesn't reuse a buffer until its
                // consumer returns (see `ZipDecoder.inflatePipelined`).
                try await unsafe contentsPipelined(of: job.entry, using: &decoder) { chunk in
                    _ = try unsafe descriptor.writeAll(chunk.bytes)
                }
            } else {
                // Unsafe: System's `writeAll` takes a buffer pointer, not a span. Safe: read within the call.
                try contents(of: job.entry, using: &decoder) { chunk in
                    _ = try chunk.withUnsafeBytes { try unsafe descriptor.writeAll($0) }
                }
            }
            try descriptor.apply(job.metadata)
            try descriptor.close()
        } catch {
            try? descriptor.close()
            try? FileManager.default.removeItem(atPath: job.target.string)
            throw error
        }
    }

    /// Applies the overwrite policy to an existing item, removing it if it's to be replaced.
    ///
    /// Emits `.skipped` if the entry is to be skipped. A directory is left in place (so the later open fails)
    /// rather than deleted recursively.
    ///
    /// - Parameters:
    ///   - entry: The entry about to be extracted.
    ///   - relative: Its path relative to the destination, for events and the `ask` policy.
    ///   - target: Its absolute destination.
    ///   - options: The extraction options.
    /// - Returns: `false` if the entry should be skipped.
    /// - Throws: `CocoaError` if the existing item can't be removed.
    private static func clearExisting(_ entry: ZipEntry, relative: FilePath, at target: FilePath, options: ExtractionOptions) throws -> Bool {
        // Regular files under `.always` need no check: open truncates, and `write` handles existing symlinks.
        if case .always = options.overwrite, entry.kind == .file { return true }
        guard let existing = try? target.stat(followTargetSymlink: false) else { return true }

        switch options.overwrite {
        case .always:
            break
        case .never:
            options.onEvent?(.skipped(entry, path: relative))
            return false
        case let .ask(shouldOverwrite):
            guard shouldOverwrite(entry, relative) else {
                options.onEvent?(.skipped(entry, path: relative))
                return false
            }
        }
        // Never recursively delete a directory to make room for a file; let the open fail instead.
        if existing.type != .directory { try FileManager.default.removeItem(atPath: target.string) }
        return true
    }

    private static func relativePath(for entry: ZipEntry, junkPaths: Bool) throws(ZipError) -> FilePath {
        guard !entry.path.hasPrefix("/") else { throw .unsafePath(entry.path) }
        let path = FilePath(entry.path)
        guard junkPaths else { return path }
        guard let name = path.lastComponent else { throw .unsafePath(entry.path) }
        return FilePath(root: nil, [name])
    }

    /// Resolves a relative entry path inside `root`. `lexicallyResolving` returns nil for anything that
    /// would escape `root` (`..` traversal), which is exactly the "zip slip" check we need.
    ///
    /// - Parameters:
    ///   - relative: The entry's relative path.
    ///   - root: The extraction root.
    ///   - entry: The entry, for the error.
    /// - Returns: The absolute destination inside `root`.
    /// - Throws: ``ZipError/unsafePath(_:)`` if the path escapes `root` or resolves to `root` itself.
    private static func resolve(_ relative: FilePath, in root: FilePath, entry: ZipEntry) throws(ZipError) -> FilePath {
        guard let resolved = root.lexicallyResolving(relative), resolved != root else {
            throw .unsafePath(entry.path)
        }
        return resolved
    }
}

/// `mkdir -p` that remembers what it has created, so each directory costs one syscall per extraction
/// instead of one per path component per file.
struct DirectoryCache {
    private var known: Set<FilePath> = []

    /// Creates `path` and any missing parents with mode 0755, skipping ones already created.
    ///
    /// - Parameter path: The directory to create.
    /// - Throws: `Errno` if `mkdir` fails for a reason other than the directory already existing.
    mutating func create(_ path: FilePath) throws {
        guard !path.isEmpty, !known.contains(path) else { return }
        let parent = path.removingLastComponent()
        if parent != path { try create(parent) }
        // Foundation's path APIs decompose Unicode (NFD), so call mkdir(2) with the exact bytes. Unsafe: a C
        // string, NUL-terminated and valid for the call only.
        if unsafe path.withPlatformString({ unsafe mkdir($0, 0o755) }) != 0, errno != EEXIST {
            throw Errno(rawValue: errno)
        }
        known.insert(path)
    }
}

extension FileDescriptor {
    /// Sets permissions and timestamps through the open descriptor: two syscalls, no path lookups.
    ///
    /// Sets the access and modification times both to the entry's date. Fields that are `nil` are left alone.
    ///
    /// - Parameter metadata: The permissions and modification date to apply.
    /// - Throws: `Errno` if `fchmod` or `futimens` fails.
    func apply(_ metadata: ItemMetadata) throws {
        if let permissions = metadata.permissions, fchmod(rawValue, mode_t(permissions)) != 0 {
            throw Errno(rawValue: errno)
        }
        if let date = metadata.modificationDate {
            let seconds = date.timeIntervalSince1970.rounded(.down)
            let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
            let times: InlineArray<2, timespec> = [time, time] // access, modification
            // Unsafe: a C array argument. Safe: exactly the two elements futimens(2) reads, during the call.
            let status = times.span.withUnsafeBufferPointer { unsafe futimens(rawValue, $0.baseAddress) }
            if status != 0 { throw Errno(rawValue: errno) }
        }
    }
}
