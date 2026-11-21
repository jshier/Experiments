import Bytes
import BytesAsync
import Darwin
import Synchronization
import System

/// Settings for ``Extraction/run(into:source:options:_:)``.
public struct ExtractionSettings: Sendable {
    public init() {}

    /// Writer tasks: each takes jobs, compresses (and decodes, in its source's ``ContentSource/write(_:to:)``), then
    /// writes. Default: one per performance core.
    public var writers = DiskDefaults.writers
    /// Writers in file system calls at once (each blocks its thread in the call). APFS contends beyond a few, so CPU
    /// work runs outside this limit and the calls inside it. Also the width of the passes after the writers.
    public var fileSystemWidth = DiskDefaults.fileSystemWidth
    /// Jobs queued ahead of the writers (back-pressure on the planner): with the source's buffers, it bounds memory.
    public var queueCapacity = 16_384
    /// Bytes of queued jobs' paths.
    public var queuePathBytes = 4 << 20
    /// The largest file a writer gathers from several writes before writing it (bigger ones stream): its staging
    /// buffer's size. Pages past 2 MiB are given back after each use.
    public var stagingCapacity = 1 << 20
    /// Large files (``Planner/beginLargeFile(_:size:metadata:storage:first:minimumPieceSize:tag:)``) open at once: a
    /// file's slot is held until its last piece is written, which waits behind the queue (NativeAEA: 4 slots left its
    /// walker waiting 6 of 9 seconds; 128 none).
    public var largeFileSlots = 128
    /// Stop at the first entry that fails (and throw it), or record failures and go on
    /// (``ExtractionReport/failures``). Cancellation always stops.
    public var stopsOnFirstFailure = true
    /// Where to count entries and bytes as they're written, for a client to poll.
    public var progress: ExtractionProgress?
    /// Measure time per kind of work (``ExtractionReport/phaseSeconds``, ``ExtractionReport/writerSeconds``).
    public var collectsTimings = false
}

/// An entry that failed, with ``ExtractionSettings/stopsOnFirstFailure`` off.
public struct EntryFailure: Error, Sendable, CustomStringConvertible {
    /// The entry's path in the destination.
    public var path: String
    /// The caller's tag for the entry (an index in its archive).
    public var tag: Int
    public var error: DiskError

    public var description: String { "\(path): \(error)" }
}

/// What an extraction did.
public struct ExtractionReport: Sendable {
    public var directories = 0
    public var files = 0
    public var symbolicLinks = 0
    public var hardLinks = 0
    public var specialFiles = 0
    /// Entries left alone: existing items under ``ExistingItemPolicy/skip``, devices without root.
    public var skipped = 0
    /// Bytes of file contents (before compression).
    public var fileBytes = 0
    /// Files stored plain, inline, and in resource forks.
    public var plainFiles = 0
    public var inlineFiles = 0
    public var forkFiles = 0
    /// With ``ExtractionSettings/stopsOnFirstFailure`` off: the entries that failed, in the order they failed.
    public var failures: [EntryFailure] = []
    public var seconds = 0.0
    /// Seconds per phase after the planner: `writers` (waiting for them), `hardLinks`, `specialFiles`,
    /// `symbolicLinks`, `deferred`, `directories`; and `planning`.
    public var phaseSeconds: [String: Double] = [:]
    /// Writers' seconds by kind of work, summed over writers (``ExtractionSettings/collectsTimings``).
    public var writerSeconds: [String: Double] = [:]
    /// Seconds the planner waited for room in the queue.
    public var plannerWaitSeconds = 0.0
    /// Times the planner waited for room in the queue (each one a suspension and a wake-up).
    public var plannerWaits = 0
}

/// An extraction's failure: the disk's, or the plan's own (its walker's error).
public enum ExtractionError<PlanFailure: Error>: Error {
    case disk(DiskError)
    case plan(PlanFailure)
}

extension ExtractionError: Sendable where PlanFailure: Sendable {}

/// Identifies a planned entry, to add extended attributes or an ACL to it (``Planner/addExtendedAttributes(_:to:)``),
/// or, for a file, to link other names to it (``Planner/hardLink(_:to:metadata:)``).
public struct EntryToken: Sendable, Hashable {
    /// The entry's deferred record, or -1.
    let deferred: Int
    /// The entry's path in the planner's arena (files planned `hardLinked`), or -1.
    let path: Int

    /// No entry: nothing can be added to it.
    public static var none: EntryToken { EntryToken(deferred: -1, path: -1) }
}

/// A large file being written in pieces.
public struct LargeFileToken: Sendable {
    let slot: Int
    let size: Int

    /// Whether the file is written APFS-compressed (its storage asked for it, and its size and pieces allow it). Its
    /// pieces in which no 64 KiB chunk ends then have no job of their own: they're written, and counted in the
    /// progress, with the piece that completes the chunk.
    public let isCompressed: Bool

    /// The file's entry: to add extended attributes or an ACL to it (planned with `attachments`), or to link other
    /// names to it (planned `hardLinked`). ``EntryToken/none`` if it has neither.
    public let entry: EntryToken
}

// MARK: - Running

/// Extracting a tree: a planner on the calling task makes directories and queues files, writers write them, and the
/// passes after them make links and finish metadata. See ``run(into:source:options:_:)``.
public enum Extraction {
    /// Extracts the tree `plan` describes into `destination`.
    ///
    /// Runs off the caller's actor, every part a child task of the calling task:
    /// - `plan` runs on the calling task: it calls the ``Planner`` for each entry, in archive order. Directories are made
    ///   at once (so a file's parent exists before it's queued); files are queued for the writers (the planner suspends
    ///   while the queue is full); links, special files, and metadata are recorded.
    /// - ``ExtractionSettings/writers`` writers take files, get their bytes from `source`, compress them, and write them,
    ///   at most ``ExtractionSettings/fileSystemWidth`` in file system calls at once.
    /// - After the writers: hard links, special files, symbolic links (last, so nothing is written through one),
    ///   deferred metadata (extended attributes, ACLs, then mode, times, flags), and directories' metadata, deepest
    ///   first.
    ///
    /// Cancelling the task stops every part promptly: writers skip what's queued (releasing its contents), and the
    /// planner's next call throws. A file being written is removed; what was finished stays, and directories made keep
    /// their temporary permissions (owner-writable). With a staging destination, ``Destination/discard()`` removes it
    /// all.
    ///
    /// - Returns: Counts and timings.
    /// - Throws: ``ExtractionError/disk(_:)`` (``DiskError/cancelled`` on cancellation), or ``ExtractionError/plan(_:)``
    ///   with `plan`'s own error.
    @concurrent @discardableResult
    public static func run<Source: ContentSource, PlanFailure: Error>(
        into destination: Destination, source: Source, options: ExtractionSettings = .init(),
        _ plan: (inout Planner<Source>) async throws(PlanFailure) -> Void
    ) async throws(ExtractionError<PlanFailure>) -> ExtractionReport {
        let started = DispatchClock.now
        if options.writers > 0, destination.options.directoryResolution == .descriptors { DiskDefaults.raiseDescriptorLimit() }
        let context = ExtractionContext(destination: destination, source: source, options: options)
        var planner = Planner(context)
        var planFailure: PlanFailure?
        let writers = max(1, options.writers)
        let writersDone = AsyncLatch(count: writers)
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                for index in 0..<writers {
                    group.addTask {
                        var writer = Writer(context, index: index)
                        await writer.run()
                        writersDone.arrive()
                    }
                }
                let planStarted = DispatchClock.now
                do throws(PlanFailure) {
                    try await plan(&planner)
                } catch {
                    // A plan that threw because the extraction stopped (the planner threw its failure) reports that
                    // failure; its own error otherwise.
                    if context.stoppingFailure == nil {
                        planFailure = error
                        context.fail(.cancelled, path: "", tag: -1, stopping: true)
                    }
                }
                await planner.abandonOpenFile()
                context.queue.close()
                planner.phases["planning"] = Double(DispatchClock.now - planStarted) / 1e9
                await writersDone.wait()
            }
        } onCancel: {
            context.fail(.cancelled, path: "", tag: -1, stopping: true)
        }
        defer { planner.closeDirectories() }
        if let planFailure { throw .plan(planFailure) }
        do throws(DiskError) {
            if let failure = context.stoppingFailure { throw failure }
            try await planner.finish()
        } catch {
            throw .disk(error)
        }
        var report = planner.report
        context.counters.add(to: &report)
        report.failures = context.failures.withLock { $0 }
        report.seconds = Double(DispatchClock.now - started) / 1e9
        report.phaseSeconds = planner.phases
        report.writerSeconds = context.timings.seconds
        report.plannerWaitSeconds = Double(context.queue.pushWaitNanoseconds.load(ordering: .relaxed)) / 1e9
        report.plannerWaits = context.queue.pushWaits.load(ordering: .relaxed)
        return report
    }
}

// MARK: - Shared state

/// Counts the writers keep, read once at the end.
final class WriterCounters: Sendable {
    let files = Atomic<Int>(0)
    let bytes = Atomic<Int>(0)
    let plain = Atomic<Int>(0)
    let inline = Atomic<Int>(0)
    let fork = Atomic<Int>(0)
    let skipped = Atomic<Int>(0)

    func count(_ form: StoredForm, bytes byteCount: Int) {
        switch form {
        case .plain: plain.add(1, ordering: .relaxed)
        case .inline: inline.add(1, ordering: .relaxed)
        case .resourceFork: fork.add(1, ordering: .relaxed)
        case .skipped:
            skipped.add(1, ordering: .relaxed)
            return
        }
        files.add(1, ordering: .relaxed)
        bytes.add(byteCount, ordering: .relaxed)
    }

    func add(to report: inout ExtractionReport) {
        report.files += files.load(ordering: .relaxed)
        report.fileBytes += bytes.load(ordering: .relaxed)
        report.plainFiles += plain.load(ordering: .relaxed)
        report.inlineFiles += inline.load(ordering: .relaxed)
        report.forkFiles += fork.load(ordering: .relaxed)
        report.skipped += skipped.load(ordering: .relaxed)
    }
}

/// Nanoseconds per kind of writer work (with ``ExtractionSettings/collectsTimings``).
final class WorkTimings: Sendable {
    enum Kind: Int, CaseIterable {
        case wait, compress, produce, open, data, fork, finish, close, piece, turn, largeFileFinish
    }

    private let counters = (0..<Kind.allCases.count).map { _ in Counter() }

    @inline(__always)
    func add(_ kind: Kind, since start: Int) {
        counters[kind.rawValue].add(DispatchClock.now - start)
    }

    var seconds: [String: Double] {
        var result: [String: Double] = [:]
        for kind in Kind.allCases {
            let value = counters[kind.rawValue].value
            if value > 0 { result["\(kind)"] = Double(value) / 1e9 }
        }
        return result
    }
}

/// One unit of work for a writer: a whole file, or a piece of a large file.
struct WriteJob<Contents: Sendable>: Sendable {
    enum Kind: Sendable { case file, piece }
    var kind: Kind
    var contents: Contents
    /// The directory the file is made in (its parent, or the destination), and where its name starts in its path.
    var directory: Int32 = -1
    var leaf = 0
    /// The file's size (-1: unknown, streamed).
    var size = 0
    var metadata = EntryMetadata()
    var storage = Storage.plain
    /// Finish only `UF_COMPRESSED` now; the rest after the writers (extended attributes, an ACL, locking flags).
    var deferred = false
    var tag = 0
    // Pieces:
    var largeFile = -1
    var piece = 0
    var fileOffset = 0
    var count = 0
    /// Earlier pieces holding the start of this piece's first chunk, oldest first; the job holds a reference to each.
    var bridge = Bridge<Contents>()
    /// Bytes of the bridge's pieces that had no job of their own (no chunk ends in them): counted in the progress with
    /// this piece's.
    var bridgedBytes = 0
}

/// Pieces whose bytes begin a chunk that a later piece completes: each piece's contents and where its bytes go.
struct Bridge<Contents: Sendable>: Sendable {
    /// The most pieces a chunk may span: a 64 KiB chunk over pieces of at least a seventh of it spans 8.
    static var capacity: Int { 8 }
    private(set) var parts: [(contents: Contents, fileOffset: Int, count: Int)] = []

    var count: Int { parts.count }
    var isEmpty: Bool { parts.isEmpty }

    mutating func append(_ contents: Contents, fileOffset: Int, count: Int) {
        if parts.capacity == 0 { parts.reserveCapacity(Self.capacity) }
        parts.append((contents, fileOffset, count))
    }

    subscript(index: Int) -> (contents: Contents, fileOffset: Int, count: Int) { parts[index] }
}

/// What the planner and the writers share.
final class ExtractionContext<Source: ContentSource>: @unchecked Sendable {
    // Unchecked: the large files' fields are set by the planner before it queues their pieces (the queue's lock orders
    // them); everything else is immutable, a `Mutex`, or atomics.
    let destination: Destination
    let source: Source
    let options: ExtractionSettings
    let queue: JobQueue<WriteJob<Source.Contents>>
    let fileSystem: AsyncLimiter
    let counters = WriterCounters()
    let timings = WorkTimings()
    let failures = Mutex<[EntryFailure]>([])
    private let stopping = Mutex<DiskError?>(nil)
    let stopped = Atomic<Bool>(false)
    /// Large files' slots, each made when first used.
    let largeFiles: LargeFileTable
    let freeLargeFiles: AsyncIndexPool
    /// Every writer's path buffer, one allocation (``WriterCore/pathCapacity`` bytes a writer).
    let writerPaths: RawStorage

    init(destination: Destination, source: Source, options: ExtractionSettings) {
        self.destination = destination
        self.source = source
        self.options = options
        let writers = max(1, options.writers)
        queue = JobQueue(capacity: max(1, options.queueCapacity), pathBytes: options.queuePathBytes, waiters: writers)
        fileSystem = AsyncLimiter(max(1, options.fileSystemWidth), waiters: writers + 1)
        largeFiles = LargeFileTable(count: max(1, options.largeFileSlots), writers: writers)
        freeLargeFiles = AsyncIndexPool(count: max(1, options.largeFileSlots))
        writerPaths = RawStorage(byteCount: writers * WriterCore.pathCapacity, alignment: RawStorage.small)
    }

    var stoppingFailure: DiskError? { stopping.withLock { $0 } }

    /// Records a failure: the first stops everything (with ``ExtractionSettings/stopsOnFirstFailure``, or `stopping`);
    /// otherwise it's listed and the extraction goes on.
    func fail(_ error: DiskError, path: @autoclosure () -> String, tag: Int, stopping force: Bool = false) {
        if force || options.stopsOnFirstFailure {
            stopping.withLock { if $0 == nil { $0 = error } }
            stopped.store(true, ordering: .relaxed)
        } else {
            let failure = EntryFailure(path: path(), tag: tag, error: error)
            failures.withLock { $0.append(failure) }
        }
    }

    var isStopped: Bool { stopped.load(ordering: .relaxed) }
}

/// The large files' slots, each made the first time the planner takes its index: an extraction that plans no large
/// file (any source but a ``PieceSource``, or one with only whole files) makes none.
@safe
final class LargeFileTable: @unchecked Sendable {
    // Unchecked: slot `index` is made by the planner while it holds `index` (from `freeLargeFiles`), before it queues a
    // job naming it; writers reach a slot only through such jobs (the queue's lock orders the two), and a slot, once
    // made, stays until the table goes.
    private let slots: UnsafeMutablePointer<LargeFile?>
    private let count: Int
    private let writers: Int

    init(count: Int, writers: Int) {
        self.count = count
        self.writers = writers
        // Unsafe: a raw allocation of `count` slots. Safe: owned by the table, freed in `deinit`.
        unsafe slots = .allocate(capacity: count)
        // Unsafe: initializes them. Safe: all `count` of the slots just allocated, to `nil`.
        unsafe slots.initialize(repeating: nil, count: count)
    }

    deinit {
        // Unsafe: deinitializes the slots. Safe: the `count` slots `init` initialized (each `nil` or a slot made since).
        unsafe slots.deinitialize(count: count)
        // Unsafe: frees them. Safe: `init`'s allocation, once.
        unsafe slots.deallocate()
    }

    /// Slot `index`, made by the planner (``make(_:)``) before any job named it.
    subscript(index: Int) -> LargeFile {
        precondition(index >= 0 && index < count, "a large-file slot out of range")
        // Unsafe: reads a slot without a lock. Safe: within the slots (checked above), and made before any job named
        // it (the queue's lock orders the planner's write before this read).
        return unsafe slots[index]!
    }

    /// Slot `index`, made if this is its first use. The planner's alone, while it holds `index`.
    func make(_ index: Int) -> LargeFile {
        precondition(index >= 0 && index < count, "a large-file slot out of range")
        // Unsafe: reads a slot without a lock. Safe: within the slots (checked above); only the planner writes one,
        // and it's the caller, holding the index.
        if let slot = unsafe slots[index] { return slot }
        let slot = LargeFile(writers: writers)
        // Unsafe: writes the slot. Safe: as above; no job names this index yet, so no writer reads it.
        unsafe slots[index] = slot
        return slot
    }
}

/// A file written in pieces, by any writer, as they arrive.
final class LargeFile: @unchecked Sendable {
    // Unchecked: set by the planner before the file's first piece is queued; the turn state is in a `Mutex`.
    /// The NUL-terminated path, copied by the planner.
    let path = RawStorage(byteCount: Int(PATH_MAX) + 1, alignment: RawStorage.small)
    var pathCount = 0
    var directory: Int32 = -1
    var leaf = 0
    var descriptor: Int32 = -1
    var size = 0
    var metadata = EntryMetadata()
    var mode: mode_t = 0
    var deferred = false
    var tag = 0
    /// The storage policy, or `nil` for a plain file.
    var policy: StoragePolicy?
    var chunkCount = 0
    /// Pieces not yet written, plus one the planner holds until it queues the last.
    let outstanding = Atomic<Int>(0)

    /// Compressed pieces go into the fork in order: piece `next` writes at `forkOffset`. Pieces that come to their turn
    /// early (they compress in parallel first) wait here.
    private struct Turn {
        var next = 0
        var forkOffset = 0
        var failed = false
        var waiters: WaiterQueue<(piece: Int, continuation: Continuation<Bool>)>
    }

    private let turn: Mutex<Turn>

    init(writers: Int) {
        turn = Mutex(Turn(waiters: WaiterQueue(capacity: writers)))
    }

    /// The path (`pathCount` bytes in its storage, which this slot owns).
    var pathRef: PathRef {
        // Unsafe: a reference to the slot's path bytes. Safe: `pathCount` bytes of storage this slot owns, read only
        // while the slot's file is being written (the slot lives as long as the extraction).
        unsafe PathRef(path.base, count: pathCount)
    }

    func resetTurns(forkOffset: Int) {
        turn.withLock { turn in
            turn.next = 0
            turn.forkOffset = forkOffset
            turn.failed = false
        }
    }

    var progress: (failed: Bool, forkOffset: Int) {
        turn.withLock { ($0.failed, $0.forkOffset) }
    }

    /// Suspends until it's `piece`'s turn to write the fork: where its chunks go, or `nil` if an earlier piece failed.
    nonisolated(nonsending) func waitForTurn(_ piece: Int) async -> Int? {
        let now: Int?? = turn.withLock { turn in
            if turn.failed { return .some(nil) }
            return turn.next == piece ? .some(turn.forkOffset) : nil
        }
        if let now { return now }
        let proceed = await withContinuation { (continuation: Continuation<Bool>) in
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
