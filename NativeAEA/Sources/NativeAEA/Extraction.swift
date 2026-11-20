import Darwin
import Foundation
import Synchronization
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

    /// The `decmpfs` type a file is stored with, for the type the archive asks for.
    func type(_ archived: UInt32?) -> UInt32? {
        switch self {
        case .archived: archived
        case .lzfse: archived.flatMap { Decmpfs.codec($0) != nil ? 12 : nil }
        case .none: nil
        }
    }
}

/// Settings for ``AEAArchive/extract(to:options:)``.
public struct AEAExtractionOptions: Sendable {
    public init() {}

    /// Decoding: decoders, decoder, input, checks.
    public var read = AEAReadOptions()
    /// Writers (child tasks) writing files, and compressing them with ``DiskCompressionMode/archived``.
    public var writerThreads = 24
    /// Writers in file system calls at once (each blocks its thread in the call). APFS contends beyond a few: creating
    /// small files peaked at 4 threads (about 46,000 a second) and slowed past 8, in one directory or many, so
    /// compression runs outside this limit and the calls inside it. Also the width of the passes after the writers.
    public var fileSystemWidth = 6
    /// How files are stored: compressed as the archive asks, or not.
    public var diskCompression = DiskCompressionMode.archived
    /// Replace existing files and links (otherwise an existing one is an error). Existing directories are reused.
    public var overwrite = false
    /// Restore the archived owner and group (root only).
    public var restoreOwnership = false
    /// Create entries relative to their parent directory's descriptor (kept open) instead of by path from the destination.
    /// Off by default: it measured 3% slower on Xcode (8.28–8.40 s against 7.98–8.17 s, interleaved): the name cache
    /// makes path lookups cheap, and opening each directory is one more call on the walker's critical path.
    public var relativeToParents = false
    /// Copy the archive file's quarantine attribute onto everything extracted, as Apple's `aa extract` does (the
    /// destination directory included).
    public var copyQuarantine = true
    /// Admit writers to the file system by directory: ``fileSystemWidth`` lanes of one writer each, a file's lane
    /// chosen by its parent directory, so the calls in flight are in different directories (the archive's order puts
    /// each directory's files together). Off: one limit for all.
    public var spreadDirectories = false
    /// Tasks making hard links while the writers run, as the walker finds the later names (0, the default: all
    /// after the writers). APFS spends about 280 µs of kernel time on every `linkat`, whatever the file: Xcode's xip
    /// has 26,000 later names, 2.6 s after the writers on 6 threads. Made during the writes, each took longer (a
    /// link task waits until the writers have taken its file's job), and the writers slowed: on an idle machine, 4
    /// link threads made Xcode 27.2's xip 11% slower (10.9–11.2 s against 9.9–10.1 s) with 30% more system time.
    /// With ``overwrite`` they're all made after the writers (a writer replaces an existing file, which an early link
    /// would keep).
    public var hardLinkThreads = 0
}

extension AEAArchive {
    /// Extracts the archive beneath `destination`, created if needed.
    ///
    /// Runs off the caller's actor, every part of it a child task of the calling task: ``AEAReadOptions/decodeThreads``
    /// decoders fill a fixed pool of buffers, and the calling task walks the stream in order: it checks each path,
    /// creates directories, and hands files to ``AEAExtractionOptions/writerThreads`` writers as jobs pointing into the
    /// buffers (a file's bytes are never copied: they go from the decoded segment to `write`, or to the compressor). A
    /// file that spans segments is written in pieces as they arrive. Symbolic links are made last (so no file is
    /// written through one), then directories get their permissions, times, and flags.
    ///
    /// Cancelling the task stops every part promptly, releases the buffers, closes what's open, and throws
    /// ``AEAError/cancelled``; what was extracted until then stays.
    ///
    /// - Returns: Counts and timings.
    /// - Throws: ``AEAError``: a failed check, a malformed stream, an unsafe path, a file system error, or cancellation.
    @concurrent @discardableResult
    public func extract(to destination: FilePath, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        let source = try payload(options.read, heldBeyondDecoding: options.writerThreads)
        // `aa extract` quarantines what's in the destination, not the destination itself, for an `.aea` (Xcode's,
        // compared item by item); for a plain `.aar` it quarantines the destination too.
        return try await Extractor.extract(source, to: destination, options: options, archivePath: path, quarantineDestination: false)
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
    /// Extracts the archive stream `source` decodes (not yet running) beneath `destination`.
    ///
    /// One task group holds everything while the calling task walks: the source's decoders, the writers, and the
    /// link tasks. The passes after the walk run in its body too (in task groups of their own), after the writers.
    ///
    /// - Parameters:
    ///   - format: What the stream holds.
    ///   - archivePath: The archive file, whose quarantine attribute is copied.
    ///   - quarantineDestination: Whether the destination directory gets it too.
    nonisolated(nonsending) static func extract(
        _ source: some ChunkSource, format: StreamFormat = .appleArchive, to destination: FilePath, options: AEAExtractionOptions,
        archivePath: FilePath, quarantineDestination: Bool
    ) async throws(AEAError) -> AEAStatistics {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try FileManager.default.createDirectory(atPath: destination.string, withIntermediateDirectories: true)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw .fileSystem("mkdir \(destination)", underlying.map { Errno(rawValue: Int32($0.code)) } ?? .ioError)
        }
        let root = unsafe open(destination.string, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw .fileSystem("open \(destination)", Errno(rawValue: errno)) }
        defer { close(root) }
        DirectoryTable.raiseDescriptorLimit()

        let quarantine = options.copyQuarantine ? EntryMetadata.quarantine(of: archivePath.string) : nil
        if quarantineDestination, let quarantine, let failure = EntryMetadata.setQuarantine(root, quarantine) { throw failure }

        let target = CancellationTarget()
        let outcome: Result<AEAStatistics, AEAError> = await source.withDecoding(onCancel: {
            // Writers skip what's left (releasing its references), and the walker stops at its next entry or chunk.
            target.cancel()
        }) { group in
            do throws(AEAError) {
                return .success(try await extract(
                    source, format: format, root: root, options: options, quarantine: quarantine, target: target, group: &group
                ))
            } catch {
                return .failure(error)
            }
        }
        var statistics = try outcome.get()
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        statistics.unreleasedBuffers = source.pools.reduce(0) { $0 + $1.buffersInUse }
        return statistics
    }

    /// The extraction inside the task group: once the source knows its pool, the context, the writers and link
    /// tasks (added to `group`), the walk, and, once the writers are done, the passes after it.
    nonisolated(nonsending) private static func extract(
        _ source: some ChunkSource, format: StreamFormat, root: Int32, options: AEAExtractionOptions, quarantine: [UInt8]?,
        target: CancellationTarget, group: inout DiscardingTaskGroup
    ) async throws(AEAError) -> AEAStatistics {
        try await source.prepare()
        let pool = source.pool
        let context = ExtractionContext(pool: pool, root: root, options: options, segmentSize: pool.segmentCapacity, quarantine: quarantine)
        target.set(context)
        let writers = max(1, options.writerThreads)
        let linkers = context.makesLinksEarly ? options.hardLinkThreads : 0
        let writersDone = AsyncLatch(count: writers), linkersDone = AsyncLatch(count: linkers)
        for _ in 0..<writers {
            group.addTask {
                var writer = Writer(context)
                await writer.run()
                writersDone.arrive()
            }
        }
        for _ in 0..<linkers {
            group.addTask {
                await EarlyLink.run(context)
                linkersDone.arrive()
            }
        }

        var sink = ExtractionSink(context)
        defer { sink.closeDirectories() }
        let walkStarted = DispatchTime.now().uptimeNanoseconds
        do throws(AEAError) {
            try await format.walk(source, into: &sink)
        } catch {
            context.fail(error)
        }
        await sink.abandonOpenFile()
        let walkEnded = DispatchTime.now().uptimeNanoseconds
        // No more chunks are taken: the decoders end (at once after a failure). The writers and link tasks finish what's
        // queued.
        source.stop(nil)
        context.queue.close()
        context.links.close()
        var phases: [String: Double] = [:]
        var phaseStarted = walkEnded
        func phase(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases[name] = Double(now - phaseStarted) / 1e9
            phaseStarted = now
        }
        await linkersDone.wait()
        phase("linkersAfterWalk")
        await writersDone.wait()
        phase("writersAfterWalk")
        if let failure = context.failure.withLock({ $0 }) { throw failure }
        sink.addLateLinks(context.lateLinks.withLock { $0 })

        // Hard links to the files just written, then FIFOs and devices; symbolic links after those, so nothing is
        // written through one; then what waited for its file to be complete (extended attributes, ACLs, and the
        // mode, flags, and times after them), and directories' last of all, deepest first. Each checks for
        // cancellation as it goes.
        try await sink.createHardLinks(lanes: options.fileSystemWidth)
        phase("hardLinks")
        try sink.createSpecialFiles()
        phase("specialFiles")
        try await sink.createSymbolicLinks(lanes: options.fileSystemWidth)
        phase("symbolicLinks")
        try await sink.applyDeferredMetadata(lanes: options.fileSystemWidth)
        phase("deferredMetadata")
        try await sink.fixDirectories(lanes: options.fileSystemWidth)
        phase("directories")

        var statistics = sink.statistics
        sink.diskCompression.add(to: &statistics.filesByDiskCompression)
        statistics.phaseSeconds = phases
        statistics.decodeSeconds = Double(source.counters.busy.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(source.counters.read.load(ordering: .relaxed)) / 1e9
        statistics.walkSeconds = Double(walkEnded - walkStarted) / 1e9
        statistics.writeSeconds = Double(context.writeNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.writerWork = context.timings.seconds
        statistics.walkWaitForSegments = Double(source.counters.wait.load(ordering: .relaxed)) / 1e9
        statistics.walkWaitForWriters = Double(context.queue.pushWaitNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = pool.peakInUse.load(ordering: .relaxed)
        statistics.hardLinksAfterWriters = sink.pendingHardLinks
        return statistics
    }
}

/// What the extraction's cancellation handler stops: the context, once the stream's first chunk has made it (the
/// handler is installed before).
final class CancellationTarget: Sendable {
    private let state = Mutex<(cancelled: Bool, context: ExtractionContext?)>((false, nil))

    func cancel() {
        let context = state.withLock { state in
            state.cancelled = true
            return state.context
        }
        context?.fail(.cancelled)
    }

    func set(_ context: ExtractionContext) {
        let cancelled = state.withLock { state in
            state.context = context
            return state.cancelled
        }
        if cancelled { context.fail(.cancelled) }
    }
}

/// A later name of a hard-linked file, made by a link task while the writers run: each name in its parent (open for
/// the whole extraction) or as a path from the destination, copied in (the walker's arena grows, so other tasks can't
/// read it).
struct EarlyLink: Sendable {
    /// The longest name or path held, NUL included (`PATH_MAX`).
    static let capacity = 1024
    var targetDirectory: Int32
    var directory: Int32
    /// Writer jobs that must have been taken before the file can exist (its job among them).
    var after: Int
    /// NUL-terminated.
    var targetName = InlineArray<1024, CChar>(repeating: 0)
    var name = InlineArray<1024, CChar>(repeating: 0)
    /// The link as the pass after the writers makes it, if its file isn't there yet.
    var late: ExtractionSink.HardLink

    /// Copies `count` bytes at `source` into `name` (which is zeroed: the NUL follows).
    static func copy(_ source: UnsafeRawPointer, count: Int, into name: inout InlineArray<1024, CChar>) {
        var span = name.mutableSpan
        // `count` < 1024 (checked by the caller), into the array's 1024 bytes: safe.
        span.withUnsafeMutableBufferPointer { unsafe UnsafeMutableRawPointer($0.baseAddress!).copyMemory(from: source, byteCount: count) }
    }

    /// A link task: makes links as the walker queues them until it closes the queue.
    ///
    /// The writers run behind the walker (up to the queue's 16,384 jobs), so a link waits until the writers have
    /// taken its file's job (suspended in the write queue until it's taken): then a writer has it, and it's created
    /// within a file system call or so.
    nonisolated(nonsending) static func run(_ context: ExtractionContext) async {
        while let link = await context.links.pop() {
            if context.failed.load(ordering: .relaxed) { continue } // Drained, so the walker's pushes land.
            let waited = DispatchTime.now().uptimeNanoseconds
            // `after` counts a job past the file's, which never comes for the last file: the wait also ends once the
            // queue is closed and every job is taken (or on a failure).
            await context.queue.waitUntilPopped(link.after)
            context.timings.add(.linkWait, since: waited)
            var error: Int32 = 0
            // Taken isn't opened: the writer may still be waiting to enter the file system. Retry for up to 50 ms,
            // suspended between tries (no event says when a writer has created a file).
            for attempt in 0..<250 {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: .microseconds(200))
                    } catch {
                        break // Cancelled.
                    }
                }
                let started = DispatchTime.now().uptimeNanoseconds
                // Both names NUL-terminated in their arrays, both directories open; no link followed in either path.
                let made = link.targetName.span.withUnsafeBufferPointer { target in
                    link.name.span.withUnsafeBufferPointer { name in
                        unsafe linkat(link.targetDirectory, target.baseAddress!, link.directory, name.baseAddress!, AT_SYMLINK_NOFOLLOW_ANY) == 0
                    }
                }
                error = made ? 0 : errno
                context.timings.add(.link, since: started)
                if error != ENOENT || context.failed.load(ordering: .relaxed) { break }
            }
            if error == 0 { continue }
            if error == ENOENT {
                // Still no file: link it after the writers.
                context.lateLinks.withLock { $0.append(link.late) }
            } else {
                let name = link.name.span.withUnsafeBufferPointer { unsafe String(cString: $0.baseAddress!) } // NUL-terminated: safe.
                context.fail(.fileSystem("link \(name)", Errno(rawValue: error)))
            }
        }
    }
}

// MARK: - Shared state

/// What the walker and the writers share.
final class ExtractionContext: @unchecked Sendable {
    let pool: SegmentBufferPool
    let root: Int32
    let options: AEAExtractionOptions
    let queue: JobQueue<WriteJob>
    /// Hard links for the link tasks, and those whose files weren't made yet when they tried, for after the writers.
    let links: JobQueue<EarlyLink>
    let lateLinks = Mutex<[ExtractionSink.HardLink]>([])
    /// Whether hard links are made while the writers run (see ``AEAExtractionOptions/hardLinkThreads``).
    var makesLinksEarly: Bool { options.hardLinkThreads > 0 && !options.overwrite }
    /// Admits at most ``AEAExtractionOptions/fileSystemWidth`` writers to file system calls at once.
    let fileSystem: AsyncLimiter
    /// With ``AEAExtractionOptions/spreadDirectories``: one writer per lane instead.
    let lanes: [AsyncLimiter]

    /// The limit admitting a writer for a file in `lane`.
    func admission(_ lane: Int) -> AsyncLimiter {
        lanes.isEmpty ? fileSystem : lanes[lane % lanes.count]
    }
    let processUmask: mode_t
    let restoreOwnership: Bool
    /// The most chunks of a single-piece file: a segment's worth, plus one.
    let maximumChunks: Int
    /// Files up to this size are written whole even when they cross a segment boundary (they span two at most).
    let smallSpanLimit: Int
    /// Whether segments are long enough that a chunk spans no more pieces of a file than a ``Bridge`` holds.
    let chunksFitBridges: Bool
    /// The archive's quarantine attribute, set on every entry.
    let quarantine: [UInt8]?
    /// The destination's absolute path (from its descriptor), for setting attributes by path.
    let rootPath: [UInt8]

    let largeFiles: [LargeFile]
    /// Free slots of `largeFiles`.
    private let freeLargeFiles: AsyncIndexPool

    let failure = Mutex<AEAError?>(nil)
    let failed = Atomic<Bool>(false)
    let writeNanoseconds = Atomic<Int>(0)
    let timings = WorkTimings()

    init(pool: SegmentBufferPool, root: Int32, options: AEAExtractionOptions, segmentSize: Int, quarantine: [UInt8]?) {
        self.pool = pool
        self.root = root
        self.options = options
        self.quarantine = quarantine
        let writers = max(1, options.writerThreads)
        queue = JobQueue(capacity: 16_384, waiters: writers)
        // An `EarlyLink` is 2 KiB, and the ring is written when it's made: 8.7 MB for 4,096. Unused without link tasks.
        links = JobQueue(capacity: options.hardLinkThreads > 0 && !options.overwrite ? 4_096 : 1, waiters: max(1, options.hardLinkThreads))
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let resolved = path.withUnsafeMutableBytes { unsafe fcntl(root, F_GETPATH, $0.baseAddress!) } // MAXPATHLEN bytes, as F_GETPATH needs: safe.
        rootPath = resolved == 0 ? Array(path.prefix { $0 != 0 }) : []
        // Every writer may wait for the file system (and the walker, finishing a large file).
        fileSystem = AsyncLimiter(max(1, options.fileSystemWidth), waiters: writers + 1)
        lanes = options.spreadDirectories ? (0..<max(1, options.fileSystemWidth)).map { _ in AsyncLimiter(1, waiters: writers + 1) } : []
        // Read without setting it: `umask(0)` then restoring it left a window in which another extraction starting
        // at once read 0 and restored that, leaving the process's umask 0 (and every file it made world-writable).
        processUmask = getumask()
        restoreOwnership = options.restoreOwnership && geteuid() == 0
        maximumChunks = segmentSize / Decmpfs.chunkSize + 2
        smallSpanLimit = min(Decmpfs.batchChunks * Decmpfs.chunkSize, segmentSize)
        // A chunk spans at most chunk / segment + 1 pieces (rounded up): what a bridge holds, for segments of at
        // least a seventh of a chunk.
        chunksFitBridges = segmentSize * (Bridge.capacity - 1) >= Decmpfs.chunkSize
        // Files spanning segments: one is being planned at a time, the rest finish without the walker (which waits
        // for a free one). With 4, the walker waited 6.0 s of a 9.0 s extraction: a piece's job waits behind the
        // queue's small files, so a file's state is held that long. They're small; 128 are plenty.
        let count = 128
        largeFiles = (0..<count).map { _ in LargeFile(writers: writers) }
        freeLargeFiles = AsyncIndexPool(count: count, waiters: 1)
        unpackerSlots = AsyncIndexPool(count: 2, waiters: writers + 1) // `unpackers`' two.
    }

    func fail(_ error: AEAError) {
        failure.withLock { if $0 == nil { $0 = error } }
        failed.store(true, ordering: .relaxed)
        // Link tasks waiting for their files' jobs stop waiting.
        queue.releaseWatchers()
    }

    /// Rewriting files whose fork didn't pay (rare: Xcode has one): a few unpackers, made once.
    private let unpackers = [ForkUnpacker(), ForkUnpacker()]
    private let unpackerSlots: AsyncIndexPool

    /// Calls `body` with an unpacker of its own, waiting for one if all are in use.
    nonisolated(nonsending) func withConverter(_ body: (ForkUnpacker) -> AEAError?) async -> AEAError? {
        let slot = await unpackerSlots.acquire()
        defer { unpackerSlots.release(slot) }
        return body(unpackers[slot])
    }

    /// A free large-file slot, waiting for one: only the walker takes them.
    nonisolated(nonsending) func acquireLargeFile() async -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { timings.add(.largeFileWait, since: started) }
        return await freeLargeFiles.acquire()
    }

    func releaseLargeFile(_ index: Int) {
        freeLargeFiles.release(index)
    }

    /// Whether `mode` needs an `fchmod` after `open`/`mkdir` (the umask removed bits, or it has special bits).
    func needsChmod(_ mode: mode_t) -> Bool {
        mode & ~0o777 != 0 || mode & processUmask != 0
    }
}

/// A file whose contents span segments, written in pieces by any writer as segments arrive.
final class LargeFile: @unchecked Sendable {
    /// The NUL-terminated path, copied by the walker (the header's buffer is released before the last piece).
    let path = RawStorage(byteCount: Int(PATH_MAX) + 1, alignment: RawStorage.small)
    var descriptor: Int32 = -1
    var size = 0
    var mode: mode_t = 0
    var flags: UInt32 = 0
    var owner: (uid: UInt32, gid: UInt32)?
    var times = EntryTimes()
    /// The `decmpfs` fork type, or 0 for an uncompressed file. Set when the file opens; if the whole fork doesn't
    /// pay at the end, the file is rewritten plain from it.
    var forkType: UInt32 = 0
    var codec = DiskCodec.lzbitmap
    var chunkCount = 0
    /// Pieces not yet written, plus one held by the walker until it has issued the last piece.
    let outstanding = Atomic<Int>(0)
    /// Leave the mode, flags, and times to the pass after the writers (see ``WriteJob/deferFinish``).
    var deferFinish = false
    var lane = 0

    /// Compressed pieces go into the resource fork in order: piece `next` writes at `forkOffset`. Pieces that come to
    /// their turn early (they compress in parallel first) wait here, each with its number.
    private struct Turn {
        var next = 0
        var forkOffset = 0
        var failed = false
        var waiters: WaiterQueue<(piece: Int, continuation: Continuation<Bool>)>
    }

    private let turn: Mutex<Turn>

    /// - Parameter writers: Pieces that may wait for their turn at once, reserved for.
    init(writers: Int) {
        turn = Mutex(Turn(waiters: WaiterQueue(capacity: writers)))
    }

    /// Before the file's first piece is queued (the slot is reused).
    func resetTurns(forkOffset: Int) {
        turn.withLock { turn in
            turn.next = 0
            turn.forkOffset = forkOffset
            turn.failed = false
        }
    }

    /// Whether a piece failed (or the walker abandoned the file), and the fork's size so far.
    var progress: (failed: Bool, forkOffset: Int) {
        turn.withLock { ($0.failed, $0.forkOffset) }
    }

    /// Suspends until it's `piece`'s turn to write the fork.
    ///
    /// - Returns: Where its chunks go in the fork, or `nil` if an earlier piece failed (it has no turn then).
    nonisolated(nonsending) func waitForTurn(_ piece: Int) async -> Int? {
        // `.some(nil)`: failed; `nil`: wait.
        let now: Int?? = turn.withLock { turn in
            if turn.failed { return .some(nil) }
            return turn.next == piece ? .some(turn.forkOffset) : nil
        }
        if let now { return now }
        let proceed = await suspend { (continuation: Continuation<Bool>) in
            let ready: Bool? = turn.withLock { turn in
                if turn.failed { return false }
                if turn.next == piece { return true }
                turn.waiters.append((piece, continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        return proceed ? turn.withLock { $0.forkOffset } : nil
    }

    /// Passes the turn to the next piece, with the fork's new end (`nil`: unchanged, after a failed write).
    func passTurn(forkOffset: Int?) {
        let next: Continuation<Bool>? = turn.withLock { turn in
            if let forkOffset { turn.forkOffset = forkOffset }
            turn.next += 1
            let piece = turn.next
            return turn.waiters.removeFirst { $0.piece == piece }?.continuation
        }
        next?.resume(returning: true)
    }

    /// Marks the file failed: pieces waiting for their turn, and later ones, don't write.
    func failTurns() {
        let waiting = turn.withLock { turn in
            turn.failed = true
            return turn.waiters.removeAll()
        }
        for waiter in waiting { waiter.continuation.resume(returning: false) }
    }
}

/// One unit of work for a writer: a whole file, or a piece of a ``LargeFile``.
///
/// Copied into the write queue's ring (16,384 slots, written when it's made): the small fields are ordered to leave no
/// padding.
struct WriteJob: Sendable {
    enum Kind: Sendable { case file, piece }
    /// The directory the file is created in (its parent, or the destination), and where its name starts in the path.
    var directory: Int32 = -1
    var kind = Kind.file
    /// The file gets more after the writers (extended attributes, an ACL, hard links to it): leave it owner-writable,
    /// with only `UF_COMPRESSED` set, for that pass to finish.
    var deferFinish = false
    var mode: UInt16 = 0o644
    var leaf = 0
    /// The path, in a header in buffer `pathBuffer` (offsets from its segment base; negative is the carry region).
    var pathBuffer = -1
    var pathOffset = 0
    var pathCount = 0
    /// The bytes to write, in buffer `dataBuffer`.
    var dataBuffer = -1
    var dataOffset = 0
    var dataCount = 0
    /// A small file across a segment boundary: its second range, in another buffer.
    var secondBuffer = -1
    var secondOffset = 0
    var secondCount = 0
    /// Where `dataCount` bytes go in the file, and the file's size.
    var fileOffset = 0
    var fileSize = 0
    var flags: UInt32 = 0
    var diskCompression: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var times = EntryTimes()
    /// The file system lane: a hash of the parent directory's path (see ``AEAExtractionOptions/spreadDirectories``).
    var lane = 0
    // Pieces:
    var largeFile = -1
    var piece = 0
    /// Earlier pieces holding the start of a compressed piece's first chunk, oldest first (a chunk spans several
    /// pieces when segments are smaller than a chunk); the job holds a reference to each.
    var bridge = Bridge()
}

/// Pieces of a file whose bytes begin a chunk that a later piece completes: each piece's buffer, where its bytes
/// are there, and where they go in the file.
///
/// Every job carries one, in the write queue's ring (16,384 jobs, written when it's made), so it's held in 32-bit
/// fields: buffer indexes, offsets within a buffer and counts (a chunk at most 256 MiB, plus the carry region), and file
/// offsets (only compressed files have bridges, and those are under 2 GiB: their fork offsets are 32-bit).
struct Bridge: Sendable {
    /// The most pieces a chunk may span: a 64 KiB chunk over segments of 16 KiB (the smallest `aea` makes) spans 5.
    /// Files whose segments are smaller than chunk / (capacity - 1) are written uncompressed.
    static let capacity = 8
    private var stored: Int32 = 0
    private var buffers = InlineArray<8, Int32>(repeating: -1)
    private var offsets = InlineArray<8, Int32>(repeating: 0)
    private var fileOffsets = InlineArray<8, Int32>(repeating: 0)
    private var counts = InlineArray<8, Int32>(repeating: 0)

    var count: Int { Int(stored) }

    subscript(index: Int) -> (buffer: Int, offset: Int, fileOffset: Int, count: Int) {
        (Int(buffers[index]), Int(offsets[index]), Int(fileOffsets[index]), Int(counts[index]))
    }

    mutating func append(buffer: Int, offset: Int, fileOffset: Int, count: Int) {
        precondition(stored < Self.capacity, "A chunk spans more pieces than a bridge holds")
        let index = self.count
        // Each fits (see above); a value that didn't would trap here, not wrap.
        buffers[index] = Int32(buffer)
        offsets[index] = Int32(offset)
        fileOffsets[index] = Int32(fileOffset)
        counts[index] = Int32(count)
        stored += 1
    }

    /// Releases every piece's reference.
    mutating func release(_ pool: SegmentBufferPool) {
        for index in 0..<count { pool.release(Int(buffers[index])) }
        stored = 0
    }
}

// MARK: - The walker's side

struct ExtractionSink: ArchiveSink, ~Copyable {
    let context: ExtractionContext
    var statistics = AEAStatistics()
    /// Files by on-disk compression, for ``AEAStatistics/filesByDiskCompression`` at the end.
    var diskCompression = DiskCompressionCounts()
    private var entry = AAEntryHeader()
    private var headerBuffer = -1
    private var headerOffset = 0
    /// The current file's parent directory and where its name starts in its path.
    private var fileDirectory: Int32 = -1
    private var fileLeaf = 0
    private var largeFile = -1
    private var piece = 0
    /// A compressed large file's pieces holding the start of the chunk the next piece completes.
    private var bridge = Bridge()
    /// A small file whose first range has arrived, waiting for its second.
    private var pending: WriteJob?
    /// Whether the open large file was set up compressed: the walker's own copy (writers may change the shared one).
    private var largeFileCompressed = false
    /// The directories made so far, open: entries are created relative to their parent.
    private var directories: DirectoryTable
    /// Links to make at the end: paths and targets, NUL-terminated, in one arena, with each link's parent.
    private var linkBytes: [UInt8] = []
    private var links: [(path: Int, leaf: Int, directory: Int32, target: Int, mode: mode_t, times: EntryTimes, metadata: Int)] = []
    /// Directories whose permissions, times, flags, or metadata differ from what `mkdir` gave them, with their
    /// descriptors (-1 if not open) and their ``DeferredEntry`` (-1 if none). Each path is in `metadataBytes`
    /// (NUL-terminated, at `path`, `count` bytes before the NUL).
    private var directoryFixes: [(path: Int, count: Int, descriptor: Int32, mode: mode_t, flags: UInt32, times: EntryTimes, depth: Int, metadata: Int)] = []

    /// Entries finished after the writers: files with extended attributes or ACLs (or flags that would stop hard
    /// links to them), directories and links with extended attributes, FIFOs and devices. Their paths and blobs are
    /// in `metadataBytes`.
    private var deferred: [DeferredEntry] = []
    /// NUL-terminated paths and metadata blobs, appended: one arena, no allocation per entry.
    private var metadataBytes: [UInt8] = []
    /// The current entry's ``DeferredEntry``, which its blobs go to (-1: none).
    private var current = -1
    /// Hard links: each cluster's first file (its path in `metadataBytes`), and the links to make to it.
    private var hardLinkTargets: [UInt64: (path: Int, directory: Int32, leaf: Int, job: Int)] = [:]
    private var hardLinks: [HardLink] = []
    /// Jobs pushed to the writers: a hard link's file is made by a job pushed after its first name's entry.
    private var pushed = 0

    /// A later name of a hard-linked file: both names' paths in `metadataBytes`, and their parents' descriptors and
    /// the names' offsets in their paths, where the walker had them open (-1 otherwise).
    struct HardLink: Sendable {
        var target: Int
        var path: Int
        var targetDirectory: Int32
        var targetLeaf: Int
        var directory: Int32
        var leaf: Int
    }

    /// `path`'s parent, if the walker opened it (or the destination, for a name in it), and the name's offset in it;
    /// -1 when only a path from the destination would reach it.
    private static func resolvedParent(_ directories: borrowing DirectoryTable, _ path: UnsafeRawPointer, count: Int) -> (directory: Int32, leaf: Int) {
        let (directory, leaf) = unsafe directories.resolve(path, count: count)
        if leaf > 0 { return (directory, leaf) }
        // `resolve` gives the destination and offset 0 for a single name, and for a parent it didn't open.
        let hasSlash = unsafe memchr(path, 0x2F, count) != nil
        return hasSlash ? (-1, 0) : (directory, 0)
    }
    /// The current entry is a hard link to an earlier one: its contents aren't written.
    private var skipContents = false

    struct DeferredEntry: Sendable {
        enum Kind: Sendable { case file, directory, link, special(AAEntryType) }
        var kind: Kind
        /// The path's offset in `metadataBytes`, NUL-terminated.
        var path: Int
        var extendedAttributes = 0..<0
        var accessControlList = 0..<0
        var mode: mode_t = 0
        var flags: UInt32 = 0
        var owner: (uid: UInt32, gid: UInt32)?
        var times = EntryTimes()
        var device: UInt64 = 0
    }

    init(_ context: ExtractionContext) {
        self.context = context
        directories = DirectoryTable(root: context.root)
        linkBytes.reserveCapacity(1 << 20)
    }

    /// Copies a path into `metadataBytes`, NUL-terminated, and returns its offset.
    private mutating func appendPath(_ pointer: UnsafeRawPointer, count: Int) -> Int {
        let offset = metadataBytes.count
        unsafe metadataBytes.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: count)) // Within the header: safe.
        metadataBytes.append(0)
        return offset
    }

    /// Records the entry for the pass after the writers, as the current one (its blobs go to it).
    private mutating func deferEntry(_ kind: DeferredEntry.Kind, path: Int, _ entry: AAEntryHeader) -> Int {
        deferred.append(DeferredEntry(
            kind: kind, path: path, mode: mode_t(entry.mode ?? 0o644) & 0o7777, flags: entry.flags ?? 0,
            owner: context.restoreOwnership ? (entry.uid ?? 0, entry.gid ?? 0) : nil, times: EntryTimes(entry),
            device: entry.device ?? 0
        ))
        current = deferred.count - 1
        return current
    }

    private static func hasMetadata(_ entry: AAEntryHeader) -> Bool {
        (entry.extendedAttributes?.count ?? 0) > 0 || (entry.accessControlList?.count ?? 0) > 0
    }

    /// The current file's file system lane.
    private var fileLane = 0

    /// A hash (FNV-1a) of the path's directory part: the lane for ``AEAExtractionOptions/spreadDirectories``.
    private static func lane(_ path: UnsafeRawPointer, count: Int) -> Int {
        var end = count
        while end > 0, unsafe path.load(fromByteOffset: end - 1, as: UInt8.self) != 0x2F { end -= 1 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for index in 0..<end {
            hash = (hash ^ UInt64(unsafe path.load(fromByteOffset: index, as: UInt8.self))) &* 0x100_0000_01B3
        }
        return Int(truncatingIfNeeded: hash >> 1)
    }

    /// Flags that would make `link` fail on a file.
    private static let unlinkableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    private func checkFailure() throws(AEAError) {
        if context.failed.load(ordering: .relaxed), let failure = context.failure.withLock({ $0 }) { throw failure }
    }

    nonisolated(nonsending) mutating func entry(_ entry: AAEntryHeader, header: UnsafeRawPointer, buffer: Int) async throws(AEAError) {
        try checkFailure()
        self.entry = entry
        statistics.entries += 1
        guard let path = entry.path, let type = entry.type else { throw .invalidArchive("an entry without a type or path") }
        let pathPointer = unsafe header + path.offset
        try unsafe Paths.check(pathPointer, count: path.count)
        headerBuffer = buffer
        headerOffset = unsafe header - UnsafeRawPointer(context.pool.segmentBase(buffer))
        current = -1
        skipContents = false
        if (entry.extendedAttributes?.count ?? 0) > 0 { statistics.withExtendedAttributes += 1 }
        if (entry.accessControlList?.count ?? 0) > 0 { statistics.withAccessControlLists += 1 }
        switch type {
        case .regularFile:
            statistics.files += 1
            statistics.fileBytes += entry.data?.count ?? 0
            diskCompression.count(entry.diskCompression)
            var stored = -1 // The path's offset in `metadataBytes`, once copied there.
            if let cluster = entry.hardLinkCluster {
                statistics.hardLinks += 1
                stored = unsafe appendPath(pathPointer, count: path.count)
                // The name's parent as the walker opened it, so the link is one `linkat` between descriptors.
                let resolved = unsafe Self.resolvedParent(directories, pathPointer, count: path.count)
                if let target = hardLinkTargets[cluster] {
                    // A later name for a file already queued: linked by a link thread (or after the writers), its
                    // copy of the contents skipped.
                    let link = HardLink(
                        target: target.path, path: stored, targetDirectory: target.directory, targetLeaf: target.leaf,
                        directory: resolved.directory, leaf: resolved.leaf
                    )
                    skipContents = true
                    // Each name in its open parent, or its path from the destination (leaf 0) when it isn't open.
                    let targetCount = metadataBytes.withUnsafeBytes { unsafe strlen($0.baseAddress!.advanced(by: target.path + target.leaf).assumingMemoryBound(to: CChar.self)) } // NUL-terminated: safe.
                    let nameCount = path.count - resolved.leaf
                    if context.makesLinksEarly, targetCount < EarlyLink.capacity, nameCount < EarlyLink.capacity {
                        var early = EarlyLink(
                            targetDirectory: target.directory >= 0 ? target.directory : context.root,
                            directory: resolved.directory >= 0 ? resolved.directory : context.root,
                            // The file's job is the next pushed after its entry, or the one after (a pending file's first).
                            after: target.job + 2, late: link
                        )
                        metadataBytes.withUnsafeBytes { unsafe EarlyLink.copy($0.baseAddress! + target.path + target.leaf, count: targetCount, into: &early.targetName) } // In the arena: safe.
                        unsafe EarlyLink.copy(pathPointer + resolved.leaf, count: nameCount, into: &early.name) // Within the header: safe.
                        await context.links.push(early) // Closed only after the walk: it lands.
                    } else {
                        hardLinks.append(link)
                    }
                    return
                }
                hardLinkTargets[cluster] = (stored, resolved.directory, resolved.leaf, pushed)
            }
            if Self.hasMetadata(entry) || (stored >= 0 && (entry.flags ?? 0) & Self.unlinkableFlags != 0) {
                if stored < 0 { stored = unsafe appendPath(pathPointer, count: path.count) }
                _ = deferEntry(.file, path: stored, entry)
            }
            (fileDirectory, fileLeaf) = unsafe directories.resolve(pathPointer, count: path.count)
            if !context.lanes.isEmpty { fileLane = unsafe Self.lane(pathPointer, count: path.count) }
        case .directory:
            statistics.directories += 1
            guard path.count > 0 else { return } // The destination itself.
            try unsafe makeDirectory(entry, pathPointer, count: path.count)
        case .symbolicLink:
            statistics.symbolicLinks += 1
            guard let target = entry.linkTarget else { throw .invalidArchive("a link without a target") }
            let (parent, leaf) = unsafe directories.resolve(pathPointer, count: path.count)
            let pathStart = linkBytes.count
            unsafe linkBytes.append(contentsOf: UnsafeRawBufferPointer(start: pathPointer, count: path.count)) // Within the header: safe.
            linkBytes.append(0)
            let targetStart = linkBytes.count
            unsafe linkBytes.append(contentsOf: UnsafeRawBufferPointer(start: header + target.offset, count: target.count)) // Same.
            linkBytes.append(0)
            let metadata = Self.hasMetadata(entry) ? deferEntry(.link, path: unsafe appendPath(pathPointer, count: path.count), entry) : -1
            links.append((pathStart, leaf, parent, targetStart, mode_t(entry.mode ?? 0o755) & 0o7777, EntryTimes(entry), metadata))
        case .fifo, .characterDevice, .blockDevice:
            statistics.otherEntries += 1
            _ = deferEntry(.special(type), path: unsafe appendPath(pathPointer, count: path.count), entry)
        default:
            // Sockets (a bound socket can't be made from an archive), whiteouts, doors, ports, metadata entries.
            statistics.otherEntries += 1
            statistics.skippedEntries += 1
        }
    }

    /// Creates a directory in its parent (or reuses one an earlier extraction made) and opens it for its contents.
    private mutating func makeDirectory(_ entry: AAEntryHeader, _ pathPointer: UnsafeRawPointer, count: Int) throws(AEAError) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { context.timings.add(.mkdir, since: started) }
        let mode = mode_t(entry.mode ?? 0o755) & 0o7777
        let (parent, leaf) = unsafe directories.resolve(pathPointer, count: count)
        let name = unsafe pathPointer + leaf, nameCount = count - leaf
        // Owner-writable while its contents go in; the fix-up at the end sets the archived mode.
        let created = unsafe Paths.withCString(name, count: nameCount) { unsafe mkdirat(parent, $0, mode | 0o700) }
        if created != 0 {
            let error = errno
            var info = stat()
            let exists = unsafe Paths.withCString(name, count: nameCount) { unsafe fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0
            guard error == EEXIST, exists, info.st_mode & S_IFMT == S_IFDIR else {
                throw .fileSystem("mkdir \(unsafe Paths.string(pathPointer, count: count))", Errno(rawValue: error))
            }
            if info.st_mode & 0o700 != 0o700 {
                _ = unsafe Paths.withCString(name, count: nameCount) { unsafe fchmodat(parent, $0, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) }
            }
        }
        // Open, never through a link. Without a descriptor (the process's limit), its entries use paths from the
        // destination.
        let descriptor = context.options.relativeToParents
            ? unsafe Paths.withCString(name, count: nameCount) { unsafe openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            : -1
        if descriptor >= 0 { unsafe directories.insert(pathPointer, count: count, descriptor: descriptor) }
        let times = EntryTimes(entry)
        let metadata = Self.hasMetadata(entry) ? deferEntry(.directory, path: unsafe appendPath(pathPointer, count: count), entry) : -1
        if mode | 0o700 != mode || context.needsChmod(mode) || (entry.flags ?? 0) != 0 || context.restoreOwnership || !times.isEmpty
            || metadata >= 0 || context.quarantine != nil {
            // The path in the arena (already there for a deferred entry): no allocation per directory.
            let stored = metadata >= 0 ? deferred[metadata].path : unsafe appendPath(pathPointer, count: count)
            let depth = unsafe UnsafeRawBufferPointer(start: pathPointer, count: count).count { $0 == 0x2F } // Within the header: safe.
            directoryFixes.append((stored, count, descriptor, mode, entry.flags ?? 0, times, depth, metadata))
        }
    }

    nonisolated(nonsending) mutating func data(_ bytes: UnsafeRawPointer, count: Int, fileOffset: Int, buffer: Int, segment: Int) async throws(AEAError) {
        guard entry.type == .regularFile, !skipContents, let path = entry.path, let data = entry.data else { return }
        let pool = context.pool
        let offset = unsafe bytes - UnsafeRawPointer(pool.segmentBase(buffer))
        if fileOffset == 0, count == data.count {
            // The whole file in one buffer: one job.
            var job = baseJob(path)
            pool.retain(headerBuffer)
            pool.retain(buffer)
            job.dataBuffer = buffer
            job.dataOffset = offset
            job.dataCount = count
            await enqueue(job)
            return
        }
        if fileOffset == 0, data.count <= context.smallSpanLimit {
            // A small file across a segment boundary: one job with two ranges, issued with the second.
            var job = baseJob(path)
            pool.retain(headerBuffer)
            pool.retain(buffer)
            job.dataBuffer = buffer
            job.dataOffset = offset
            job.dataCount = count
            pending = job
            return
        }
        if var job = pending {
            pool.retain(buffer)
            job.secondBuffer = buffer
            job.secondOffset = offset
            job.secondCount = count
            pending = nil
            await enqueue(job)
            guard fileOffset == job.dataCount, fileOffset + count == data.count else {
                throw .invalidArchive("a small file spans more than two segments")
            }
            return
        }
        if fileOffset == 0 { try await unsafe openLargeFile(path, size: data.count, first: bytes, count: count) }
        let isLast = fileOffset + count == data.count
        let chunkSize = Decmpfs.chunkSize
        if largeFileCompressed, !isLast, (fileOffset + count) / chunkSize == fileOffset / chunkSize {
            // No chunk ends in this piece: no job. Its bytes go to the piece that completes the chunk, in its bridge.
            pool.retain(buffer)
            bridge.append(buffer: buffer, offset: offset, fileOffset: fileOffset, count: count)
            return
        }
        let state = context.largeFiles[largeFile]
        state.outstanding.add(1, ordering: .relaxed)
        var job = WriteJob()
        job.kind = .piece
        job.largeFile = largeFile
        job.piece = piece
        job.dataBuffer = buffer
        job.dataOffset = offset
        job.dataCount = count
        job.fileOffset = fileOffset
        job.fileSize = data.count
        pool.retain(buffer)
        if largeFileCompressed {
            // The references taken for the bridge pass to this job.
            job.bridge = bridge
            bridge = Bridge()
            if !isLast, (fileOffset + count) % chunkSize != 0 {
                // The next chunk starts in this buffer: keep it for the piece that completes it (the walker releases
                // this segment before it reaches the next).
                pool.retain(buffer)
                bridge.append(buffer: buffer, offset: offset, fileOffset: fileOffset, count: count)
            }
        }
        piece += 1
        await enqueue(job)
        if isLast { await finishLargeFile() }
    }

    mutating func metadata(_ blob: AAMetadataBlob, _ bytes: UnsafeRawPointer, count: Int, offset: Int) throws(AEAError) {
        // Blobs come whole and in order (one finishes before the next starts), so each is one run of the arena.
        guard current >= 0 else { return }
        let start = metadataBytes.count
        unsafe metadataBytes.append(contentsOf: UnsafeRawBufferPointer(start: bytes, count: count)) // In a held buffer: safe.
        switch blob {
        case .extendedAttributes:
            deferred[current].extendedAttributes = (offset == 0 ? start : deferred[current].extendedAttributes.lowerBound)..<metadataBytes.count
        case .accessControlList:
            deferred[current].accessControlList = (offset == 0 ? start : deferred[current].accessControlList.lowerBound)..<metadataBytes.count
        }
    }

    nonisolated(nonsending) mutating func endEntry() async throws(AEAError) {
        guard entry.type == .regularFile, !skipContents, let path = entry.path, (entry.data?.count ?? 0) == 0 else { return }
        // An empty file: no data callbacks came.
        let job = baseJob(path)
        context.pool.retain(headerBuffer)
        await enqueue(job)
    }

    /// Queues a job for the writers, suspending while the queue is full.
    nonisolated(nonsending) private mutating func enqueue(_ job: WriteJob) async {
        let started = DispatchTime.now().uptimeNanoseconds
        // Only closed after the walker is done (on a failure or cancellation too: the writers drain it, skipping the
        // work), so the push always lands.
        await context.queue.push(job)
        context.timings.add(.push, since: started)
        pushed += 1
    }

    private func baseJob(_ path: AAHeaderRange) -> WriteJob {
        var job = WriteJob()
        job.pathBuffer = headerBuffer
        job.pathOffset = headerOffset + path.offset
        job.pathCount = path.count
        job.directory = fileDirectory
        job.leaf = fileLeaf
        job.fileSize = entry.data?.count ?? 0
        job.mode = entry.mode ?? 0o644
        job.flags = entry.flags ?? 0
        job.diskCompression = context.options.diskCompression.type(entry.diskCompression) ?? 0
        job.uid = entry.uid ?? 0
        job.gid = entry.gid ?? 0
        job.times = EntryTimes(entry)
        job.deferFinish = current >= 0
        job.lane = fileLane
        return job
    }

    /// Sets up a file whose contents span segments: copies its path and opens it here, so pieces can write in any
    /// order.
    /// - Parameters:
    ///   - first: The file's first `count` bytes (the first piece), for formats the extractor leaves alone.
    nonisolated(nonsending) private mutating func openLargeFile(_ path: AAHeaderRange, size: Int, first: UnsafeRawPointer, count: Int) async throws(AEAError) {
        let source = unsafe UnsafeRawPointer(context.pool.segmentBase(headerBuffer)) + headerOffset + path.offset
        guard path.count < Int(PATH_MAX) else { throw .unsafePath(unsafe Paths.string(source, count: path.count)) }
        let index = await context.acquireLargeFile()
        let state = context.largeFiles[index]
        unsafe state.path.base.copyMemory(from: source, byteCount: path.count) // Under PATH_MAX, the storage's size: safe.
        unsafe state.path.base.storeBytes(of: 0, toByteOffset: path.count, as: UInt8.self)
        let mode = mode_t(entry.mode ?? 0o644) & 0o7777
        state.size = size
        state.mode = mode
        state.flags = entry.flags ?? 0
        state.owner = context.restoreOwnership ? (entry.uid ?? 0, entry.gid ?? 0) : nil
        state.times = EntryTimes(entry)
        state.chunkCount = (size + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        state.forkType = 0
        // Fork offsets are 32-bit: larger files are written uncompressed. So are files across segments too small for a
        // chunk's pieces to fit a bridge (under 9,363 bytes; `aea` makes them 16 KiB at least).
        if size < 1 << 31, context.chunksFitBridges,
           let type = context.options.diskCompression.type(entry.diskCompression), let codec = Decmpfs.codec(type), !(unsafe Decmpfs.skips(first, count: count, codec: codec.codec)) {
            state.forkType = codec.fork
            state.codec = codec.codec
        }
        state.resetTurns(forkOffset: (state.chunkCount + 1) * 4)
        state.deferFinish = current >= 0
        state.lane = fileLane
        state.outstanding.store(1, ordering: .relaxed)
        let directory = fileDirectory, leaf = fileLeaf
        state.descriptor = context.timings.measure(.largeFileOpen) {
            unsafe Writer.create(context, directory: directory, state.path.base + leaf, mode: mode)
        }
        if state.descriptor < 0 {
            let error = errno
            context.releaseLargeFile(index)
            throw .fileSystem("open \(unsafe Paths.string(source, count: path.count))", Errno(rawValue: error))
        }
        largeFile = index
        largeFileCompressed = state.forkType != 0
        piece = 0
        bridge = Bridge()
    }

    /// The walker has issued the last piece: drop its hold.
    nonisolated(nonsending) private mutating func finishLargeFile() async {
        let state = context.largeFiles[largeFile]
        let index = largeFile
        largeFile = -1
        bridge.release(context.pool)
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            await Writer.finishLargeFile(context, index)
        }
    }

    /// After a failure mid-file, releases what's held and closes what's open.
    nonisolated(nonsending) mutating func abandonOpenFile() async {
        if let job = pending {
            context.pool.release(job.pathBuffer)
            context.pool.release(job.dataBuffer)
            pending = nil
        }
        bridge.release(context.pool)
        if largeFile >= 0 {
            context.largeFiles[largeFile].failTurns()
            await finishLargeFile()
        }
    }

    /// Runs `lane(0)` to `lane(count - 1)` as child tasks and waits for them: the passes after the writers, each lane
    /// taking every `count`-th item. The lanes' work is file system calls, each blocking its thread: `count` is the
    /// file system width.
    nonisolated(nonsending) private static func inLanes(_ count: Int, _ lane: @escaping @Sendable (Int) -> Void) async {
        await withDiscardingTaskGroup { group in
            for index in 0..<count { group.addTask { lane(index) } }
        }
    }

    nonisolated(nonsending) func createSymbolicLinks(lanes width: Int) async throws(AEAError) {
        guard !links.isEmpty else { return }
        let failure = FirstFailure()
        let overwrite = context.options.overwrite, root = context.root
        let quarantine = context.quarantine, deferred = self.deferred, rootPath = context.rootPath
        // The arenas are complete: each lane borrows its own reference to them (no copy).
        let links = self.links, linkBytes = self.linkBytes, metadataBytes = self.metadataBytes
        let lanes = max(1, min(width, links.count))
        await Self.inLanes(lanes) { lane in
            linkBytes.withUnsafeBufferPointer { bytes in
            metadataBytes.withUnsafeBytes { metadata in
                let base = unsafe UnsafeRawPointer(bytes.baseAddress!) // Non-empty: there are links.
                var index = lane
                while index < links.count {
                    if Task.isCancelled {
                        failure.record(.cancelled)
                        return
                    }
                    let link = links[index]
                    // Offsets into the arena, each a NUL-terminated string: safe.
                    let target = unsafe base.advanced(by: link.target).assumingMemoryBound(to: CChar.self)
                    let path = unsafe base.advanced(by: link.path).assumingMemoryBound(to: CChar.self)
                    let blob = link.metadata >= 0 ? unsafe EntryMetadata.slice(metadata, deferred[link.metadata].extendedAttributes) : nil
                    let make = { (directory: Int32, name: UnsafePointer<CChar>) -> AEAError? in
                        unsafe Self.makeLink(
                            target, in: directory, named: name, path: path, mode: link.mode, times: link.times, attributes: blob,
                            quarantine: quarantine, rootPath: rootPath, overwrite: overwrite
                        )
                    }
                    // In the parent, never through a link: an earlier link of this pass (or one already there) could
                    // otherwise redirect a path through it, out of the destination. With `relativeToParents` the
                    // walker already opened the parent (`O_NOFOLLOW`) and the name is one component.
                    let problem = link.directory == root
                        ? unsafe Paths.withParent(of: path, in: root, make) ?? .fileSystem("open", Errno(rawValue: errno))
                        : unsafe make(link.directory, base.advanced(by: link.path + link.leaf).assumingMemoryBound(to: CChar.self))
                    if let problem {
                        let name = unsafe String(cString: path)
                        failure.record(problem.at(name))
                    }
                    index += lanes
                }
            }
            }
        }
        if let error = failure.error { throw error }
    }

    /// Makes one symbolic link `name` in `directory` (a parent opened without following links), then its mode,
    /// extended attributes (the archive's, and the quarantine), and times, all on the link itself.
    private static func makeLink(
        _ target: UnsafePointer<CChar>, in directory: Int32, named name: UnsafePointer<CChar>, path: UnsafePointer<CChar>,
        mode: mode_t, times: EntryTimes, attributes: UnsafeRawBufferPointer?, quarantine: [UInt8]?, rootPath: [UInt8], overwrite: Bool
    ) -> AEAError? {
        var created = unsafe symlinkat(target, directory, name) == 0
        if !created, errno == EEXIST, overwrite {
            // Replace what's there (not a directory: `unlinkat` without AT_REMOVEDIR leaves those).
            created = unsafe unlinkat(directory, name, 0) == 0 && symlinkat(target, directory, name) == 0
        }
        guard created else { return .fileSystem("symlink", Errno(rawValue: errno)) }
        if mode != 0o755 {
            // Links get 0755 (`symlinkat` ignores the umask); the archive's mode otherwise, as Apple's extractor sets it.
            unsafe fchmodat(directory, name, mode, AT_SYMLINK_NOFOLLOW)
        }
        let hasAttributes = unsafe attributes != nil
        if let quarantine, !hasAttributes, !rootPath.isEmpty {
            // Only the quarantine: by path, on the link itself, following no link in the path: one call.
            if let problem = unsafe EntryMetadata.setQuarantine(root: rootPath, path: path, count: strlen(path), quarantine, link: true) {
                return problem
            }
        } else if quarantine != nil || hasAttributes {
            // The link itself (`O_SYMLINK`), for its extended attributes.
            let descriptor = unsafe openat(directory, name, O_RDONLY | O_SYMLINK | O_CLOEXEC)
            guard descriptor >= 0 else { return .fileSystem("open", Errno(rawValue: errno)) }
            defer { close(descriptor) }
            if let quarantine, let problem = EntryMetadata.setQuarantine(descriptor, quarantine) { return problem }
            if let attributes = unsafe attributes, let problem = unsafe EntryMetadata.applyExtendedAttributes(descriptor, attributes) { return problem }
        }
        _ = unsafe times.apply(directory, name)
        return nil
    }

    /// Hard links to the files the writers made, each made in its parent opened without following links (as are the
    /// targets' parents).
    /// Links the later names of hard-linked files to the first, `threads` at a time (a xip has thousands: Xcode's,
    /// 21,000).
    /// Links the link threads found no file for yet, for ``createHardLinks(threads:)``.
    mutating func addLateLinks(_ links: [HardLink]) { hardLinks += links }

    /// Links left for ``createHardLinks(threads:)``.
    var pendingHardLinks: Int { hardLinks.count }

    nonisolated(nonsending) func createHardLinks(lanes width: Int) async throws(AEAError) {
        guard !hardLinks.isEmpty else { return }
        let root = context.root, overwrite = context.options.overwrite
        let failure = FirstFailure()
        let links = hardLinks, metadataBytes = self.metadataBytes
        let lanes = max(1, min(width, links.count))
        await Self.inLanes(lanes) { lane in
            metadataBytes.withUnsafeBytes { arena in
                let base = arena.baseAddress! // Non-empty: every link's paths are in it.
                var index = lane
                while index < links.count {
                    if Task.isCancelled {
                        failure.record(.cancelled)
                        return
                    }
                    let link = links[index]
                    index += lanes
                    // Offsets of NUL-terminated paths in the arena: safe.
                    let target = unsafe base.advanced(by: link.target).assumingMemoryBound(to: CChar.self)
                    let path = unsafe base.advanced(by: link.path).assumingMemoryBound(to: CChar.self)
                    // No link followed anywhere in either path (`AT_SYMLINK_NOFOLLOW_ANY`: `ELOOP` instead).
                    let flags = AT_SYMLINK_NOFOLLOW_ANY
                    func make(_ targetDirectory: Int32, _ targetName: UnsafePointer<CChar>, _ directory: Int32, _ name: UnsafePointer<CChar>) -> Bool {
                        var created = unsafe linkat(targetDirectory, targetName, directory, name, flags) == 0
                        if !created, errno == EEXIST, overwrite {
                            created = unsafe unlinkat(directory, name, flags) == 0 && linkat(targetDirectory, targetName, directory, name, flags) == 0
                        }
                        return created
                    }
                    // Each name in its parent as the walker opened it (the leaf of its path), or its path from the
                    // destination: one call either way. NUL-terminated in the arena: safe.
                    let created = unsafe make(
                        link.targetDirectory >= 0 ? link.targetDirectory : root, target + (link.targetDirectory >= 0 ? link.targetLeaf : 0),
                        link.directory >= 0 ? link.directory : root, path + (link.directory >= 0 ? link.leaf : 0)
                    )
                    if !created {
                        failure.record(.fileSystem("link \(unsafe String(cString: path))", Errno(rawValue: errno)))
                    }
                }
            }
        }
        if let error = failure.error { throw error }
    }

    /// FIFOs and devices (devices need root: without it they're skipped and counted).
    mutating func createSpecialFiles() throws(AEAError) {
        let root = context.root, overwrite = context.options.overwrite
        var made = 0, skipped = 0
        let context = self.context, deferred = self.deferred
        let failure: AEAError? = metadataBytes.withUnsafeBytes { arena in
            for entry in deferred {
                guard case .special(let type) = entry.kind else { continue }
                let path = unsafe arena.baseAddress!.advanced(by: entry.path).assumingMemoryBound(to: CChar.self) // NUL-terminated: safe.
                // In the parent, opened without following links.
                let result: Int32? = unsafe Paths.withParent(of: path, in: root) { directory, name in
                    func make() -> Int32 {
                        switch type {
                        case .fifo: unsafe mkfifoat(directory, name, entry.mode)
                        case .characterDevice: unsafe mknodat(directory, name, S_IFCHR | entry.mode, dev_t(truncatingIfNeeded: entry.device))
                        default: unsafe mknodat(directory, name, S_IFBLK | entry.mode, dev_t(truncatingIfNeeded: entry.device))
                        }
                    }
                    var result = make()
                    if result != 0, errno == EEXIST, overwrite, unsafe unlinkat(directory, name, 0) == 0 { result = make() }
                    guard result == 0 else { return errno }
                    if context.needsChmod(entry.mode) { unsafe fchmodat(directory, name, entry.mode, AT_SYMLINK_NOFOLLOW) }
                    if let owner = entry.owner { unsafe fchownat(directory, name, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) }
                    _ = unsafe entry.times.apply(directory, name)
                    return 0
                }
                let code = result ?? errno
                if code != 0 {
                    if code == EPERM, type != .fifo {
                        skipped += 1
                        continue
                    }
                    return .fileSystem("mknod \(unsafe String(cString: path))", Errno(rawValue: code))
                }
                made += 1
            }
            return nil
        }
        if let failure { throw failure }
        statistics.specialFiles += made
        statistics.skippedEntries += skipped
    }

    /// Files that waited for the writers: extended attributes and ACLs, then mode, times, and flags.
    nonisolated(nonsending) func applyDeferredMetadata(lanes width: Int) async throws(AEAError) {
        let files = deferred.indices.filter { if case .file = deferred[$0].kind { true } else { false } }
        guard !files.isEmpty else { return }
        let failure = FirstFailure()
        let context = self.context, deferred = self.deferred, metadataBytes = self.metadataBytes
        let lanes = max(1, min(width, files.count))
        await Self.inLanes(lanes) { lane in
            metadataBytes.withUnsafeBytes { arena in
                var index = lane
                while index < files.count {
                    if Task.isCancelled {
                        failure.record(.cancelled)
                        return
                    }
                    let entry = deferred[files[index]]
                    let path = unsafe arena.baseAddress!.advanced(by: entry.path).assumingMemoryBound(to: CChar.self) // NUL-terminated: safe.
                    if let problem = unsafe Self.finishDeferred(context, entry, path, arena) {
                        failure.record(problem.at(unsafe String(cString: path)))
                    }
                    index += lanes
                }
            }
        }
        if let error = failure.error { throw error }
    }

    private static func finishDeferred(
        _ context: ExtractionContext, _ entry: DeferredEntry, _ path: UnsafePointer<CChar>, _ arena: UnsafeRawBufferPointer
    ) -> AEAError? {
        let descriptor = unsafe openat(context.root, path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return .fileSystem("open", Errno(rawValue: errno)) }
        defer { close(descriptor) }
        if let problem = unsafe applyBlobs(descriptor, entry, arena) { return problem }
        // The writer set `UF_COMPRESSED` if it compressed the file; the archive's flags otherwise.
        var info = stat()
        guard unsafe fstat(descriptor, &info) == 0 else { return .fileSystem("stat", Errno(rawValue: errno)) }
        let flags = (entry.flags & ~UInt32(UF_COMPRESSED)) | (info.st_flags & UInt32(UF_COMPRESSED))
        return Writer.finishAttributes(context, descriptor, mode: entry.mode, flags: flags, owner: entry.owner, forceChmod: true, times: entry.times)
    }

    /// An entry's extended attributes, then its ACL.
    private static func applyBlobs(_ descriptor: Int32, _ entry: DeferredEntry, _ arena: UnsafeRawBufferPointer) -> AEAError? {
        if !entry.extendedAttributes.isEmpty, let problem = unsafe EntryMetadata.applyExtendedAttributes(descriptor, EntryMetadata.slice(arena, entry.extendedAttributes)) {
            return problem
        }
        if !entry.accessControlList.isEmpty, let problem = unsafe EntryMetadata.applyAccessControlList(descriptor, EntryMetadata.slice(arena, entry.accessControlList)) {
            return problem
        }
        return nil
    }

    /// Directories' metadata, quarantine, permissions, times, and flags: deepest first (a parent's mode may stop
    /// opening what's in it), each depth's in parallel.
    nonisolated(nonsending) func fixDirectories(lanes width: Int) async throws(AEAError) {
        guard !directoryFixes.isEmpty else { return }
        let failure = FirstFailure()
        let context = self.context, deferred = self.deferred, metadataBytes = self.metadataBytes
        let fixes = directoryFixes.sorted(by: { $0.depth > $1.depth })
        var start = 0
        while start < fixes.count, failure.error == nil {
            var end = start
            while end < fixes.count, fixes[end].depth == fixes[start].depth { end += 1 }
            let level = fixes[start..<end]
            let lanes = max(1, min(width, level.count))
            await Self.inLanes(lanes) { lane in
                metadataBytes.withUnsafeBytes { arena in
                    var index = level.startIndex + lane
                    while index < level.endIndex {
                        if Task.isCancelled {
                            failure.record(.cancelled)
                            return
                        }
                        let fix = level[index]
                        // A NUL-terminated path in the arena (non-empty: it holds every fix's path): safe.
                        let path = unsafe arena.baseAddress!.advanced(by: fix.path).assumingMemoryBound(to: CChar.self)
                        if let problem = unsafe Self.fixDirectory(context, path, count: fix.count, fix.descriptor, fix.mode, fix.flags, fix.times, fix.metadata >= 0 ? deferred[fix.metadata] : nil, arena) {
                            failure.record(problem.at(unsafe String(cString: path)))
                        }
                        index += lanes
                    }
                }
            }
            start = end
        }
        if let error = failure.error { throw error }
    }

    private static func fixDirectory(
        _ context: ExtractionContext, _ path: UnsafePointer<CChar>, count: Int, _ open: Int32, _ mode: mode_t, _ flags: UInt32,
        _ times: EntryTimes, _ metadata: DeferredEntry?, _ arena: UnsafeRawBufferPointer
    ) -> AEAError? {
        // Only the quarantine to set (the common case: `mkdir` gave the archived mode, nothing else is archived): by
        // path, one call instead of open, set, close.
        if open < 0, metadata == nil, let quarantine = context.quarantine, !context.rootPath.isEmpty, mode | 0o700 == mode,
           !context.needsChmod(mode), flags == 0, times.isEmpty, !context.restoreOwnership {
            return unsafe EntryMetadata.setQuarantine(root: context.rootPath, path: UnsafeRawPointer(path), count: count, quarantine, link: false) // `count` bytes in the arena: safe.
        }
        var descriptor = open
        if descriptor < 0 {
            descriptor = unsafe openat(context.root, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) // NUL-terminated: safe.
            guard descriptor >= 0 else { return .fileSystem("open", Errno(rawValue: errno)) }
        }
        defer { if open < 0 { close(descriptor) } }
        if let quarantine = context.quarantine, let problem = EntryMetadata.setQuarantine(descriptor, quarantine) { return problem }
        if let metadata, let problem = unsafe applyBlobs(descriptor, metadata, arena) { return problem }
        return Writer.finishAttributes(context, descriptor, mode: mode, flags: flags, owner: nil, forceChmod: mode | 0o700 != mode, times: times)
    }

    /// Closes the directories' descriptors (after the fix-ups, which use them).
    func closeDirectories() {
        directories.closeAll()
    }
}

/// Path checks and C strings.
enum Paths {
    /// Rejects absolute paths, `..` and empty components, and NUL bytes.
    static func check(_ bytes: UnsafeRawPointer, count: Int) throws(AEAError) {
        guard count < Int(PATH_MAX) else { throw .unsafePath(unsafe string(bytes, count: count)) }
        var componentStart = 0
        for index in 0...count {
            let byte: UInt8 = index < count ? unsafe bytes.load(fromByteOffset: index, as: UInt8.self) : 0x2F
            if byte == 0 { throw .unsafePath(unsafe string(bytes, count: count)) }
            if byte == 0x2F {
                let length = index - componentStart
                var isDotDot = false
                if length == 2 {
                    let first = unsafe bytes.load(fromByteOffset: componentStart, as: UInt8.self)
                    let second = unsafe bytes.load(fromByteOffset: componentStart + 1, as: UInt8.self)
                    isDotDot = first == 0x2E && second == 0x2E
                }
                // An empty path is the destination itself (allowed); empty components otherwise are not.
                if isDotDot || (length == 0 && count > 0) { throw .unsafePath(unsafe string(bytes, count: count)) }
                componentStart = index + 1
            }
        }
    }

    static func string(_ bytes: UnsafeRawPointer, count: Int) -> String {
        unsafe String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// Calls `body` with the parent directory of `path` (relative to `root`), opened so that no component of it may be
    /// a symbolic link (`O_NOFOLLOW_ANY`), and the path's last component: for calls that take a directory and a name
    /// and would otherwise follow links in the path (`symlinkat`, `linkat`, `unlinkat`, `mkfifoat`, `fchmodat`,
    /// `setattrlistat`). A path with no `/` uses `root` itself.
    ///
    /// - Returns: `body`'s result, or `nil` with `errno` set if the parent couldn't be opened.
    static func withParent<R>(of path: UnsafePointer<CChar>, in root: Int32, _ body: (Int32, UnsafePointer<CChar>) -> R) -> R? {
        guard let slash = unsafe strrchr(path, 0x2F) else { return unsafe body(root, path) }
        let count = unsafe UnsafePointer(slash) - path
        let parent = unsafe withCString(UnsafeRawPointer(path), count: count) { unsafe openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        return unsafe body(parent, UnsafePointer(slash) + 1)
    }

    /// Calls `body` with a NUL-terminated copy of the path on the stack.
    @inline(__always)
    static func withCString<R>(_ bytes: UnsafeRawPointer, count: Int, _ body: (UnsafePointer<CChar>) -> R) -> R {
        withUnsafeTemporaryAllocation(byteCount: count + 1, alignment: 1) { buffer in
            unsafe buffer.baseAddress!.copyMemory(from: bytes, byteCount: count)
            unsafe buffer.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
            return unsafe body(buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
