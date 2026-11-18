import Compression
import Darwin
import Foundation
import Synchronization
public import System

/// How extracted files are stored.
public enum DiskCompressionMode: String, Sendable, CaseIterable {
    /// As the archive asks (`AFT`): APFS-compressed files, as Apple's extractor writes them.
    case archived
    /// Uncompressed files.
    case none
}

/// Settings for ``AEAArchive/extract(to:options:)``.
public struct AEAExtractionOptions: Sendable {
    public init() {}

    /// Decoding: threads, decoder, input, checks.
    public var read = AEAReadOptions()
    /// Threads writing files, and compressing them with ``DiskCompressionMode/archived``.
    public var writerThreads = 24
    /// Writers in file system calls at once. APFS contends beyond a few: creating small files peaked at 4 threads
    /// (about 46,000 a second) and slowed past 8, in one directory or many, so compression runs outside this limit
    /// and the calls inside it.
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
}

extension AEAArchive {
    /// Extracts the archive beneath `destination`, created if needed.
    ///
    /// Segments decode on ``AEAReadOptions/decodeThreads`` threads into a fixed pool of buffers. One thread walks
    /// the stream in order: it checks each path, creates directories (keeping each open, so what goes in it is
    /// created relative to it), and hands files to ``AEAExtractionOptions/writerThreads`` writers as jobs pointing
    /// into the buffers (a file's bytes are never copied: they go from the decoded segment to `write`, or to the
    /// compressor). A file that spans segments is written in pieces as they arrive. Symbolic links are made last (so
    /// no file is written through one), then directories get their permissions, times, and flags.
    ///
    /// - Returns: Counts and timings.
    /// - Throws: ``AEAError``: a failed check, a malformed stream, an unsafe path, or a file system error.
    @discardableResult
    public func extract(to destination: FilePath, options: AEAExtractionOptions = .init()) throws(AEAError) -> AEAStatistics {
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

        let read = options.read
        let pool = SegmentBufferPool(
            count: read.decodeThreads + read.extraBuffers + options.writerThreads, segmentCapacity: rootHeader.segmentSize
        )
        let stream = try SegmentStream(
            archive: self, pool: pool, threads: read.decodeThreads, backend: read.decoder,
            verifyMACs: read.verifyMACs, verifyChecksums: read.verifyChecksums, input: read.input
        )
        let context = ExtractionContext(pool: pool, root: root, options: options, segmentSize: rootHeader.segmentSize)
        let writers = DispatchGroup()
        for _ in 0..<max(1, options.writerThreads) {
            writers.enter()
            let thread = Thread {
                Writer(context).run()
                writers.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
        stream.start()

        var sink = ExtractionSink(context)
        defer { sink.closeDirectories() }
        let walkStarted = DispatchTime.now().uptimeNanoseconds
        do {
            try ArchiveWalker.walk(stream, into: &sink)
        } catch {
            context.fail(error)
        }
        sink.abandonOpenFile()
        let walkSeconds = Double(DispatchTime.now().uptimeNanoseconds - walkStarted) / 1e9
        context.queue.close()
        writers.wait()
        if let failure = context.failure.withLock({ $0 }) { throw failure }

        // Links last, so no file is written through one; then directories' permissions, times, and flags, deepest
        // first.
        try sink.createSymbolicLinks(threads: options.fileSystemWidth)
        try sink.fixDirectories()

        var statistics = sink.statistics
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        statistics.decodeSeconds = Double(stream.busyNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(stream.readNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.walkSeconds = walkSeconds
        statistics.writeSeconds = Double(context.writeNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.writerWork = context.timings.seconds
        statistics.walkWaitForSegments = Double(stream.waitNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.walkWaitForWriters = Double(context.queue.pushWaitNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = pool.peakInUse.load(ordering: .relaxed)
        statistics.unreleasedBuffers = pool.buffersInUse
        return statistics
    }
}

// MARK: - Shared state

/// What the walker and the writers share.
final class ExtractionContext: @unchecked Sendable {
    let pool: SegmentBufferPool
    let root: Int32
    let options: AEAExtractionOptions
    let queue = JobQueue<WriteJob>(capacity: 16_384)
    /// Admits at most ``AEAExtractionOptions/fileSystemWidth`` writers to file system calls at once.
    let fileSystem: DispatchSemaphore
    let processUmask: mode_t
    let restoreOwnership: Bool
    /// The most chunks of a single-piece file: a segment's worth, plus one.
    let maximumChunks: Int
    /// Files up to this size are written whole even when they cross a segment boundary (they span two at most).
    let smallSpanLimit: Int
    /// Whether segments are at least a chunk long, so a chunk spans at most two pieces of a file.
    let chunksSpanAtMostTwoPieces: Bool

    let largeFiles: [LargeFile]
    private let freeLargeFiles: Mutex<[Int]>
    private let largeFileAvailable: DispatchSemaphore

    let failure = Mutex<AEAError?>(nil)
    let failed = Atomic<Bool>(false)
    let writeNanoseconds = Atomic<Int>(0)
    let timings = WorkTimings()

    init(pool: SegmentBufferPool, root: Int32, options: AEAExtractionOptions, segmentSize: Int) {
        self.pool = pool
        self.root = root
        self.options = options
        fileSystem = DispatchSemaphore(value: max(1, options.fileSystemWidth))
        let mask = umask(0)
        umask(mask)
        processUmask = mask
        restoreOwnership = options.restoreOwnership && geteuid() == 0
        maximumChunks = segmentSize / Decmpfs.chunkSize + 2
        smallSpanLimit = min(Decmpfs.batchChunks * Decmpfs.chunkSize, segmentSize)
        chunksSpanAtMostTwoPieces = segmentSize >= Decmpfs.chunkSize
        // Files spanning segments: one is being planned at a time, the rest finish without the walker (which waits
        // for a free one). With 4, the walker waited 6.0 s of a 9.0 s extraction: a piece's job waits behind the
        // queue's small files, so a file's state is held that long. They're small; 128 are plenty.
        let count = 128
        largeFiles = (0..<count).map { _ in LargeFile() }
        freeLargeFiles = Mutex(Array(0..<count))
        largeFileAvailable = DispatchSemaphore(value: count)
    }

    func fail(_ error: AEAError) {
        failure.withLock { if $0 == nil { $0 = error } }
        failed.store(true, ordering: .relaxed)
    }

    func acquireLargeFile() -> Int {
        timings.measure(.largeFileWait) { largeFileAvailable.wait() }
        return freeLargeFiles.withLock { $0.removeLast() }
    }

    func releaseLargeFile(_ index: Int) {
        freeLargeFiles.withLock { $0.append(index) }
        largeFileAvailable.signal()
    }

    /// Whether `mode` needs an `fchmod` after `open`/`mkdir` (the umask removed bits, or it has special bits).
    func needsChmod(_ mode: mode_t) -> Bool {
        mode & ~0o777 != 0 || mode & processUmask != 0
    }
}

/// A file whose contents span segments, written in pieces by any writer as segments arrive.
final class LargeFile: @unchecked Sendable {
    /// The NUL-terminated path, copied by the walker (the header's buffer is released before the last piece).
    let path = RawStorage(byteCount: Int(PATH_MAX) + 1)
    var descriptor: Int32 = -1
    var size = 0
    var mode: mode_t = 0
    var flags: UInt32 = 0
    var owner: (uid: UInt32, gid: UInt32)?
    var times = EntryTimes()
    /// The `decmpfs` fork type, or 0 for an uncompressed file. The piece with the first chunk may clear it
    /// (guarded by `turn` from then on).
    var forkType: UInt32 = 0
    var algorithm = COMPRESSION_LZBITMAP
    var chunkCount = 0
    /// Pieces not yet written, plus one held by the walker until it has issued the last piece.
    let outstanding = Atomic<Int>(0)
    /// Compressed pieces go into the resource fork in order: piece `nextPiece` writes at `forkOffset`.
    let turn = NSCondition()
    var nextPiece = 0
    var forkOffset = 0
    var failed = false
    /// Whether the piece with the first chunk has decided between compressed and plain (guarded by `turn`).
    var decided = false
}

/// One unit of work for a writer: a whole file, or a piece of a ``LargeFile``.
struct WriteJob: Sendable {
    enum Kind: Sendable { case file, piece }
    var kind = Kind.file
    /// The path, in a header in buffer `pathBuffer` (offsets from its segment base; negative is the carry region).
    var pathBuffer = -1
    var pathOffset = 0
    var pathCount = 0
    /// The directory the file is created in (its parent, or the destination), and where its name starts in the path.
    var directory: Int32 = -1
    var leaf = 0
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
    var mode: UInt16 = 0o644
    var flags: UInt32 = 0
    var diskCompression: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var times = EntryTimes()
    // Pieces:
    var largeFile = -1
    var piece = 0
    /// The previous piece's buffer, its data's offset there, and its file offset: a compressed piece's first chunk
    /// can start there.
    var previousBuffer = -1
    var previousOffset = 0
    var previousFileOffset = 0
}

// MARK: - The walker's side

struct ExtractionSink: ArchiveSink, ~Copyable {
    let context: ExtractionContext
    var statistics = AEAStatistics()
    private var entry = AAEntryHeader()
    private var headerBuffer = -1
    private var headerOffset = 0
    /// The current file's parent directory and where its name starts in its path.
    private var fileDirectory: Int32 = -1
    private var fileLeaf = 0
    private var largeFile = -1
    private var piece = 0
    private var previous = (buffer: -1, offset: 0, fileOffset: 0)
    /// A small file whose first range has arrived, waiting for its second.
    private var pending: WriteJob?
    /// Whether the open large file was set up compressed: the walker's own copy (writers may change the shared one).
    private var largeFileCompressed = false
    /// The directories made so far, open: entries are created relative to their parent.
    private var directories: DirectoryTable
    /// Links to make at the end: paths and targets, NUL-terminated, in one arena, with each link's parent.
    private var linkBytes: [UInt8] = []
    private var links: [(path: Int, leaf: Int, directory: Int32, target: Int, mode: mode_t, times: EntryTimes)] = []
    /// Directories whose permissions, times, or flags differ from what `mkdir` gave them, with their descriptors
    /// (-1 if not open).
    private var directoryFixes: [(path: [UInt8], descriptor: Int32, mode: mode_t, flags: UInt32, times: EntryTimes, depth: Int)] = []

    init(_ context: ExtractionContext) {
        self.context = context
        directories = DirectoryTable(root: context.root)
        linkBytes.reserveCapacity(1 << 20)
    }

    private func checkFailure() throws(AEAError) {
        if context.failed.load(ordering: .relaxed), let failure = context.failure.withLock({ $0 }) { throw failure }
    }

    mutating func entry(_ entry: AAEntryHeader, header: UnsafeRawPointer, buffer: Int) throws(AEAError) {
        try checkFailure()
        self.entry = entry
        statistics.entries += 1
        guard let path = entry.path, let type = entry.type else { throw .invalidArchive("an entry without a type or path") }
        let pathPointer = unsafe header + path.offset
        try unsafe Paths.check(pathPointer, count: path.count)
        headerBuffer = buffer
        headerOffset = unsafe header - UnsafeRawPointer(context.pool.segmentBase(buffer))
        switch type {
        case .regularFile:
            statistics.files += 1
            statistics.fileBytes += entry.data?.count ?? 0
            statistics.filesByDiskCompression[entry.diskCompression ?? 0, default: 0] += 1
            if entry.hardLinkCluster != nil { statistics.hardLinks += 1 }
            (fileDirectory, fileLeaf) = unsafe directories.resolve(pathPointer, count: path.count)
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
            links.append((pathStart, leaf, parent, targetStart, mode_t(entry.mode ?? 0o755) & 0o7777, EntryTimes(entry)))
        default:
            statistics.otherEntries += 1
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
        if mode | 0o700 != mode || context.needsChmod(mode) || (entry.flags ?? 0) != 0 || context.restoreOwnership || !times.isEmpty {
            let bytes = unsafe Array(UnsafeRawBufferPointer(start: pathPointer, count: count)) // Within the header: safe.
            directoryFixes.append((bytes, descriptor, mode, entry.flags ?? 0, times, bytes.count { $0 == 0x2F }))
        }
    }

    mutating func data(_ bytes: UnsafeRawPointer, count: Int, fileOffset: Int, buffer: Int, segment: Int) throws(AEAError) {
        guard entry.type == .regularFile, let path = entry.path, let data = entry.data else { return }
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
            push(job)
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
            push(job)
            guard fileOffset == job.dataCount, fileOffset + count == data.count else {
                throw .invalidArchive("a small file spans more than two segments")
            }
            return
        }
        if fileOffset == 0 {
            try openLargeFile(path, size: data.count)
            if largeFileCompressed, count < Decmpfs.chunkSize {
                // No whole chunk in this first piece: no job. Its bytes go with the next piece, as that piece's bridge
                // (so the piece holding chunk 0, which decides how the file is stored, is always piece 0).
                pool.retain(buffer)
                previous = (buffer, offset, fileOffset)
                return
            }
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
        if largeFileCompressed, previous.buffer >= 0 {
            // The reference taken for the bridge below, when the previous piece was issued, passes to this job.
            job.previousBuffer = previous.buffer
            job.previousOffset = previous.offset
            job.previousFileOffset = previous.fileOffset
            previous = (-1, 0, 0)
        }
        let isLast = fileOffset + count == data.count
        if largeFileCompressed, !isLast {
            // The next piece's first chunk may start in this buffer: keep it for that job (the walker releases
            // this segment before it reaches the next).
            pool.retain(buffer)
            previous = (buffer, offset, fileOffset)
        }
        piece += 1
        push(job)
        if isLast { finishLargeFile() }
    }

    mutating func extendedAttributes(_ bytes: UnsafeRawPointer, count: Int, offset: Int) throws(AEAError) {}

    mutating func endEntry() throws(AEAError) {
        guard entry.type == .regularFile, let path = entry.path, (entry.data?.count ?? 0) == 0 else { return }
        // An empty file: no data callbacks came.
        let job = baseJob(path)
        context.pool.retain(headerBuffer)
        push(job)
    }

    private func push(_ job: WriteJob) {
        context.timings.measure(.push) { context.queue.push(job) }
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
        job.diskCompression = context.options.diskCompression == .archived ? entry.diskCompression ?? 0 : 0
        job.uid = entry.uid ?? 0
        job.gid = entry.gid ?? 0
        job.times = EntryTimes(entry)
        return job
    }

    /// Sets up a file whose contents span segments: copies its path and opens it here, so pieces can write in any
    /// order.
    private mutating func openLargeFile(_ path: AAHeaderRange, size: Int) throws(AEAError) {
        let index = context.acquireLargeFile()
        let state = context.largeFiles[index]
        let source = unsafe UnsafeRawPointer(context.pool.segmentBase(headerBuffer)) + headerOffset + path.offset
        guard path.count < Int(PATH_MAX) else { throw .unsafePath(unsafe Paths.string(source, count: path.count)) }
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
        // Fork offsets are 32-bit: larger files are written uncompressed. So are files across segments smaller than a
        // chunk (`aea -b` allows them), where a chunk could span more than two pieces.
        if context.options.diskCompression == .archived, size < 1 << 31, context.chunksSpanAtMostTwoPieces,
           let type = entry.diskCompression, let codec = Decmpfs.algorithm(type) {
            state.forkType = codec.fork
            state.algorithm = codec.algorithm
        }
        state.nextPiece = 0
        state.forkOffset = (state.chunkCount + 1) * 4
        state.failed = false
        state.decided = state.forkType == 0
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
        previous = (-1, 0, 0)
    }

    /// The walker has issued the last piece: drop its hold.
    private mutating func finishLargeFile() {
        let state = context.largeFiles[largeFile]
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            Writer.finishLargeFile(context, largeFile)
        }
        largeFile = -1
        previous = (-1, 0, 0)
    }

    /// After a failure mid-file, releases what's held and closes what's open.
    mutating func abandonOpenFile() {
        if let job = pending {
            context.pool.release(job.pathBuffer)
            context.pool.release(job.dataBuffer)
            pending = nil
        }
        if previous.buffer >= 0 {
            context.pool.release(previous.buffer)
            previous = (-1, 0, 0)
        }
        if largeFile >= 0 {
            context.largeFiles[largeFile].turn.lock()
            context.largeFiles[largeFile].failed = true
            context.largeFiles[largeFile].turn.broadcast()
            context.largeFiles[largeFile].turn.unlock()
            finishLargeFile()
        }
    }

    func createSymbolicLinks(threads: Int) throws(AEAError) {
        guard !links.isEmpty else { return }
        let failure = Mutex<AEAError?>(nil)
        let overwrite = context.options.overwrite
        linkBytes.withUnsafeBufferPointer { bytes in
            nonisolated(unsafe) let base = unsafe UnsafeRawPointer(bytes.baseAddress!) // The arena, alive and unchanged until `concurrentPerform` returns.
            let links = self.links
            let lanes = max(1, min(threads, links.count))
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var index = lane
                while index < links.count {
                    let link = links[index]
                    // Offsets into the arena, each a NUL-terminated string: safe.
                    let target = unsafe base.advanced(by: link.target).assumingMemoryBound(to: CChar.self)
                    let name = unsafe base.advanced(by: link.path + link.leaf).assumingMemoryBound(to: CChar.self)
                    var created = unsafe symlinkat(target, link.directory, name) == 0
                    if !created, errno == EEXIST, overwrite {
                        // Replace what's there (not a directory: `unlinkat` without AT_REMOVEDIR leaves those).
                        created = unsafe unlinkat(link.directory, name, 0) == 0 && symlinkat(target, link.directory, name) == 0
                    }
                    if !created {
                        let error = Errno(rawValue: errno)
                        let path = unsafe String(cString: base.advanced(by: link.path).assumingMemoryBound(to: CChar.self))
                        failure.withLock { if $0 == nil { $0 = .fileSystem("symlink \(path)", error) } }
                    } else {
                        if link.mode != 0o755 {
                            // Links get 0755 (`symlinkat` ignores the umask); the archive's mode otherwise, as Apple's
                            // extractor sets it.
                            unsafe fchmodat(link.directory, name, link.mode, AT_SYMLINK_NOFOLLOW)
                        }
                        _ = unsafe link.times.apply(link.directory, name)
                    }
                    index += lanes
                }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func fixDirectories() throws(AEAError) {
        for fix in directoryFixes.sorted(by: { $0.depth > $1.depth }) {
            var descriptor = fix.descriptor
            var opened = false
            if descriptor < 0 {
                var path = fix.path
                path.append(0)
                descriptor = path.withUnsafeBufferPointer { bytes in
                    // A NUL-terminated copy of the path: safe.
                    unsafe openat(context.root, UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                }
                guard descriptor >= 0 else {
                    throw .fileSystem("open \(String(decoding: fix.path, as: UTF8.self))", Errno(rawValue: errno))
                }
                opened = true
            }
            defer { if opened { close(descriptor) } }
            if let failure = Writer.finishAttributes(context, descriptor, mode: fix.mode, flags: fix.flags, owner: nil, forceChmod: true, times: fix.times) {
                if case .fileSystem(let what, let code) = failure {
                    throw .fileSystem("\(what) \(String(decoding: fix.path, as: UTF8.self))", code)
                }
                throw failure
            }
        }
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
