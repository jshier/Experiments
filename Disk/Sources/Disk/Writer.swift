import Bytes
import BytesAsync
import Darwin
import Synchronization

/// A scheduled file's destination, given to its source (``ContentSource/write(_:to:)``): write the file's bytes in
/// order, in one call or several.
///
/// - One write of the whole file (the usual case): written as it is, no copy. Compression runs first, then the file
///   system calls, inside the limit.
/// - Several writes of a file up to `ExtractionSettings.stagingCapacity` (1 MiB): gathered in the writer's staging buffer, then
///   written as one.
/// - A bigger file (or one of unknown size): streamed, each write written as it comes (or compressed a 64 KiB chunk at
///   a time into the resource fork, a batch of 16 chunks per call).
///
/// The file is finished (its attributes set, and closed) after ``ContentSource/write(_:to:)`` returns, so a source can
/// still fail it after its last write (a checksum that comes out wrong): throw, and the file is removed. A file written
/// whole keeps its file system permit from that write until then, so the work after the last write should be short.
///
/// It owns the writer's scratch while the source writes (the writer moves it in and out: no allocation).
public struct FileOutput: ~Copyable {
    var core: WriterCore
    let limiter: AsyncLimiter?
    let timings: WorkTimings?
    let progress: ExtractionProgress.Slot?
    let directory: Int32
    let leaf: Int
    let pathCount: Int
    let metadata: EntryMetadata
    let storage: Storage
    let deferred: Bool
    let finalMode: mode_t
    let stagingCapacity: Int

    /// The writer writing this file: 0 to ``ExtractionSettings/writers`` − 1. A source with state per writer (a decoder's
    /// tables) keeps one per index: no writer uses two at once, and each index is used by one writer at a time.
    public let writerIndex: Int

    /// The size the planner gave (`nil`: unknown).
    let expectedSize: Int?
    /// Bytes written so far.
    private(set) var bytesWritten = 0

    enum Mode { case initial, staged, streaming, done }
    var mode = Mode.initial
    /// How the file ended up, once done.
    var result = StoredForm.plain
    /// The file, while it's open: taken and closed (or abandoned) exactly once, where its writing ends.
    var file: OwnedDescriptor?
    /// The file's descriptor, or -1 when none is open.
    var descriptor: Int32 {
        switch file {
        case let .some(open): open.raw
        case .none: -1
        }
    }

    // Streaming compressed:
    var policy: StoragePolicy?
    var forkOffset = 0
    var chunkIndex = 0
    var batchStart = 0
    var batchBytes = 0
    var partial = 0
    /// Bytes written whole, counted with the entry by `complete()` (one progress add per file).
    var uncountedBytes = 0
    /// A file written whole: its contents are written and it's still open (`descriptor`), its permit held, until
    /// `complete()` finishes it (or `abandon()` removes it). Whether it's compressed.
    var unfinished: Bool?

    init(
        core: consuming WriterCore, limiter: AsyncLimiter?, timings: WorkTimings?, progress: ExtractionProgress.Slot?,
        directory: Int32, leaf: Int, pathCount: Int, size: Int?, metadata: EntryMetadata, storage: Storage, deferred: Bool,
        stagingCapacity: Int, writerIndex: Int = 0
    ) {
        self.core = core
        self.limiter = limiter
        self.timings = timings
        self.progress = progress
        self.directory = directory
        self.leaf = leaf
        self.pathCount = pathCount
        expectedSize = size
        self.metadata = metadata
        self.storage = storage
        self.deferred = deferred
        self.stagingCapacity = stagingCapacity
        self.writerIndex = writerIndex
        finalMode = self.core.destination.finalMode(metadata.mode, default: 0o644)
    }

    consuming func takeCore() -> WriterCore { core }

    // MARK: Admission

    @inline(__always)
    private func enter() async {
        guard let limiter else { return }
        let started = timings != nil ? MonotonicClock.now : 0
        await limiter.acquire()
        timings?.add(.wait, since: started)
    }

    @inline(__always)
    private func leave() {
        limiter?.release()
    }

    // MARK: Writing

    /// Writes the next bytes of the file.
    ///
    /// - Throws: ``DiskError/invalidMetadata(_:)`` past the expected size; what writing throws.
    public mutating func write(_ bytes: RawSpan) async throws(DiskError) {
        let count = bytes.byteCount
        if let expectedSize, bytesWritten + count > expectedSize {
            throw .invalidMetadata("more contents than the file's size (\(expectedSize) bytes), \(core.pathRef.string)")
        }
        switch mode {
        case .initial:
            if let expectedSize, count == expectedSize {
                // The whole file at once, in place.
                // Unsafe (both lines): the span's memory as a pointer to `writeWhole`, across the write's waits. Safe:
                // the span is borrowed for this call, so its `count` bytes stay put until `writeWhole` returns.
                try await unsafe bytes.withLentBytesAsync { lent throws(DiskError) in
                    try await unsafe writeWhole(lent.buffer.baseAddress, count: count)
                }
                bytesWritten = count
                mode = .done
                return
            }
            if let expectedSize, expectedSize <= stagingCapacity {
                mode = .staged
                core.staging.reuse(expectedSize)
            } else {
                try await openStream(first: bytes)
                mode = .streaming
            }
        case .done:
            throw .invalidMetadata("contents written after the file was complete, \(core.pathRef.string)")
        case .staged, .streaming:
            break
        }
        if mode == .staged {
            // Unsafe: copies the span's bytes into the staging buffer at `bytesWritten`. Safe: `bytesWritten + count <=
            // expectedSize <= stagingCapacity` (checked on entry, and to enter this mode), the buffer's size; the
            // span's buffer is valid inside `withUnsafeBytes`, and separate from the core's staging storage.
            // (An empty write has no address and copies nothing.)
            bytes.withUnsafeBytes { buffer in
                guard let source = buffer.baseAddress else { return }
                unsafe (core.staging.base + bytesWritten).copyMemory(from: source, byteCount: buffer.count)
            }
            bytesWritten += count
            if bytesWritten == expectedSize {
                // Unsafe: the staging buffer's base to `writeWhole`, across its waits. Safe: the `bytesWritten` bytes
                // just gathered there, in storage the core owns; nothing else writes it until this returns.
                try await unsafe writeWhole(unsafe UnsafeRawPointer(core.staging.base), count: bytesWritten)
                core.staging.giveBack(bytesWritten)
                mode = .done
            }
            return
        }
        // Unsafe (both lines): the span's memory as a pointer to `stream`, across its waits. Safe: the span is borrowed
        // for this call, so its `count` bytes stay put until `stream` returns.
        try await unsafe bytes.withLentBytesAsync { lent throws(DiskError) in
            try await unsafe stream(lent.buffer.baseAddress, count: count)
        }
        progress?.add(entries: 0, bytes: count)
        bytesWritten += count
    }

    /// After the source's last write: checks the size and finishes a streamed file.
    mutating func complete() async throws(DiskError) {
        switch mode {
        case .initial:
            guard expectedSize ?? 0 == 0 else {
                throw .invalidMetadata("no contents for a file of \(expectedSize ?? 0) bytes, \(core.pathRef.string)")
            }
            // Unsafe: a pointer parameter. Safe: `nil` with a count of 0 (an empty file): nothing is read.
            try await unsafe writeWhole(nil, count: 0)
            mode = .done
            try finishWhole()
        case .staged:
            throw .invalidMetadata("\(bytesWritten) bytes of contents for a file of \(expectedSize ?? 0), \(core.pathRef.string)")
        case .streaming:
            if let expectedSize, bytesWritten != expectedSize {
                throw .invalidMetadata("\(bytesWritten) bytes of contents for a file of \(expectedSize), \(core.pathRef.string)")
            }
            try await finishStream()
            mode = .done
        case .done:
            try finishWhole()
        }
        if result != .skipped { progress?.add(entries: 1, bytes: uncountedBytes) }
        uncountedBytes = 0
    }

    /// Closes and removes what a failed file left (and gives back a permit a file written whole still holds).
    mutating func abandon() {
        if let open = file.take() {
            core.abandon(open.release(), directory: directory, leaf: leaf)
        }
        if unfinished != nil {
            unfinished = nil
            leave()
        }
    }

    /// Finishes a file written whole, once its source has returned: the one call for its attributes, then `close`,
    /// inside the permit its write took.
    private mutating func finishWhole() throws(DiskError) {
        guard let compressed = unfinished else { return }
        unfinished = nil
        defer { leave() }
        do throws(DiskError) {
            try core.finish(descriptor, metadata: metadata, mode: finalMode, compressed: compressed, deferred: deferred)
            file.take()?.close()
        } catch {
            if let open = file.take() { core.abandon(open.release(), directory: directory, leaf: leaf) }
            throw error
        }
    }

    /// A whole file in memory: compressed outside the limit, then made inside it. It stays open, holding its permit,
    /// until `complete()` finishes it (``finishWhole()``).
    private mutating func writeWhole(_ data: UnsafeRawPointer?, count: Int) async throws(DiskError) {
        // The caller's contract: `data` is `count` bytes (the source's span, or the staging buffer; `nil` for none) that
        // stay valid and unchanged until this returns, across its waits.
        let started = timings != nil ? MonotonicClock.now : 0
        // Unsafe: `data` to `prepare`. Safe: the caller's `count` bytes, as above; `prepare` only reads them.
        let form = unsafe core.prepare(data, count: count, storage: storage)
        timings?.add(.compress, since: started)
        // Unsafe: reads the optional pointer. Safe: only its value, tested for `nil`.
        if case let .batches(policy) = form, let data = unsafe data {
            // Unsafe: `data` to `writeBatches`, across its waits. Safe: the caller's `count` bytes, valid until this
            // function returns, which `writeBatches` does first.
            try await unsafe writeBatches(data, count: count, policy: policy)
            uncountedBytes = count
            return
        }
        await enter()
        let descriptor: Int32
        do throws(DiskError) {
            descriptor = try core.create(directory: directory, leaf: leaf, mode: finalMode)
        } catch {
            leave()
            throw error
        }
        guard descriptor >= 0 else {
            leave()
            result = .skipped
            return
        }
        do throws(DiskError) {
            // Unsafe: `data` to `write`. Safe: the caller's `count` bytes (or `nil`), still valid; `form` is what
            // `prepare` made from them above, its bytes still in the core's output (nothing has used it since).
            unfinished = try unsafe core.write(descriptor, form: form, data: data, count: count)
            file = OwnedDescriptor(adopting: descriptor, kind: .fileBeingWritten)
        } catch {
            core.abandon(descriptor, directory: directory, leaf: leaf)
            leave()
            throw error
        }
        switch form {
        case .inline: result = .inline
        case .fork: result = .resourceFork
        default: result = .plain
        }
        uncountedBytes = count
    }

    /// A whole file in memory of more than one batch: each batch compressed outside the limit, written inside it.
    private mutating func writeBatches(_ data: UnsafeRawPointer, count: Int, policy: StoragePolicy) async throws(DiskError) {
        // The caller's contract: `data` is the whole file's `count` bytes, valid and unchanged until this returns.
        await enter()
        let created: Int32
        do throws(DiskError) {
            created = try core.create(directory: directory, leaf: leaf, mode: finalMode)
        } catch {
            leave()
            throw error
        }
        leave()
        guard created >= 0 else {
            result = .skipped
            return
        }
        file = OwnedDescriptor(adopting: created, kind: .fileBeingWritten)
        let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        core.reserveTable(chunkCount + 1)
        var forkOffset = (chunkCount + 1) * 4
        var chunk = 0
        while chunk < chunkCount {
            let end = min(chunkCount, chunk + Decmpfs.batchChunks)
            let started = timings != nil ? MonotonicClock.now : 0
            // Unsafe: `data` to `compressBatch`. Safe: the whole file's `count` bytes; `chunk..<end` are at most 16 of
            // its `chunkCount` chunks, and the table was reserved for all of them above.
            let written = unsafe core.compressBatch(data, count: count, chunks: chunk..<end, forkOffset: forkOffset, policy: policy)
            timings?.add(.compress, since: started)
            await enter()
            defer { leave() }
            // Unsafe: the output's base to `setAttribute`. Safe: the `written` bytes `compressBatch` just put there,
            // in the core's storage, which only this task uses (the wait above included); read during the call.
            try unsafe core.setAttribute(descriptor, Decmpfs.resourceFork, core.output.base, count: written, position: forkOffset)
            forkOffset += written
            chunk = end
        }
        await enter()
        let compressed: Bool
        do throws(DiskError) {
            // Unsafe: `data` to `finishFork`. Safe: the whole file's `count` bytes, still valid (the contract above);
            // the table has the `chunkCount + 1` entries reserved above, every chunk's stored by the batches.
            compressed = try unsafe core.finishFork(descriptor, end: forkOffset, size: count, policy: policy, data: data)
        } catch {
            leave()
            throw error
        }
        // Finished by `complete()`, in this permit (as `writeWhole`).
        unfinished = compressed
        result = compressed ? .resourceFork : .plain
    }

    // MARK: Streaming

    private mutating func openStream(first: RawSpan) async throws(DiskError) {
        await enter()
        let created: Int32
        do throws(DiskError) {
            created = try core.create(directory: directory, leaf: leaf, mode: finalMode)
        } catch {
            leave()
            throw error
        }
        leave()
        if created < 0 {
            result = .skipped
            return
        }
        file = OwnedDescriptor(adopting: created, kind: .fileBeingWritten)
        if case let .compressed(policy) = storage, let size = expectedSize, size < 1 << 32, policy.codec.types.fork != 0,
           !policy.skips(size: size, first: first.extracting(first: min(first.byteCount, 8))) {
            self.policy = policy
            let chunkCount = (size + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
            core.reserveTable(chunkCount + 1)
            forkOffset = (chunkCount + 1) * 4
        }
    }

    private mutating func stream(_ data: UnsafeRawPointer?, count: Int) async throws(DiskError) {
        // The caller's contract: `data` is `count` bytes (the source's span) that stay valid until this returns, across
        // its waits.
        // Unsafe: reads the optional pointer. Safe: only its value, tested for `nil`.
        guard result != .skipped, let data = unsafe data, count > 0 else { return }
        guard let policy else {
            await enter()
            defer { leave() }
            let started = timings != nil ? MonotonicClock.now : 0
            // Unsafe: `data` to `writeFully`. Safe: the caller's `count` bytes, as above; read during the call.
            try unsafe FileIO.writeFully(descriptor, data, count: count, at: bytesWritten, path: core.pathRef)
            timings?.add(.data, since: started)
            return
        }
        let size = expectedSize! // Compressed streams have a size (`openStream`).
        var offset = 0
        while offset < count {
            let chunkStart = chunkIndex * Decmpfs.chunkSize
            let need = min(Decmpfs.chunkSize, size - chunkStart)
            if partial == 0, count - offset >= need {
                // A whole chunk in the caller's bytes: compressed from them.
                // Unsafe: `data + offset` to `compressChunk`. Safe: `need` bytes from there are within the caller's
                // `count` (`count - offset >= need`, just tested), and `need` is at most a chunk.
                unsafe compressChunk(unsafe data + offset, count: need, policy: policy)
                offset += need
            } else {
                let take = min(need - partial, count - offset)
                // Unsafe: copies `take` of the caller's bytes into the chunk buffer at `partial`. Safe: `take <= count
                // - offset`, within the caller's bytes; `partial + take <= need <= chunkSize`, the buffer's size
                // (the core's own storage, apart from the caller's).
                unsafe (core.chunk.base + partial).copyMemory(from: data + offset, byteCount: take)
                partial += take
                offset += take
                guard partial == need else { continue }
                // Unsafe: the chunk buffer's base to `compressChunk`. Safe: the `need` bytes gathered there (`partial
                // == need`), in the core's storage, which `compressChunk` reads but doesn't write.
                unsafe compressChunk(unsafe UnsafeRawPointer(core.chunk.base), count: need, policy: policy)
                partial = 0
            }
            if chunkIndex - batchStart == Decmpfs.batchChunks { try await flushBatch() }
        }
    }

    private mutating func compressChunk(_ data: UnsafeRawPointer, count: Int, policy: StoragePolicy) {
        let started = timings != nil ? MonotonicClock.now : 0
        // Unsafe: stores chunk `chunkIndex`'s entry in the table. Safe: `openStream` reserved an entry for every chunk
        // of the expected size and one more, and `write` refuses bytes past that size, so `chunkIndex` is one of them.
        unsafe core.table.base.storeBytes(of: UInt32(forkOffset + batchBytes).littleEndian, toByteOffset: chunkIndex * 4, as: UInt32.self)
        // Unsafe: the chunk and the output at `batchBytes` to `compress`. Safe: `data` is the caller's `count` bytes,
        // a chunk at most (`stream`); a batch is flushed at 16 chunks, so `batchBytes` is at most 15 chunks of a chunk
        // and one byte, leaving the chunk and one byte `compress` needs within `outputCapacity`.
        batchBytes += unsafe core.encoders.compress(data, count: count, into: core.output.base + batchBytes, policy: policy)
        chunkIndex += 1
        timings?.add(.compress, since: started)
    }

    private mutating func flushBatch() async throws(DiskError) {
        guard batchBytes > 0 else { return }
        await enter()
        defer { leave() }
        // Unsafe: the output's base to `setAttribute`. Safe: the batch's `batchBytes` bytes, written there by
        // `compressChunk`, in the core's storage, which only this task uses; read during the call.
        try unsafe core.setAttribute(descriptor, Decmpfs.resourceFork, core.output.base, count: batchBytes, position: forkOffset)
        forkOffset += batchBytes
        batchBytes = 0
        batchStart = chunkIndex
    }

    private mutating func finishStream() async throws(DiskError) {
        guard result != .skipped else { return }
        if let policy {
            try await flushBatch()
            await enter()
            defer { leave() }
            // Unsafe: `finishFork`, which takes a pointer and writes the table's last entry. Safe: no data in memory
            // (`nil`: the fork is read back if it doesn't pay); the table has the entries `openStream` reserved for
            // the expected size, which `bytesWritten` equals here (`complete` checked), every chunk's stored.
            let compressed = try unsafe core.finishFork(descriptor, end: forkOffset, size: bytesWritten, policy: policy, data: nil)
            try core.finish(descriptor, metadata: metadata, mode: finalMode, compressed: compressed, deferred: deferred)
            result = compressed ? .resourceFork : .plain
        } else {
            await enter()
            defer { leave() }
            try core.finish(descriptor, metadata: metadata, mode: finalMode, compressed: false, deferred: deferred)
            result = .plain
        }
        file.take()?.close()
    }
}

// MARK: - The writers

/// A writer (a child task of the extraction): takes jobs from the queue and writes files. Owns its scratch, made on its
/// first job (a writer that gets none, in an extraction of a few files, allocates nothing) and kept for the rest.
/// It suspends only where a thread would have blocked: for a job, a file system permit, and a fork's turn.
@safe
struct Writer<Source: ContentSource>: ~Copyable {
    let context: ExtractionContext<Source>
    /// The scratch: `nil` until the first job, and while a `FileOutput` has it.
    var core: WriterCore?
    let slot: ExtractionProgress.Slot?
    let index: Int
    /// This writer's part of the extraction's path buffers (``WriterCore/pathCapacity`` bytes): `pop` copies each
    /// job's path here, and the core names files from it.
    let pathBuffer: UnsafeMutableRawPointer

    init(_ context: ExtractionContext<Source>, index: Int) {
        self.context = context
        // Unsafe: a pointer into the context's path storage, kept. Safe: writer `index`'s `pathCapacity` bytes of
        // the `writers * pathCapacity` there (`index < writers`: `Extraction.run` starts that many); the storage
        // lives as long as the context, which this writer holds.
        unsafe pathBuffer = context.writerPaths.base + index * WriterCore.pathCapacity
        core = nil
        slot = context.options.progress?.slot(index + 1)
        self.index = index
    }

    var timings: WorkTimings? { context.options.collectsTimings ? context.timings : nil }

    /// The scratch, made on first use; the caller gives it back (`core = consume …`) when it's done.
    mutating func takeCore() -> WriterCore {
        switch core.take() {
        case let .some(core):
            core
        case .none:
            // Unsafe: the path buffer's pointer to the core's initializer, which keeps it. Safe: `pathCapacity` bytes
            // within `context.writerPaths` (`init`), which is passed along for the core to keep alive.
            unsafe WriterCore(context.destination, stagingCapacity: context.options.stagingCapacity, path: pathBuffer, in: context.writerPaths)
        }
    }

    /// Writes jobs until the queue is closed and empty. After a failure (or cancellation) it still takes every job,
    /// skipping the work, so every content reference is released and the planner's pushes land.
    nonisolated(nonsending) mutating func run() async {
        let source = context.source
        // Unsafe: the path buffer's pointer to `pop`, which writes a job's path and a NUL there. Safe: this writer's
        // own `PATH_MAX + 1` bytes (`init`), all `pop` needs; no one else writes them, and the context keeps them
        // allocated across the wait.
        while let (job, pathCount) = unsafe await context.queue.pop(pathInto: pathBuffer) {
            if !context.isStopped {
                switch job.kind {
                case .file: await writeFile(job, pathCount: pathCount)
                case .piece: await writePiece(job)
                }
            } else if job.kind == .piece {
                // Mark the file failed, so later pieces don't wait for this one's turn.
                context.largeFiles[job.largeFile].failTurns()
                await pieceDone(job.largeFile)
            }
            source.release(job.contents)
            for index in 0..<job.bridge.count {
                source.release(job.bridge[index].contents)
            }
        }
    }

    private nonisolated(nonsending) mutating func writeFile(_ job: WriteJob<Source.Contents>, pathCount: Int) async {
        var output = FileOutput(
            core: takeCore(), limiter: context.fileSystem, timings: timings, progress: slot, directory: job.directory,
            leaf: job.leaf, pathCount: pathCount, size: job.size >= 0 ? job.size : nil, metadata: job.metadata,
            storage: job.storage, deferred: job.deferred, stagingCapacity: context.options.stagingCapacity,
            writerIndex: index
        )
        do throws(EntryError<Source.Failure>) {
            let started = timings != nil ? MonotonicClock.now : 0
            try await context.source.write(job.contents, to: &output)
            timings?.add(.produce, since: started)
            do throws(DiskError) {
                try await output.complete()
            } catch {
                throw .disk(error)
            }
            context.counters.count(output.result, bytes: output.bytesWritten)
        } catch {
            output.abandon()
            context.fail(error, path: output.core.pathRef.string, tag: job.tag)
        }
        core = output.takeCore()
    }

    // MARK: Pieces of large files

    /// Writes one piece of a large file.
    ///
    /// Plain, a piece is one `pwrite` at its offset, in any order. Compressed, pieces go into the fork in order (chunk
    /// offsets are cumulative), but they compress in parallel, before their turn: each chunk's output moves back over
    /// the piece's own consumed input (no other job reads those bytes), so a piece needs no memory of its own and its
    /// turn is only the writes. If output would reach input not yet compressed, the rest is compressed after the turn,
    /// a batch at a time.
    ///
    /// A chunk may start in earlier pieces (the job's bridge). A piece only overwrites input before its last chunk's
    /// end, so the bridges' bytes are intact. Whether compressing paid is decided on the whole file when the last piece
    /// is written (``finishLargeFile(_:)``): a fork that doesn't pay is read back into a plain file.
    private nonisolated(nonsending) mutating func writePiece(_ job: WriteJob<Source.Contents>) async {
        let state = context.largeFiles[job.largeFile]
        do throws(DiskError) {
            try await writePiece(job, state)
        } catch {
            state.failTurns()
            context.fail(.disk(error), path: state.pathRef.string, tag: state.tag)
        }
        slot?.add(entries: 0, bytes: job.count + job.bridgedBytes)
        await pieceDone(job.largeFile)
    }

    /// The address of a piece's bytes, which stay put until its last release (``ContentSource/withPiece(_:_:)``).
    private static func pieceBase(_ source: Source, _ contents: Source.Contents, count: Int) throws(DiskError) -> UnsafeMutableRawPointer {
        // Unsafe: the piece's address escapes `withPiece`'s closure (and the span's own, below). Safe: `PieceSource`'s
        // contract keeps the bytes at this address until the piece's last release, and `Writer.run` releases a job's
        // piece and its bridge's only after the job's work; at least `count > 0` bytes are there (checked): not `nil`.
        try unsafe source.withPiece(contents) { span throws(DiskError) -> UnsafeMutableRawPointer in
            guard span.byteCount >= count, count > 0 else { throw .invalidMetadata("a piece shorter than its count") }
            return span.withUnsafeMutableBytes { $0.baseAddress! }
        }
    }

    private nonisolated(nonsending) mutating func writePiece(_ job: WriteJob<Source.Contents>, _ state: LargeFile) async throws(DiskError) {
        let pieceStart = job.fileOffset
        // Unsafe: the address of the piece's bytes, kept in `data`. Safe: `job.count` bytes (`pieceBase` checked) that
        // the job holds, at that address, until `run` releases its contents after this returns.
        let data = try unsafe Self.pieceBase(context.source, job.contents, count: job.count)
        if state.progress.failed { throw .invalidMetadata("an earlier piece of the file failed, \(state.pathRef.string)") }
        guard let policy = state.policy else {
            // Plain: each piece writes its own range, in any order.
            try await context.fileSystem.withPermit { () throws(DiskError) in
                // Unsafe: `data` to `writeFully`. Safe: the piece's `job.count` bytes, held by the job (above), across
                // the wait before this too; read during the call.
                try unsafe FileIO.writeFully(state.descriptor, data, count: job.count, at: pieceStart, path: state.pathRef)
            }
            return
        }
        var core = takeCore()
        do throws(DiskError) {
            // Unsafe: `data` to `writeCompressedPiece`, which reads and overwrites it across its waits. Safe: the
            // piece's `job.count` bytes, held until `run` releases them after this returns. It overwrites only bytes
            // before its last chunk's end; a later job that bridges this piece reads only the tail after that.
            try await unsafe Self.writeCompressedPiece(job, state, data, policy: policy, core: &core, context: context, timings: timings)
        } catch {
            self.core = consume core
            throw error
        }
        self.core = consume core
    }

    /// A compressed piece: compressed in place, then written in its turn.
    private nonisolated(nonsending) static func writeCompressedPiece(
        _ job: WriteJob<Source.Contents>, _ state: LargeFile, _ data: UnsafeMutableRawPointer, policy: StoragePolicy,
        core: inout WriterCore, context: ExtractionContext<Source>, timings: WorkTimings?
    ) async throws(DiskError) {
        // The caller's contract: `data` is the piece's `job.count` bytes, file offsets `pieceStart..<pieceEnd`, held by
        // the job until after this returns (across the waits here). The chunks worked on are `firstChunk..<endChunk`:
        // all end at or before `pieceEnd`, and only the first may start before `pieceStart` (in the bridge's pieces).
        let size = state.size
        let chunkSize = Decmpfs.chunkSize
        let pieceStart = job.fileOffset, pieceEnd = job.fileOffset + job.count
        let firstChunk = pieceStart / chunkSize
        let endChunk = pieceEnd == size ? state.chunkCount : pieceEnd / chunkSize
        // Unsafe: the output storage's base pointer, kept for this call. Safe: `outputCapacity` bytes (18 chunks of a
        // chunk and one byte, and more) that the core owns, and the caller's `inout` core outlives the call.
        let out = unsafe core.output.base
        var head = 0 // Compressed bytes in `output`, before the in-place ones.
        var sizes = 0 // Chunk sizes recorded in `table`.
        var chunk = firstChunk
        core.reserveTable(endChunk - firstChunk + 1)

        func record(_ core: inout WriterCore, _ count: Int) {
            // Unsafe: stores a chunk's size in the table. Safe: called once per chunk of `firstChunk..<endChunk`, so
            // `sizes` is under `endChunk - firstChunk`, within the entries reserved just above (one more than that).
            unsafe core.table.base.storeBytes(of: UInt32(count), toByteOffset: sizes * 4, as: UInt32.self)
            sizes += 1
        }
        /// Compresses chunk `index`, which starts in this piece, into `destination`.
        func compress(_ core: inout WriterCore, _ index: Int, into destination: UnsafeMutableRawPointer) -> Int {
            let start = index * chunkSize
            let end = min(start + chunkSize, size)
            // Unsafe: the chunk within the piece and `destination` to `compress`. Safe: `pieceStart <= start` (only the
            // head chunk, compressed below, starts before) and `end <= pieceEnd`, so its `end - start` bytes (a chunk at
            // most) are within `data`; `destination` has a chunk and one byte of room (each call below says where), in
            // the core's output, apart from `data`.
            return unsafe core.encoders.compress(data + (start - pieceStart), count: end - start, into: destination, policy: policy)
        }

        let compressStarted = timings != nil ? MonotonicClock.now : 0
        // A chunk that starts in an earlier piece (the bridge's) goes into `output`: its input isn't all in this piece.
        // It's gathered into the chunk buffer first: the bridged pieces' tails (never overwritten), then this piece's
        // start. The bridge is read here only, before any wait, so each piece's address is used as it's found.
        if chunk < endChunk, chunk * chunkSize < pieceStart {
            let start = chunk * chunkSize
            let end = min(start + chunkSize, size)
            for part in 0..<job.bridge.count {
                let bridged = job.bridge[part]
                let low = max(start, bridged.fileOffset), high = min(pieceStart, bridged.fileOffset + bridged.count)
                guard low < high else { continue }
                // Unsafe: the bridged piece's address. Safe: its `count` bytes (`pieceBase` checks), which the job holds
                // a reference to until `run` releases it after this returns.
                let base = try unsafe Self.pieceBase(context.source, bridged.contents, count: bridged.count)
                // Unsafe: copies file bytes `low..<high` from the bridged piece into the chunk buffer. Safe: the range
                // is within the piece's (`fileOffset..<fileOffset + count`, by `low` and `high`), whose bytes `base`
                // addresses; in the buffer it's `low - start..<high - start`, within a chunk, since `start <= low` and
                // `high <= pieceStart < start + chunkSize`.
                unsafe (core.chunk.base + (low - start)).copyMemory(from: base + (low - bridged.fileOffset), byteCount: high - low)
            }
            // Unsafe: copies the chunk's rest, from this piece's start, into the chunk buffer. Safe: `end - pieceStart`
            // bytes, within the piece (`end <= pieceEnd`); they end at `end - start`, at most a chunk.
            unsafe (core.chunk.base + (pieceStart - start)).copyMemory(from: data, byteCount: end - pieceStart)
            // Unsafe: the chunk buffer and the output's start to `compress`. Safe: the chunk's `end - start` bytes
            // gathered above (the bridge's pieces cover `start..<pieceStart`: the planner's rule); `head` is 0, and the
            // output has far more than the chunk and one byte `compress` may write.
            let count = unsafe core.encoders.compress(core.chunk.base, count: end - start, into: out + head, policy: policy)
            record(&core, count)
            head += count
            chunk += 1
        }
        // The rest in place: into the scratch slot after the batch, then moved to `data + inPlace`, while that stays
        // at or before the input not yet read (the next chunk's start).
        var inPlace = 0
        // Unsafe: a pointer 17 chunks (of a chunk and one byte each) into the output. Safe: `outputCapacity` is 18 such
        // chunks and more, so a chunk and one byte of room follow it; it's past the head chunk (the output's first).
        let slot = unsafe out + Decmpfs.batchChunks * (chunkSize + 1) + chunkSize + 1
        while chunk < endChunk {
            // Unsafe: the slot to `compress`. Safe: a chunk and one byte of room (above), apart from the head chunk's
            // bytes and from `data`.
            let count = unsafe compress(&core, chunk, into: slot)
            let consumed = min((chunk + 1) * chunkSize, size) - pieceStart
            guard inPlace + count <= consumed else { break } // Would overwrite unread input: the rest after the turn.
            // Unsafe: copies the chunk's output from the slot over the piece's bytes at `inPlace`. Safe: it ends at
            // `inPlace + count <= consumed`, the end of this chunk's input within the piece (at most `job.count`):
            // bytes already compressed, which no later chunk or bridging job reads; `count` is what `compress` wrote.
            unsafe (data + inPlace).copyMemory(from: slot, byteCount: count)
            record(&core, count)
            inPlace += count
            chunk += 1
        }
        timings?.add(.compress, since: compressStarted)

        let turnStarted = timings != nil ? MonotonicClock.now : 0
        guard let pieceForkStart = await state.waitForTurn(job.piece) else {
            throw .invalidMetadata("an earlier piece of the file failed, \(state.pathRef.string)")
        }
        timings?.add(.turn, since: turnStarted)
        var written: Int? // The fork's new end, once this piece's writes are done.
        defer { state.passTurn(forkOffset: written) }
        var forkOffset = pieceForkStart
        let fileSystem = context.fileSystem
        if head > 0 {
            try await fileSystem.withPermit { () throws(DiskError) in
                // Unsafe: the output's base to `setAttribute`. Safe: the head chunk's `head` bytes, written there above
                // and not touched since (the slot is beyond them), in the core's storage; read during the call.
                try unsafe core.setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: head, position: forkOffset)
            }
            forkOffset += head
        }
        if inPlace > 0 {
            try await fileSystem.withPermit { () throws(DiskError) in
                // Unsafe: `data` to `setAttribute`. Safe: the `inPlace` compressed bytes moved to the piece's start
                // above (`inPlace <= job.count`), still held by the job after the waits; read during the call.
                try unsafe core.setAttribute(state.descriptor, Decmpfs.resourceFork, data, count: inPlace, position: forkOffset)
            }
            forkOffset += inPlace
        }
        // Chunks left (output caught up with input): batches into `output`, written as they're made.
        while chunk < endChunk {
            let batchEnd = min(endChunk, chunk + Decmpfs.batchChunks)
            var batch = 0
            while chunk < batchEnd {
                // Unsafe: the output at `batch` to `compress`. Safe: a batch is at most 16 chunks, so `batch` is at
                // most 15 chunks of a chunk and one byte, leaving that much room within the output (the head chunk's
                // bytes there are already written to the fork). These chunks' input wasn't overwritten in place: the
                // moves stopped before the first of them.
                let count = unsafe compress(&core, chunk, into: out + batch)
                record(&core, count)
                batch += count
                chunk += 1
            }
            try await fileSystem.withPermit { () throws(DiskError) in
                // Unsafe: the output's base to `setAttribute`. Safe: the batch's `batch` bytes just written there, in
                // the core's storage, which only this task uses; read during the call.
                try unsafe core.setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: batch, position: forkOffset)
            }
            forkOffset += batch
        }
        // The table entries for this piece's chunks: sizes to offsets, plus the end for the last piece.
        var offset = pieceForkStart
        for index in 0..<sizes {
            // Unsafe (the next two): loads entry `index` of the table (a size) and stores its offset there. Safe:
            // `index < sizes`, entries `record` stored, within the table; its storage is aligned to 16 bytes
            // (`RawStorage.small`) and entries are 4 bytes apart, so the load is aligned.
            let count = Int(unsafe core.table.base.load(fromByteOffset: index * 4, as: UInt32.self))
            unsafe core.table.base.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: index * 4, as: UInt32.self)
            offset += count
        }
        var entries = sizes
        if pieceEnd == size {
            // Unsafe: stores the fork's end after the piece's entries. Safe: entry `sizes`, at most `endChunk -
            // firstChunk`, the last of the `endChunk - firstChunk + 1` reserved.
            unsafe core.table.base.storeBytes(of: UInt32(forkOffset).littleEndian, toByteOffset: entries * 4, as: UInt32.self)
            entries += 1
        }
        if entries > 0 {
            try await fileSystem.withPermit { () throws(DiskError) in
                // Unsafe: the table's base to `setAttribute`. Safe: its first `entries` entries, all stored above, in
                // the core's storage; read during the call.
                try unsafe core.setAttribute(state.descriptor, Decmpfs.resourceFork, core.table.base, count: entries * 4, position: firstChunk * 4)
            }
        }
        written = forkOffset
    }

    private nonisolated(nonsending) mutating func pieceDone(_ index: Int) async {
        let state = context.largeFiles[index]
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            await finishLargeFile(index)
        }
    }

    /// The last piece is written (or the file failed): finish it, close it, and free its slot.
    private nonisolated(nonsending) mutating func finishLargeFile(_ index: Int) async {
        let state = context.largeFiles[index]
        let started = timings != nil ? MonotonicClock.now : 0
        await context.fileSystem.acquire()
        let (failed, forkOffset) = state.progress
        var ok = !failed && !context.isStopped
        if ok {
            var core = takeCore()
            // The large file's path, for messages from the shared steps.
            // Unsafe: the slot's path storage, as a pointer, to `setPath`. Safe: the `pathCount` bytes the planner
            // copied there (an entry's path, under `PATH_MAX`, as `setPath` needs), in storage the slot owns, which
            // lives as long as the extraction; `setPath` copies them.
            unsafe core.setPath(unsafe UnsafeRawPointer(state.path.base), count: state.pathCount)
            do throws(DiskError) {
                var compressed = false
                if let policy = state.policy {
                    // Unsafe: `finishFork`, which takes a pointer and may write the table. Safe: no data in memory
                    // (`nil`), and `writesTable` is off (the pieces wrote theirs), so the table isn't touched.
                    compressed = try unsafe core.finishFork(state.descriptor, end: forkOffset, size: state.size, policy: policy, data: nil, writesTable: false)
                }
                try core.finish(state.descriptor, metadata: state.metadata, mode: state.mode, compressed: compressed, deferred: state.deferred)
                context.counters.count(compressed ? .resourceFork : .plain, bytes: state.size)
                slot?.add(entries: 1, bytes: 0)
            } catch {
                ok = false
                context.fail(.disk(error), path: state.pathRef.string, tag: state.tag)
            }
            self.core = consume core
        }
        state.file.close()
        if !ok {
            // A half-written file is removed.
            // Unsafe: a C string from `leaf` bytes into the slot's path storage, to `unlinkat`. Safe: the planner
            // copied the path there NUL-terminated, with `leaf` where its last component starts; the slot owns the
            // storage, and the planner doesn't reuse the slot until its index is released, below.
            _ = unsafe Sys.unlinkat(state.directory, state.path.base.advanced(by: state.leaf).assumingMemoryBound(to: CChar.self), AT_SYMLINK_NOFOLLOW_ANY)
        }
        context.fileSystem.release()
        timings?.add(.largeFileFinish, since: started)
        context.freeLargeFiles.release(index)
    }
}
