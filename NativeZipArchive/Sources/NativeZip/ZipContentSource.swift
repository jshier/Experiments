internal import BytesAsync
import Disk
import Synchronization

/// One archive's part of an extraction, shared by its jobs: what a writer needs to decode an entry.
final class ArchiveJob: Sendable {
    let archive: ZipArchive
    /// The entries being extracted (the caller's selection): jobs name them by index.
    let entries: [ZipEntry]
    let password: String?
    /// Where the archive's entries go in the destination, with a trailing `/` (empty: the destination itself).
    let prefix: String

    init(archive: ZipArchive, entries: [ZipEntry], password: String?, prefix: String) {
        self.archive = archive
        self.entries = entries
        self.password = password
        self.prefix = prefix
    }
}

/// Where Disk's writers get entries' bytes: each job names an entry, which the writer decodes (in its own decoder,
/// outside the file system limit) and hands to its `FileOutput`.
///
/// - Unencrypted stored entries are written from the mapped archive: whole, or in 8 MiB pieces when larger, each
///   checksummed just before it's written (the 1 GB stored entry: 250 ms checksummed whole then written whole, 180 ms
///   in pieces; RESULTS.md, step15).
/// - Others are decoded a chunk (up to 1 MB) at a time into the writer's decoder and each chunk written before the next
///   is decoded; from 4 MB, decoding runs in a child task while the writer writes the previous chunk (two buffers
///   alternate).
/// - The size and CRC-32 are checked after the file's last bytes are written: Disk finishes a file only once `write`
///   returns, so a damaged entry's file is removed when this throws.
///
/// Failures are thrown as they are: the archive's as `EntryError.source` (a ``ZipError``), the output's as
/// `EntryError.disk`; ``ZipExtractionFailure/error`` and the extraction's throw carry both as ``ZipError``.
struct ZipContentSource: ContentSource {
    typealias Failure = ZipError

    struct Contents: Sendable {
        let job: ArchiveJob
        /// The entry's index in `job.entries`.
        let entry: Int32
        /// The entry's place in the plan.
        let tag: Int32
        /// An earlier file at the same path that this one replaces (its tag), or -1: this one is written after it.
        let replaces: Int32
    }

    /// Compressed entries at least this big decode in a child task while the writer writes (several chunks' worth).
    static var overlapThreshold: UInt64 { 4 << 20 }
    /// Unencrypted stored entries bigger than this are written in pieces of this size, each checksummed first.
    static var storedPieceSize: Int { 8 << 20 }

    let state: SourceState

    init(writers: Int) {
        state = SourceState(writers: writers)
    }

    func write(_ contents: Contents, to output: inout FileOutput) async throws(EntryError<ZipError>) {
        let job = contents.job
        let entry = job.entries[Int(contents.entry)]
        // The earlier entry at this path is written first, then replaced (Disk's `.replace`): the archive's order.
        if contents.replaces >= 0 { await state.waitUntilWritten(Int(contents.replaces)) }
        try await Self.write(entry, of: job, to: &output, state: state)
    }

    func release(_ contents: Contents) {
        state.written(Int(contents.tag))
    }

    // MARK: Writing an entry

    private nonisolated(nonsending) static func write(
        _ entry: ZipEntry, of job: ArchiveJob, to output: inout FileOutput, state: SourceState
    ) async throws(EntryError<ZipError>) {
        let archive = job.archive
        let range: Range<Int>
        do throws(ZipError) {
            range = try archive.payloadRange(of: entry)
        } catch {
            throw .source(error)
        }
        // Unsafe: a pointer into the mapping, which `job.archive` keeps alive for the extraction (the job outlives the
        // write: the queue holds it until `release`).
        let payload = unsafe archive.file.buffer(range)
        guard let size = Int(exactly: entry.uncompressedSize) else {
            throw .source(.invalidRecord(.invalidValue, "size of '\(entry.path)'"))
        }
        if entry.method == ZipArchive.Method.stored, !entry.isEncrypted {
            try await unsafe writeStored(entry, payload: payload, size: size, to: &output)
            return
        }
        let decoder = unsafe state.decoder(output.writerIndex)
        do throws(ZipError) {
            // Unsafe: the writer's own decoder slot (no other writer uses this index while it writes), at a stable
            // address.
            try unsafe decoder.pointee!.beginEntry(payload, entry: entry, password: job.password)
        } catch {
            throw .source(error)
        }
        defer { unsafe decoder.pointee!.endEntry() }
        if entry.method != ZipArchive.Method.stored, entry.uncompressedSize >= overlapThreshold {
            try await unsafe writeOverlapped(entry, decoder: decoder, size: size, to: &output)
        } else {
            try await unsafe writeInline(entry, decoder: decoder, size: size, to: &output)
        }
    }

    /// An unencrypted stored entry, from the mapped archive.
    @unsafe
    private nonisolated(nonsending) static func writeStored(
        _ entry: ZipEntry, payload: UnsafeRawBufferPointer, size: Int, to output: inout FileOutput
    ) async throws(EntryError<ZipError>) {
        guard payload.count == size else {
            throw .source(.sizeMismatch(entry.path, expected: entry.uncompressedSize, actual: UInt64(payload.count)))
        }
        // Unsafe: the mapping, valid for the extraction (`write`'s comment).
        let bytes = unsafe RawSpan(_unsafeBytes: payload)
        // Whole, or in pieces each checksummed just before it's written; a failed check removes the file.
        var crc: UInt = 0
        var offset = 0
        while offset < size {
            let piece = bytes.extracting(offset..<min(offset + storedPieceSize, size))
            crc = ZipDecoder.crc32(crc, piece)
            try await writeBytes(piece, to: &output)
            offset += piece.byteCount
        }
        try check(entry, written: size, crc: crc)
    }

    /// Writes `bytes` to the file: Disk's errors as `EntryError.disk`.
    @inline(__always)
    private nonisolated(nonsending) static func writeBytes(_ bytes: RawSpan, to output: inout FileOutput) async throws(EntryError<ZipError>) {
        do throws(DiskError) {
            try await output.write(bytes)
        } catch {
            throw .disk(error)
        }
    }

    /// ``ZipArchive/check(_:written:crc:)``: its errors as the source's.
    @inline(__always)
    private static func check(_ entry: ZipEntry, written: Int, crc: UInt) throws(EntryError<ZipError>) {
        do throws(ZipError) {
            try ZipArchive.check(entry, written: UInt64(written), crc: crc)
        } catch {
            throw .source(error)
        }
    }

    /// Decodes a chunk, writes it, then decodes the next, on the writer's task.
    @unsafe
    private nonisolated(nonsending) static func writeInline(
        _ entry: ZipEntry, decoder: UnsafeMutablePointer<ZipDecoder?>, size: Int, to output: inout FileOutput
    ) async throws(EntryError<ZipError>) {
        // Unsafe: the writer's decoder (see `write`); chunks point into its buffers, which nothing else writes until
        // the next `nextChunk` into the same buffer.
        var crc: UInt = 0
        var written = 0
        while true {
            let next: (chunk: ZipDecoder.Chunk, finished: Bool)
            do throws(ZipError) {
                try unsafe next = decoder.pointee!.nextChunk(into: 0)
            } catch {
                throw .source(error)
            }
            let count = unsafe next.chunk.bytes.count
            if count > 0 {
                written += count
                // More than the entry's size: its own error, before Disk's.
                if written > size { try check(entry, written: written, crc: crc) }
                crc = unsafe ZipDecoder.crc32(crc, RawSpan(_unsafeBytes: next.chunk.bytes))
                try await writeBytes(unsafe RawSpan(_unsafeBytes: next.chunk.bytes), to: &output)
            }
            if unsafe next.finished { break }
        }
        // After the last write: a failed check removes the file (Disk finishes it after this returns).
        try check(entry, written: written, crc: crc)
    }

    /// Decodes in a child task while the writer writes the previous chunk: two buffers alternate (see
    /// ``ZipDecoder/nextChunk(into:)``), handed over by a ``ChunkHandoff``.
    @unsafe
    private nonisolated(nonsending) static func writeOverlapped(
        _ entry: ZipEntry, decoder: UnsafeMutablePointer<ZipDecoder?>, size: Int, to output: inout FileOutput
    ) async throws(EntryError<ZipError>) {
        // Unsafe (here and at `close` and `fail` below): a handoff of `Chunk`s, which are pointers into the decoder's
        // buffers. Safe: these calls move no chunk; `send` and `receive` say why theirs stay valid.
        let handoff = unsafe ChunkHandoff()
        // Unsafe: the writer's decoder, used by the child task alone while the writer waits for its chunks (the group
        // ends before `write` ends the entry).
        let slot = unsafe DecoderSlot(pointer: decoder)
        var crc: UInt = 0
        var written = 0
        // The child returns its error, as a value (a child that threw would type it `any Error`). The throwing group,
        // though nothing throws (`try?`: its `any Error` is never made): the non-throwing `withTaskGroup` measured one
        // more malloc per large entry (`Extract 32 MB text: Bytes`, 105 → 106).
        let failure = try? await withThrowingTaskGroup(of: ZipError?.self) { group -> EntryError<ZipError>? in
            group.addTask {
                defer { unsafe handoff.close() }
                var target = 0
                while true {
                    // Large entries only: stop promptly when the task is cancelled.
                    if Task.isCancelled { return .cancelled }
                    let next: (chunk: ZipDecoder.Chunk, finished: Bool)
                    do throws(ZipError) {
                        try unsafe next = slot.pointer.pointee!.nextChunk(into: target)
                    } catch {
                        return error
                    }
                    if unsafe !next.chunk.bytes.isEmpty {
                        // Returns once the writer has finished the previous chunk and taken this one: the other
                        // buffer is free. `false`: the writer failed; stop.
                        guard await unsafe handoff.send(next.chunk) else { return nil }
                        target ^= 1
                    }
                    if unsafe next.finished { return nil }
                }
            }
            do throws(EntryError<ZipError>) {
                // Unsafe: each chunk is in a decoder buffer the child doesn't write until the next `receive`.
                while let chunk = await unsafe handoff.receive() {
                    let bytes = unsafe RawSpan(_unsafeBytes: chunk.bytes)
                    written += bytes.byteCount
                    guard written <= size else {
                        throw .source(.sizeMismatch(entry.path, expected: entry.uncompressedSize, actual: UInt64(written)))
                    }
                    crc = ZipDecoder.crc32(crc, bytes)
                    try await writeBytes(bytes, to: &output)
                }
            } catch {
                unsafe handoff.fail()
                group.cancelAll()
                return error
            }
            // The handoff closed: the child is done, with its error if it failed.
            for try await result in group {
                if let result { return .source(result) }
            }
            return nil
        }
        if let failure { throw failure }
        // After the last write: a failed check removes the file.
        try check(entry, written: written, crc: crc)
    }
}

/// A writer's decoder, lent to the child task that decodes a large entry for it.
@unsafe
struct DecoderSlot: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<ZipDecoder?>
}

/// What the source's writers share: a decoder per writer (made on first use), and which jobs are written (for
/// replacements, which wait).
@safe
final class SourceState: Sendable {
    // Unchecked state below: raw slots, each used by one writer at a time (Disk's `FileOutput.writerIndex`).
    private let writers: Int
    private nonisolated(unsafe) let decoders: UnsafeMutablePointer<ZipDecoder?>
    private let completion = Mutex(Completion())

    init(writers: Int) {
        self.writers = max(1, writers)
        // Unsafe: slots allocated and initialized here (to `nil`), deinitialized and freed in `deinit`.
        unsafe decoders = .allocate(capacity: self.writers)
        for index in 0..<self.writers {
            unsafe (decoders + index).initialize(to: nil)
        }
    }

    deinit {
        // Unsafe: the slots `init` made; no writer is left (the extraction has ended).
        unsafe decoders.deinitialize(count: writers)
        unsafe decoders.deallocate()
    }

    /// Writer `index`'s decoder, made on its first entry.
    @unsafe
    func decoder(_ index: Int) -> UnsafeMutablePointer<ZipDecoder?> {
        precondition(index >= 0 && index < writers, "a writer index beyond the extraction's writers")
        // Unsafe: within the slots (checked above), used only by this writer.
        let slot = unsafe decoders + index
        if unsafe slot.pointee == nil { unsafe slot.pointee = ZipDecoder() }
        return unsafe slot
    }

    // MARK: Replacements

    /// A replacement waiting for the job with `tag` to be written.
    struct Waiter: ~Copyable {
        let tag: Int
        let continuation: Continuation<Void, Never>
    }

    /// Which plan tags have been written (released by the writers), and who waits for one.
    struct Completion: ~Copyable {
        var written: [UInt64] = []
        var waiters = WaiterQueue<Waiter>(capacity: 1)

        func isWritten(_ tag: Int) -> Bool {
            let word = tag >> 6
            return word < written.count && written[word] & (1 << UInt64(tag & 63)) != 0
        }

        mutating func reserve(_ tags: Int) {
            let words = (tags + 63) >> 6
            if words > written.count { written.append(contentsOf: repeatElement(0, count: words - written.count)) }
        }
    }

    /// Makes room to record tags below `tags`, so writers never grow the record (the planner calls it before queuing).
    func reserve(tags: Int) {
        completion.withLock { $0.reserve(tags) }
    }

    /// A writer is done with a job (written, failed, or skipped): wakes a replacement waiting for it.
    func written(_ tag: Int) {
        // Every waiter for this tag (no allocation when none waits), resumed out of the lock.
        var woken = completion.withLock { state -> WaiterQueue<Waiter> in
            state.reserve(tag + 1)
            state.written[tag >> 6] |= 1 << UInt64(tag & 63)
            return state.waiters.removeAll { $0.tag == tag }
        }
        while let waiter = woken.popFirst() {
            waiter.continuation.resume()
        }
    }

    /// Waits until the job with `tag` has been written. It was queued before the caller's job, so a writer has it or
    /// will take it before this one: the wait ends. Rare (one archive path planned twice).
    nonisolated(nonsending) func waitUntilWritten(_ tag: Int) async {
        if completion.withLock({ $0.isWritten(tag) }) { return }
        await wait(in: completion) { state, continuation in
            if state.isWritten(tag) { return () }
            state.waiters.append(Waiter(tag: tag, continuation: continuation.take()!))
            return nil
        }
    }
}
