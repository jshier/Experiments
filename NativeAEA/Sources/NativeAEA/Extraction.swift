import Bytes
import BytesAsync
import Darwin
public import Disk
import Foundation
public import System

/// How extracted files are stored.
public enum DiskCompressionMode: String, Sendable, CaseIterable {
    /// As the archive asks (`AFT`): APFS-compressed files, as Apple's extractor writes them.
    case archived
    /// LZFSE resource forks for the files the archive compresses, whatever its codec (what unxip writes, for
    /// comparing with it; LZFSE takes about twice LZVN's time to compress, for smaller files).
    case lzfse
    /// Uncompressed files.
    case none

    /// How a file is stored, for the `decmpfs` type the archive asks for (`AFT`): by `aa extract`'s rules for its
    /// codec (Disk's `StoragePolicy.forArchivedType(_:)`; a `.xip`'s LZVN forks, which its walker asks for only over 16
    /// KiB, by `xip --expand`'s).
    @inline(__always)
    func storage(_ archived: UInt32?) -> Storage {
        switch self {
        case .none: return .plain
        case .archived:
            guard let archived, let policy = StoragePolicy.forArchivedType(archived) else { return .plain }
            return .compressed(policy)
        case .lzfse:
            guard let archived, DiskCodec(decmpfsType: archived) != nil else { return .plain }
            return .compressed(.appleArchiveLZFSE)
        }
    }
}

/// Settings for ``AEAArchive/extract(to:options:)``, ``AppleArchiveFile/extract(to:options:)``, and
/// ``XIPArchive/extract(to:options:)``. The tree is written by Disk (`Disk/ARCHITECTURE.md`): these map onto its
/// `ExtractionSettings` and `DestinationOptions`.
public struct AEAExtractionOptions: Sendable {
    public init() {}

    /// Decoding: decoders, decoder, input, checks.
    public var read = AEAReadOptions()
    /// How Disk writes: `writers` (child tasks writing files, and compressing them with
    /// ``DiskCompressionMode/archived``: one per performance core by default), `fileSystemWidth` (writers in file
    /// system calls at once; APFS contends beyond a few, so compression runs outside this limit and the calls inside
    /// it; also the width of the passes after the writers), `progress`, and `collectsTimings` (the writers' time per
    /// kind of work, in ``AEAStatistics/writerWork``).
    ///
    /// `progress` is where the extraction counts entries and bytes as they're written, for an app to poll (a timer
    /// reading `read()`): relaxed per-writer counters, nothing published. The extraction sets its totals. No archive
    /// here lists them up front, so the bytes start as an estimate, the size of the decoded stream the files are in
    /// (headers included, so a little high):
    /// - `.aea`: the payload's raw size from the root header (for a payload that's a `pbz` stream, its compressed size:
    ///   low);
    /// - `.aar`: the file's size (compressed, for `pbz`: low);
    /// - `.xip`: the cpio stream's size from the archive's `Metadata` (else `Content`'s stored size: low).
    ///
    /// Once the walk has read the whole stream, both totals become exact: the entries to make and the bytes of the
    /// files to write (each hard-linked file once). The walk runs ahead of the writers, so that's well before the end.
    public var disk = ExtractionSettings()
    /// How files are stored: compressed as the archive asks, or not.
    public var diskCompression = DiskCompressionMode.archived
    /// Replace existing files and links (otherwise an existing one is an error). Existing directories are reused.
    public var overwrite = false
    /// Restore the archived owner and group (root only).
    public var restoresOwnership = false
    /// Create entries relative to their parent directory's descriptor (each directory opened once) instead of by path
    /// from the destination (Disk's `DirectoryResolution.descriptors`). Off by default: it measured 3% slower on Xcode
    /// (an `open` per directory on the walker's critical path).
    public var relativeToParents = false
    /// For the `FilePath` forms of `extract`: copy the archive file's quarantine attribute onto everything extracted, as
    /// Apple's `aa extract` does (the destination directory too, for an `.aar`). A `.xip` copies none, as `xip --expand`.
    /// The forms that take a `Destination` ignore it: the destination's options say what everything gets (Disk's
    /// `DestinationOptions.quarantine`).
    public var copiesQuarantine = true
    /// Give the destination directory the mode, times, flags, and attributes of the archive's entry for its root (`aa
    /// archive -d DIR` writes one), as Archive Utility does for the folder it makes. Off by default: `aa extract` leaves
    /// the destination as it is.
    public var restoresDestinationMetadata = false
    /// For a `.xip`: give directories the modification times its cpio stream records. Off by default: `xip --expand`
    /// leaves every directory the time it was extracted. (Archive Utility sets them before it writes the files, so
    /// only directories holding nothing but directories keep them: 1,877 of Xcode 27.3's 30,068. NativeAEA/RESULTS.md,
    /// 2026-11-21.)
    public var restoresXIPDirectoryTimes = false

    /// ``disk``, with at least one writer and one in file system calls.
    var scheduling: ExtractionSettings {
        var settings = disk
        settings.writers = max(1, settings.writers)
        settings.fileSystemWidth = max(1, settings.fileSystemWidth)
        return settings
    }

    /// Writers that may hold a decoded buffer through a job: what the buffer pool adds for them.
    var heldBuffers: Int { max(1, disk.writers) }

    /// Disk's settings for the destination: Apple's extractors' (`aa extract`, `xip --expand`).
    func destination(quarantine: Quarantine?, quarantinesDestination: Bool) -> DestinationOptions {
        var options = DestinationOptions()
        options.existingItems = overwrite ? .replace : .fail
        // The archived mode exactly, special bits included, as `aa extract` restores it.
        options.permissions = .exact
        options.keepsSpecialBits = true
        options.restoresOwnership = restoresOwnership
        // Devices as root (`aa extract` makes them); otherwise skipped and counted.
        options.allowsDevices = true
        options.quarantine = quarantine
        options.quarantinesDestination = quarantinesDestination
        options.directoryResolution = relativeToParents ? .descriptors : .paths
        return options
    }
}

extension AEAArchive {
    /// Extracts the archive beneath `destination`, created if needed.
    ///
    /// Runs off the caller's actor, every part of it a child task of the calling task: ``AEAReadOptions/decodeThreads``
    /// decoders fill a fixed pool of buffers, and the calling task walks the stream in order and plans each entry for
    /// Disk's writers (``AEAExtractionOptions/disk``), files as references into the buffers (a file's bytes are
    /// never copied: they go from the decoded segment to `write`, or to the compressor). A file that spans segments is
    /// written in pieces as they arrive. Symbolic links are made last (so no file is written through one), then
    /// directories get their permissions, times, and flags.
    ///
    /// Cancelling the task stops every part promptly, releases the buffers, closes what's open, and throws
    /// ``AEAError/cancelled``; what was extracted until then stays.
    ///
    /// - Returns: Counts and timings.
    /// - Throws: ``AEAError``: a failed check, a malformed stream, an unsafe path, a file system error, or cancellation.
    @concurrent @discardableResult
    public func extract(to destination: FilePath, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        let source = try payload(options.read, heldBeyondDecoding: options.heldBuffers)
        // `aa extract` quarantines what's in the destination, not the destination itself, for an `.aea` (Xcode's,
        // compared item by item); for a plain `.aar` it quarantines the destination too.
        let target = try Extractor.open(destination, options: options, archivePath: path, quarantinesDestination: false)
        return try await Extractor.extract(source, into: target, options: options, expectedBytes: rootHeader.rawSize)
    }

    /// Extracts the archive into `destination`, a directory the caller opened (a staging directory an app publishes
    /// when it's done): as ``extract(to:options:)``, with the archive's policies (``AEAExtractionOptions``) on a
    /// duplicate of the destination's descriptor (`Destination.reopened(with:)`). Nothing is looked up by path.
    ///
    /// Everything extracted gets the destination's quarantine (its options'), whatever
    /// ``AEAExtractionOptions/copiesQuarantine`` says; the destination directory itself is left as its caller opened it.
    @concurrent @discardableResult
    public func extract(into destination: Destination, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        let source = try payload(options.read, heldBeyondDecoding: options.heldBuffers)
        let target = try Extractor.reopen(destination, options: options)
        return try await Extractor.extract(source, into: target, options: options, expectedBytes: rootHeader.rawSize)
    }
}

/// The archive format a decoded stream holds.
enum StreamFormat {
    /// Apple Archive (`AA01`/`YAA1` entries): `.aea` and `.aar`.
    case appleArchive
    /// cpio (odc): a `.xip`'s content.
    case cpio
}

extension StreamFormat {
    /// Walks `source`'s entries into `sink` with this format's walker.
    nonisolated(nonsending) func walk<Sink: ArchiveSink & ~Copyable>(_ source: some ChunkSource, into sink: inout Sink) async throws(AEAError) {
        switch self {
        case .appleArchive: try await ArchiveWalker.walk(source, into: &sink)
        case .cpio: try await CpioWalker.walk(source, into: &sink)
        }
    }
}

enum Extractor {
    /// The destination for the `FilePath` forms: `path` made if needed and opened with the options' policies, and the
    /// archive's quarantine when ``AEAExtractionOptions/copiesQuarantine`` asks.
    ///
    /// - Parameters:
    ///   - archivePath: The archive file, whose quarantine attribute is copied.
    ///   - quarantinesDestination: Whether the destination directory gets it too.
    static func open(_ path: FilePath, options: AEAExtractionOptions, archivePath: FilePath, quarantinesDestination: Bool) throws(AEAError) -> Destination {
        let quarantine = options.copiesQuarantine ? Quarantine(copyingFrom: archivePath) : nil
        do throws(DiskError) {
            return try Destination(path, options: options.destination(quarantine: quarantine, quarantinesDestination: quarantinesDestination))
        } catch {
            throw AEAError(error)
        }
    }

    /// The destination for the forms that take one: the caller's directory with the options' policies and the
    /// caller's quarantine.
    static func reopen(_ destination: Destination, options: AEAExtractionOptions) throws(AEAError) -> Destination {
        do throws(DiskError) {
            return try destination.reopened(with: options.destination(quarantine: destination.options.quarantine, quarantinesDestination: false))
        } catch {
            throw AEAError(error)
        }
    }

    /// Extracts the archive stream `source` decodes (not yet running) into `target`.
    ///
    /// The source's decoders run as child tasks while Disk's extraction runs: its writers, and the walk on this task as
    /// its plan, then the passes after the writers (links, deferred metadata, directories).
    ///
    /// - Parameters:
    ///   - format: What the stream holds.
    ///   - target: The destination, opened with ``AEAExtractionOptions``' policies (``open(_:options:archivePath:quarantinesDestination:)``
    ///     or ``reopen(_:options:)``), owned by this call: closed as soon as Disk's extraction returns.
    ///   - expectedBytes: The estimate of the files' bytes the progress (`options.disk.progress`) starts with.
    nonisolated(nonsending) static func extract(
        _ source: some ChunkSource, format: StreamFormat = .appleArchive, into target: Destination, options: AEAExtractionOptions,
        expectedBytes: Int = 0
    ) async throws(AEAError) -> AEAStatistics {
        let started = MonotonicClock.now
        options.disk.progress?.setExpected(entries: 0, bytes: max(0, expectedBytes))
        let outcome: Result<AEAStatistics, AEAError> = await source.withDecoding { _ in
            do throws(AEAError) {
                return .success(try await extract(source, format: format, into: target, options: options))
            } catch {
                return .failure(error)
            }
        }
        // The extraction's own descriptor (opened or reopened for it): its last use was Disk's last pass.
        target.close()
        var statistics = try outcome.get()
        statistics.seconds = MonotonicClock.seconds(since: started)
        statistics.unreleasedBuffers = source.pools.reduce(0) { $0 + $1.buffersInUse }
        return statistics
    }

    /// The extraction inside the decoding: once the source knows its pool, Disk's extraction with the walk as its plan.
    nonisolated(nonsending) private static func extract(
        _ source: some ChunkSource, format: StreamFormat, into destination: Destination, options: AEAExtractionOptions
    ) async throws(AEAError) -> AEAStatistics {
        try await source.prepare()
        let pool = source.pool
        var walked = AEAStatistics()
        var compression = DiskCompressionCounts()
        let report: ExtractionReport<Never>
        do throws(ExtractionError<AEAError, Never>) {
            report = try await Extraction.run(into: destination, source: SegmentContents(pool: pool), settings: options.scheduling) {
                (planner: inout Planner<SegmentContents>) async throws(AEAError) in
                // The sink holds the planner while the walk runs, and hands it back after.
                var sink = ExtractionSink(planner, pool: pool, options: options, keepsDirectoryTimes: format != .cpio || options.restoresXIPDirectoryTimes)
                var failure: AEAError?
                do throws(AEAError) {
                    try await format.walk(source, into: &sink)
                } catch {
                    failure = error
                }
                // No more chunks are taken: the decoders end (at once after a failure) while the writers finish.
                source.stop(nil)
                walked = sink.statistics
                compression = sink.diskCompression
                planner = sink.finish(walked: failure == nil)
                if let failure { throw failure }
            }
        } catch {
            switch error {
            case .disk(let error): throw AEAError(error)
            case .plan(let error): throw error
            // The segments' source can't fail (its contents are decoded and checked before they're planned).
            case .source(let impossible): switch impossible {}
            }
        }
        var statistics = walked
        compression.add(to: &statistics.filesByDiskCompression)
        statistics.specialFiles = report.specialFiles
        statistics.skippedEntries += report.skipped
        statistics.unquarantinedItems = report.unquarantinedItems
        statistics.phaseSeconds = report.phaseSeconds
        statistics.writerWork = report.writerSeconds
        statistics.writeSeconds = report.writerSeconds.values.reduce(0, +)
        statistics.walkSeconds = report.phaseSeconds[.planning] ?? 0
        statistics.walkWaitForWriters = report.plannerWaitSeconds
        statistics.decodeSeconds = Double(source.counters.busy.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(source.counters.read.load(ordering: .relaxed)) / 1e9
        statistics.walkWaitForSegments = Double(source.counters.wait.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = pool.peakInUse.load(ordering: .relaxed)
        return statistics
    }
}

// MARK: - Contents

/// Files' contents as Disk's writers get them: ranges of decoded segment buffers, each held by a reference the job
/// owns (the walker retains a buffer for each job that names it; the writer releases it once written).
///
/// A whole file is one range; a small file across a segment boundary is two, written as two `FileOutput.write`s
/// (Disk gathers them in the writer's staging buffer); a large file is a piece per segment (Disk's `PieceSource`),
/// compressed in place over its own consumed bytes, which no one else reads.
struct SegmentContents: PieceSource {
    let pool: SegmentBufferPool

    /// One or two ranges of buffers: offsets from each buffer's segment base.
    struct Contents: Sendable {
        var buffer = -1
        var offset = 0
        var count = 0
        var secondBuffer = -1
        var secondOffset = 0
        var secondCount = 0
    }

    func write(_ contents: Contents, to output: inout FileOutput) async throws(EntryError<Never>) {
        do throws(DiskError) {
            if contents.buffer >= 0 {
                // The job's reference keeps the buffer's bytes until `release`, after the write.
                try await output.write(pool.bytes(contents.buffer, at: contents.offset, count: contents.count))
            }
            if contents.secondBuffer >= 0 {
                // Same, for the second buffer.
                try await output.write(pool.bytes(contents.secondBuffer, at: contents.secondOffset, count: contents.secondCount))
            }
        } catch {
            throw .disk(error)
        }
    }

    func release(_ contents: Contents) {
        if contents.buffer >= 0 { pool.release(contents.buffer) }
        if contents.secondBuffer >= 0 { pool.release(contents.secondBuffer) }
    }

    func retain(_ contents: Contents) {
        // Pieces only: one range.
        pool.retain(contents.buffer)
    }

    func withPiece<R>(_ contents: Contents, _ body: (inout MutableRawSpan) throws(DiskError) -> R) throws(DiskError) -> R {
        // A piece's range of its buffer, held by the job until its last release, and read by no one else (the walker
        // reads only past it, and the buffer's next user gets it after the release).
        try pool.withMutableBytes(contents.buffer, at: contents.offset, count: contents.count, body)
    }
}

// MARK: - The walker's side

/// Plans the walked entries for Disk: directories, links, and special files from their headers; files as their data
/// arrives (whole, in two ranges, or in pieces); hard links to the first name; blobs (extended attributes, ACLs) added
/// to their entry once it ends.
struct ExtractionSink: ArchiveSink, ~Copyable {
    private var planner: Planner<SegmentContents>
    let pool: SegmentBufferPool
    private let mode: DiskCompressionMode
    private let restoresOwnership: Bool
    private let restoresDestinationMetadata: Bool
    /// Whether directories get their archived times (not a `.xip`'s, unless asked).
    private let keepsDirectoryTimes: Bool
    private let progress: ExtractionProgress?
    /// Files up to this size are written whole even when they cross a segment boundary (they span two at most).
    private let smallSpanLimit: Int
    /// The segments' size: every piece of a large file but the first and last is a whole segment.
    private let segmentSize: Int
    var statistics = AEAStatistics()
    /// Files by on-disk compression, for ``AEAStatistics/filesByDiskCompression`` at the end.
    var diskCompression = DiskCompressionCounts()

    /// The current entry's path, copied from its header: a file's data can arrive after the walker has released the
    /// header's buffer (a header that ends a segment), and planning it copies the path again.
    /// (`PATH_MAX` bytes, the first `pathCount` of them the path; bound to a local constant to plan: its span then
    /// borrows the constant, not the sink, so the planner can be called while it's alive.)
    private var path = [UInt8](repeating: 0, count: Int(PATH_MAX))
    private var pathCount = 0
    private var entry = AAEntryHeader()
    private var tag = 0
    // The current file:
    private var metadata = EntryMetadata()
    private var storage = Storage.plain
    private var attachments = false
    /// Its hard-link cluster, for its first name: the later names link to it.
    private var cluster: UInt64?
    /// A later name of a hard-linked file: its contents aren't written.
    private var skipContents = false
    private var largeFile: LargeFileToken?
    /// A small file whose first range has arrived, waiting for its second (its reference held).
    private var pending: SegmentContents.Contents?
    /// The current entry, to add its blobs to.
    private var token = EntryToken.none
    /// The current entry's blobs, gathered until it ends (a file is planned only when its data arrives, and blobs can
    /// come first).
    private var acceptsBlobs = false
    private var blobs: [UInt8] = []
    private var extendedAttributes = 0..<0
    private var accessControlList = 0..<0
    /// Each hard-link cluster's first name.
    private var hardLinkTargets: [UInt64: EntryToken] = [:]
    /// The exact totals, known once the walk ends: entries to make, bytes to write.
    private var plannedEntries = 0
    private var plannedBytes = 0

    init(_ planner: consuming Planner<SegmentContents>, pool: SegmentBufferPool, options: AEAExtractionOptions, keepsDirectoryTimes: Bool) {
        self.planner = planner
        self.pool = pool
        mode = options.diskCompression
        restoresOwnership = options.restoresOwnership
        restoresDestinationMetadata = options.restoresDestinationMetadata
        self.keepsDirectoryTimes = keepsDirectoryTimes
        progress = options.disk.progress
        segmentSize = pool.segmentCapacity
        // A batch of chunks (1 MiB, Disk's staging buffer), or a segment if that's smaller.
        smallSpanLimit = min(1 << 20, pool.segmentCapacity)
    }

    /// After the walk: releases what's held for a file that never got its second range, sets the progress's exact
    /// totals if the walk got to the end, and hands the planner back.
    consuming func finish(walked: Bool) -> Planner<SegmentContents> {
        if let pending {
            if pending.buffer >= 0 { pool.release(pending.buffer) }
            if pending.secondBuffer >= 0 { pool.release(pending.secondBuffer) }
        }
        if walked, let progress {
            progress.setExpected(entries: plannedEntries, bytes: plannedBytes)
        }
        return planner
    }

    private static func metadata(_ entry: AAEntryHeader, owner: Bool) -> EntryMetadata {
        EntryMetadata(
            mode: entry.mode.map { $0 & 0o7777 },
            owner: owner ? Owner(user: entry.uid ?? 0, group: entry.gid ?? 0) : nil,
            times: EntryTimes(
                modification: entry.modificationTime.map { Timestamp(seconds: $0.seconds, nanoseconds: $0.nanoseconds) },
                creation: entry.creationTime.map { Timestamp(seconds: $0.seconds, nanoseconds: $0.nanoseconds) }
            ),
            flags: entry.flags ?? 0
        )
    }

    nonisolated(nonsending) mutating func entry(_ entry: AAEntryHeader, header: RawSpan, buffer: Int) async throws(AEAError) {
        statistics.entries += 1
        guard let range = entry.path, let type = entry.type else { throw .invalidArchive("an entry without a type or path") }
        let name = header.extracting(range.offset..<(range.offset + range.count))
        guard range.count <= EntryPath.maximumByteCount else {
            throw .unsafePath(String(decoding: [UInt8](copying: name), as: UTF8.self))
        }
        var pathBytes = path.mutableSpan
        pathBytes.copyBytes(from: name, toByteOffset: 0) // Under PATH_MAX (checked above).
        pathCount = range.count
        self.entry = entry
        tag = statistics.entries
        token = .none
        skipContents = false
        cluster = nil
        largeFile = nil
        acceptsBlobs = false
        blobs.removeAll(keepingCapacity: true)
        extendedAttributes = 0..<0
        accessControlList = 0..<0
        let hasAttributes = (entry.extendedAttributes?.count ?? 0) > 0, hasACL = (entry.accessControlList?.count ?? 0) > 0
        if hasAttributes { statistics.withExtendedAttributes += 1 }
        if hasACL { statistics.withAccessControlLists += 1 }
        let hasBlobs = hasAttributes || hasACL
        if type == .symbolicLink, entry.linkTarget == nil { throw .invalidArchive("a link without a target") }
        let pathStorage = path
        do throws(DiskError) {
            let entryPath = try EntryPath(validating: pathStorage.span.bytes.extracting(0..<pathCount))
            switch type {
            case .regularFile:
                let size = entry.data?.count ?? 0
                statistics.files += 1
                statistics.fileBytes += size
                diskCompression.count(entry.diskCompression)
                if let id = entry.hardLinkCluster {
                    statistics.hardLinks += 1
                    if let target = hardLinkTargets[id] {
                        // A later name for a file already planned: linked after the writers, its copy of the contents
                        // skipped.
                        skipContents = true
                        try planner.hardLink(entryPath, to: target, tag: tag)
                        plannedEntries += 1
                        return
                    }
                    cluster = id
                }
                metadata = Self.metadata(entry, owner: restoresOwnership)
                storage = mode.storage(entry.diskCompression)
                attachments = hasBlobs
                acceptsBlobs = hasBlobs
                plannedEntries += 1
                plannedBytes += size
            case .directory:
                statistics.directories += 1
                // The destination itself: left as it is (as before Disk; `aa extract` compares the same) unless asked.
                guard pathCount > 0 || restoresDestinationMetadata else { return }
                var metadata = Self.metadata(entry, owner: restoresOwnership)
                if !keepsDirectoryTimes { metadata.times = EntryTimes() }
                token = try planner.directory(entryPath, metadata: metadata, attachments: hasBlobs, tag: tag)
                acceptsBlobs = hasBlobs
                plannedEntries += 1
            case .symbolicLink:
                statistics.symbolicLinks += 1
                let target = entry.linkTarget! // Checked above.
                // Within the header, valid for the call (the planner copies it).
                let targetBytes = header.extracting(target.offset..<(target.offset + target.count))
                token = try planner.symbolicLink(entryPath, target: targetBytes, metadata: Self.metadata(entry, owner: restoresOwnership), attachments: hasBlobs, tag: tag)
                acceptsBlobs = hasBlobs
                plannedEntries += 1
            case .fifo, .characterDevice, .blockDevice:
                statistics.otherEntries += 1
                let kind: SpecialFileKind = switch type {
                case .fifo: .fifo
                case .characterDevice: .characterDevice(entry.device ?? 0)
                default: .blockDevice(entry.device ?? 0)
                }
                try planner.specialFile(entryPath, kind, metadata: Self.metadata(entry, owner: restoresOwnership), tag: tag)
                plannedEntries += 1
            default:
                // Sockets (a bound socket can't be made from an archive), whiteouts, doors, ports, metadata entries.
                statistics.otherEntries += 1
                statistics.skippedEntries += 1
            }
        } catch {
            throw AEAError(error)
        }
    }

    /// Queues the current file, whose contents are `contents` (their references taken: the planner owns them now).
    nonisolated(nonsending) private mutating func planFile(size: Int, contents: SegmentContents.Contents) async throws(DiskError) {
        let pathStorage = path
        let entryPath: EntryPath
        do throws(DiskError) {
            entryPath = try EntryPath(validating: pathStorage.span.bytes.extracting(0..<pathCount))
        } catch {
            SegmentContents(pool: pool).release(contents)
            throw error
        }
        token = try await planner.file(
            entryPath, size: size, contents: contents, metadata: metadata, storage: storage, attachments: attachments,
            hardLinked: cluster != nil, tag: tag
        )
        if let cluster { hardLinkTargets[cluster] = token }
    }

    nonisolated(nonsending) mutating func data(_ bytes: RawSpan, offset: Int, fileOffset: Int, buffer: Int, segment: Int) async throws(AEAError) {
        guard entry.type == .regularFile, !skipContents, let data = entry.data else { return }
        let size = data.count
        let count = bytes.byteCount
        if var contents = pending {
            // The second range of a small file across a segment boundary.
            pending = nil
            pool.retain(buffer)
            contents.secondBuffer = buffer
            contents.secondOffset = offset
            contents.secondCount = count
            guard fileOffset == contents.count, fileOffset + count == size else {
                SegmentContents(pool: pool).release(contents)
                throw .invalidArchive("a small file spans more than two segments")
            }
            do throws(DiskError) {
                try await planFile(size: size, contents: contents)
            } catch {
                throw AEAError(error)
            }
            return
        }
        do throws(DiskError) {
            if fileOffset == 0, count == size {
                // The whole file in one buffer: one job.
                pool.retain(buffer)
                try await planFile(size: size, contents: SegmentContents.Contents(buffer: buffer, offset: offset, count: count))
                return
            }
            if fileOffset == 0, size <= smallSpanLimit {
                // A small file across a segment boundary: one job with two ranges, queued with the second.
                pool.retain(buffer)
                pending = SegmentContents.Contents(buffer: buffer, offset: offset, count: count)
                return
            }
            if fileOffset == 0 {
                // A large file: opened now, written a piece per segment as they arrive (pieces compress in parallel).
                let pathStorage = path
                let file = try await planner.beginLargeFile(
                    EntryPath(validating: pathStorage.span.bytes.extracting(0..<pathCount)), size: size, metadata: metadata, storage: storage,
                    first: bytes, // This piece, in the walker's buffer, for the call.
                    minimumPieceSize: segmentSize, attachments: attachments, hardLinked: cluster != nil, tag: tag
                )
                largeFile = file
                token = file.entry
                if let cluster { hardLinkTargets[cluster] = token }
            }
            guard let largeFile else { return }
            pool.retain(buffer)
            try await planner.piece(SegmentContents.Contents(buffer: buffer, offset: offset, count: count), of: largeFile, at: fileOffset, count: count)
        } catch {
            throw AEAError(error)
        }
    }

    mutating func metadata(_ blob: AAMetadataBlob, _ bytes: RawSpan, offset: Int) throws(AEAError) {
        // Blobs come whole and in order (one finishes before the next starts), so each is one run of `blobs`.
        guard acceptsBlobs else { return }
        let start = blobs.count
        blobs.append(copying: bytes)
        switch blob {
        case .extendedAttributes:
            extendedAttributes = (offset == 0 ? start : extendedAttributes.lowerBound)..<blobs.count
        case .accessControlList:
            accessControlList = (offset == 0 ? start : accessControlList.lowerBound)..<blobs.count
        }
    }

    nonisolated(nonsending) mutating func endEntry() async throws(AEAError) {
        do throws(DiskError) {
            if entry.type == .regularFile, !skipContents, (entry.data?.count ?? 0) == 0 {
                // An empty file: no data callbacks came.
                try await planFile(size: 0, contents: SegmentContents.Contents())
            }
            guard acceptsBlobs, token != EntryToken.none, !blobs.isEmpty else { return }
            if !extendedAttributes.isEmpty { try planner.addExtendedAttributes(blobs.span.bytes.extracting(extendedAttributes), to: token) }
            if !accessControlList.isEmpty { try planner.addAccessControlList(blobs.span.bytes.extracting(accessControlList), to: token) }
        } catch {
            throw AEAError(error)
        }
    }
}
