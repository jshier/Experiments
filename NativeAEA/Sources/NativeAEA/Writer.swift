import Compression
import Darwin
import Foundation
import Synchronization
import System

/// A writer thread: takes jobs from the queue and writes files. Owns its scratch memory, made once: a path
/// buffer, compressed output for a batch of chunks, a chunk table, a bridge chunk, and Compression's encoder
/// scratch. Nothing is allocated per file.
struct Writer: ~Copyable {
    let context: ExtractionContext
    private let path = RawStorage(byteCount: Int(PATH_MAX) + 1)
    private let output: RawStorage
    private let table: RawStorage
    private let bridge = RawStorage(byteCount: Decmpfs.chunkSize)
    /// A small file across a segment boundary, made contiguous.
    private let staging: RawStorage
    private let scratch: RawStorage

    init(_ context: ExtractionContext) {
        self.context = context
        staging = RawStorage(byteCount: context.smallSpanLimit)
        // A batch of chunks, then a slot for one more (pieces compress there before moving output in place); also
        // room for a single-batch file's table before its chunks.
        output = RawStorage(byteCount: (Decmpfs.batchChunks + 2) * (Decmpfs.chunkSize + 1) + (context.maximumChunks + 1) * 4 + 64)
        table = RawStorage(byteCount: (context.maximumChunks + 1) * 4)
        scratch = RawStorage(byteCount: max(
            compression_encode_scratch_buffer_size(COMPRESSION_LZBITMAP),
            compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
        ))
    }

    func run() {
        let pool = context.pool
        while let job = context.queue.pop() {
            let started = DispatchTime.now().uptimeNanoseconds
            if !context.failed.load(ordering: .relaxed) {
                do throws(AEAError) {
                    switch job.kind {
                    case .file: try writeFile(job)
                    case .piece: try writePiece(job)
                    }
                } catch {
                    context.fail(error)
                }
            } else if job.kind == .piece {
                // Still take the piece's turn, so later pieces don't wait for it.
                skipPiece(job)
            }
            if job.pathBuffer >= 0 { pool.release(job.pathBuffer) }
            if job.dataBuffer >= 0 { pool.release(job.dataBuffer) }
            if job.previousBuffer >= 0 { pool.release(job.previousBuffer) }
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

    private func writeFile(_ job: WriteJob) throws(AEAError) {
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
        if let data = unsafe data, let codec = Decmpfs.algorithm(job.diskCompression) {
            let start = DispatchTime.now().uptimeNanoseconds
            form = unsafe prepare(data, count: count, codec)
            context.timings.add(.compress, since: start)
        }
        if case .streamed(let codec) = form, let data = unsafe data {
            let descriptor = try fileSystem { () throws(AEAError) in try openFile(mode, job) }
            defer { context.timings.measure(.close) { _ = close(descriptor) } }
            if try unsafe writeStreamed(descriptor, data, count: count, codec) { flags |= UInt32(UF_COMPRESSED) }
            try fileSystem { () throws(AEAError) in try finish(descriptor, mode: mode, flags: flags, owner: owner, times: job.times) }
            return
        }
        try fileSystem { () throws(AEAError) in
            let descriptor = try openFile(mode, job)
            defer { context.timings.measure(.close) { _ = close(descriptor) } }
            switch form {
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
            try finish(descriptor, mode: mode, flags: flags, owner: owner, times: job.times)
        }
    }

    /// How a file is stored, decided before any file system call.
    private enum Form {
        case plain
        /// The `decmpfs` attribute with the data inline: the first `count` bytes of `output`.
        case inline(Int)
        /// The resource fork: the first `count` bytes of `output`, table and chunks.
        case fork(Int, type: UInt32)
        /// More than one batch: compressed and written a batch at a time.
        case streamed((algorithm: compression_algorithm, inline: UInt32, fork: UInt32))
    }

    /// Compresses a file of one batch into `output`, ready to write.
    private func prepare(
        _ data: UnsafeRawPointer, count: Int, _ codec: (algorithm: compression_algorithm, inline: UInt32, fork: UInt32)
    ) -> Form {
        let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        let tableCount = (chunkCount + 1) * 4
        let out = unsafe output.base
        if chunkCount == 1 {
            // Header room first, so an inline attribute is one contiguous write.
            let compressed = unsafe Decmpfs.compressChunk(data, count: count, into: out + Decmpfs.headerSize, scratch: scratch.base, algorithm: codec.algorithm)
            if Decmpfs.headerSize + compressed <= Decmpfs.maximumInlineAttribute {
                let header = Decmpfs.header(type: codec.inline, size: count)
                header.span.withUnsafeBytes { unsafe out.copyMemory(from: $0.baseAddress!, byteCount: Decmpfs.headerSize) }
                return .inline(Decmpfs.headerSize + compressed)
            }
            // Too big to go inline: the same chunk, after a two-entry table.
            let end = tableCount + compressed
            guard Decmpfs.pays(end, count) else { return .plain }
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
            offset += unsafe Decmpfs.compressChunk(data + start, count: min(Decmpfs.chunkSize, count - start), into: out + offset, scratch: scratch.base, algorithm: codec.algorithm)
        }
        unsafe out.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
        return Decmpfs.pays(offset, count) ? .fork(offset, type: codec.fork) : .plain
    }

    /// Writes a file of several batches: each compressed outside the file system's limit, written inside it.
    ///
    /// - Returns: `false` if the file was written uncompressed instead (compressing didn't pay, judged on the whole
    ///   file, as Apple's extractor does).
    private func writeStreamed(
        _ descriptor: Int32, _ data: UnsafeRawPointer, count: Int,
        _ codec: (algorithm: compression_algorithm, inline: UInt32, fork: UInt32)
    ) throws(AEAError) -> Bool {
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
                written += unsafe Decmpfs.compressChunk(data + start, count: min(Decmpfs.chunkSize, count - start), into: out + written, scratch: scratch.base, algorithm: codec.algorithm)
            }
            try fileSystem { () throws(AEAError) in
                try unsafe setAttribute(descriptor, Decmpfs.resourceFork, out, count: written, position: forkOffset)
            }
            forkOffset += written
            chunk = batchEnd
        }
        return try fileSystem { () throws(AEAError) -> Bool in
            if !Decmpfs.pays(forkOffset, count) {
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

    /// Runs `body` as one of at most ``AEAExtractionOptions/fileSystemWidth`` threads in the file system.
    @inline(__always)
    private func fileSystem<R>(_ body: () throws(AEAError) -> R) throws(AEAError) -> R {
        context.timings.measure(.wait) { context.fileSystem.wait() }
        defer { context.fileSystem.signal() }
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
    /// Whether the file is compressed at all is decided once, by the piece with its first chunk, on that chunk's
    /// batch (compressed into this writer's buffer, so its input stays intact); the others wait for the decision
    /// before overwriting anything.
    private func writePiece(_ job: WriteJob) throws(AEAError) {
        let state = context.largeFiles[job.largeFile]
        // The piece's bytes are this job's alone (other jobs' ranges of the buffer are disjoint), so it may
        // overwrite them.
        let data = unsafe UnsafeMutableRawPointer(mutating: pointer(job.dataBuffer, job.dataOffset))
        defer { pieceDone(job.largeFile) }
        let size = job.fileSize
        let chunkSize = Decmpfs.chunkSize
        let pieceStart = job.fileOffset, pieceEnd = job.fileOffset + job.dataCount
        // Chunks whose end is in this piece: the first may start in the previous piece (a bridge).
        let firstChunk = pieceStart / chunkSize
        let endChunk = pieceEnd == size ? state.chunkCount : pieceEnd / chunkSize
        let decides = firstChunk == 0 && endChunk > 0
        let out = unsafe output.base
        let algorithm = state.algorithm
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
                // The bridge: the chunk's start is the previous piece's tail (which that piece never overwrites: its
                // output stays before its last whole chunk's end), the rest from this piece.
                guard job.previousBuffer >= 0 else { throw AEAError.invalidArchive("a chunk spans more than two pieces") }
                let tail = pieceStart - start
                unsafe bridge.base.copyMemory(from: pointer(job.previousBuffer, job.previousOffset + (start - job.previousFileOffset)), byteCount: tail)
                unsafe (bridge.base + tail).copyMemory(from: data, byteCount: end - pieceStart)
                return unsafe Decmpfs.compressChunk(bridge.base, count: end - start, into: destination, scratch: scratch.base, algorithm: algorithm)
            }
            return unsafe Decmpfs.compressChunk(data + (start - pieceStart), count: end - start, into: destination, scratch: scratch.base, algorithm: algorithm)
        }

        state.turn.lock()
        let settled = state.decided
        state.turn.unlock()
        if settled {
            // Stored uncompressed from the start (the archive or the options say so): nothing to decide.
        } else if decides {
            // The file's first batch, into `output`: it decides.
            let batchEnd = min(endChunk, chunk + Decmpfs.batchChunks)
            while chunk < batchEnd {
                let count = try unsafe compress(chunk, into: out + head)
                record(count)
                head += count
                chunk += 1
            }
            let raw = min(batchEnd * chunkSize, size)
            let compressed = Decmpfs.pays(head, raw)
            state.turn.lock()
            if !compressed { state.forkType = 0 }
            state.decided = true
            state.turn.broadcast()
            state.turn.unlock()
        } else {
            state.turn.lock()
            while !state.decided, !state.failed { state.turn.wait() }
            state.turn.unlock()
        }
        state.turn.lock()
        let compressedFile = state.forkType != 0, failed = state.failed
        state.turn.unlock()
        if failed { throw .invalidArchive("an earlier piece of the file failed") }
        if !compressedFile {
            // Uncompressed: each piece writes its own range, in any order (this piece's bytes are intact: nothing
            // was overwritten before the decision). The first piece also writes a first piece too small to be one
            // (the walker folded it into this one's bridge).
            if job.piece == 0, pieceStart > 0, job.previousBuffer >= 0 {
                try fileSystem { () throws(AEAError) in try unsafe writeFully(state.descriptor, pointer(job.previousBuffer, job.previousOffset), count: pieceStart, at: 0) }
            }
            try fileSystem { () throws(AEAError) in try unsafe writeFully(state.descriptor, data, count: job.dataCount, at: pieceStart) }
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

        try waitForTurn(state, piece: job.piece)
        defer { passTurn(state) }
        let pieceForkStart = state.forkOffset
        var forkOffset = pieceForkStart
        if head > 0 {
            let position = forkOffset
            try fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: head, position: position) }
            forkOffset += head
        }
        if inPlace > 0 {
            let position = forkOffset
            try fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, data, count: inPlace, position: position) }
            forkOffset += inPlace
        }
        // Chunks left (output caught up with input): batches into `output`, written as they're made.
        while chunk < endChunk {
            let batchEnd = min(endChunk, chunk + Decmpfs.batchChunks)
            var written = 0
            while chunk < batchEnd {
                let count = try unsafe compress(chunk, into: out + written)
                record(count)
                written += count
                chunk += 1
            }
            let position = forkOffset
            try fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, out, count: written, position: position) }
            forkOffset += written
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
            try fileSystem { () throws(AEAError) in try unsafe setAttribute(state.descriptor, Decmpfs.resourceFork, table.base, count: entries * 4, position: firstChunk * 4) }
        }
        state.forkOffset = forkOffset
    }

    private func waitForTurn(_ state: LargeFile, piece: Int) throws(AEAError) {
        state.turn.lock()
        while state.nextPiece != piece, !state.failed { state.turn.wait() }
        let failed = state.failed
        state.turn.unlock()
        if failed { throw .invalidArchive("an earlier piece of the file failed") }
    }

    private func passTurn(_ state: LargeFile) {
        state.turn.lock()
        state.nextPiece += 1
        state.turn.broadcast()
        state.turn.unlock()
    }

    private func skipPiece(_ job: WriteJob) {
        let state = context.largeFiles[job.largeFile]
        state.turn.lock()
        state.failed = true
        state.turn.broadcast()
        state.turn.unlock()
        pieceDone(job.largeFile)
    }

    private func pieceDone(_ index: Int) {
        let state = context.largeFiles[index]
        if state.outstanding.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            Self.finishLargeFile(context, index)
        }
    }

    /// The last piece is written (or the file failed): set its attributes, close it, and free its state.
    static func finishLargeFile(_ context: ExtractionContext, _ index: Int) {
        let state = context.largeFiles[index]
        context.fileSystem.wait()
        defer { context.fileSystem.signal() }
        if !state.failed, !context.failed.load(ordering: .relaxed) {
            var flags = state.flags & ~UInt32(UF_COMPRESSED)
            var failure: AEAError?
            if state.forkType != 0 {
                let header = Decmpfs.header(type: state.forkType, size: state.size)
                let result = header.span.withUnsafeBytes { bytes in
                    unsafe fsetxattr(state.descriptor, Decmpfs.attribute, bytes.baseAddress!, Decmpfs.headerSize, 0, 0)
                }
                if result != 0 { failure = .fileSystem("setxattr decmpfs", Errno(rawValue: errno)) }
                flags |= UInt32(UF_COMPRESSED)
            }
            if failure == nil {
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
        if times.apply(descriptor) != 0 { return .fileSystem("setattrlist", Errno(rawValue: errno)) }
        if flags != 0, fchflags(descriptor, flags) != 0 { return .fileSystem("chflags", Errno(rawValue: errno)) }
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
