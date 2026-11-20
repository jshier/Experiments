import Darwin
import Foundation
import Synchronization
import System

/// A writer (a child task of the extraction): takes jobs from the queue and writes files. Owns its scratch memory,
/// made once: a path buffer, compressed output for a batch of chunks, a chunk table, a bridge chunk, and its chunk
/// encoders. Nothing is allocated per file.
///
/// It suspends only where a thread would have blocked: for a job, for a file system permit, and for a fork's turn.
/// Compression and the file system calls themselves run synchronously.
struct Writer: ~Copyable {
    let context: ExtractionContext
    private let path = RawStorage(byteCount: Int(PATH_MAX) + 1, alignment: RawStorage.small)
    private let output: RawStorage
    private let table: RawStorage
    private let bridge = RawStorage(byteCount: Decmpfs.chunkSize)
    /// A small file across a segment boundary, made contiguous.
    private let staging: RawStorage
    private let encoders = ChunkEncoders()
    /// The current job's file system lane.
    private var lane = 0

    init(_ context: ExtractionContext) {
        self.context = context
        staging = RawStorage(byteCount: context.smallSpanLimit)
        // A batch of chunks, then a slot for one more (pieces compress there before moving output in place); also
        // room for a single-batch file's table before its chunks.
        output = RawStorage(byteCount: (Decmpfs.batchChunks + 2) * (Decmpfs.chunkSize + 1) + (context.maximumChunks + 1) * 4 + 64)
        // About 1 KiB for 16 MiB segments: small.
        table = RawStorage(byteCount: (context.maximumChunks + 1) * 4, alignment: RawStorage.small)
    }

    /// Writes jobs until the queue is closed and empty. After a failure (or cancellation) it still takes every job,
    /// skipping the work, so every reference the walker took is released and the walker's pushes land.
    nonisolated(nonsending) mutating func run() async {
        let pool = context.pool
        while let job = await context.queue.pop() {
            let started = DispatchTime.now().uptimeNanoseconds
            lane = job.kind == .piece ? context.largeFiles[job.largeFile].lane : job.lane
            if !context.failed.load(ordering: .relaxed) {
                do throws(AEAError) {
                    switch job.kind {
                    case .file: try await writeFile(job)
                    case .piece: try await writePiece(job)
                    }
                } catch {
                    context.fail(error)
                }
            } else if job.kind == .piece {
                // Mark the file failed, so later pieces don't wait for this one's turn.
                await skipPiece(job)
            }
            if job.pathBuffer >= 0 { pool.release(job.pathBuffer) }
            if job.dataBuffer >= 0 { pool.release(job.dataBuffer) }
            var bridge = job.bridge
            bridge.release(pool)
            if job.secondBuffer >= 0 { pool.release(job.secondBuffer) }
            context.writeNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - started), ordering: .relaxed)
        }
    }

    /// The bytes at `offset` from buffer `buffer`'s segment base.
    @inline(__always)
    private func pointer(_ buffer: Int, _ offset: Int) -> UnsafeRawPointer {
        unsafe UnsafeRawPointer(context.pool.segmentBase(buffer)) + offset
    }

    // MARK: Whole files

    nonisolated(nonsending) private func writeFile(_ job: WriteJob) async throws(AEAError) {
        // The path into this writer's buffer, NUL-terminated (`Paths.check` limited it under PATH_MAX).
        unsafe path.base.copyMemory(from: pointer(job.pathBuffer, job.pathOffset), byteCount: job.pathCount)
        unsafe path.base.storeBytes(of: 0, toByteOffset: job.pathCount, as: UInt8.self)
        let mode = mode_t(job.mode) & 0o7777
        var data: UnsafeRawPointer? = unsafe job.dataCount > 0 ? pointer(job.dataBuffer, job.dataOffset) : nil
        let count = job.dataCount + job.secondCount
        if job.secondBuffer >= 0 {
            // Two ranges: copied together (at most `smallSpanLimit` bytes, the staging buffer's size).
            unsafe staging.base.copyMemory(from: pointer(job.dataBuffer, job.dataOffset), byteCount: job.dataCount)
            unsafe (staging.base + job.dataCount).copyMemory(from: pointer(job.secondBuffer, job.secondOffset), byteCount: job.secondCount)
            unsafe data = UnsafeRawPointer(staging.base)
        }
        let owner = context.restoreOwnership ? (job.uid, job.gid) : nil
        var flags = job.flags & ~UInt32(UF_COMPRESSED)

        // Compression first, outside the file system's limit: it's CPU work that scales with threads, while file
        // system calls contend beyond a few writers.
        var form = Form.plain
        if let data = unsafe data, let codec = Decmpfs.codec(job.diskCompression), !(unsafe Decmpfs.skips(data, count: count, codec: codec.codec)) {
            let start = DispatchTime.now().uptimeNanoseconds
            form = unsafe prepare(data, count: count, codec)
            context.timings.add(.compress, since: start)
        }
        if case .streamed(let codec) = form, let data = unsafe data {
            let descriptor = try await fileSystem { () throws(AEAError) in try openFile(mode, job) }
            defer { context.timings.measure(.close) { _ = close(descriptor) } }
            if try await unsafe writeStreamed(descriptor, data, count: count, codec) { flags |= UInt32(UF_COMPRESSED) }
            let finalFlags = flags
            try await fileSystem { () throws(AEAError) in try complete(descriptor, job, mode: mode, flags: finalFlags, owner: owner) }
            return
        }
        let finalForm = form
        try await fileSystem { () throws(AEAError) in
            var flags = flags
            let descriptor = try openFile(mode, job)
            defer { context.timings.measure(.close) { _ = close(descriptor) } }
            switch finalForm {
            case .plain:
                if let data = unsafe data { try unsafe writeFully(descriptor, data, count: count, at: 0) }
            case .inline(let attributeCount):
                try unsafe setAttribute(descriptor, Decmpfs.attribute, output.base, count: attributeCount, position: 0)
                flags |= UInt32(UF_COMPRESSED)
            case .fork(let forkCount, let type):
                try unsafe setAttribute(descriptor, Decmpfs.resourceFork, output.base, count: forkCount, position: 0)
                try setHeader(descriptor, type: type, size: count)
                flags |= UInt32(UF_COMPRESSED)
            case .streamed:
                break
            }
            try complete(descriptor, job, mode: mode, flags: flags, owner: owner)
        }
    }

    /// The archive's quarantine, then the mode, times, and flags; or, for a file finished after the writers, only
    /// `UF_COMPRESSED` (the pass after them reads it back).
    private func complete(_ descriptor: Int32, _ job: WriteJob, mode: mode_t, flags: UInt32, owner: (UInt32, UInt32)?) throws(AEAError) {
        if let failure = Self.setQuarantine(context, descriptor) { throw failure }
        if job.deferFinish {
            if flags & UInt32(UF_COMPRESSED) != 0, fchflags(descriptor, UInt32(UF_COMPRESSED)) != 0 { throw error("chflags") }
            return
        }
        try finish(descriptor, mode: mode, flags: flags, owner: owner, times: job.times)
    }

    static func setQuarantine(_ context: ExtractionContext, _ descriptor: Int32) -> AEAError? {
        guard let quarantine = context.quarantine else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { context.timings.add(.attribute, since: start) }
        return EntryMetadata.setQuarantine(descriptor, quarantine)
    }

    /// How a file is stored, decided before any file system call.
    private enum Form {
        case plain
        /// The `decmpfs` attribute with the data inline: the first `count` bytes of `output`.
        case inline(Int)
        /// The resource fork: the first `count` bytes of `output`, table and chunks.
        case fork(Int, type: UInt32)
        /// More than one batch: compressed and written a batch at a time.
        case streamed((codec: DiskCodec, inline: UInt32, fork: UInt32))
    }

    /// Compresses a file of one batch into `output`, ready to write.
    private func prepare(
        _ data: UnsafeRawPointer, count: Int, _ codec: (codec: DiskCodec, inline: UInt32, fork: UInt32)
    ) -> Form {
        let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        let tableCount = (chunkCount + 1) * 4
        let out = unsafe output.base
        if chunkCount == 1 {
            // Header room first, so an inline attribute is one contiguous write.
            let compressed = unsafe encoders.compress(data, count: count, into: out + Decmpfs.headerSize, codec: codec.codec)
            if codec.codec.allowsInline, Decmpfs.headerSize + compressed <= Decmpfs.maximumInlineAttribute {
                let header = Decmpfs.header(type: codec.inline, size: count)
                header.span.withUnsafeBytes { unsafe out.copyMemory(from: $0.baseAddress!, byteCount: Decmpfs.headerSize) }
                return .inline(Decmpfs.headerSize + compressed)
            }
            // Too big to go inline: the same chunk, after a two-entry table.
            let end = tableCount + compressed
            guard Decmpfs.pays(end, count, codec: codec.codec) else { return .plain }
            unsafe (out + tableCount).copyMemory(from: out + Decmpfs.headerSize, byteCount: compressed) // memmove: overlap is fine.
            unsafe out.storeBytes(of: UInt32(tableCount).littleEndian, toByteOffset: 0, as: UInt32.self)
            unsafe out.storeBytes(of: UInt32(end).littleEndian, toByteOffset: 4, as: UInt32.self)
            return .fork(end, type: codec.fork)
        }
        guard count <= Decmpfs.batchChunks * Decmpfs.chunkSize else { return .streamed(codec) }
        // One batch: the table and chunks contiguous, written once, unless compressing doesn't pay.
        var offset = tableCount
        for chunk in 0..<chunkCount {
            unsafe out.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: chunk * 4, as: UInt32.self)
            let start = chunk * Decmpfs.chunkSize
            offset += unsafe encoders.compress(data + start, count: min(Decmpfs.chunkSize, count - start), into: out + offset, codec: codec.codec)
        }
        unsafe out.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
        return Decmpfs.pays(offset, count, codec: codec.codec) ? .fork(offset, type: codec.fork) : .plain
    }

    /// Writes a file of several batches: each compressed outside the file system's limit, written inside it.
    ///
    /// - Returns: `false` if the file was written uncompressed instead (compressing didn't pay, judged on the whole
    ///   file, as Apple's extractor does).
    nonisolated(nonsending) private func writeStreamed(
        _ descriptor: Int32, _ data: UnsafeRawPointer, count: Int,
        _ codec: (codec: DiskCodec, inline: UInt32, fork: UInt32)
    ) async throws(AEAError) -> Bool {
        let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        let tableCount = (chunkCount + 1) * 4
        let out = unsafe output.base
        // Batches of chunks at increasing fork offsets; the table last.
        var forkOffset = tableCount
        var chunk = 0
        while chunk < chunkCount {
            let batchEnd = min(chunkCount, chunk + Decmpfs.batchChunks)
            var written = 0
            for index in chunk..<batchEnd {
                unsafe table.base.storeBytes(of: UInt32(forkOffset + written).littleEndian, toByteOffset: index * 4, as: UInt32.self)
                let start = index * Decmpfs.chunkSize
                written += unsafe encoders.compress(data + start, count: min(Decmpfs.chunkSize, count - start), into: out + written, codec: codec.codec)
            }
            let position = forkOffset
            try await fileSystem { () throws(AEAError) in
                try unsafe setAttribute(descriptor, Decmpfs.resourceFork, out, count: written, position: position)
            }
            forkOffset += written
            chunk = batchEnd
        }
        let end = forkOffset
        return try await fileSystem { () throws(AEAError) -> Bool in
            let forkOffset = end
            if !Decmpfs.pays(forkOffset, count, codec: codec.codec) {
                // The bytes are still in the segment buffer: drop the fork and write them plain.
                if unsafe fremovexattr(descriptor, Decmpfs.resourceFork, 0) != 0 { throw error("removexattr") }
                try unsafe writeFully(descriptor, data, count: count, at: 0)
                return false
            }
            unsafe table.base.storeBytes(of: UInt32(forkOffset).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
            try unsafe setAttribute(descriptor, Decmpfs.resourceFork, table.base, count: tableCount, position: 0)
            try setHeader(descriptor, type: codec.fork, size: count)
            return true
        }
    }

    private func setHeader(_ descriptor: Int32, type: UInt32, size: Int) throws(AEAError) {
        let header = Decmpfs.header(type: type, size: size)
        try header.span.withUnsafeBytes { bytes throws(AEAError) in
            try unsafe setAttribute(descriptor, Decmpfs.attribute, bytes.baseAddress!, count: Decmpfs.headerSize, position: 0)
        }
    }

    private func openFile(_ mode: mode_t, _ job: WriteJob) throws(AEAError) -> Int32 {
        let descriptor = context.timings.measure(.open) { unsafe Self.create(context, directory: job.directory, path.base + job.leaf, mode: mode) }
        guard descriptor >= 0 else { throw error("open") }
        return descriptor
    }

    /// Runs `body` as one of at most ``AEAExtractionOptions/fileSystemWidth`` writers in the file system, suspending
    /// until there's room.
    @inline(__always)
    nonisolated(nonsending) private func fileSystem<R>(_ body: () throws(AEAError) -> R) async throws(AEAError) -> R {
        let admission = context.admission(lane)
        let start = DispatchTime.now().uptimeNanoseconds
        await admission.acquire()
        context.timings.add(.wait, since: start)
        defer { admission.release() }
        return try body()
    }

    // MARK: Pieces of large files

    /// Writes one piece of a file that spans segments.
    ///
    /// Uncompressed, a piece is one `pwrite` at its offset, in any order. Compressed, pieces go into the resource fork
    /// in order, each after the one before (chunk offsets are cumulative), but they compress in parallel, before
    /// their turn: each chunk's output moves back into the piece's own consumed input in the segment buffer (no other
    /// job reads those bytes), so a piece needs no memory of its own and its turn is only the writes. If output would
    /// reach input not yet compressed (data that doesn't compress), the rest is compressed after the turn, a batch at
    /// a time, as before.
    ///
    /// A chunk may start in earlier pieces (the job's bridge): pieces in which no chunk ends get no job, and their
    /// bytes, with the tail of the piece before them, go to the piece where the chunk ends. A piece only overwrites
    /// input before its last chunk's end, so the bridges' bytes are intact.
    ///
    /// Whether compressing paid is decided on the whole file, as Apple's extractor decides it, when the last piece
    /// is written (``finishLargeFile(_:_:)``): a fork that doesn't pay is read back into a plain file.
    nonisolated(nonsending) private func writePiece(_ job: WriteJob) async throws(AEAError) {
        let state = context.largeFiles[job.largeFile]
        // The piece's bytes are this job's alone (other jobs' ranges of the buffer are disjoint), so it may
        // overwrite them.
        let data = unsafe UnsafeMutableRawPointer(mutating: pointer(job.dataBuffer, job.dataOffset))
        do throws(AEAError) {
            try await unsafe writePiece(job, state, data) // `data` is in a buffer the job holds a reference to: safe.
        } catch {
            await pieceDone(job.largeFile)
            throw error
        }
        await pieceDone(job.largeFile)
    }

    nonisolated(nonsending) private func writePiece(_ job: WriteJob, _ state: LargeFile, _ data: UnsafeMutableRawPointer) async throws(AEAError) {
        let size = job.fileSize
        let chunkSize = Decmpfs.chunkSize
        let pieceStart = job.fileOffset, pieceEnd = job.fileOffset + job.dataCount
        // Chunks whose end is in this piece: the first is the one this piece starts in (no earlier piece completed
        // it), which may start in earlier pieces (the bridge).
        let firstChunk = pieceStart / chunkSize
        let endChunk = pieceEnd == size ? state.chunkCount : pieceEnd / chunkSize
        let out = unsafe output.base
        let codec = state.codec
        var head = 0 // Compressed bytes in `output`, before the in-place ones.
        var sizes = 0 // Chunk sizes recorded in `table`.
        var chunk = firstChunk

        func record(_ count: Int) {
            unsafe table.base.storeBytes(of: UInt32(count), toByteOffset: sizes * 4, as: UInt32.self)
            sizes += 1
        }
        /// Compresses `index` into `destination`.
        func compress(_ index: Int, into destination: UnsafeMutableRawPointer) throws(AEAError) -> Int {
            let start = index * chunkSize
            let end = min(start + chunkSize, size)
            if start < pieceStart {
                // The bridge: the chunk's start from earlier pieces (their tails, which they never overwrite), the
                // rest from this piece.
                for index in 0..<job.bridge.count {
                    let part = job.bridge[index]
                    let low = max(start, part.fileOffset), high = min(pieceStart, part.fileOffset + part.count)
                    guard low < high else { continue }
                    unsafe (bridge.base + (low - start)).copyMemory(from: pointer(part.buffer, part.offset + (low - part.fileOffset)), byteCount: high - low)
                }
                unsafe (bridge.base + (pieceStart - start)).copyMemory(from: data, byteCount: end - pieceStart)
                return unsafe encoders.compress(bridge.base, count: end - start, into: destination, codec: codec)
            }
            return unsafe encoders.compress(data + (start - pieceStart), count: end - start, into: destination, codec: codec)
        }

        if state.progress.failed { throw .invalidArchive("an earlier piece of the file failed") }
        if state.forkType == 0 {
            // Uncompressed (set when the file opened): each piece writes its own range, in any order.
            try await fileSystem { () throws(AEAError) in try unsafe writeFully(state.descriptor, data, count: job.dataCount, at: pieceStart) }
            return
        }

        // The bridge chunk (if not done above) into `output` too: its input isn't all in this piece's buffer.
        if chunk < endChunk, chunk * chunkSize < pieceStart {
            let count = try unsafe compress(chunk, into: out + head)
            record(count)
            head += count
            chunk += 1
        }
        // The rest in place: chunk by chunk into the scratch slot after `head`, then moved to `data + inPlace`, while
        // that stays at or before the input not yet read (the next chunk's start).
        var inPlace = 0
        let slot = unsafe out + Decmpfs.batchChunks * (chunkSize + 1) + chunkSize + 1
        while chunk < endChunk {
            let count = try unsafe compress(chunk, into: slot)
            let consumed = min((chunk + 1) * chunkSize, size) - pieceStart
            guard inPlace + count <= consumed else { break } // Would overwrite unread input: the rest after the turn.
            unsafe (data + inPlace).copyMemory(from: slot, byteCount: count)
            record(count)
            inPlace += count
            chunk += 1
        }

        guard let pieceForkStart = await state.waitForTurn(job.piece) else {
            throw .invalidArchive("an earlier piece of the file failed")
        }
        var written: Int? // The fork's new end, once this piece's writes are done.
        defer { state.passTurn(forkOffset: written) }
        var forkOffset = pieceForkStart
        if head > 0 {
            let position = forkOffset, count = head
            try await fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: count, position: position) }
            forkOffset += head
        }
        if inPlace > 0 {
            let position = forkOffset, count = inPlace
            try await fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, data, count: count, position: position) }
            forkOffset += inPlace
        }
        // Chunks left (output caught up with input): batches into `output`, written as they're made.
        while chunk < endChunk {
            let batchEnd = min(endChunk, chunk + Decmpfs.batchChunks)
            var batch = 0
            while chunk < batchEnd {
                let count = try unsafe compress(chunk, into: out + batch)
                record(count)
                batch += count
                chunk += 1
            }
            let position = forkOffset, count = batch
            try await fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: count, position: position) }
            forkOffset += batch
        }
        // The table entries for this piece's chunks: sizes to offsets, plus the end for the last piece.
        var offset = pieceForkStart
        for index in 0..<sizes {
            let count = Int(unsafe table.base.load(fromByteOffset: index * 4, as: UInt32.self))
            unsafe table.base.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: index * 4, as: UInt32.self)
            offset += count
        }
        var entries = sizes
        if pieceEnd == size {
            unsafe table.base.storeBytes(of: UInt32(forkOffset).littleEndian, toByteOffset: entries * 4, as: UInt32.self)
            entries += 1
        }
        if entries > 0 {
            let count = entries
            try await fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, table.base, count: count * 4, position: firstChunk * 4) }
        }
        written = forkOffset
    }

    nonisolated(nonsending) private func skipPiece(_ job: WriteJob) async {
        context.largeFiles[job.largeFile].failTurns()
        await pieceDone(job.largeFile)
    }

    nonisolated(nonsending) private func pieceDone(_ index: Int) async {
        let state = context.largeFiles[index]
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            await Self.finishLargeFile(context, index)
        }
    }

    /// The last piece is written (or the file failed): set its attributes, close it, and free its state.
    nonisolated(nonsending) static func finishLargeFile(_ context: ExtractionContext, _ index: Int) async {
        let state = context.largeFiles[index]
        let admission = context.admission(state.lane)
        let (failed, forkOffset) = state.progress
        await admission.acquire()
        defer { admission.release() }
        if !failed, !context.failed.load(ordering: .relaxed) {
            var flags = state.flags & ~UInt32(UF_COMPRESSED)
            var failure: AEAError?
            if state.forkType != 0, !Decmpfs.pays(forkOffset, state.size, codec: state.codec) {
                // Compressing didn't pay over the whole file: rewrite it plain from the fork (with the permit held, as
                // before: unpackers' holders wait for nothing else).
                failure = await context.withConverter { converter in converter.unpack(state) }
                state.forkType = 0
            }
            if failure == nil, state.forkType != 0 {
                let header = Decmpfs.header(type: state.forkType, size: state.size)
                let result = header.span.withUnsafeBytes { bytes in
                    unsafe fsetxattr(state.descriptor, Decmpfs.attribute, bytes.baseAddress!, Decmpfs.headerSize, 0, 0)
                }
                if result != 0 { failure = .fileSystem("setxattr decmpfs", Errno(rawValue: errno)) }
                flags |= UInt32(UF_COMPRESSED)
            }
            if failure == nil { failure = setQuarantine(context, state.descriptor) }
            if failure == nil, state.deferFinish {
                // Finished after the writers: only `UF_COMPRESSED` now.
                if flags & UInt32(UF_COMPRESSED) != 0, fchflags(state.descriptor, UInt32(UF_COMPRESSED)) != 0 {
                    failure = .fileSystem("chflags", Errno(rawValue: errno))
                }
            } else if failure == nil {
                failure = finishAttributes(context, state.descriptor, mode: state.mode, flags: flags, owner: state.owner, times: state.times)
            }
            if let failure { context.fail(failure) }
        }
        close(state.descriptor)
        state.descriptor = -1
        context.releaseLargeFile(index)
    }

    // MARK: File system

    /// Creates a file for writing, never through a symbolic link.
    ///
    /// - Parameters:
    ///   - directory: The parent's descriptor (or the destination's, with a path from it).
    ///   - path: The name in `directory`, NUL-terminated.
    static func create(_ context: ExtractionContext, directory: Int32, _ path: UnsafeRawPointer, mode: mode_t) -> Int32 {
        let cPath = unsafe path.assumingMemoryBound(to: CChar.self)
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY
        // Owner-writable while it's written: setting attributes checks the mode, not the descriptor.
        let creationMode = (mode & 0o777) | 0o600
        var descriptor = unsafe openat(directory, cPath, flags, creationMode)
        if descriptor < 0, errno == EEXIST, context.options.overwrite {
            unsafe unlinkat(directory, cPath, 0)
            descriptor = unsafe openat(directory, cPath, flags, creationMode)
        }
        return descriptor
    }

    private func finish(_ descriptor: Int32, mode: mode_t, flags: UInt32, owner: (UInt32, UInt32)?, times: EntryTimes) throws(AEAError) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { context.timings.add(.finish, since: start) }
        if let failure = Self.finishAttributes(context, descriptor, mode: mode, flags: flags, owner: owner, times: times) { throw failure }
    }

    /// Ownership, then permissions, then flags (last: some forbid later changes).
    static func finishAttributes(
        _ context: ExtractionContext, _ descriptor: Int32, mode: mode_t, flags: UInt32, owner: (UInt32, UInt32)?, forceChmod: Bool = false,
        times: EntryTimes = EntryTimes()
    ) -> AEAError? {
        if let owner, fchown(descriptor, owner.0, owner.1) != 0 { return .fileSystem("chown", Errno(rawValue: errno)) }
        if forceChmod || mode & 0o600 != 0o600 || context.needsChmod(mode), fchmod(descriptor, mode) != 0 { return .fileSystem("chmod", Errno(rawValue: errno)) }
        // Flags before times: setting `UF_COMPRESSED` sets the modification time (every compressed file of a xip had
        // the extraction's time until this order). Bits that forbid changes (immutable, append-only) go last.
        let locking = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        if flags & ~locking != 0, fchflags(descriptor, flags & ~locking) != 0 { return .fileSystem("chflags", Errno(rawValue: errno)) }
        if times.apply(descriptor) != 0 { return .fileSystem("setattrlist", Errno(rawValue: errno)) }
        if flags & locking != 0, fchflags(descriptor, flags) != 0 { return .fileSystem("chflags", Errno(rawValue: errno)) }
        return nil
    }

    private func writeFully(_ descriptor: Int32, _ bytes: UnsafeRawPointer, count: Int, at offset: Int) throws(AEAError) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { context.timings.add(.data, since: start) }
        var done = 0
        while done < count {
            let written = unsafe pwrite(descriptor, bytes + done, count - done, off_t(offset + done))
            if written < 0 {
                if errno == EINTR { continue }
                throw error("write")
            }
            done += written
        }
    }

    private func setAttribute(_ descriptor: Int32, _ name: String, _ bytes: UnsafeRawPointer, count: Int, position: Int) throws(AEAError) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { context.timings.add(name == Decmpfs.resourceFork ? .fork : .attribute, since: start) }
        if unsafe fsetxattr(descriptor, name, bytes, count, UInt32(position), 0) != 0 {
            throw error("setxattr \(name)")
        }
    }

    private func error(_ operation: String) -> AEAError {
        let code = errno
        return .fileSystem("\(operation) \(unsafe String(cString: path.base.assumingMemoryBound(to: CChar.self)))", Errno(rawValue: code))
    }
}
