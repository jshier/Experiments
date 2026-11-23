internal import Bytes
import Disk
import Foundation
import System

/// Something that happened while planning an extraction, for progress reporting. Events arrive in archive
/// order, as each archive is planned, before its files are written.
public enum ZipExtractionEvent {
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

/// Settings for one archive's extraction: ``ZipArchive/extract(_:to:options:)`` and
/// ``ZipExtractor/add(_:entries:into:options:)``.
public struct ZipExtractionOptions {
    /// Creates options with the defaults below.
    public init() {}

    /// Flatten the archive: write every file into the destination root and skip directory entries.
    public var junkPaths = false
    /// Apply the archive's modification dates to extracted files and symbolic links' targets.
    public var restoresTimestamps = true
    /// Apply the archive's modification dates to directories.
    public var restoresDirectoryTimestamps = true
    /// Restore the recorded Unix owner and group (as root; otherwise ignored, as Info-ZIP's failures are).
    public var restoresOwnership = false
    /// Keep setuid, setgid, and sticky bits. Info-ZIP clears them unless asked (`-K`).
    public var keepsSpecialBits = false
    /// Lowercase names: none, those from MS-DOS hosts written in uppercase only (Info-ZIP's `-L`), or all (`-LL`).
    public var lowercaseNames = LowercaseNames.none
    /// What to do when an item already exists. The default is ``OverwritePolicy/always``.
    public var overwrite = OverwritePolicy.always
    /// Which entries to extract given what's on disk.
    public var update = UpdateMode.all
    /// The password for encrypted entries.
    public var password: String?
    /// Progress reporting. Paths are relative to the destination.
    public var onEvent: ((ZipExtractionEvent) -> Void)?
    /// For ``ZipArchive/extract(_:to:options:)`` and ``ZipArchive/extract(_:into:options:)``: the most files written at
    /// once (Disk's writers, each decoding its own). `nil`, the default: Disk's machine defaults, one writer per
    /// performance core with a quarter of them (2 to 6) in file system calls at once.
    public var maxConcurrency: Int?
    /// For ``ZipArchive/extract(_:to:options:)`` and ``ZipArchive/extract(_:into:options:)``: where entries and bytes
    /// are counted as they're written, for a client to poll (a timer reading `read()`; nothing is published). Its
    /// totals are set from the central directory before anything is written. ``ZipExtractor`` takes its own, for every
    /// archive it adds.
    ///
    /// (The `com.apple.quarantine` attribute everything extracted gets is the destination's: Disk's
    /// `DestinationOptions.quarantine`, for ``ZipArchive/extract(_:into:options:)``.)
    public var progress: ExtractionProgress?
    /// Merge AppleDouble entries into the items they describe instead of extracting them as files: `._NAME` beside
    /// `NAME`, or `__MACOSX/…/._NAME` (what `ditto -c -k` and the Finder's Compress write for extended attributes, Finder
    /// info, resource forks, and ACLs). On by default, as Archive Utility, `ditto -x -k`, and macOS's `unzip` do. An
    /// entry is merged only if it parses as AppleDouble and the archive holds its file, directory, or symbolic link;
    /// anything else named that way is extracted as the file it is. Every attribute the archive holds is restored,
    /// `com.apple.provenance` included (as `ditto -x` and `aa extract` restore it), and a link's go on the link itself
    /// (`ditto -x` drops them; Disk's `Planner` sets them without following it). Directory entries under `__MACOSX` aren't made (files extracted
    /// there make their parents). Off with ``junkPaths``.
    public var mergesAppleDouble = true
    /// Apply the archive's modification dates to symbolic links themselves, as Archive Utility does (Info-ZIP's `unzip`
    /// leaves a link the time it was made: the default).
    public var restoresLinkTimestamps = false
    /// Write names in the file system's decomposed form (`fileSystemRepresentation`: `Ü` as `U` and a combining
    /// diaeresis), as Archive Utility does, instead of the archive's own bytes (the default, as Info-ZIP's `unzip`).
    /// APFS finds a file by either form but keeps the bytes it was made with, which is what a listing returns.
    public var decomposesNames = false

    public enum LowercaseNames: Sendable {
        case none, fromUppercaseHosts, all
    }
}

/// An entry that failed to extract, and why.
public struct ZipExtractionFailure: Error, Sendable, CustomStringConvertible {
    /// The archive the entry is in.
    public let archive: URL
    public let entry: ZipEntry
    /// Where it was to be written, relative to its archive's destination.
    public let path: FilePath
    /// The error: the archive's data, or Disk's error from writing it (``ZipError/disk(_:)``).
    public let error: ZipError

    public var description: String { "\(path): \(error)" }
}

extension ZipArchive {
    /// Extracts `entries` (all of them by default) beneath `destination`.
    ///
    /// A ``ZipExtractor`` with one archive: see it for how the work is planned and written. The first failure is
    /// thrown (files extracted before it stay; a file that failed is removed).
    ///
    /// - Parameters:
    ///   - entries: The entries to extract; all of the archive's by default.
    ///   - destination: The directory to extract into, created if needed. A relative path is resolved
    ///     against the current directory.
    ///   - options: Path handling, timestamps, overwrite policy, password, events, concurrency, progress.
    /// - Throws: The errors of ``ZipArchive/contents(of:using:password:_:)-77zt7`` for damaged entries; ``ZipError/disk(_:)`` for file
    ///   system failures; ``ZipError/cancelled`` if the task is cancelled.
    @concurrent
    public func extract(_ entries: [ZipEntry]? = nil, to destination: FilePath, options: ZipExtractionOptions = .init()) async throws(ZipError) {
        _ = try await ZipExtractor.extract(
            into: destination, maxConcurrency: writers(for: entries, options), stopOnFirstError: true, progress: options.progress
        ) { (extractor) async throws(ZipError) in
            try await extractor.add(self, entries: entries, options: options)
        }
    }

    /// Extracts `entries` (all of them by default) into `destination`, a directory the caller opened (a staging
    /// directory an app publishes when it's done): as ``extract(_:to:options:)``, with NativeZip's policies on a
    /// duplicate of the destination's descriptor (`Destination.reopened(with:)`), so nothing is looked up by path.
    /// Everything extracted gets the destination's quarantine (its options'); the directory itself is left as it is.
    @concurrent
    public func extract(_ entries: [ZipEntry]? = nil, into destination: Destination, options: ZipExtractionOptions = .init()) async throws(ZipError) {
        _ = try await ZipExtractor.extract(
            into: destination, maxConcurrency: writers(for: entries, options), stopOnFirstError: true, progress: options.progress
        ) { (extractor) async throws(ZipError) in
            try await extractor.add(self, entries: entries, options: options)
        }
    }

    /// The writers for one archive: no more than files, since an idle writer still costs its task (about 6 mallocs and
    /// 1 system call each, and 1 M instructions for 23 of them: RESULTS.md, 2026-11-20 follow-ups).
    private func writers(for entries: [ZipEntry]?, _ options: ZipExtractionOptions) -> Int {
        options.maxConcurrency ?? max(1, min(DiskDefaults.writers, (entries ?? self.entries).count { $0.kind == .file }))
    }
}

/// Extracts any number of archives into one destination with one pool of writers, writing files while it's still
/// planning.
///
/// ``extract(into:maxConcurrency:stopOnFirstError:progress:_:)-(FilePath,_,_,_,_)`` opens the destination and starts Disk's writers
/// (`Extraction`), then calls its closure, which adds archives with ``add(_:entries:into:options:)``. Adding plans
/// an archive serially, in archive order: it sanitizes paths, applies the overwrite and update policies (asking, if the
/// policy asks), reports events, and resolves entries that would land on the same item (the later one replaces the
/// earlier, after it's written, or is skipped, per the policy). Each file is queued for the writers as soon as it's
/// planned; directories are made at once. After the last file, symbolic links are made (after every file, so no entry
/// is written through a link from an archive), then directories' permissions and timestamps, deepest first.
///
/// Paths are made safe as Info-ZIP does: a leading `/` and any `..` components are removed (reported as
/// ``ZipExtractionEvent/pathAdjusted(_:path:)``). Disk then makes every entry relative to the destination's descriptor,
/// refusing symbolic links anywhere in a path (`O_NOFOLLOW_ANY`) and anything outside it (`O_RESOLVE_BENEATH`). A file
/// that fails to extract is removed.
///
/// Parallelism (Disk's): writers decode their files (CPU work) outside a small limit of writers in file system calls at
/// once, since creating files contends inside APFS. A large compressed entry decodes in a child task while its writer
/// writes, and a large stored one is checksummed and written in 8 MiB pieces.
public struct ZipExtractor: ~Copyable {
    private var planner: Planner<ZipContentSource>
    private let destination: Destination
    private let source: ZipContentSource
    private let record: PlanRecord
    private let stopOnFirstError: Bool
    private let progress: ExtractionProgress?
    /// Whether the destination's volume distinguishes case (APFS volumes usually don't).
    private let caseSensitive: Bool
    /// The process's umask, for entries without a mode (0644 and 0755 less it, as `open` and `mkdir` would leave).
    private let umask: mode_t
    /// Planned items by destination (case-folded on case-insensitive volumes): which entry writes each.
    private var claims: [ClaimKey: Claim] = [:]
    /// Each archive subdirectory's number, for claim keys.
    private var roots: [String: Int] = [:]
    /// Decodes symbolic links' destinations during planning.
    private var linkDecoder: ZipDecoder?
    /// The entry's path in the destination, built here: the archive's subdirectory and `/`, then the cleaned name.
    private var path = [UInt8](repeating: 0, count: Int(PATH_MAX) * 2)

    private enum Claim {
        case file(tag: Int), link(Int)
    }

    fileprivate init(
        planner: consuming Planner<ZipContentSource>, destination: Destination, source: ZipContentSource, record: PlanRecord,
        stopOnFirstError: Bool, progress: ExtractionProgress?, caseSensitive: Bool
    ) {
        self.planner = planner
        self.destination = destination
        self.source = source
        self.record = record
        self.stopOnFirstError = stopOnFirstError
        self.progress = progress
        self.caseSensitive = caseSensitive
        umask = getumask()
    }

    /// Ends planning: the planner goes back to the extraction.
    fileprivate consuming func finish() -> Planner<ZipContentSource> {
        planner
    }

    /// Extracts the archives `plan` adds into `destination`.
    ///
    /// - Parameters:
    ///   - destination: The directory to extract into, created if needed. A relative path is resolved against the
    ///     current directory. Nothing extracted gets a quarantine: for one, open a `Destination` with it and use the
    ///     `Destination` form.
    ///   - maxConcurrency: The most files written at once (Disk's writers). `nil`: Disk's machine defaults (one per
    ///     performance core).
    ///   - stopOnFirstError: Whether the first failure stops everything and is thrown, or failures are
    ///     collected and returned while everything else is extracted.
    ///   - progress: Where entries and bytes are counted as they're written, for a client to poll. Each
    ///     ``add(_:entries:into:options:)`` adds its archive's entries and uncompressed bytes to the totals (from the
    ///     central directory) before planning them; entries it skips are taken off again.
    ///   - plan: Adds archives with ``add(_:entries:into:options:)``. It runs while files are written.
    /// - Returns: Every failure, in plan order (empty if everything was extracted).
    /// - Throws: Whatever `plan` throws; with `stopOnFirstError`, the first failure's error; ``ZipError/cancelled`` if
    ///   the task is cancelled; ``ZipError/disk(_:)`` if `destination` can't be made or opened, or a directory, link,
    ///   or the metadata after the writers fails.
    @concurrent
    public static func extract(
        into destination: FilePath,
        maxConcurrency: Int? = nil,
        stopOnFirstError: Bool = false,
        progress: ExtractionProgress? = nil,
        _ plan: (inout ZipExtractor) async throws(ZipError) -> Void
    ) async throws(ZipError) -> [ZipExtractionFailure] {
        let root = (destination.isAbsolute ? destination : FilePath(FileManager.default.currentDirectoryPath).pushing(destination))
            .lexicallyNormalized()
        let target: Destination
        do throws(DiskError) {
            target = try Destination(root, options: destinationOptions(quarantine: nil))
        } catch {
            throw ZipError(error)
        }
        return try await extract(target, maxConcurrency: maxConcurrency, stopOnFirstError: stopOnFirstError, progress: progress, plan)
    }

    /// Extracts the archives `plan` adds into `destination`, a directory the caller opened (a staging directory an app
    /// publishes when it's done), with NativeZip's policies on a duplicate of its descriptor (`Destination.reopened(with:)`):
    /// nothing is looked up by path.
    ///
    /// Everything extracted, every archive's entries, gets the destination's quarantine (its options'): Disk's writers
    /// set it on each file while it's open, and the passes after them on directories (the ones the archives don't
    /// list too) and links: one more call per entry (Disk/RESULTS.md: 13–17% on small files). The destination directory
    /// itself is left as its caller opened it.
    ///
    /// The other parameters, the result, and the errors are as for the `FilePath` form.
    @concurrent
    public static func extract(
        into destination: Destination,
        maxConcurrency: Int? = nil,
        stopOnFirstError: Bool = false,
        progress: ExtractionProgress? = nil,
        _ plan: (inout ZipExtractor) async throws(ZipError) -> Void
    ) async throws(ZipError) -> [ZipExtractionFailure] {
        let target: Destination
        do throws(DiskError) {
            target = try destination.reopened(with: destinationOptions(quarantine: destination.options.quarantine))
        } catch {
            throw ZipError(error)
        }
        return try await extract(target, maxConcurrency: maxConcurrency, stopOnFirstError: stopOnFirstError, progress: progress, plan)
    }

    /// NativeZip's policies for a destination, with `quarantine` on everything extracted.
    private static func destinationOptions(quarantine: Quarantine?) -> DestinationOptions {
        var options = DestinationOptions()
        // Planning applies the overwrite policy (an existing item it keeps isn't queued): what's left replaces.
        options.existingItems = .replace
        // Archived modes as they are, as Info-ZIP restores them (planning strips setuid, setgid, and sticky unless
        // asked, and gives entries without a mode the umask's).
        options.permissions = .exact
        options.keepsSpecialBits = true
        // Owners are in the metadata only when asked; Disk sets them only as root.
        options.restoresOwnership = true
        // What's extracted gets it; the destination itself doesn't (the caller's directory).
        options.quarantine = quarantine
        return options
    }

    /// The extraction into `target`, opened with ``destinationOptions(quarantine:)`` and closed here when Disk's extraction
    /// returns. `@concurrent`, as its callers are: the
    /// planning closure stays in their task's region, so Disk's extraction can take it.
    @concurrent
    private static func extract(
        _ target: Destination, maxConcurrency: Int?, stopOnFirstError: Bool, progress: ExtractionProgress?,
        _ plan: (inout ZipExtractor) async throws(ZipError) -> Void
    ) async throws(ZipError) -> [ZipExtractionFailure] {
        let caseSensitive = target.isCaseSensitive

        // Disk's defaults otherwise: writers make their scratch on their first job, and large-file slots on first use
        // (none here: files are written whole or streamed), so a small archive costs no more than it uses.
        let writers = max(1, maxConcurrency ?? DiskDefaults.writers)
        var options = ExtractionSettings()
        options.writers = writers
        options.fileSystemWidth = min(DiskDefaults.fileSystemWidth, writers)
        options.stopsOnFirstFailure = stopOnFirstError
        options.progress = progress
        let source = ZipContentSource(writers: writers)
        let record = PlanRecord()

        let report: ExtractionReport<ZipError>
        do throws(ExtractionError<ZipError, ZipError>) {
            report = try await Extraction.run(into: target, source: source, settings: options) {
                (planner: inout Planner<ZipContentSource>) async throws(ZipError) in
                var extractor = ZipExtractor(
                    planner: planner, destination: target, source: source, record: record, stopOnFirstError: stopOnFirstError,
                    progress: progress, caseSensitive: caseSensitive
                )
                do throws(ZipError) {
                    try await plan(&extractor)
                    try extractor.planLinks()
                } catch {
                    planner = extractor.finish()
                    throw error
                }
                planner = extractor.finish()
            }
        } catch {
            target.close()
            switch error {
            case .plan(let error), .source(let error): throw error
            case .disk(let error): throw ZipError(error)
            }
        }
        // The extraction's own descriptor (opened or reopened for it): its last use was Disk's last pass.
        target.close()

        // Disk's failures (writing, making directories and links), with the source's own errors for what it failed.
        var failures = record.failures
        for failure in report.failures {
            guard failure.tag >= 0, failure.tag < record.tags.count else { continue }
            let (jobIndex, entryIndex) = record.tags[failure.tag]
            let job = record.jobs[Int(jobIndex)]
            let error: ZipError = switch failure.error {
            case .disk(let error): ZipError(error)
            case .source(let error): error
            }
            let relative = failure.path.hasPrefix(job.prefix) ? String(failure.path.dropFirst(job.prefix.count)) : failure.path
            failures.append((failure.tag, ZipExtractionFailure(
                archive: job.archive.url, entry: job.entries[Int(entryIndex)], path: FilePath(relative), error: error
            )))
        }
        return failures.sorted { $0.tag < $1.tag }.map(\.failure)
    }

    /// Plans an archive's extraction: see ``ZipExtractor``. Each file is queued for the writers once planned
    /// (suspending while the queue is full).
    ///
    /// - Parameters:
    ///   - archive: The archive.
    ///   - entries: The entries to extract; all of the archive's by default.
    ///   - subdirectory: Where in the destination the archive goes (a relative path, made if needed); the destination
    ///     itself by default.
    ///   - options: Path handling, timestamps, overwrite and update policies, password, and events (its
    ///     `maxConcurrency` and `progress` are the extraction's, given to
    ///     ``extract(into:maxConcurrency:stopOnFirstError:progress:_:)-(FilePath,_,_,_,_)``).
    /// - Returns: The failures planning found (also returned by
    ///   ``extract(into:maxConcurrency:stopOnFirstError:progress:_:)-(FilePath,_,_,_,_)``): entries that can't be read, symbolic links
    ///   that couldn't be read. (Directories that couldn't be made are among the extraction's failures.)
    /// - Throws: With `stopOnFirstError`, the first failure's error; ``ZipError/cancelled`` if the task is cancelled;
    ///   ``ZipError/disk(_:)`` with `DiskError.unsafePath` for a `subdirectory` that isn't a relative path inside the
    ///   destination, and with `DiskError.stopped` once the extraction has stopped on another entry's failure (which
    ///   the extraction throws).
    @discardableResult
    public mutating func add(
        _ archive: ZipArchive, entries: [ZipEntry]? = nil, into subdirectory: FilePath = FilePath(), options: ZipExtractionOptions = .init()
    ) async throws(ZipError) -> [ZipExtractionFailure] {
        let selected = entries ?? archive.entries
        let prefix = subdirectory.lexicallyNormalized().string
        let prefixCount: Int
        do throws(DiskError) {
            prefixCount = try setPrefix(prefix)
        } catch {
            throw ZipError(error)
        }
        let rootIndex = roots[prefix] ?? roots.count
        roots[prefix] = rootIndex
        let job = ArchiveJob(
            archive: archive, entries: selected, password: options.password,
            prefix: prefixCount > 0 ? prefix + "/" : ""
        )
        let jobIndex = record.jobs.count
        record.jobs.append(job)
        source.state.reserve(tags: record.tags.count + selected.count)
        let failureCount = record.failures.count

        // The totals from the central directory, before anything of this archive is queued.
        var expected = (entries: 0, bytes: 0)
        for entry in selected where !(options.junkPaths && entry.kind == .directory) {
            expected.entries += 1
            if entry.kind == .file { expected.bytes += Int(clamping: entry.uncompressedSize) }
        }
        progress?.addExpected(entries: expected.entries, bytes: expected.bytes)
        var unplanned = (entries: 0, bytes: 0)
        let appleDoubles = options.mergesAppleDouble && !options.junkPaths ? readAppleDoubles(selected, job: job, options: options) : nil

        for (index, entry) in selected.enumerated() {
            if Task.isCancelled { throw .cancelled }
            if options.junkPaths, entry.kind == .directory { continue }
            let tag = record.tags.count
            record.tags.append((Int32(jobIndex), Int32(index)))
            let planned: Bool
            do throws(ZipError) {
                if let appleDoubles, appleDoubles.merged.contains(index) || (entry.kind == .directory && AppleDouble.isSequesterDirectory(entry.path)) {
                    // Merged into its item (or a `__MACOSX` directory, made only if something is extracted into it).
                    planned = false
                } else {
                    planned = try await plan(
                        entry, index: index, tag: tag, job: job, prefixCount: prefixCount, root: rootIndex, options: options,
                        appleDouble: appleDoubles?.attachments[index]
                    )
                }
            } catch {
                // The extraction is over (cancelled, or stopped by another entry's failure): not this entry's.
                if stopOnFirstError || error.isCancellation || error == .disk(.stopped) { throw error }
                record.failures.append((tag, ZipExtractionFailure(archive: archive.url, entry: entry, path: Self.cleaned(entry.path), error: error)))
                planned = false
            }
            if !planned {
                unplanned.entries += 1
                if entry.kind == .file { unplanned.bytes += Int(clamping: entry.uncompressedSize) }
            }
        }
        if unplanned.entries > 0 { progress?.addExpected(entries: -unplanned.entries, bytes: -unplanned.bytes) }
        return record.failures[failureCount...].map(\.failure)
    }

    /// The AppleDouble entries among `selected` that describe another selected entry: which entries they are (not
    /// extracted), and what each described entry gets. `nil` when there are none (the usual archive: one scan of the
    /// names). They're decoded here, during planning, as symbolic links are: small (attributes), except for a
    /// resource fork; one over 64 MB is left as a file.
    private mutating func readAppleDoubles(_ selected: [ZipEntry], job: ArchiveJob, options: ZipExtractionOptions) -> (merged: Set<Int>, attachments: [Int: AppleDouble])? {
        var candidates: [(index: Int, target: String)] = []
        for (index, entry) in selected.enumerated() where entry.kind == .file {
            guard entry.uncompressedSize >= 26, entry.uncompressedSize <= 64 << 20, let target = AppleDouble.target(of: entry.path) else { continue }
            candidates.append((index, target))
        }
        guard !candidates.isEmpty else { return nil }
        // Files, directories, and symbolic links by name (a directory's without its `/`). A link's AppleDouble file holds
        // its own attributes (`ditto -c` writes one for any link that has some, `com.apple.provenance` included): they
        // go on the link, as the archive's other attributes go on their items.
        var items: [String: Int] = [:]
        items.reserveCapacity(selected.count)
        for (index, entry) in selected.enumerated() {
            switch entry.kind {
            case .file, .symlink: items[entry.path] = index
            case .directory: items[entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path] = index
            }
        }
        var merged: Set<Int> = []
        var attachments: [Int: AppleDouble] = [:]
        for (index, target) in candidates {
            guard let item = items[target], item != index else { continue }
            let entry = selected[index]
            guard ZipArchive.Method.isSupported(entry.method), !entry.isEncrypted || options.password != nil else { continue }
            if linkDecoder == nil { linkDecoder = ZipDecoder() }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(entry.uncompressedSize))
            // One that can't be read is planned as a file, where its error is reported.
            guard (try? job.archive.contents(of: entry, using: &linkDecoder!, password: options.password) { bytes.append(copying: $0) }) != nil,
                  let appleDouble = AppleDouble(
                      bytes, skippingQuarantine: destination.options.quarantine != nil, keepsResourceFork: selected[item].kind == .file
                  )
            else { continue }
            merged.insert(index)
            if !appleDouble.isEmpty { attachments[item] = appleDouble }
        }
        return merged.isEmpty ? nil : (merged, attachments)
    }

    /// Puts the archive's subdirectory and a `/` at the front of the path buffer: its length.
    private mutating func setPrefix(_ prefix: String) throws(DiskError) -> Int {
        guard !prefix.isEmpty, prefix != "." else { return 0 }
        let bytes = Array(prefix.utf8)
        guard bytes.count < EntryPath.maximumByteCount else { throw .unsafePath(prefix) }
        _ = try EntryPath(validating: bytes.span.bytes)
        if path.count < bytes.count + 1 + Int(PATH_MAX) { path = [UInt8](repeating: 0, count: bytes.count + 1 + Int(PATH_MAX) * 2) }
        for (index, byte) in bytes.enumerated() { path[index] = byte }
        path[bytes.count] = UInt8(ascii: "/")
        return bytes.count + 1
    }

    /// Plans one entry.
    ///
    /// - Returns: Whether it was planned (`false`: skipped).
    private mutating func plan(
        _ entry: ZipEntry, index: Int, tag: Int, job: ArchiveJob, prefixCount: Int, root: Int, options: ZipExtractionOptions,
        appleDouble: AppleDouble?
    ) async throws(ZipError) -> Bool {
        // The name, cleaned, after the subdirectory.
        var name = entry.path
        switch options.lowercaseNames {
        case .none: break
        case .fromUppercaseHosts: if entry.hostSystem == 0, name.uppercased() == name { name = name.lowercased() }
        case .all: name = name.lowercased()
        }
        var renamed = options.lowercaseNames != .none
        if options.decomposesNames, !name.utf8.allSatisfy({ $0 < 0x80 }) {
            // Unsafe: `fileSystemRepresentation` returns a pointer to a C string. Safe: NUL-terminated, valid until the
            // autorelease pool drains (after this statement at the earliest); `String(cString:)` copies it at once.
            name = unsafe String(cString: (name as NSString).fileSystemRepresentation)
            renamed = true
        }
        let nameBytes = name.utf8.span.bytes
        if path.count < prefixCount + nameBytes.byteCount { path += [UInt8](repeating: 0, count: prefixCount + nameBytes.byteCount - path.count) }
        let sanitized: EntryPath.Sanitized
        do throws(DiskError) {
            sanitized = try path.withOutputRawSpan(overwritingFrom: prefixCount) { (output) throws(DiskError) in
                try EntryPath.sanitize(nameBytes, into: &output)
            }
        } catch {
            throw ZipError(error)
        }
        var nameCount = sanitized.count
        if options.junkPaths { nameCount = junkPath(at: prefixCount, count: nameCount) }
        let count = prefixCount + nameCount
        guard nameCount > 0 else {
            options.onEvent?(.pathAdjusted(entry, path: FilePath()))
            return false
        }
        if sanitized.adjusted { options.onEvent?(.pathAdjusted(entry, path: relativePath(prefixCount..<count))) }
        let entryPath = try Self.entryPath(path.span.bytes.extracting(0..<count))

        let mask: UInt16 = options.keepsSpecialBits ? 0o7777 : 0o777
        let defaultMode = mode_t(entry.kind == .directory ? 0o755 : 0o644) & ~umask
        var metadata = EntryMetadata(mode: entry.posixPermissions.map { UInt16(truncatingIfNeeded: $0) & mask } ?? UInt16(defaultMode))
        if options.restoresOwnership, let user = entry.ownerID, let group = entry.groupID { metadata.owner = Owner(user: user, group: group) }
        let time = entry.modificationTime
        if !time.isNaN {
            let seconds = time.rounded(.down)
            let stamp = Timestamp(seconds: Int64(seconds), nanoseconds: UInt32((time - seconds) * 1e9))
            metadata.times = EntryTimes(modification: stamp, access: stamp)
        }

        if entry.kind == .directory {
            options.onEvent?(.creatingDirectory(entry, path: relativePath(prefixCount..<count)))
            // Applied last, so read-only directories and mtimes aren't disturbed by their contents.
            if !options.restoresDirectoryTimestamps { metadata.times = EntryTimes() }
            do throws(DiskError) {
                let token = try planner.directory(entryPath, metadata: metadata, attachments: appleDouble != nil, tag: tag)
                if let appleDouble { try Self.attach(appleDouble, to: token, in: &planner) }
            } catch {
                throw ZipError(error)
            }
            return true
        }

        // Entries that can't be read fail here, before they're reported as being extracted.
        guard ZipArchive.Method.isSupported(entry.method) else { throw .unsupportedMethod(entry.method, entry.path) }
        if case .unsupported = entry.encryption { throw .unsupportedEncryption(entry.path) }
        if entry.isEncrypted, options.password == nil { throw .passwordRequired(entry.path) }

        // What's at the path now, looked up only when a policy needs it.
        var looked = false
        var existing: Destination.ExistingItem?
        if options.update != .all {
            existing = try? destination.existingItem(at: entryPath)
            looked = true
            if let existing {
                // DOS times have 2-second resolution: an entry within a second of the item isn't newer.
                let itemTime = Double(existing.modification.seconds) + Double(existing.modification.nanoseconds) / 1e9
                if !time.isNaN, time <= itemTime + 1 { return false }
            } else if options.update == .freshen {
                return false
            }
        }

        // The short relative name, not the whole path: cheaper to hash. For a clean name, the entry's own string (no
        // copy). (Subdirectories nested inside one another aren't matched up.)
        let isEntryName = nameCount == entry.path.utf8.count && !renamed
        let key = ClaimKey(root: root, path: isEntryName ? entry.path : String(decoding: path[prefixCount..<count], as: UTF8.self), caseSensitive: caseSensitive)

        // An earlier entry at the same place, or an item on disk: the entry replaces it (an earlier file once it's
        // written), or is skipped.
        var replaces: Int32 = -1
        var replacesItem = false
        if let claim = claims[key] {
            replacesItem = true
            if case let .link(link) = claim { record.links[link] = nil }
            if case let .file(earlier) = claim { replaces = Int32(earlier) }
        } else if case .always = options.overwrite, entry.kind == .file {
            // Nothing to ask: Disk replaces what's there (`.replace`: a file or link is unlinked; a directory stays, and
            // the file fails).
        } else {
            if !looked { existing = try? destination.existingItem(at: entryPath) }
            replacesItem = existing != nil
        }
        if replacesItem {
            var replace = false
            switch options.overwrite {
            case .always: replace = true
            case .never: break
            case let .ask(shouldOverwrite): replace = shouldOverwrite(entry, relativePath(prefixCount..<count))
            }
            guard replace else {
                options.onEvent?(.skipped(entry, path: relativePath(prefixCount..<count)))
                return false
            }
        }

        if !options.restoresTimestamps { metadata.times = EntryTimes() }
        if entry.kind == .symlink {
            // Read now (links are small), so the event can name the destination; made after every file.
            if linkDecoder == nil { linkDecoder = ZipDecoder() }
            var target: [UInt8] = []
            try job.archive.contents(of: entry, using: &linkDecoder!, password: options.password) { target.append(copying: $0) }
            options.onEvent?(.linking(entry, path: relativePath(prefixCount..<count), destination: String(decoding: target, as: UTF8.self)))
            claims[key] = .link(record.links.count)
            // As Info-ZIP does, only the owner (no mode) on the link; its time when asked (Archive Utility's).
            record.links.append(PlanRecord.Link(
                path: Array(path[0..<count]), target: target, owner: metadata.owner,
                times: options.restoresLinkTimestamps ? metadata.times : EntryTimes(), appleDouble: appleDouble, tag: tag
            ))
            return true
        }
        options.onEvent?(.extracting(entry, path: relativePath(prefixCount..<count)))
        claims[key] = .file(tag: tag)
        let contents = ZipContentSource.Contents(job: job, entry: Int32(index), tag: Int32(tag), replaces: replaces)
        do throws(DiskError) {
            let token = try await planner.file(
                entryPath, size: Int(clamping: entry.uncompressedSize), contents: contents, metadata: metadata, attachments: appleDouble != nil, tag: tag
            )
            if let appleDouble { try Self.attach(appleDouble, to: token, in: &planner) }
        } catch {
            throw ZipError(error)
        }
        return true
    }

    /// `bytes` as an entry's path: Disk's validation, its error as ``ZipError/disk(_:)``.
    @_lifetime(copy bytes)
    private static func entryPath(_ bytes: RawSpan) throws(ZipError) -> EntryPath {
        do throws(DiskError) {
            return try EntryPath(validating: bytes)
        } catch {
            throw ZipError(error)
        }
    }

    /// Gives a planned entry its AppleDouble file's attributes and ACL (Disk sets them after the writers).
    private static func attach(_ appleDouble: AppleDouble, to token: EntryToken, in planner: inout Planner<ZipContentSource>) throws(DiskError) {
        // An entry that failed (collected, not thrown) has nothing to add to.
        guard token != .none else { return }
        if !appleDouble.attributes.bytes.isEmpty { try planner.addExtendedAttributes(appleDouble.attributes.bytes.span.bytes, to: token) }
        if !appleDouble.accessControlList.isEmpty { try planner.addAccessControlList(appleDouble.accessControlList.span.bytes, to: token) }
    }

    /// An entry's name as planning cleans it (without the lowercasing or flattening options), for a failure's path.
    private static func cleaned(_ name: String) -> FilePath {
        var bytes = [UInt8](repeating: 0, count: name.utf8.count)
        let nameBytes = name.utf8.span.bytes
        let count = (try? bytes.withOutputRawSpan { (output) throws(DiskError) in try EntryPath.sanitize(nameBytes, into: &output).count }) ?? 0
        return FilePath(String(decoding: bytes[..<count], as: UTF8.self))
    }

    /// Bytes of the path buffer as a path, for events and questions (made only when asked for).
    private func relativePath(_ range: Range<Int>) -> FilePath {
        FilePath(String(decoding: path[range], as: UTF8.self))
    }

    /// Keeps only the last component of the cleaned name at `start` (`count` bytes) for ``ZipExtractionOptions/junkPaths``:
    /// its new length.
    private mutating func junkPath(at start: Int, count: Int) -> Int {
        var slash = start + count - 1
        while slash >= start, path[slash] != UInt8(ascii: "/") { slash -= 1 }
        guard slash >= start else { return count }
        let leaf = start + count - (slash + 1)
        for offset in 0..<leaf { path[start + offset] = path[slash + 1 + offset] }
        return leaf
    }

    /// Records the symbolic links planning kept (after every archive, so a later entry can still replace one): Disk
    /// makes them after the files.
    private mutating func planLinks() throws(ZipError) {
        for link in record.links {
            guard let link else { continue }
            let bytes = link.path
            let target = link.target
            do throws(DiskError) {
                let entryPath = try EntryPath(validating: bytes.span.bytes)
                let token = try planner.symbolicLink(
                    entryPath, target: target.span.bytes, metadata: EntryMetadata(owner: link.owner, times: link.times),
                    attachments: link.appleDouble != nil, tag: link.tag
                )
                if let appleDouble = link.appleDouble { try Self.attach(appleDouble, to: token, in: &planner) }
            } catch {
                throw ZipError(error)
            }
        }
    }
}

/// What planning keeps for the end of the extraction: archives, which entry each plan tag is, failures planning found,
/// and the symbolic links to make.
final class PlanRecord {
    struct Link {
        var path: [UInt8]
        var target: [UInt8]
        var owner: Owner?
        var times: EntryTimes
        /// The link's own AppleDouble file, merged: its attributes go on the link.
        var appleDouble: AppleDouble?
        var tag: Int
    }

    var jobs: [ArchiveJob] = []
    /// By plan tag: the archive (its index in `jobs`) and the entry (its index in the job's entries).
    var tags: [(job: Int32, entry: Int32)] = []
    var failures: [(tag: Int, failure: ZipExtractionFailure)] = []
    /// Symbolic links to make; `nil` for one a later entry replaced.
    var links: [Link?] = []
}

/// A destination, as its volume compares names: its root's number and its path relative to the root, with case
/// ignored where the volume ignores it (APFS's default).
///
/// Compared and hashed in place, ASCII case folded byte by byte: building a `"\(root)/\(path.lowercased())"` key
/// was two or three allocations per entry. A non-ASCII name on a case-insensitive volume falls back to
/// `lowercased()`, as before.
struct ClaimKey: Hashable {
    let root: Int
    let path: String
    let caseSensitive: Bool

    /// Whether every byte of `path` is ASCII.
    private var isASCII: Bool { path.utf8.allSatisfy { $0 < 0x80 } }

    /// An ASCII letter in lowercase; any other byte as it is.
    @inline(__always)
    private static func folded(_ byte: UInt8) -> UInt8 {
        byte &- UInt8(ascii: "A") < 26 ? byte | 0x20 : byte
    }

    static func == (lhs: ClaimKey, rhs: ClaimKey) -> Bool {
        guard lhs.root == rhs.root else { return false }
        if lhs.caseSensitive { return lhs.path == rhs.path }
        guard lhs.isASCII, rhs.isASCII else { return lhs.path.lowercased() == rhs.path.lowercased() }
        return lhs.path.utf8.elementsEqual(rhs.path.utf8) { folded($0) == folded($1) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(root)
        if caseSensitive {
            hasher.combine(path)
            return
        }
        // Case-folded bytes, 8 at a time. A non-ASCII name hashes its lowercased form the same way, so names
        // equal under `lowercased()` hash alike.
        func combine(_ bytes: some Sequence<UInt8>) {
            var word: UInt64 = 0
            var count = 0
            for byte in bytes {
                word = word &<< 8 | UInt64(Self.folded(byte))
                count &+= 1
                if count & 7 == 0 { hasher.combine(word); word = 0 }
            }
            hasher.combine(word)
            hasher.combine(count)
        }
        if isASCII { combine(path.utf8) } else { combine(path.lowercased().utf8) }
    }
}
