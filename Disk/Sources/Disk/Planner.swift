import Bytes
import BytesAsync
import Darwin
import Synchronization

/// The calling task's side of an extraction: describes the tree, entry by entry, in archive order.
///
/// Directories are made at once (each file's parent exists before the file is queued; parents an archive doesn't list
/// are made too). Files are queued for the writers. Links, special files, extended attributes, ACLs, and directories'
/// final metadata are recorded and made after the writers. Paths, link targets, and blobs are copied into one arena,
/// and the write queue copies each file's path into its own ring: nothing is allocated per entry.
///
/// Every method checks first whether the extraction has stopped (a failure, cancellation) and throws its error if so.
/// With ``ExtractionSettings/stopsOnFirstFailure`` off, an entry that fails is recorded and the method returns
/// ``EntryToken`` with nothing to add to.
public struct Planner<Source: ContentSource>: ~Copyable {
    let context: ExtractionContext<Source>
    let destination: Destination
    let root: Int32
    private var directories: DirectoryTable
    /// The current entry's path, NUL-terminated.
    private let path = RawStorage(byteCount: Int(PATH_MAX) + 1, alignment: RawStorage.small)
    /// The last file's parent, resolved: its path and where its contents are made.
    private let lastParent = RawStorage(byteCount: Int(PATH_MAX) + 1, alignment: RawStorage.small)
    private var lastParentCount = -1
    private var lastParentResolved: (directory: Int32, leaf: Bool) = (-1, false)
    /// Whether the last `ensureDirectory` made its directory (`false`: it was there).
    private var madeLastDirectory = false
    private let progress: ExtractionProgress.Slot?

    /// NUL-terminated paths, link targets, and blobs, appended.
    var arena: [UInt8] = []
    var links: [LinkRecord] = []
    var hardLinks: [HardLinkRecord] = []
    var specials: [SpecialRecord] = []
    var deferred: [DeferredEntry] = []
    var fixes: [DirectoryFix] = []
    var report = ExtractionReport()
    var phases: [ExtractionPhase: Double] = [:]
    /// The blob last appended to: its entry, kind, and where it ended in the arena.
    private var lastBlob: (entry: Int, isACL: Bool, end: Int) = (-1, false, -1)
    // The large file being planned.
    private var largeFile = -1
    private var largePiece = 0
    private var largeBridge = Bridge<Source.Contents>()
    /// Bytes of the bridge's pieces that have no job.
    private var largeBridgedBytes = 0

    struct LinkRecord {
        var path: Int
        var count: Int
        var target: Int
        var metadata: EntryMetadata
        var deferred: Int
        var tag: Int
    }

    struct HardLinkRecord {
        var path: Int
        var target: Int
        var tag: Int
    }

    struct SpecialRecord {
        var path: Int
        var count: Int
        var kind: SpecialFileKind
        var metadata: EntryMetadata
        var tag: Int
    }

    struct DeferredEntry {
        enum Kind { case file, directory, link }
        var kind: Kind
        var path: Int
        var count: Int
        var metadata: EntryMetadata
        var extendedAttributes = 0..<0
        var accessControlList = 0..<0
        var tag: Int
    }

    struct DirectoryFix {
        var path: Int
        var count: Int
        var descriptor: Int32
        var metadata: EntryMetadata
        var depth: Int
        var deferred: Int
        var tag: Int
        /// The directory wasn't made with this entry's mode (it was there, or was made as an entry's parent before the
        /// archive listed it): its mode is set whatever `mkdir` would have left.
        var setsMode = false
        /// A parent the archive didn't list, made on the way to an entry: it gets the quarantine, nothing else.
        var quarantineOnly = false
    }

    init(_ context: ExtractionContext<Source>) {
        self.context = context
        destination = context.destination
        root = context.destination.root
        directories = DirectoryTable()
        progress = context.options.progress?.slot(0)
        arena.reserveCapacity(1 << 16)
    }

    // MARK: Failures

    /// Throws the extraction's stopping failure, if it has one.
    @inline(__always)
    private func checkStopped() throws(DiskError) {
        if context.isStopped, let failure = context.stoppingFailure { throw failure }
    }

    /// An entry failed: stops (throws) or records it, by the options.
    private func entryFailed(_ error: DiskError, tag: Int) throws(DiskError) {
        if context.options.stopsOnFirstFailure {
            context.fail(error, path: currentPath, tag: tag)
            throw error
        }
        context.fail(error, path: currentPath, tag: tag)
    }

    // Unsafe (both properties below): the path buffer as a C string, which `PathRef` measures (`strlen`); `currentRef`
    // keeps the pointer. Safe: every entry method calls `setPath`, which writes a path and its NUL, before anything
    // reads these; the buffer is the planner's, `PATH_MAX + 1` bytes, and a reference is read only while the planner
    // is in the call that made it (the path still there).
    /// The path buffer, NUL-terminated (set by `setPath`).
    private var currentPath: String { unsafe PathRef(cString: path.base.assumingMemoryBound(to: CChar.self)).string }
    private var currentRef: PathRef { unsafe PathRef(cString: path.base.assumingMemoryBound(to: CChar.self)) }

    // MARK: Paths

    /// Copies `entry` into the path buffer, NUL-terminated.
    @inline(__always)
    private mutating func setPath(_ entry: borrowing EntryPath) -> Int {
        let count = entry.bytes.byteCount
        entry.bytes.withUnsafeBytes { bytes in
            // Unsafe: copies the entry's bytes into the path buffer. Safe: `count` is under `PATH_MAX` (an
            // `EntryPath`) and the buffer holds `PATH_MAX + 1`; the span's buffer is valid inside `withUnsafeBytes`
            // and, with `count > 0`, not `nil`.
            if count > 0 { unsafe path.base.copyMemory(from: bytes.baseAddress!, byteCount: count) }
        }
        // Unsafe: stores the NUL after the path. Safe: offset `count`, at most `PATH_MAX - 1`, within the buffer.
        unsafe path.base.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
        return count
    }

    /// Appends `count` bytes of the path buffer to the arena, NUL-terminated: its offset.
    private mutating func storePath(_ count: Int) -> Int {
        let offset = arena.count
        // Unsafe: a buffer over the path buffer's first `count` bytes, appended to the arena. Safe: the planner's own
        // buffer, holding at least `count` bytes of the current path (the caller's `count`, from `setPath` or a prefix
        // of it); the array copies them during the call.
        unsafe arena.append(contentsOf: UnsafeRawBufferPointer(start: path.base, count: count))
        arena.append(0)
        return offset
    }

    /// Where the entry whose path is the first `count` bytes of the path buffer is made: its parent's descriptor and
    /// the name's offset, or the destination and 0. Makes parents that aren't there (checking each one that is).
    private mutating func parent(_ count: Int) throws(DiskError) -> (directory: Int32, leaf: Int) {
        // The path buffer holds the current path's `count` bytes (the caller's contract), `count` under `PATH_MAX`.
        var slash = count - 1
        // Unsafe: loads byte `slash` of the path buffer. Safe: `0 <= slash < count` (tested first), within the path.
        while slash >= 0, unsafe path.base.load(fromByteOffset: slash, as: UInt8.self) != 0x2F { slash -= 1 }
        guard slash > 0 else { return (root, 0) }
        // The usual case: the same parent as the last entry's (archives keep a directory's entries together).
        // Unsafe: `memcmp` of the two buffers' first `slash` bytes. Safe: `slash < count`, within the path; and
        // `slash == lastParentCount`, the bytes copied into the last parent's buffer (the same size) below.
        if slash == lastParentCount, unsafe memcmp(lastParent.base, path.base, slash) == 0 {
            return lastParentResolved.leaf ? (lastParentResolved.directory, slash + 1) : (root, 0)
        }
        // Unsafe: the path buffer's first `slash` bytes, compared in the table. Safe: within the path (`slash <
        // count`); `lookup` only reads them, during the call.
        var descriptor = unsafe directories.lookup(path.base, count: slash)
        if descriptor == nil { descriptor = try ensureDirectory(slash, mode: 0o755, listed: false) }
        let resolved = descriptor ?? -1
        // Unsafe: copies the parent's `slash` bytes into the last parent's buffer. Safe: within the path, under
        // `PATH_MAX`, into a separate buffer of `PATH_MAX + 1` bytes.
        unsafe lastParent.base.copyMemory(from: path.base, byteCount: slash)
        lastParentCount = slash
        lastParentResolved = resolved >= 0 ? (resolved, true) : (root, false)
        return resolved >= 0 ? (resolved, slash + 1) : (root, 0)
    }

    /// Makes (or checks) the directory whose path is the first `count` bytes of the path buffer, and its parents.
    ///
    /// - Parameter listed: Whether the archive lists the directory (``directory(_:metadata:attachments:tag:)`` records
    ///   what it gets at the end). A parent made on the way to an entry isn't listed: if this call makes it, it gets
    ///   the destination's quarantine at the end (as the files in it do), and nothing else.
    /// - Returns: Its descriptor if directories are opened, else -1.
    @discardableResult
    private mutating func ensureDirectory(_ count: Int, mode: mode_t, listed: Bool) throws(DiskError) -> Int32 {
        // Unsafe (the next three): NUL-terminates the prefix in the path buffer, restoring the byte after. Safe: the
        // buffer holds a path longer than `count` (or `count` bytes and its NUL): offset `count` is within it.
        let saved = unsafe path.base.load(fromByteOffset: count, as: UInt8.self)
        unsafe path.base.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
        defer { unsafe path.base.storeBytes(of: saved, toByteOffset: count, as: UInt8.self) }
        let (directory, leaf) = try parent(count)
        // Unsafe: the name's C string in the path buffer. Safe: `leaf` is within the prefix, NUL-terminated above.
        let name = unsafe path.base.advanced(by: leaf).assumingMemoryBound(to: CChar.self)
        // Unsafe: passes it on. Safe: valid for the call (the buffer is the planner's).
        let made = try unsafe destination.makeDirectory(directory, name, mode: mode, path: currentRef)
        madeLastDirectory = made
        var descriptor: Int32 = -1
        if destination.options.directoryResolution == .descriptors {
            // Unsafe and safe as above.
            descriptor = unsafe Sys.openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | destination.openBeneath)
            // At the descriptor limit: its contents use paths from the destination.
            if descriptor < 0 { descriptor = -1 }
        }
        // Unsafe: the prefix's bytes, copied into the table. Safe: `count` bytes of the path buffer.
        unsafe directories.insert(path.base, count: count, descriptor: descriptor)
        if made, !listed, destination.options.quarantine != nil {
            fixes.append(DirectoryFix(
                path: storePath(count), count: count, descriptor: descriptor, metadata: EntryMetadata(), depth: depth(count),
                deferred: -1, tag: -1, quarantineOnly: true
            ))
        }
        return descriptor
    }

    /// How deep the directory at the first `count` bytes of the path buffer is: its components.
    private func depth(_ count: Int) -> Int {
        // Unsafe: a buffer over the path buffer's first `count` bytes. Safe: the planner's own, at least that long.
        unsafe UnsafeRawBufferPointer(start: path.base, count: count).count { $0 == 0x2F } + (count > 0 ? 1 : 0)
    }

    // MARK: Entries

    /// Makes a directory (and missing parents) now; its permissions, times, flags, and attachments are applied after
    /// everything else, deepest first.
    ///
    /// - Parameters:
    ///   - attachments: Extended attributes or an ACL will be added (``addExtendedAttributes(_:to:)``).
    ///   - tag: The caller's tag for failures.
    @discardableResult
    public mutating func directory(_ entry: EntryPath, metadata: EntryMetadata = .init(), attachments: Bool = false, tag: Int = 0) throws(DiskError) -> EntryToken {
        try checkStopped()
        let count = setPath(entry)
        let final = destination.finalMode(metadata.mode, default: 0o755)
        var descriptor: Int32 = -1
        // Whether its mode is what `mkdir` made of this entry's: so for a directory this call makes. One that was
        // there, or was made as some entry's parent before the archive listed it, or the destination itself (an
        // entry for the archive's root: a staging directory is 0700), has another mode: it's set at the end.
        var hasItsMode = count > 0
        if count > 0 {
            do throws(DiskError) {
                // Unsafe: the path buffer's first `count` bytes, compared in the table. Safe: the entry's, just set.
                if let known = unsafe directories.lookup(path.base, count: count) {
                    descriptor = known
                    hasItsMode = false
                } else {
                    descriptor = try ensureDirectory(count, mode: final & 0o777, listed: true)
                    hasItsMode = madeLastDirectory
                }
            } catch {
                try entryFailed(error, tag: tag)
                return .none
            }
        }
        report.directories += 1
        progress?.add(entries: 1, bytes: 0)
        let created = destination.createdMode(final | 0o700)
        let quarantined = destination.options.quarantine != nil && (count > 0 || destination.options.quarantinesDestination)
        let needsFix = !hasItsMode || final != created || !metadata.times.isEmpty || destination.finalFlags(metadata.flags, compressed: false) != 0
            || destination.finalOwner(metadata.owner) != nil || quarantined || attachments
        guard needsFix else { return .none }
        let stored = storePath(count)
        var deferredIndex = -1
        if attachments {
            deferred.append(DeferredEntry(kind: .directory, path: stored, count: count, metadata: metadata, tag: tag))
            deferredIndex = deferred.count - 1
        }
        fixes.append(DirectoryFix(
            path: stored, count: count, descriptor: descriptor, metadata: metadata, depth: depth(count), deferred: deferredIndex,
            tag: tag, setsMode: !hasItsMode
        ))
        return EntryToken(deferred: deferredIndex, path: -1)
    }

    /// Flags that would stop `link` on a file.
    private static var lockingFlags: UInt32 { UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) }

    /// Queues a file for the writers, suspending while the queue is full.
    ///
    /// The call takes `contents`: they're released (``ContentSource/release(_:)``) exactly once, whether or not it
    /// succeeds.
    ///
    /// - Parameters:
    ///   - size: The file's size, if known (a file of unknown size is streamed, and stored plain).
    ///   - storage: Plain, or APFS-compressed by a policy.
    ///   - attachments: Extended attributes or an ACL will be added: the file's mode, times, and flags wait for them.
    ///   - hardLinked: Other names will be linked to it (``hardLink(_:to:metadata:tag:)``).
    @discardableResult
    public mutating func file(
        _ entry: EntryPath, size: Int?, contents: Source.Contents, metadata: EntryMetadata = .init(), storage: Storage = .plain,
        attachments: Bool = false, hardLinked: Bool = false, tag: Int = 0
    ) async throws(DiskError) -> EntryToken {
        do throws(DiskError) {
            try checkStopped()
        } catch {
            context.source.release(contents)
            throw error
        }
        let count = setPath(entry)
        let resolved: (directory: Int32, leaf: Int)
        do throws(DiskError) {
            guard count > 0 else { throw .unsafePath("") }
            resolved = try parent(count)
        } catch {
            context.source.release(contents)
            try entryFailed(error, tag: tag)
            return .none
        }
        var token = EntryToken.none
        let defers = attachments || (hardLinked && metadata.flags & Self.lockingFlags != 0)
        if defers || hardLinked {
            let stored = storePath(count)
            var deferredIndex = -1
            if defers {
                deferred.append(DeferredEntry(kind: .file, path: stored, count: count, metadata: metadata, tag: tag))
                deferredIndex = deferred.count - 1
            }
            token = EntryToken(deferred: deferredIndex, path: hardLinked ? stored : -1)
        }
        var job = WriteJob<Source.Contents>(kind: .file, contents: contents)
        job.directory = resolved.directory
        job.leaf = resolved.leaf
        job.size = size ?? -1
        job.metadata = metadata
        job.storage = storage
        job.deferred = defers
        job.tag = tag
        // Closed only after the plan: the push lands.
        // Unsafe: a buffer over the path buffer's first `count` bytes, to `push`, across its waits. Safe: the entry's
        // path (`setPath`), in the planner's own buffer, which nothing changes until `push` returns (the planner is
        // suspended in this call); the queue copies the bytes into its ring before then.
        _ = unsafe await context.queue.push(job, path: unsafe UnsafeRawBufferPointer(start: path.base, count: count))
        return token
    }

    /// Records a symbolic link, made after everything else (so nothing is written through it).
    @discardableResult
    public mutating func symbolicLink(_ entry: EntryPath, target: RawSpan, metadata: EntryMetadata = .init(), attachments: Bool = false, tag: Int = 0) throws(DiskError) -> EntryToken {
        try checkStopped()
        let count = setPath(entry)
        do throws(DiskError) {
            guard count > 0 else { throw .unsafePath("") }
            guard target.byteCount < Int(PATH_MAX) else { throw .invalidMetadata("a link target of \(target.byteCount) bytes") }
            _ = try parent(count)
        } catch {
            try entryFailed(error, tag: tag)
            return .none
        }
        let stored = storePath(count)
        let targetOffset = arena.count
        // Unsafe: appends the closure's raw buffer to the arena. Safe: the target span's own bytes, valid inside
        // `withUnsafeBytes`; the array copies them before the closure returns.
        target.withUnsafeBytes { unsafe arena.append(contentsOf: $0) }
        arena.append(0)
        var deferredIndex = -1
        if attachments {
            deferred.append(DeferredEntry(kind: .link, path: stored, count: count, metadata: metadata, tag: tag))
            deferredIndex = deferred.count - 1
        }
        links.append(LinkRecord(path: stored, count: count, target: targetOffset, metadata: metadata, deferred: deferredIndex, tag: tag))
        return EntryToken(deferred: deferredIndex, path: -1)
    }

    /// Records another name for a file planned with `hardLinked` (so only files this extraction writes can be linked),
    /// made after the writers (`linkat` relative to the destination, following no link in either path).
    public mutating func hardLink(_ entry: EntryPath, to file: EntryToken, tag: Int = 0) throws(DiskError) {
        try checkStopped()
        let count = setPath(entry)
        do throws(DiskError) {
            guard count > 0 else { throw .unsafePath("") }
            guard file.path >= 0 else { throw .refused("a hard link to a file not planned as hardLinked: \(currentPath)") }
            _ = try parent(count)
        } catch {
            try entryFailed(error, tag: tag)
            return
        }
        hardLinks.append(HardLinkRecord(path: storePath(count), target: file.path, tag: tag))
    }

    /// Records a FIFO or device, made after the writers (devices: as root, with ``DestinationOptions/allowsDevices``).
    public mutating func specialFile(_ entry: EntryPath, _ kind: SpecialFileKind, metadata: EntryMetadata = .init(), tag: Int = 0) throws(DiskError) {
        try checkStopped()
        let count = setPath(entry)
        do throws(DiskError) {
            guard count > 0 else { throw .unsafePath("") }
            if case .fifo = kind {} else if !destination.options.allowsDevices {
                throw .refused("a device: \(currentPath)")
            }
            _ = try parent(count)
        } catch {
            try entryFailed(error, tag: tag)
            return
        }
        specials.append(SpecialRecord(path: storePath(count), count: count, kind: kind, metadata: metadata, tag: tag))
    }

    /// Adds extended attributes (an `XAT` blob, ``ExtendedAttributeBlob``) to an entry planned with `attachments`.
    /// A blob may come in several calls, in order.
    public mutating func addExtendedAttributes(_ blob: RawSpan, to entry: EntryToken) throws(DiskError) {
        try addBlob(blob, to: entry, isACL: false)
    }

    /// Adds an ACL (an Apple Archive `ACL` blob) to an entry planned with `attachments`.
    public mutating func addAccessControlList(_ blob: RawSpan, to entry: EntryToken) throws(DiskError) {
        try addBlob(blob, to: entry, isACL: true)
    }

    private mutating func addBlob(_ blob: RawSpan, to entry: EntryToken, isACL: Bool) throws(DiskError) {
        try checkStopped()
        guard entry.deferred >= 0, entry.deferred < deferred.count else { throw .refused("attachments for an entry planned without them") }
        let index = entry.deferred
        var range = isACL ? deferred[index].accessControlList : deferred[index].extendedAttributes
        if !range.isEmpty, !(lastBlob.entry == index && lastBlob.isACL == isACL && lastBlob.end == arena.count) {
            // Not contiguous with the earlier part: move that to the end first (blobs are self-delimiting entries).
            let earlier = Array(arena[range])
            range = arena.count..<arena.count
            arena.append(contentsOf: earlier)
            range = range.lowerBound..<arena.count
        }
        let start = range.isEmpty ? arena.count : range.lowerBound
        // Unsafe: appends the closure's raw buffer to the arena. Safe: the blob span's own bytes, valid inside
        // `withUnsafeBytes`; the array copies them before the closure returns.
        blob.withUnsafeBytes { unsafe arena.append(contentsOf: $0) }
        range = start..<arena.count
        if isACL { deferred[index].accessControlList = range } else { deferred[index].extendedAttributes = range }
        lastBlob = (index, isACL, arena.count)
    }

    // MARK: Large files

    /// Opens a file whose contents come in pieces (``piece(_:of:at:count:)``), in order, as they arrive: each piece is a
    /// job, so pieces are written (and compressed, in parallel) while later ones are still coming. Suspends while all
    /// ``ExtractionSettings/largeFileSlots`` are in use.
    ///
    /// - Parameters:
    ///   - first: The file's first bytes (at least 8, for a policy that skips PNGs).
    ///   - minimumPieceSize: The smallest piece but the last: compressed files need pieces of at least a seventh of a
    ///     64 KiB chunk (a chunk spans at most 8 pieces); smaller ones are stored plain.
    public mutating func beginLargeFile(
        _ entry: EntryPath, size: Int, metadata: EntryMetadata = .init(), storage: Storage = .plain, first: RawSpan,
        minimumPieceSize: Int, attachments: Bool = false, hardLinked: Bool = false, tag: Int = 0
    ) async throws(DiskError) -> LargeFileToken where Source: PieceSource {
        try checkStopped()
        precondition(largeFile < 0, "a large file is already open")
        let count = setPath(entry)
        let resolved: (directory: Int32, leaf: Int)
        do throws(DiskError) {
            guard count > 0 else { throw .unsafePath("") }
            resolved = try parent(count)
        } catch {
            try entryFailed(error, tag: tag)
            return LargeFileToken(slot: -1, size: size, isCompressed: false, entry: .none)
        }
        var token = EntryToken.none
        let defers = attachments || (hardLinked && metadata.flags & Self.lockingFlags != 0)
        if defers || hardLinked {
            let stored = storePath(count)
            var deferredIndex = -1
            if defers {
                deferred.append(DeferredEntry(kind: .file, path: stored, count: count, metadata: metadata, tag: tag))
                deferredIndex = deferred.count - 1
            }
            token = EntryToken(deferred: deferredIndex, path: hardLinked ? stored : -1)
        }
        let index = await context.freeLargeFiles.acquire()
        let state = context.largeFiles.make(index)
        // Unsafe: copies the path and its NUL from the path buffer into the slot's path storage. Safe: `count + 1`
        // bytes, at most `PATH_MAX`, which `setPath` wrote (nothing has changed them since); the slot's storage is
        // `PATH_MAX + 1` bytes, and no writer reads it now: the planner holds `index`, and no job names it yet.
        unsafe state.path.base.copyMemory(from: path.base, byteCount: count + 1)
        state.pathCount = count
        state.directory = resolved.directory
        state.leaf = resolved.leaf
        state.size = size
        state.metadata = metadata
        state.mode = destination.finalMode(metadata.mode, default: 0o644)
        state.deferred = defers
        state.tag = tag
        state.chunkCount = (size + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        state.policy = nil
        // Fork offsets are 32-bit; pieces must be big enough for a chunk's pieces to fit a bridge.
        if case .compressed(let policy) = storage, size < 1 << 31, minimumPieceSize * (Bridge<Source.Contents>.capacity - 1) >= Decmpfs.chunkSize,
           policy.codec.types.fork != 0, !policy.skips(size: size, first: first.extracting(first: min(8, first.byteCount))) {
            state.policy = policy
        }
        state.resetTurns(forkOffset: (state.chunkCount + 1) * 4)
        state.outstanding.store(1, ordering: .relaxed)
        // Opened here, so pieces can be written in any order.
        // Unsafe: a C string from `leaf` bytes into the slot's path. Safe: the path copied above, NUL-terminated;
        // `leaf` is where its last component starts (`parent`), before the NUL; bytes are `CChar`-compatible.
        let name = unsafe state.path.base.advanced(by: resolved.leaf).assumingMemoryBound(to: CChar.self)
        do throws(DiskError) {
            // Unsafe: `name` to `createFile`. Safe: NUL-terminated, in the slot's storage, which lives as long as the
            // extraction and isn't changed during the call; `createFile` doesn't keep it.
            let descriptor = try unsafe destination.createFile(resolved.directory, name, mode: destination.creationMode(state.mode), path: state.pathRef)
            guard descriptor >= 0 else { throw .exists(currentPath) }
            state.descriptor = descriptor
        } catch {
            context.freeLargeFiles.release(index)
            try entryFailed(error, tag: tag)
            return LargeFileToken(slot: -1, size: size, isCompressed: false, entry: .none)
        }
        largeFile = index
        largePiece = 0
        largeBridge = Bridge()
        largeBridgedBytes = 0
        return LargeFileToken(slot: index, size: size, isCompressed: state.policy != nil, entry: token)
    }

    /// Queues the next piece of a large file: `count` bytes at `fileOffset` (pieces in order, the last ending at the
    /// file's size). Takes `contents`, as ``file(_:size:contents:metadata:storage:attachments:hardLinked:tag:)`` does.
    public mutating func piece(_ contents: Source.Contents, of file: LargeFileToken, at fileOffset: Int, count: Int) async throws(DiskError) where Source: PieceSource {
        guard file.slot >= 0, file.slot == largeFile, !context.isStopped else {
            context.source.release(contents)
            try checkStopped()
            return
        }
        let state = context.largeFiles[file.slot]
        let isLast = fileOffset + count == file.size
        let chunkSize = Decmpfs.chunkSize
        if state.policy != nil, !isLast, (fileOffset + count) / chunkSize == fileOffset / chunkSize {
            // No chunk ends in this piece: no job. Its bytes go to the piece that completes the chunk, which counts them
            // in the progress too.
            largeBridge.append(contents, fileOffset: fileOffset, count: count)
            largeBridgedBytes += count
            return
        }
        var job = WriteJob<Source.Contents>(kind: .piece, contents: contents)
        job.largeFile = file.slot
        job.piece = largePiece
        job.fileOffset = fileOffset
        job.count = count
        job.size = file.size
        job.tag = state.tag
        if state.policy != nil {
            job.bridge = largeBridge
            job.bridgedBytes = largeBridgedBytes
            largeBridge = Bridge()
            largeBridgedBytes = 0
            if !isLast, (fileOffset + count) % chunkSize != 0 {
                // The next chunk starts here: keep the bytes for the piece that completes it.
                context.source.retain(contents)
                largeBridge.append(contents, fileOffset: fileOffset, count: count)
            }
        }
        largePiece += 1
        // The last piece takes over the planner's hold on the file.
        if !isLast { state.outstanding.add(1, ordering: .relaxed) }
        // Unsafe: a raw buffer to `push`. Safe: empty (`nil`, 0 bytes: a piece job carries no path), so nothing is
        // read through it.
        _ = unsafe await context.queue.push(job, path: unsafe UnsafeRawBufferPointer(start: nil, count: 0))
        if isLast { largeFile = -1 }
    }

    /// After a failure mid-file: releases what the planner holds and closes the file if no piece is left.
    mutating func abandonOpenFile() async {
        for index in 0..<largeBridge.count { context.source.release(largeBridge[index].contents) }
        largeBridge = Bridge()
        largeBridgedBytes = 0
        guard largeFile >= 0 else { return }
        let state = context.largeFiles[largeFile]
        state.failTurns()
        let index = largeFile
        largeFile = -1
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            Sys.close(state.descriptor)
            // Unsafe: a C string from `leaf` bytes into the slot's path storage, to `unlinkat`. Safe: `beginLargeFile`
            // copied the path there NUL-terminated, with `leaf` where its last component starts; no piece is left
            // (the count just reached 0), so only the planner uses the slot until its index is released, below.
            _ = unsafe Sys.unlinkat(state.directory, state.path.base.advanced(by: state.leaf).assumingMemoryBound(to: CChar.self), AT_SYMLINK_NOFOLLOW_ANY)
            state.descriptor = -1
            context.freeLargeFiles.release(index)
        }
    }

    func closeDirectories() {
        directories.closeAll()
    }
}

// MARK: - The directory table

/// The directories made or checked so far, by path, each with its descriptor (-1 unless directories are opened):
/// a file's parent is in it, or is made (and checked) before the file. An open-addressed table keyed by the path's
/// bytes, in one arena: no allocation per lookup. Only the planner touches it.
struct DirectoryTable: ~Copyable {
    private var arena: [UInt8] = []
    private var entries: [(hash: UInt64, start: Int, count: Int, descriptor: Int32)] = []
    /// Indices into `entries`, plus one; 0 is empty. A power of two, at most half full.
    private var slots: [Int32] = Array(repeating: 0, count: 1 << 10)

    init() {}

    @inline(__always)
    private static func hash(_ bytes: UnsafeRawPointer, _ count: Int) -> UInt64 {
        // FNV-1a.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for index in 0..<count {
            // Unsafe: loads byte `index`. Safe: `index < count`, and the caller's `count` bytes at `bytes` are
            // readable for the call (its contract).
            hash = (hash ^ UInt64(unsafe bytes.load(fromByteOffset: index, as: UInt8.self))) &* 0x100_0000_01B3
        }
        return hash
    }

    /// The directory at `path` (`count` bytes): its descriptor (-1: not opened), or `nil` if it isn't known.
    func lookup(_ path: UnsafeRawPointer, count: Int) -> Int32? {
        if entries.isEmpty { return nil }
        // Unsafe: `path` to `hash`. Safe: the caller's `count` readable bytes, valid for this call (its contract).
        let hash = unsafe Self.hash(path, count)
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while slots[slot] != 0 {
            let entry = entries[Int(slots[slot]) - 1]
            if entry.hash == hash, entry.count == count {
                // Unsafe: `memcmp` of an entry's bytes in the arena with the caller's. Safe: `insert` appended the
                // entry's `entry.count` bytes at `entry.start`, and `entry.count == count` (just tested), so both
                // sides have `count` bytes; the arena's buffer is valid inside `withUnsafeBytes`, and not `nil` (it
                // holds this entry: no path here is empty).
                let equal = arena.withUnsafeBytes { unsafe memcmp($0.baseAddress! + entry.start, path, count) == 0 }
                if equal { return entry.descriptor }
            }
            slot = (slot + 1) & mask
        }
        return nil
    }

    mutating func insert(_ path: UnsafeRawPointer, count: Int, descriptor: Int32) {
        if (entries.count + 1) * 2 > slots.count { grow() }
        // Unsafe: `path` to `hash`. Safe: the caller's `count` readable bytes, valid for this call (its contract).
        let hash = unsafe Self.hash(path, count)
        let start = arena.count
        // Unsafe: a buffer over the caller's bytes, appended to the arena. Safe: the same `count` bytes; the array
        // copies them during the call, and they aren't in the arena itself (the planner's path buffer).
        unsafe arena.append(contentsOf: UnsafeRawBufferPointer(start: path, count: count))
        entries.append((hash, start, count, descriptor))
        place(entries.count - 1)
    }

    private mutating func place(_ index: Int) {
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: entries[index].hash) & mask
        while slots[slot] != 0 { slot = (slot + 1) & mask }
        slots[slot] = Int32(index + 1)
    }

    private mutating func grow() {
        slots = Array(repeating: 0, count: slots.count * 2)
        for index in entries.indices { place(index) }
    }

    func closeAll() {
        for entry in entries where entry.descriptor >= 0 { Sys.close(entry.descriptor) }
    }
}
