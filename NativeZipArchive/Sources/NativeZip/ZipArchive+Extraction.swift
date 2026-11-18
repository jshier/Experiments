import Foundation
import Synchronization
import System

/// Something that happened while planning an extraction, for progress reporting. Events arrive in archive
/// order, as each archive is planned, before its files are written.
public enum ExtractionEvent {
    /// A directory is being created.
    case creatingDirectory(ZipEntry, path: FilePath)
    /// A file will be decompressed and written. Files are written in parallel after planning, so this
    /// precedes the write, not its completion.
    case extracting(ZipEntry, path: FilePath)
    /// A symbolic link will be created, pointing at `destination`.
    case linking(ZipEntry, path: FilePath, destination: String)
    /// An existing item (or an earlier entry with the same path) was kept, so the entry isn't extracted.
    case skipped(ZipEntry, path: FilePath)
    /// The entry's name was absolute or had `..` components, which were removed: it's extracted to `path`.
    case pathAdjusted(ZipEntry, path: FilePath)
}

/// What to do when an item already exists at an entry's destination: on disk, or planned by an earlier
/// entry (an archive can hold one name twice, or two names a case-insensitive volume treats as one).
public enum OverwritePolicy {
    /// Replace existing items without asking. (An existing directory is never removed to make room for a file.)
    case always
    /// Keep existing items and skip their entries.
    case never
    /// Ask per item; return `true` to replace it. Called serially, in archive order, during planning.
    case ask((_ entry: ZipEntry, _ path: FilePath) -> Bool)
}

/// Which entries to extract, given what's on disk: Info-ZIP's freshen (`-f`) and update (`-u`).
public enum UpdateMode: Sendable {
    /// Every entry.
    case all
    /// Only entries whose file exists and is older than the entry.
    case freshen
    /// Entries whose file is missing, or exists and is older than the entry.
    case update
}

/// Settings for one archive's extraction: ``ZipArchive/extract(_:to:options:)`` and ``ZipExtractor/add(_:entries:to:options:)``.
public struct ExtractionOptions {
    /// Creates options with the defaults below.
    public init() {}

    /// Flatten the archive: write every file into the destination root and skip directory entries.
    public var junkPaths = false
    /// Apply the archive's modification dates to extracted files and symbolic links' targets.
    public var restoreTimestamps = true
    /// Apply the archive's modification dates to directories.
    public var restoreDirectoryTimestamps = true
    /// Restore the recorded Unix owner and group (where permitted; failures are ignored, as Info-ZIP does).
    public var restoreOwnership = false
    /// Keep setuid, setgid, and sticky bits. Info-ZIP clears them unless asked (`-K`).
    public var keepSetIDBits = false
    /// Lowercase names: none, those from MS-DOS hosts written in uppercase only (Info-ZIP's `-L`), or all (`-LL`).
    public var lowercaseNames = LowercaseNames.none
    /// What to do when an item already exists. The default is ``OverwritePolicy/always``.
    public var overwrite = OverwritePolicy.always
    /// Which entries to extract given what's on disk.
    public var update = UpdateMode.all
    /// The password for encrypted entries.
    public var password: String?
    /// Progress reporting. Paths are relative to the destination.
    public var onEvent: ((ExtractionEvent) -> Void)?
    /// For ``ZipArchive/extract(_:to:options:)``: the most items processed at once. Extraction uses fewer when
    /// that's faster (see ``ZipExtractor``).
    public var maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
    /// Which DEFLATE implementation decompresses.
    public var backend = ZipDecoder.Backend.bytes

    public enum LowercaseNames: Sendable {
        case none, fromUppercaseHosts, all
    }
}

/// An entry that failed to extract, and why.
public struct ExtractionFailure: Error, Sendable, CustomStringConvertible {
    /// The archive the entry is in.
    public let archive: URL
    public let entry: ZipEntry
    /// Where it was to be written, relative to its destination.
    public let path: FilePath
    /// The error: a ``ZipError``, or `Errno` or `CocoaError` from the file system.
    public let error: any Error

    public var description: String { "\(path): \(error)" }
}

/// Permissions, timestamps, and ownership to apply to an extracted item.
struct ItemMetadata: Sendable {
    var permissions: Int?
    var modificationDate: Date?
    var owner: (uid: UInt32, gid: UInt32)?

    var isEmpty: Bool { permissions == nil && modificationDate == nil && owner == nil }
}

extension ZipArchive {
    /// Extracts `entries` (all of them by default) beneath `destination`.
    ///
    /// A ``ZipExtractor`` with one archive: see it for how the work is planned and spread across workers.
    /// The first failure is thrown (files extracted before it stay; the failing file is deleted).
    ///
    /// - Parameters:
    ///   - entries: The entries to extract; all of the archive's by default.
    ///   - destination: The directory to extract into, created if needed. A relative path is resolved
    ///     against the current directory.
    ///   - options: Path handling, timestamps, overwrite policy, password, progress events, concurrency.
    /// - Throws: The errors of ``contents(of:using:password:_:)`` for damaged entries; `Errno` or `CocoaError`
    ///   for file system failures.
    public func extract(_ entries: [ZipEntry]? = nil, to destination: FilePath, options: ExtractionOptions = .init()) async throws {
        _ = try await ZipExtractor.extract(maxConcurrency: options.maxConcurrency, stopOnFirstError: true) { extractor in
            try extractor.add(self, entries: entries, to: destination, options: options)
        }
    }
}

/// Extracts any number of archives with one pool of workers, writing files while it's still planning.
///
/// ``extract(maxConcurrency:stopOnFirstError:_:)`` starts the workers, then calls its closure, which adds
/// archives with ``add(_:entries:to:options:)``. Adding plans an archive serially, in archive order: it
/// sanitizes paths, creates directories, applies the overwrite and update policies (asking, if the policy
/// asks), reports events, and resolves entries that would land on the same item (the later one replaces the
/// earlier, or is skipped, per the policy). Each file is handed to the workers as soon as it's planned. After
/// the last file, symbolic links are created (after every file, so no entry is written through a link from an
/// archive), then directories' permissions and timestamps are applied, deepest first.
///
/// Paths are made safe as Info-ZIP does: a leading `/` and any `..` components are removed (reported as
/// ``ExtractionEvent/pathAdjusted(_:path:)``), and files are never written through symbolic links. A file
/// that fails to extract is deleted.
///
/// Parallelism: creating files contends inside the file system (measured: beyond about 8 concurrent writers,
/// small files got slower), while decompressing large entries scales with cores. So ``fileCreationWidth``
/// workers take any file, and the rest (up to `maxConcurrency`) take only large ones, largest first. A large
/// compressed entry overlaps decoding with writing and checksumming. (A large stored entry is copied in
/// pieces, but not in parallel: the kernel serializes writes to one file.)
public struct ZipExtractor: ~Copyable {
    private let queue: JobQueue
    private let stopOnFirstError: Bool
    private var directories = DirectoryCache()
    private var files: [FileJob] = []
    private var links: [LinkJob?] = []
    /// Replacements for files that were already being written when the replacing entry was planned: written
    /// after the pool finishes.
    private var deferred: [FileJob] = []
    private var directoryMetadata: [DirectoryJob] = []
    private var failures: [ExtractionFailure] = []
    /// Planned items by destination (case-folded on case-insensitive volumes): which job writes each.
    private var claims: [String: Claim] = [:]
    /// Each destination root: a number for claim keys, and whether its volume distinguishes case.
    private var roots: [FilePath: (index: Int, caseSensitive: Bool)] = [:]
    /// Decodes symbolic links' destinations during planning.
    private var linkDecoder: ZipDecoder?

    private enum Claim {
        case file(Int), link(Int)
    }

    private init(queue: JobQueue, stopOnFirstError: Bool) {
        self.queue = queue
        self.stopOnFirstError = stopOnFirstError
    }

    /// Extracts the archives `plan` adds.
    ///
    /// - Parameters:
    ///   - maxConcurrency: The most files processed at once.
    ///   - stopOnFirstError: Whether the first failure stops everything and is thrown, or failures are
    ///     collected and returned while everything else is extracted.
    ///   - plan: Adds archives with ``add(_:entries:to:options:)``. It runs while files are written.
    /// - Returns: Every failure, in plan order (empty if everything was extracted).
    /// - Throws: Whatever `plan` throws; with `stopOnFirstError`, the first failure's error.
    public static func extract(
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        stopOnFirstError: Bool = false,
        _ plan: (inout ZipExtractor) throws -> Void
    ) async throws -> [ExtractionFailure] {
        let maxConcurrency = max(1, maxConcurrency)
        let queue = JobQueue()
        let log = FailureLog()
        var extractor = ZipExtractor(queue: queue, stopOnFirstError: stopOnFirstError)
        var planningError: (any Error)?

        await withDiscardingTaskGroup { group in
            for worker in 0..<maxConcurrency {
                let takesSmallFiles = worker < fileCreationWidth
                group.addTask {
                    var decoders = WorkerDecoders()
                    while let job = await queue.next(takingSmallFiles: takesSmallFiles) {
                        await perform(job, decoders: &decoders, log: log, queue: queue, stopOnFirstError: stopOnFirstError)
                    }
                }
            }
            do {
                try plan(&extractor)
            } catch {
                planningError = error
                queue.abort()
            }
            queue.finish()
        }
        if stopOnFirstError, let error = log.firstError { throw error }
        if let planningError { throw planningError }
        return try await extractor.finish(log: log, maxConcurrency: maxConcurrency)
    }

    /// Plans an archive's extraction: see ``ZipExtractor``. Each file is handed to the workers once planned.
    ///
    /// - Parameters:
    ///   - archive: The archive.
    ///   - entries: The entries to extract; all of the archive's by default.
    ///   - destination: The directory to extract into, created if needed. A relative path is resolved against
    ///     the current directory.
    ///   - options: Path handling, timestamps, overwrite and update policies, password, and events.
    /// - Returns: The failures planning found (also returned by ``extract(maxConcurrency:stopOnFirstError:_:)``):
    ///   entries that can't be read, directories that couldn't be created, existing items that couldn't be
    ///   removed, symbolic links that couldn't be read.
    /// - Throws: With `stopOnFirstError`, the first failure's error (`CancellationError` if a worker's failure
    ///   stopped the extraction); `Errno` if `destination` can't be created.
    @discardableResult
    public mutating func add(_ archive: ZipArchive, entries: [ZipEntry]? = nil, to destination: FilePath, options: ExtractionOptions = .init()) throws -> [ExtractionFailure] {
        let root = (destination.isAbsolute ? destination : FilePath(FileManager.default.currentDirectoryPath).pushing(destination))
            .lexicallyNormalized()
        try directories.create(root)
        let rootKey = rootKey(root)
        let failureCount = failures.count

        for entry in entries ?? archive.entries {
            if queue.isAborted { throw CancellationError() }
            if options.junkPaths, entry.kind == .directory { continue }
            guard let (relative, adjusted) = Self.relativePath(for: entry, options: options) else {
                options.onEvent?(.pathAdjusted(entry, path: FilePath()))
                continue
            }
            if adjusted { options.onEvent?(.pathAdjusted(entry, path: relative)) }
            do {
                // `relative` has no `..` and isn't absolute, so this can't leave `root`; checked anyway.
                guard let target = root.lexicallyResolving(relative), target != root else { throw ZipError.unsafePath(entry.path) }
                try plan(entry, relative: relative, target: target, archive: archive, rootKey: rootKey, options: options)
            } catch {
                if stopOnFirstError { throw error }
                failures.append(ExtractionFailure(archive: archive.url, entry: entry, path: relative, error: error))
            }
        }
        return Array(failures[failureCount...])
    }

    private mutating func plan(
        _ entry: ZipEntry, relative: FilePath, target: FilePath, archive: ZipArchive, rootKey: (index: Int, caseSensitive: Bool),
        options: ExtractionOptions
    ) throws {
        let mask = options.keepSetIDBits ? 0o7777 : 0o777
        let metadata = ItemMetadata(
            permissions: entry.posixPermissions.map { $0 & mask },
            modificationDate: entry.modificationDate,
            owner: options.restoreOwnership ? entry.ownerID.flatMap { uid in entry.groupID.map { (uid, $0) } } : nil
        )

        if entry.kind == .directory {
            options.onEvent?(.creatingDirectory(entry, path: relative))
            try directories.create(target)
            // Applied last, so read-only directories and mtimes aren't disturbed by their contents.
            var metadata = metadata
            if !options.restoreDirectoryTimestamps { metadata.modificationDate = nil }
            directoryMetadata.append(DirectoryJob(path: target, depth: target.components.count, metadata: metadata))
            return
        }

        // Entries that can't be read fail here, before they're reported as being extracted.
        guard ZipArchive.Method.isSupported(entry.method) else { throw ZipError.unsupportedMethod(entry.method, entry.path) }
        if case .unsupported = entry.encryption { throw ZipError.unsupportedEncryption(entry.path) }
        if entry.isEncrypted, options.password == nil { throw ZipError.passwordRequired(entry.path) }

        try directories.create(target.removingLastComponent())
        guard try shouldUpdate(entry, at: target, mode: options.update) else { return }
        // The short relative path, not the absolute one: cheaper to hash. (Destinations nested inside one
        // another aren't matched up.)
        let relativeKey = relative.string
        let key = "\(rootKey.index)/" + (rootKey.caseSensitive ? relativeKey : relativeKey.lowercased())
        guard let decision = try resolveConflict(entry, relative: relative, target: target, key: key, options: options) else { return }

        var fileMetadata = metadata
        if !options.restoreTimestamps { fileMetadata.modificationDate = nil }
        if entry.kind == .symlink {
            // Read now (links are small), so the event can name the destination; created after every file.
            if linkDecoder == nil { linkDecoder = ZipDecoder(backend: options.backend) }
            var bytes: [UInt8] = []
            try archive.contents(of: entry, using: &linkDecoder!, password: options.password) { bytes.append(copying: $0) }
            let destination = String(decoding: bytes, as: UTF8.self)
            options.onEvent?(.linking(entry, path: relative, destination: destination))
            claims[key] = .link(links.count)
            links.append(LinkJob(archive: archive.url, entry: entry, relative: relative, target: target, destination: destination, owner: metadata.owner))
        } else {
            options.onEvent?(.extracting(entry, path: relative))
            claims[key] = .file(files.count)
            let job = FileJob(
                archive: archive, entry: entry, relative: relative, target: target, metadata: fileMetadata,
                password: options.password, backend: options.backend, order: files.count
            )
            files.append(job)
            if decision == .afterEarlier { deferred.append(job) } else { queue.push(job) }
        }
    }

    /// A destination root's number, and whether its volume distinguishes case (APFS volumes usually don't).
    private mutating func rootKey(_ root: FilePath) -> (index: Int, caseSensitive: Bool) {
        if let known = roots[root] { return known }
        // Unsafe: a C string, NUL-terminated and valid for the call only.
        let sensitive = unsafe root.withPlatformString { unsafe pathconf($0, _PC_CASE_SENSITIVE) } == 1
        let key = (roots.count, sensitive)
        roots[root] = key
        return key
    }

    /// Applies freshen or update: whether the entry is newer than the file at `target`.
    private func shouldUpdate(_ entry: ZipEntry, at target: FilePath, mode: UpdateMode) throws -> Bool {
        guard mode != .all else { return true }
        guard let existing = try? target.stat(followTargetSymlink: false) else { return mode == .update }
        guard let date = entry.modificationDate else { return true }
        // DOS times have 2-second resolution: an entry within a second of the file isn't newer.
        let modified = existing.rawValue.st_mtimespec
        let existingTime = Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9
        return date.timeIntervalSince1970 > existingTime + 1
    }

    private enum Decision {
        /// Write it when a worker is free.
        case now
        /// An earlier file at the same place is already being written: write this one after the pool finishes.
        case afterEarlier
    }

    /// Applies the overwrite policy to an item already at `target`, planned or on disk. A planned file that's
    /// to be replaced is cancelled if it hasn't started; one on disk is removed (a directory is left in place,
    /// so the later open fails, rather than deleted recursively).
    ///
    /// - Returns: `nil` if the entry is to be skipped (after reporting it).
    /// - Throws: `CocoaError` if an existing item can't be removed.
    private mutating func resolveConflict(
        _ entry: ZipEntry, relative: FilePath, target: FilePath, key: String, options: ExtractionOptions
    ) throws -> Decision? {
        func shouldReplace() -> Bool {
            switch options.overwrite {
            case .always: return true
            case .never: break
            case let .ask(shouldOverwrite): if shouldOverwrite(entry, relative) { return true }
            }
            options.onEvent?(.skipped(entry, path: relative))
            return false
        }

        if let claim = claims[key] {
            guard shouldReplace() else { return nil }
            switch claim {
            case let .file(index):
                if !files[index].cancel() { return .afterEarlier }
            case let .link(index):
                links[index] = nil
            }
            return .now
        }
        // Regular files under `.always` need no check: open truncates, and `write` handles existing symlinks.
        if case .always = options.overwrite, entry.kind == .file { return .now }
        guard let existing = try? target.stat(followTargetSymlink: false) else { return .now }
        guard shouldReplace() else { return nil }
        if existing.type != .directory { try FileManager.default.removeItem(atPath: target.string) }
        return .now
    }

    /// The path an entry is extracted to, relative to the destination: with a leading `/`, `.`, and `..`
    /// components removed (Info-ZIP's behavior), flattened or lowercased per `options`.
    ///
    /// - Returns: The path, and whether anything unsafe was removed; `nil` if nothing is left.
    private static func relativePath(for entry: ZipEntry, options: ExtractionOptions) -> (FilePath, adjusted: Bool)? {
        var name = entry.path
        switch options.lowercaseNames {
        case .none: break
        case .fromUppercaseHosts: if entry.hostSystem == 0, name.uppercased() == name { name = name.lowercased() }
        case .all: name = name.lowercased()
        }
        var adjusted = name.hasPrefix("/")
        var components: [Substring] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": adjusted = true
            default: components.append(component)
            }
        }
        if options.junkPaths, let last = components.last { components = [last] }
        guard !components.isEmpty else { return nil }
        return (FilePath(components.joined(separator: "/")), adjusted)
    }

    // MARK: Running

    /// Writes one file for a worker, recording a failure; with `stopOnFirstError`, a failure stops the queue.
    private static func perform(
        _ job: FileJob, decoders: inout WorkerDecoders, log: FailureLog, queue: JobQueue, stopOnFirstError: Bool
    ) async {
        guard job.start() else { return } // Replaced by a later entry.
        do {
            try await write(job, decoders: &decoders)
        } catch {
            log.record(ExtractionFailure(archive: job.archive.url, entry: job.entry, path: job.relative, error: error), order: job.order)
            if stopOnFirstError { queue.abort() }
        }
    }

    /// After the pool: deferred replacements, then symbolic links, then directories' metadata.
    private consuming func finish(log: FailureLog, maxConcurrency: Int) async throws -> [ExtractionFailure] {
        var decoders = WorkerDecoders()
        for job in deferred {
            await Self.perform(job, decoders: &decoders, log: log, queue: queue, stopOnFirstError: stopOnFirstError)
        }
        if stopOnFirstError, let error = log.firstError { throw error }

        let linkOrder = files.count
        let symlinks = links.compactMap(\.self)
        let width = min(maxConcurrency, Self.fileCreationWidth)
        try await Self.forEachConcurrently(symlinks, width: width, weight: { _ in 1 }) { link, _ in
            do {
                try Self.create(link)
            } catch {
                log.record(ExtractionFailure(archive: link.archive, entry: link.entry, path: link.relative, error: error), order: linkOrder)
            }
        }
        if stopOnFirstError, let error = log.firstError { throw error }

        // Deepest first, a level at a time, so setting a parent's attributes isn't undone by its children's.
        let levels = Dictionary(grouping: directoryMetadata.filter { !$0.metadata.isEmpty }, by: \.depth)
        for depth in levels.keys.sorted(by: >) {
            try await Self.forEachConcurrently(levels[depth]!, width: width, weight: { _ in 1 }) { job, _ in
                // Like Info-ZIP, a directory whose metadata can't be applied isn't an error.
                guard let descriptor = try? FileDescriptor.open(job.path, .readOnly, options: [.directory, .noFollow, .closeOnExec]) else { return }
                try? descriptor.closeAfter { try descriptor.apply(job.metadata) }
            }
        }
        return failures + log.sorted()
    }

    /// Creating files contends inside the file system beyond about 8 concurrent writers (measured: 8 workers
    /// 106 ms, 32 workers 311 ms for 2,000 small files; 4 and 8 the same for 20,000, 12 or more slower), while
    /// decompressing large entries scales with cores.
    static let fileCreationWidth = 8

    static let largeEntrySize: UInt64 = 1 << 20
    /// Compressed entries at least this big overlap decoding with writing (several chunks' worth).
    static let pipelineThreshold: UInt64 = 4 << 20
    /// Unencrypted stored entries bigger than this are copied in pieces of this size (see `copyStored`).
    static let storedPieceSize = 8 << 20

    /// Decompresses one file into place and applies its metadata. Runs concurrently with other jobs.
    ///
    /// A partial file is deleted if anything fails.
    ///
    /// - Throws: `Errno` or `CocoaError` for file system failures, or the errors of
    ///   ``ZipArchive/contents(of:using:password:_:)``.
    private static func write(_ job: FileJob, decoders: inout WorkerDecoders) async throws {
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
            let entry = job.entry
            if entry.method == ZipArchive.Method.stored, !entry.isEncrypted, entry.uncompressedSize > storedPieceSize {
                try copyStored(job, to: descriptor)
            } else if entry.method != ZipArchive.Method.stored, entry.uncompressedSize >= pipelineThreshold {
                // Write chunk N in a child task while chunk N+1 decodes. Unsafe: the chunk is a pointer into
                // the decoder's buffer, sent across tasks. Safe: the decoder doesn't reuse a buffer until its
                // consumer returns (see `ZipDecoder.decodePipelined`).
                try await decoders.withDecoder(job.backend) { decoder in
                    try await unsafe job.archive.contentsPipelined(of: entry, using: &decoder, password: job.password) { chunk in
                        _ = try unsafe descriptor.writeAll(chunk.bytes)
                    }
                }
            } else {
                try decoders.withDecoder(job.backend) { decoder in
                    // Unsafe: System's `writeAll` takes a buffer pointer, not a span. Safe: read within the call.
                    try job.archive.contents(of: entry, using: &decoder, password: job.password) { chunk in
                        _ = try chunk.withUnsafeBytes { try unsafe descriptor.writeAll($0) }
                    }
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

    /// Copies a large stored entry in pieces, each checksummed and then written while it's in cache.
    ///
    /// One whole-entry checksum, then one whole-entry write, read the 1 GB test entry from memory twice: 250 ms.
    /// In 8 MB pieces, 180 ms. Writing pieces in parallel gained nothing more: the kernel serializes writes to
    /// one file (1, 4, and 24 writers all took 178–180 ms, the parallel ones with more CPU time), and copying
    /// into a shared mapping of the file in parallel was slower (246 ms with 4 threads, 571 ms with 24).
    ///
    /// - Throws: ``ZipError/sizeMismatch(_:expected:actual:)``, ``ZipError/crcMismatch(_:expected:actual:)``,
    ///   the archive's errors for a damaged local header, or `Errno` from writing.
    private static func copyStored(_ job: FileJob, to descriptor: FileDescriptor) throws {
        let entry = job.entry
        let range = try job.archive.payloadRange(of: entry)
        guard UInt64(range.count) == entry.uncompressedSize else {
            throw ZipError.sizeMismatch(entry.path, expected: entry.uncompressedSize, actual: UInt64(range.count))
        }
        var crc: UInt = 0
        for start in stride(from: range.lowerBound, to: range.upperBound, by: storedPieceSize) {
            // Unsafe: a pointer into the mapping, which `job.archive` keeps alive for this call.
            let piece = unsafe job.archive.file.stableBuffer(start..<min(start + storedPieceSize, range.upperBound))
            crc = unsafe ZipDecoder.crc32(crc, RawSpan(_unsafeBytes: piece), backend: job.backend)
            _ = try unsafe descriptor.writeAll(piece)
        }
        guard crc == UInt(entry.crc32) || !entry.checksCRC else {
            throw ZipError.crcMismatch(entry.path, expected: entry.crc32, actual: UInt32(truncatingIfNeeded: crc))
        }
    }


    /// Creates a planned symbolic link.
    private static func create(_ link: LinkJob) throws {
        // System has no symlink(2) wrapper, and Foundation's would normalize the name, so use Darwin.
        // Unsafe: C strings. Safe: both are NUL-terminated and valid for the call only.
        let status = unsafe link.target.withPlatformString { path in
            link.destination.withCString { unsafe symlink($0, path) }
        }
        guard status == 0 else { throw Errno(rawValue: errno) }
        if let owner = link.owner {
            // Unsafe: a C string, as above. Like Info-ZIP, failing to set the owner isn't an error.
            _ = unsafe link.target.withPlatformString { unsafe lchown($0, owner.uid, owner.gid) }
        }
    }

    /// Runs `body` for every item using up to `width` child tasks, each with its own decoders, largest first
    /// (longest-processing-time scheduling: one big entry doesn't start last and leave the other workers idle
    /// while it finishes). With one worker, or one item, everything runs inline, in order. If `body` throws,
    /// the group cancels the other workers, which stop claiming items; items already started finish.
    static func forEachConcurrently<Item: Sendable>(
        _ items: [Item],
        width: Int,
        weight: (Item) -> UInt64,
        _ body: @escaping @Sendable (Item, inout WorkerDecoders) async throws -> Void
    ) async throws {
        let width = min(max(width, 1), items.count)
        guard width > 1 else {
            var decoders = WorkerDecoders()
            for item in items {
                try await body(item, &decoders)
            }
            return
        }
        let ordered = items.sorted { weight($0) > weight($1) }
        let queue = WorkQueue(count: ordered.count)
        try await withThrowingDiscardingTaskGroup { group in
            for _ in 0..<width {
                group.addTask {
                    var decoders = WorkerDecoders()
                    while !Task.isCancelled, let index = queue.claim() {
                        try await body(ordered[index], &decoders)
                    }
                }
            }
        }
    }
}

/// A file to write. A class: jobs are queued and handed to workers, and copying a struct's fields (some
/// resilient, like `Date?`) went through value witnesses.
final class FileJob: Sendable {
    /// 0 waiting, 1 started, 2 cancelled (replaced by a later entry before it started).
    private let state = Atomic<UInt8>(0)

    /// Claims the job for a worker. `false` if it was cancelled.
    func start() -> Bool { state.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged }

    /// Cancels the job. `false` if a worker has already started it.
    func cancel() -> Bool { state.compareExchange(expected: 0, desired: 2, ordering: .acquiringAndReleasing).exchanged }

    let archive: ZipArchive
    let entry: ZipEntry
    let relative: FilePath
    let target: FilePath
    let metadata: ItemMetadata
    let password: String?
    let backend: ZipDecoder.Backend
    /// For reporting failures in archive order: the job's place in the plan.
    let order: Int

    init(
        archive: ZipArchive, entry: ZipEntry, relative: FilePath, target: FilePath, metadata: ItemMetadata,
        password: String?, backend: ZipDecoder.Backend, order: Int
    ) {
        self.archive = archive
        self.entry = entry
        self.relative = relative
        self.target = target
        self.metadata = metadata
        self.password = password
        self.backend = backend
        self.order = order
    }
}

/// A symbolic link to create.
struct LinkJob: Sendable {
    let archive: URL
    let entry: ZipEntry
    let relative: FilePath
    let target: FilePath
    let destination: String
    let owner: (uid: UInt32, gid: UInt32)?
}

/// A directory whose metadata to apply.
struct DirectoryJob: Sendable {
    let path: FilePath
    let depth: Int
    let metadata: ItemMetadata
}

/// A worker's decoders, made on first use: one per DEFLATE backend.
struct WorkerDecoders: ~Copyable {
    private var bytes: ZipDecoder?
    private var zlib: ZipDecoder?

    init() {}

    mutating func withDecoder<R>(_ backend: ZipDecoder.Backend, _ body: (inout ZipDecoder) throws -> R) rethrows -> R {
        switch backend {
        case .bytes:
            if bytes == nil { bytes = ZipDecoder(backend: .bytes) }
            return try body(&bytes!)
        case .zlib:
            if zlib == nil { zlib = ZipDecoder(backend: .zlib) }
            return try body(&zlib!)
        }
    }

    mutating func withDecoder<R>(_ backend: ZipDecoder.Backend, _ body: (inout ZipDecoder) async throws -> R) async rethrows -> R {
        switch backend {
        case .bytes:
            if bytes == nil { bytes = ZipDecoder(backend: .bytes) }
            return try await body(&bytes!)
        case .zlib:
            if zlib == nil { zlib = ZipDecoder(backend: .zlib) }
            return try await body(&zlib!)
        }
    }
}

/// Failures from concurrent workers.
private final class FailureLog: Sendable {
    private let failures = Mutex<[(order: Int, failure: ExtractionFailure)]>([])

    func record(_ failure: ExtractionFailure, order: Int) {
        failures.withLock { $0.append((order, failure)) }
    }

    /// The error of the first failure recorded.
    var firstError: (any Error)? {
        failures.withLock { $0.first?.failure.error }
    }

    func sorted() -> [ExtractionFailure] {
        failures.withLock { $0.sorted { $0.order < $1.order }.map(\.failure) }
    }
}

/// Files waiting for workers, filled while planning goes on. Large files (``ZipExtractor/largeEntrySize`` or
/// more) are handed out largest first, so a big one doesn't start last and leave the other workers idle while
/// it finishes; small files in plan order. Workers that don't take small files wait for large ones.
final class JobQueue: Sendable {
    private struct State {
        var large: [FileJob] = []
        var small: [FileJob] = []
        var smallHead = 0
        var finished = false
        var aborted = false
        var anyWaiters: [CheckedContinuation<FileJob?, Never>] = []
        var largeWaiters: [CheckedContinuation<FileJob?, Never>] = []

        enum Take {
            case job(FileJob), done, wait
        }

        mutating func take(smallFiles: Bool) -> Take {
            if aborted { return .done }
            if !large.isEmpty {
                let index = large.indices.max { large[$0].entry.uncompressedSize < large[$1].entry.uncompressedSize }!
                large.swapAt(index, large.count - 1)
                return .job(large.removeLast())
            }
            if smallFiles, smallHead < small.count {
                defer { smallHead += 1 }
                return .job(small[smallHead])
            }
            return finished ? .done : .wait
        }
    }

    private let state = Mutex(State())

    /// Hands `job` to a waiting worker, or queues it.
    func push(_ job: FileJob) {
        let isLarge = job.entry.uncompressedSize >= ZipExtractor.largeEntrySize
        state.withLock { state in
            if isLarge, let waiter = state.largeWaiters.popLast() {
                waiter.resume(returning: job)
            } else if let waiter = state.anyWaiters.popLast() {
                waiter.resume(returning: job)
            } else if isLarge {
                state.large.append(job)
            } else {
                state.small.append(job)
            }
        }
    }

    /// The next job for a worker, waiting for planning if none is ready; `nil` once everything is done.
    func next(takingSmallFiles: Bool) async -> FileJob? {
        if case let .job(job) = state.withLock({ $0.take(smallFiles: takingSmallFiles) }) { return job }
        return await withCheckedContinuation { continuation in
            state.withLock { state in
                switch state.take(smallFiles: takingSmallFiles) {
                case let .job(job): continuation.resume(returning: job)
                case .done: continuation.resume(returning: nil)
                case .wait:
                    if takingSmallFiles { state.anyWaiters.append(continuation) } else { state.largeWaiters.append(continuation) }
                }
            }
        }
    }

    /// No more jobs are coming: waiting workers finish once the queue is empty.
    func finish() {
        state.withLock { state in
            state.finished = true
            for waiter in state.anyWaiters + state.largeWaiters {
                waiter.resume(returning: nil)
            }
            state.anyWaiters = []
            state.largeWaiters = []
        }
    }

    /// Stops handing out jobs (and planning, which checks ``isAborted``).
    func abort() {
        state.withLock { $0.aborted = true }
        finish()
    }

    var isAborted: Bool { state.withLock { $0.aborted } }
}

/// `mkdir -p` that remembers what it has created, so each directory costs one syscall per extraction
/// instead of one per path component per file.
struct DirectoryCache {
    private var known: Set<FilePath> = []
    /// The last directory asked for: files come in runs from one directory, so most lookups stop here.
    private var last = FilePath()

    /// Creates `path` and any missing parents with mode 0755, skipping ones already created.
    ///
    /// - Parameter path: The directory to create.
    /// - Throws: `Errno` if `mkdir` fails for a reason other than the directory already existing.
    mutating func create(_ path: FilePath) throws {
        guard path != last else { return }
        guard !path.isEmpty, !known.contains(path) else {
            last = path
            return
        }
        let parent = path.removingLastComponent()
        if parent != path { try create(parent) }
        // Foundation's path APIs decompose Unicode (NFD), so call mkdir(2) with the exact bytes. Unsafe: a C
        // string, NUL-terminated and valid for the call only.
        if unsafe path.withPlatformString({ unsafe mkdir($0, 0o755) }) != 0, errno != EEXIST {
            throw Errno(rawValue: errno)
        }
        known.insert(path)
        last = path
    }
}

extension FileDescriptor {
    /// Sets permissions, timestamps, and ownership through the open descriptor: no path lookups.
    ///
    /// Sets the access and modification times both to the entry's date. Fields that are `nil` are left alone.
    /// Failing to set the owner isn't an error (it needs privileges), as in Info-ZIP.
    ///
    /// - Parameter metadata: The permissions, modification date, and owner to apply.
    /// - Throws: `Errno` if `fchmod` or `futimens` fails.
    func apply(_ metadata: ItemMetadata) throws {
        if let owner = metadata.owner { _ = fchown(rawValue, owner.uid, owner.gid) }
        guard let date = metadata.modificationDate else {
            if let permissions = metadata.permissions, fchmod(rawValue, mode_t(permissions)) != 0 {
                throw Errno(rawValue: errno)
            }
            return
        }
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
        // Times and mode in one fsetattrlist(2) call instead of futimens and fchmod (one syscall fewer per
        // file). Its buffer holds the attributes in their bits' order: modification time, access time, mode.
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        var buffer = TimesAndMode(modification: time, access: time, mode: 0)
        if let permissions = metadata.permissions {
            attributes.commonattr |= attrgroup_t(ATTR_CMN_ACCESSMASK)
            buffer.mode = UInt32(permissions)
        }
        let size = metadata.permissions == nil ? MemoryLayout<TimesAndMode>.offset(of: \.mode)! : MemoryLayout<TimesAndMode>.size
        // Unsafe: pointers to two locals, valid for the call; `size` covers exactly the attributes requested.
        let status = withUnsafeMutablePointer(to: &attributes) { attributes in
            withUnsafeMutableBytes(of: &buffer) { buffer in
                unsafe fsetattrlist(rawValue, attributes, buffer.baseAddress, size, 0)
            }
        }
        if status != 0 { throw Errno(rawValue: errno) }
    }
}

/// fsetattrlist's buffer for ATTR_CMN_MODTIME, ATTR_CMN_ACCTIME, and ATTR_CMN_ACCESSMASK.
private struct TimesAndMode {
    var modification: timespec
    var access: timespec
    var mode: UInt32
}
