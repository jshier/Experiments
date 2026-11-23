import BytesAsync
import Darwin
import Synchronization

/// The first failure of a pass spread over lanes.
final class FirstFailure: Sendable {
    private let stored = Mutex<DiskError?>(nil)

    func record(_ error: DiskError) {
        stored.withLock { if $0 == nil { $0 = error } }
    }

    var error: DiskError? { stored.withLock { $0 } }
}

/// An arena shared read-only by a pass's lanes: the planner's, complete when the passes run.
@safe
struct SharedArena: @unchecked Sendable {
    // Unchecked: read only, by the lanes of one pass, while the planner (which owns it) waits for them.
    let base: UnsafeRawPointer

    init(_ base: UnsafeRawPointer) {
        // Unsafe: stores the arena's base pointer. Safe: read only by `cString` and `span`, during the passes, while
        // `Planner.finish` keeps the array it points into alive and unchanged.
        unsafe self.base = base
    }

    @inline(__always)
    func cString(_ offset: Int) -> UnsafePointer<CChar> {
        // Unsafe: a C string at `offset` in the arena. Safe: callers pass only offsets the planner recorded
        // (`storePath`, a link's target), each the start of bytes it appended with a NUL after them; the arena
        // outlives the pass, and bytes are `CChar`-compatible.
        unsafe (base + offset).assumingMemoryBound(to: CChar.self)
    }

    @inline(__always) @_lifetime(borrow self)
    func span(_ range: Range<Int>) -> RawSpan {
        // Unsafe (the next two): a span over `range` of the arena, its lifetime set by hand to a borrow of `self`.
        // Safe: callers pass only ranges the planner recorded for blobs it appended (`addBlob`), within the arena;
        // the arena outlives the pass, as does every copy of this value used in it.
        let span = unsafe RawSpan(_unsafeStart: base + range.lowerBound, byteCount: range.count)
        return unsafe _overrideLifetime(span, borrowing: self)
    }
}

extension Planner {
    /// The passes after the writers: hard links, special files, symbolic links, deferred metadata, directories.
    mutating func finish() async throws(DiskError) {
        var phaseStarted = MonotonicClock.now
        func phase(_ name: ExtractionPhase, _ phases: inout [ExtractionPhase: Double]) {
            let now = MonotonicClock.now
            phases[name] = Double(now - phaseStarted) / 1e9
            phaseStarted = now
        }
        arena.append(0) // Never empty: lanes take its base.
        let arena = self.arena
        let width = max(1, context.options.fileSystemWidth)
        let progress = context.options.progress?.slot(0)
        // Unsafe: the array's base address, taken out of `withUnsafeBytes` and kept for the passes. Safe: `arena` is a
        // constant holding the array's storage (not empty: a byte was just appended, so the base isn't `nil`), never
        // mutated, and kept alive past the last pass by the `defer` below; a native array's storage doesn't move
        // while that holds, and the lanes only read it.
        let shared = unsafe SharedArena(arena.withUnsafeBytes { $0.baseAddress! })
        defer { withExtendedLifetime(arena) {} }
        do {
            try await hardLinkPass(shared, width: width, progress: progress)
            phase(.hardLinks, &phases)
            try specialPass(shared, progress: progress)
            phase(.specialFiles, &phases)
            try await linkPass(shared, width: width, progress: progress)
            phase(.symbolicLinks, &phases)
            try await deferredPass(shared, width: width)
            phase(.deferred, &phases)
            try await directoryPass(shared, width: width)
            phase(.directories, &phases)
        }
    }

    /// Runs `body` for items `0..<count` in `width` lanes (child tasks), each taking every `width`-th item and checking
    /// for cancellation and a stop between items. Their work is file system calls, each blocking its thread: `width`
    /// is the file system width.
    private func inLanes(_ count: Int, width: Int, _ body: @escaping @Sendable (Int) throws(DiskError) -> Void) async throws(DiskError) {
        guard count > 0 else { return }
        let failure = FirstFailure()
        let context = self.context
        let lanes = max(1, min(width, count))
        await withDiscardingTaskGroup { group in
            for lane in 0..<lanes {
                group.addTask {
                    var index = lane
                    while index < count {
                        if Task.isCancelled {
                            failure.record(.cancelled)
                            return
                        }
                        if context.isStopped { return }
                        do throws(DiskError) {
                            try body(index)
                        } catch {
                            if context.options.stopsOnFirstFailure { failure.record(error) }
                        }
                        index += lanes
                    }
                }
            }
        }
        if let error = failure.error {
            context.fail(error, path: "", tag: -1, stopping: true)
            throw error
        }
        if let stopping = context.stoppingFailure { throw stopping }
    }

    private static func record(_ context: ExtractionContext<Source>, _ error: DiskError, path: UnsafePointer<CChar>, tag: Int) throws(DiskError) {
        if !context.options.stopsOnFirstFailure {
            // Unsafe: `path` as a `PathRef` (`strlen`, then its bytes). Safe: the caller's NUL-terminated string in
            // the arena, which outlives the pass; read at once, into the failure's string.
            context.fail(error, path: unsafe PathRef(cString: path).string, tag: tag)
            return
        }
        throw error
    }

    // MARK: Hard links

    private mutating func hardLinkPass(_ arena: SharedArena, width: Int, progress: ExtractionProgress.Slot?) async throws(DiskError) {
        let links = hardLinks, destination = self.destination
        let context = self.context
        let counter = RelaxedCounter(), skipped = RelaxedCounter()
        try await inLanes(links.count, width: width) { index throws(DiskError) in
            let link = links[index]
            do throws(DiskError) {
                // Unsafe: two C strings from the arena to `makeHardLink`. Safe: `link.path` and `link.target` are
                // offsets `storePath` returned (the link's path, and the path of the file it names, from the token
                // this planner gave for it): NUL-terminated strings in the arena, which outlives the pass.
                if try unsafe destination.makeHardLink(arena.cString(link.path), to: arena.cString(link.target)) {
                    counter.add()
                    progress?.add(entries: 1, bytes: 0)
                } else {
                    skipped.add()
                }
            } catch {
                // Unsafe: the link's path, from the arena, to `record`. Safe: the same NUL-terminated string.
                try unsafe Self.record(context, error, path: arena.cString(link.path), tag: link.tag)
            }
        }
        report.hardLinks += counter.value
        report.skipped += skipped.value
    }

    // MARK: Special files

    private mutating func specialPass(_ arena: SharedArena, progress: ExtractionProgress.Slot?) throws(DiskError) {
        for special in specials {
            if Task.isCancelled { throw .cancelled }
            do throws(DiskError) {
                // Unsafe: a C string from the arena to `makeSpecialFile`. Safe: `special.path` is the offset
                // `storePath` returned for its path: `special.count` bytes and a NUL, in the arena, which outlives
                // the pass.
                if try unsafe destination.makeSpecialFile(arena.cString(special.path), count: special.count, special.kind, metadata: special.metadata) {
                    report.specialFiles += 1
                    progress?.add(entries: 1, bytes: 0)
                } else {
                    report.skipped += 1
                }
            } catch {
                // Unsafe: the file's path, from the arena, to `record`. Safe: the same NUL-terminated string.
                try unsafe Self.record(context, error, path: arena.cString(special.path), tag: special.tag)
            }
        }
    }

    // MARK: Symbolic links

    private mutating func linkPass(_ arena: SharedArena, width: Int, progress: ExtractionProgress.Slot?) async throws(DiskError) {
        let links = self.links, deferred = self.deferred, destination = self.destination
        let context = self.context
        let counter = RelaxedCounter(), skipped = RelaxedCounter()
        try await inLanes(links.count, width: width) { index throws(DiskError) in
            let link = links[index]
            let blob = link.deferred >= 0 && !deferred[link.deferred].extendedAttributes.isEmpty ? arena.span(deferred[link.deferred].extendedAttributes) : nil
            do throws(DiskError) {
                // Unsafe: two C strings from the arena to `makeSymbolicLink`. Safe: `link.path` is the offset
                // `storePath` returned (`link.count` bytes and a NUL) and `link.target` where `symbolicLink` appended
                // the target and a NUL: both in the arena, which outlives the pass.
                if try unsafe destination.makeSymbolicLink(arena.cString(link.path), count: link.count, target: arena.cString(link.target), metadata: link.metadata, attributes: blob) {
                    counter.add()
                    progress?.add(entries: 1, bytes: 0)
                } else {
                    skipped.add()
                }
            } catch {
                // Unsafe: the link's path, from the arena, to `record`. Safe: the same NUL-terminated string.
                try unsafe Self.record(context, error, path: arena.cString(link.path), tag: link.tag)
            }
        }
        report.symbolicLinks += counter.value
        report.skipped += skipped.value
    }

    // MARK: Deferred files

    /// Files that waited for the writers: extended attributes and ACLs, then mode, times, owner, and flags in one call.
    private func deferredPass(_ arena: SharedArena, width: Int) async throws(DiskError) {
        let files = deferred.filter { $0.kind == .file }
        let destination = self.destination
        let context = self.context
        try await inLanes(files.count, width: width) { index throws(DiskError) in
            let entry = files[index]
            // Unsafe: a C string from the arena, kept for this item. Safe: `entry.path` is the offset `storePath`
            // returned for the file's path: NUL-terminated, in the arena, which outlives the pass. Every `PathRef` of
            // it below is read before this closure returns.
            let path = unsafe arena.cString(entry.path)
            do throws(DiskError) {
                // Unsafe: `path` to `openat`. Safe: NUL-terminated (above); read only during the call.
                let descriptor = unsafe Sys.openat(destination.root, path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | destination.openBeneath)
                // A file the writers skipped or that failed isn't there: nothing to finish.
                guard descriptor >= 0 else {
                    if errno == ENOENT { return }
                    // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated, in the arena; read at once, into the error.
                    throw .system("open", path: unsafe PathRef(cString: path), code: errno)
                }
                defer { Sys.close(descriptor) }
                if !entry.extendedAttributes.isEmpty {
                    // Unsafe: `path` as a `PathRef`, to `applyExtendedAttributes`. Safe: as above; read while it runs.
                    try unsafe EntryAttributes.applyExtendedAttributes(descriptor, arena.span(entry.extendedAttributes), path: PathRef(cString: path))
                }
                if !entry.accessControlList.isEmpty {
                    // Unsafe: `path` as a `PathRef`, to `applyAccessControlList`. Safe: as above; read while it runs.
                    try unsafe EntryAttributes.applyAccessControlList(descriptor, arena.span(entry.accessControlList), path: PathRef(cString: path))
                }
                // The writer set `UF_COMPRESSED` if it compressed the file.
                var info = stat()
                // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated, in the arena; read at once, into the error.
                guard Sys.fstat(descriptor, &info) == 0 else { throw .system("stat", path: unsafe PathRef(cString: path), code: errno) }
                let compressed = info.st_flags & UInt32(UF_COMPRESSED) != 0
                let final = destination.finalMode(entry.metadata.mode, default: 0o644)
                // The mode always: the file was made owner-writable.
                var attributes = destination.attributes(entry.metadata, mode: final, created: ~final, compressed: compressed)
                // Unsafe: `path` as a `PathRef`. Safe: NUL-terminated, in the arena; read at once, into the error.
                if attributes.apply(descriptor) != 0 { throw .system("setattrlist", path: unsafe PathRef(cString: path), code: errno) }
            } catch {
                // Unsafe: `path` to `record`. Safe: the same NUL-terminated string; `record` reads it at once.
                try unsafe Self.record(context, error, path: path, tag: entry.tag)
            }
        }
    }

    // MARK: Directories

    /// Directories' quarantine, attachments, mode, times, owner, and flags: deepest first (a parent's mode may stop
    /// opening what's in it), each depth's in parallel.
    private func directoryPass(_ arena: SharedArena, width: Int) async throws(DiskError) {
        guard !fixes.isEmpty else { return }
        let sorted = fixes.sorted { $0.depth > $1.depth }
        let context = self.context
        let deferred = self.deferred, destination = self.destination
        var start = 0
        while start < sorted.count {
            var end = start
            while end < sorted.count, sorted[end].depth == sorted[start].depth { end += 1 }
            let level = Array(sorted[start..<end])
            try await inLanes(level.count, width: width) { index throws(DiskError) in
                let fix = level[index]
                // Unsafe: a C string from the arena, kept for this item. Safe: `fix.path` is the offset `storePath`
                // returned for the directory's path: `fix.count` bytes and a NUL, in the arena, which outlives the
                // pass.
                let path = unsafe arena.cString(fix.path)
                do throws(DiskError) {
                    // Unsafe: `path` to `fixDirectory`. Safe: NUL-terminated, `fix.count` bytes before the NUL (above),
                    // valid for the call.
                    try unsafe Self.fixDirectory(destination, fix, path: path, attachments: fix.deferred >= 0 ? deferred[fix.deferred] : nil, arena)
                } catch {
                    // Unsafe: `path` to `record`. Safe: the same NUL-terminated string; `record` reads it at once.
                    try unsafe Self.record(context, error, path: path, tag: fix.tag)
                }
            }
            start = end
        }
    }

    private static func fixDirectory(
        _ destination: Destination, _ fix: DirectoryFix, path: UnsafePointer<CChar>, attachments: DeferredEntry?, _ arena: SharedArena
    ) throws(DiskError) {
        let isRoot = fix.count == 0
        let final = destination.finalMode(fix.metadata.mode, default: 0o755)
        // What it has now, as far as it's known: `~final` (never equal) makes the mode be set.
        let created = fix.setsMode ? ~final : destination.createdMode(final | 0o700)
        let quarantine = isRoot && !destination.options.quarantinesDestination ? nil : destination.options.quarantine
        // A parent the archive didn't list gets the quarantine and nothing else (its mode is what `mkdir` gave it).
        if fix.quarantineOnly, quarantine == nil { return }
        // Only the quarantine to set (the common case): by path, one call instead of open, set, close.
        let onlyQuarantine = fix.quarantineOnly || (attachments == nil && final == created && fix.metadata.times.isEmpty
            && destination.finalFlags(fix.metadata.flags, compressed: false) == 0 && destination.finalOwner(fix.metadata.owner) == nil)
        if fix.descriptor < 0, !isRoot, let quarantine, !destination.resolvedPath.isEmpty, onlyQuarantine {
            let total = destination.resolvedPath.count + 1 + fix.count
            let result = withUnsafeTemporaryAllocation(byteCount: total + 1, alignment: 1) { buffer -> Int32 in
                // Unsafe: builds root | "/" | path | NUL in the stack buffer. Safe: `total + 1` bytes of it, from the
                // resolved root (its count) and the arena's `fix.count` path bytes.
                destination.resolvedPath.withUnsafeBytes { unsafe buffer.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                unsafe buffer.storeBytes(of: 0x2F, toByteOffset: destination.resolvedPath.count, as: UInt8.self)
                unsafe (buffer.baseAddress! + destination.resolvedPath.count + 1).copyMemory(from: path, byteCount: fix.count)
                unsafe buffer.storeBytes(of: 0, toByteOffset: total, as: UInt8.self)
                return quarantine.value.withUnsafeBytes {
                    // Unsafe: the C string just built and the value's bytes. Safe: both valid for the call.
                    unsafe Sys.setxattr(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), EntryAttributes.quarantine, $0.baseAddress, $0.count, XATTR_NOFOLLOW_ANY)
                }
            }
            // Unsafe: `path` for the message. Safe: NUL-terminated in the arena, which outlives the pass.
            if result != 0 { throw .system("setxattr quarantine", path: unsafe PathRef(cString: path), code: errno) }
            return
        }
        // Unsafe: `path` for messages. Safe: NUL-terminated in the arena, which outlives the pass.
        let name = unsafe PathRef(cString: path)
        var descriptor = fix.descriptor
        if descriptor < 0 {
            // Unsafe: C strings passed to `openat`. Safe: a literal, or `path` (NUL-terminated in the arena), valid
            // for the call.
            descriptor = isRoot
                ? unsafe Sys.openat(destination.root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                : unsafe Sys.openat(destination.root, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | destination.openBeneath)
            guard descriptor >= 0 else { throw .system("open", path: name, code: errno) }
        }
        defer { if fix.descriptor < 0 { Sys.close(descriptor) } }
        if let quarantine { try quarantine.apply(descriptor, path: name) }
        if fix.quarantineOnly { return }
        if let attachments {
            if !attachments.extendedAttributes.isEmpty {
                try EntryAttributes.applyExtendedAttributes(descriptor, arena.span(attachments.extendedAttributes), path: name)
            }
            if !attachments.accessControlList.isEmpty {
                try EntryAttributes.applyAccessControlList(descriptor, arena.span(attachments.accessControlList), path: name)
            }
        }
        var attributes = destination.attributes(fix.metadata, mode: final, created: created, compressed: false)
        if attributes.apply(descriptor) != 0 { throw .system("setattrlist", path: name, code: errno) }
    }
}
