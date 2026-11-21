import Bytes
import Darwin
import System

/// How a file ended up stored.
public enum StoredForm: Sendable, Hashable {
    /// An ordinary file.
    case plain
    /// APFS-compressed, the data inline in the `com.apple.decmpfs` attribute.
    case inline
    /// APFS-compressed, the data in the resource fork.
    case resourceFork
    /// Not written: something was there and the policy is ``ExistingItemPolicy/skip``.
    case skipped
}

/// A writer's scratch and the steps of writing one file, each synchronous: compressing (CPU work, outside any file
/// system limit) apart from the calls (inside it). ``FileWriter`` runs the steps in turn; the scheduler's writers wait
/// for a file system permit between them. Everything is allocated once: nothing per file. Each buffer is made the first
/// time it's needed (a writer of plain files whole never makes its output, table, chunk, or staging buffer), and the
/// scheduler's writers make the core itself on their first job: a writer that gets none allocates nothing.
@safe
struct WriterCore: ~Copyable {
    let destination: Destination
    /// Holds the path buffer: this core's own, or the extraction's, shared by its writers (each its own part).
    private let pathStorage: RawStorage
    /// The current file's path, NUL-terminated (``pathCapacity`` bytes, in `pathStorage`).
    let path: UnsafeMutableRawPointer
    private var outputStorage: RawStorage?
    private var tableStorage: RawStorage?
    private var stagingStorage: RawStorage?
    private var chunkStorage: RawStorage?
    private let stagingCapacity: Int
    let encoders = ChunkEncoders()
    private var unpacker: ForkUnpacker?

    /// Compressed output: a batch of chunks, then a slot for one more (pieces compress there before moving output in
    /// place); also room for the header before an inline attribute and a one-batch file's table before its chunks.
    var output: RawStorage {
        mutating get {
            if let outputStorage { return outputStorage }
            let storage = RawStorage(byteCount: Self.outputCapacity)
            outputStorage = storage
            return storage
        }
    }

    /// A streamed or batched file's chunk table (``reserveTable(_:)`` makes room for a file's).
    var table: RawStorage {
        mutating get {
            if let tableStorage { return tableStorage }
            let storage = RawStorage(byteCount: 64 * 1024, alignment: RawStorage.small)
            tableStorage = storage
            return storage
        }
    }

    /// Small files gathered from several writes (decoded, or across buffers).
    var staging: RawStorage {
        mutating get {
            if let stagingStorage { return stagingStorage }
            let storage = RawStorage(byteCount: stagingCapacity)
            stagingStorage = storage
            return storage
        }
    }

    /// A streamed file's partial chunk; a piece's chunk that starts in earlier pieces.
    var chunk: RawStorage {
        mutating get {
            if let chunkStorage { return chunkStorage }
            let storage = RawStorage(byteCount: Decmpfs.chunkSize)
            chunkStorage = storage
            return storage
        }
    }

    static let outputCapacity = (Decmpfs.batchChunks + 2) * (Decmpfs.chunkSize + 1) + (Decmpfs.batchChunks + 2) * 4 + 64
    /// A path buffer's size: a path under `PATH_MAX` bytes and its NUL.
    static var pathCapacity: Int { Int(PATH_MAX) + 1 }

    /// Scratch with its own path buffer.
    init(_ destination: Destination, stagingCapacity: Int) {
        let storage = RawStorage(byteCount: Self.pathCapacity, alignment: RawStorage.small)
        // Unsafe: `storage`'s base pointer as the path buffer. Safe: `pathCapacity` bytes just allocated, and the core
        // keeps `storage` (its `pathStorage`) for as long as it has the pointer.
        unsafe self.init(destination, stagingCapacity: stagingCapacity, path: storage.base, in: storage)
    }

    /// Scratch whose path buffer is ``pathCapacity`` bytes at `path`, in `storage` (which the core keeps alive).
    init(_ destination: Destination, stagingCapacity: Int, path: UnsafeMutableRawPointer, in storage: RawStorage) {
        self.destination = destination
        pathStorage = storage
        // Unsafe: stores the caller's pointer. Safe: `pathCapacity` bytes within `storage` (the caller's contract),
        // which `pathStorage`, set above, keeps allocated as long as the core.
        unsafe self.path = path
        self.stagingCapacity = stagingCapacity
    }

    // Unsafe (the property below): the path buffer as a C string, which `PathRef` measures (`strlen`) and keeps a
    // pointer to. Safe: `setPath` (or the queue's `pop`) wrote a path and its NUL there before any file is worked on;
    // the buffer lives as long as the core, and the reference is read only while this file's path is still in it.
    /// The path buffer, NUL-terminated (set by `setPath`).
    var pathRef: PathRef { unsafe PathRef(cString: path.assumingMemoryBound(to: CChar.self)) }

    /// Copies `count` path bytes into the path buffer, NUL-terminated.
    mutating func setPath(_ bytes: UnsafeRawPointer, count: Int) {
        // Unsafe (the next two): copies the caller's bytes into the path buffer and stores a NUL after them. Safe:
        // `count` is under `PATH_MAX` (an `EntryPath`'s bytes) and the buffer holds `PATH_MAX + 1`, so `count + 1`
        // bytes fit; the caller keeps `count` bytes at `bytes` valid for the call.
        unsafe path.copyMemory(from: bytes, byteCount: count)
        unsafe path.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
    }

    /// Room for a table of `entries` 32-bit offsets.
    mutating func reserveTable(_ entries: Int) {
        if entries * 4 > (tableStorage?.byteCount ?? 0) {
            tableStorage = RawStorage(byteCount: max(entries * 4, 64 * 1024), alignment: RawStorage.small)
        }
    }

    // MARK: Compressing (outside the file system limit)

    enum Form {
        case plain
        /// The `decmpfs` attribute with the data inline: the first `count` bytes of `output`.
        case inline(Int)
        /// The resource fork: the first `count` bytes of `output`, table and chunks; its type.
        case fork(Int, type: UInt32)
        /// More than one batch of chunks: compressed and written a batch at a time.
        case batches(StoragePolicy)
    }

    /// Decides how a whole file in memory is stored, compressing it if it fits one batch.
    mutating func prepare(_ data: UnsafeRawPointer?, count: Int, storage: Storage) -> Form {
        // `data` is `count` bytes the caller keeps valid for the call. The output (`outputCapacity` bytes) holds a table
        // of up to 18 entries and 18 chunks of a chunk and one byte each, the most `compress` writes, and 64 bytes.
        // Unsafe: reads the optional pointer. Safe: only its value, tested for `nil`.
        guard case .compressed(let policy) = storage, let data = unsafe data, count > 0 else { return .plain }
        // Unsafe: a span over the file's first bytes, with no lifetime the compiler can check. Safe: at most `count`
        // of the caller's bytes; `skips` only reads it, during the call.
        if unsafe policy.skips(size: count, first: RawSpan(_unsafeStart: data, byteCount: min(count, 8))) { return .plain }
        let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        let tableCount = (chunkCount + 1) * 4
        // Unsafe: the output storage's base pointer. Safe: `outputCapacity` bytes that the core owns (`outputStorage`)
        // for longer than this call, the only user of `out`.
        let out = unsafe output.base
        let types = policy.codec.types
        if chunkCount == 1 {
            // Header room first, so an inline attribute is one contiguous write.
            // Unsafe: the file and the output after 16 bytes to `compress`. Safe: one chunk's `count` bytes of `data`;
            // a chunk and one byte of room at offset 16, well within the output.
            let compressed = unsafe encoders.compress(data, count: count, into: out + Decmpfs.headerSize, policy: policy)
            if policy.allowsInline, Decmpfs.headerSize + compressed <= Decmpfs.maximumInlineAttribute {
                let header = Decmpfs.header(type: types.inline, size: count)
                // Unsafe: copies the header from the span's buffer to the output's start. Safe: the header is 16
                // bytes (`headerSize`), valid inside `withUnsafeBytes`, so non-`nil`; the output's first 16 are free.
                header.span.withUnsafeBytes { unsafe out.copyMemory(from: $0.baseAddress!, byteCount: Decmpfs.headerSize) }
                return .inline(Decmpfs.headerSize + compressed)
            }
            guard types.fork != 0 else { return .plain }
            // Too big for inline: the same chunk after a two-entry table.
            let end = tableCount + compressed
            guard policy.pays(end, count) else { return .plain }
            // Unsafe: moves the chunk down from offset 16 to offset 8 (`tableCount`), overlapping. Safe: both ranges
            // are within the output (`compressed` is at most a chunk and one byte), and `copyMemory` allows overlap.
            unsafe (out + tableCount).copyMemory(from: out + Decmpfs.headerSize, byteCount: compressed) // memmove.
            // Unsafe (the next two): stores the table's two entries. Safe: the output's first 8 bytes, before the
            // chunk at offset 8.
            unsafe out.storeBytes(of: UInt32(tableCount).littleEndian, toByteOffset: 0, as: UInt32.self)
            unsafe out.storeBytes(of: UInt32(end).littleEndian, toByteOffset: 4, as: UInt32.self)
            return .fork(end, type: types.fork)
        }
        guard types.fork != 0 else { return .plain }
        guard count <= Decmpfs.batchChunks * Decmpfs.chunkSize else { return .batches(policy) }
        // One batch: the table and chunks contiguous, written once, unless compressing doesn't pay.
        var offset = tableCount
        for chunk in 0..<chunkCount {
            // Unsafe: stores chunk `chunk`'s table entry. Safe: `chunk < chunkCount <= 16`, so within the table's
            // `tableCount` bytes at the output's start, before the first chunk's bytes.
            unsafe out.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: chunk * 4, as: UInt32.self)
            let start = chunk * Decmpfs.chunkSize
            // Unsafe: one chunk of the file and the output at `offset` to `compress`. Safe: `start < count`, and the
            // chunk's length is what's left of `count`, at most 64 KiB; `offset` is at most the table (68 bytes) and
            // 15 chunks of a chunk and one byte, leaving the chunk and one byte `compress` needs within the output.
            offset += unsafe encoders.compress(data + start, count: min(Decmpfs.chunkSize, count - start), into: out + offset, policy: policy)
        }
        // Unsafe: stores the table's last entry (the end). Safe: entry `chunkCount`, the last of the table's
        // `chunkCount + 1`, at the output's start.
        unsafe out.storeBytes(of: UInt32(offset).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
        return policy.pays(offset, count) ? .fork(offset, type: types.fork) : .plain
    }

    /// Compresses chunks `first..<end` of `data` (a whole file of `count` bytes) into `output`, recording their offsets
    /// from `forkOffset` in the table.
    ///
    /// - Returns: The bytes written to `output`.
    mutating func compressBatch(_ data: UnsafeRawPointer, count: Int, chunks: Range<Int>, forkOffset: Int, policy: StoragePolicy) -> Int {
        // The caller's contract: `data` is the whole file (`count` bytes, valid for the call), `chunks` are chunks of
        // it, at most a batch (16), and `reserveTable` has made room for an entry per chunk of the file and one more.
        var written = 0
        for index in chunks {
            // Unsafe: stores chunk `index`'s entry in the table. Safe: `index` is a chunk of the file, so within the
            // entries reserved; the table storage is the core's.
            unsafe table.base.storeBytes(of: UInt32(forkOffset + written).littleEndian, toByteOffset: index * 4, as: UInt32.self)
            let start = index * Decmpfs.chunkSize
            // Unsafe: one chunk of the file and the output at `written` to `compress`. Safe: `start < count` (a chunk
            // of the file), its length what's left of `count`, at most 64 KiB; `written` is at most 15 chunks of a
            // chunk and one byte, leaving the chunk and one byte `compress` needs within `outputCapacity`.
            written += unsafe encoders.compress(data + start, count: min(Decmpfs.chunkSize, count - start), into: output.base + written, policy: policy)
        }
        return written
    }

    // MARK: File system calls (inside the limit)

    /// Creates the file at the path buffer (`leaf` bytes in, relative to `directory`), owner-writable.
    ///
    /// - Returns: The descriptor, or -1 if skipped.
    func create(directory: Int32, leaf: Int, mode final: mode_t) throws(DiskError) -> Int32 {
        // Unsafe: a C string from `leaf` bytes into the path buffer. Safe: the buffer holds the file's NUL-terminated
        // path (`setPath`, or the queue's `pop`), and `leaf` is where its last component starts (the caller's
        // contract), so at or before the NUL; bytes are `CChar`-compatible.
        let name = unsafe path.advanced(by: leaf).assumingMemoryBound(to: CChar.self)
        // Unsafe: `name` to `createFile`. Safe: NUL-terminated, in the core's buffer, which isn't changed during the
        // call; `createFile` doesn't keep it.
        return try unsafe destination.createFile(directory, name, mode: destination.creationMode(final), path: pathRef)
    }

    /// Creates the file, making its parents if it had none (``FileWriter``'s path; the scheduler made them).
    func createMakingParents(count: Int, mode final: mode_t) throws(DiskError) -> Int32 {
        do throws(DiskError) {
            return try create(directory: destination.root, leaf: 0, mode: final)
        } catch .system(_, _, let errno) where errno == .noSuchFileOrDirectory {
            // Unsafe: the path buffer as a C string to `makeParents`. Safe: it holds the path's `count` bytes and a
            // NUL (`setPath`, the caller's contract), in the core's buffer, unchanged during the call.
            try unsafe destination.makeParents(of: path.assumingMemoryBound(to: CChar.self), count: count)
            return try create(directory: destination.root, leaf: 0, mode: final)
        }
    }

    /// Writes `form` (and `data` for a plain file) to the new file.
    ///
    /// - Returns: Whether it's compressed.
    mutating func write(_ descriptor: Int32, form: Form, data: UnsafeRawPointer?, count: Int) throws(DiskError) -> Bool {
        switch form {
        case .plain:
            // Unsafe: reads the optional pointer, then passes it to `writeFully`. Safe: `data`, when not `nil`, is
            // `count` bytes the caller keeps valid for the call; `writeFully` only reads them, during it.
            if let data = unsafe data, count > 0 { try unsafe FileIO.writeFully(descriptor, data, count: count, at: 0, path: pathRef) }
            return false
        case .inline(let attributeCount):
            // Unsafe: the output's base to `setAttribute`. Safe: `prepare` (which made this form) wrote the header
            // and chunk into the output's first `attributeCount` bytes; the storage is the core's, read during the call.
            try unsafe setAttribute(descriptor, Decmpfs.attribute, output.base, count: attributeCount, position: 0)
            return true
        case .fork(let forkCount, let type):
            // Unsafe: the output's base to `setAttribute`. Safe: `prepare` wrote the table and chunks into the
            // output's first `forkCount` bytes; the storage is the core's, read during the call.
            try unsafe setAttribute(descriptor, Decmpfs.resourceFork, output.base, count: forkCount, position: 0)
            try setHeader(descriptor, type: type, size: count)
            return true
        case .batches:
            preconditionFailure("batches are written by the caller")
        }
    }

    /// The quarantine and the one call that sets times, owner, mode, and flags; or, for a file finished after the
    /// writers (`deferred`), only `UF_COMPRESSED`.
    func finish(_ descriptor: Int32, metadata: EntryMetadata, mode final: mode_t, compressed: Bool, deferred: Bool) throws(DiskError) {
        if deferred {
            if let quarantine = destination.options.quarantine { try quarantine.apply(descriptor, path: pathRef) }
            if compressed {
                var flags = AttributeList(times: EntryTimes(), owner: nil, mode: nil, flags: UInt32(UF_COMPRESSED))
                if flags.apply(descriptor) != 0 { throw .system("setattrlist", path: pathRef, code: errno) }
            }
            return
        }
        let created = destination.createdMode(destination.creationMode(final))
        var attributes = destination.attributes(metadata, mode: final, created: created, compressed: compressed)
        try destination.finish(descriptor, attributes: &attributes, path: pathRef)
    }

    func setAttribute(_ descriptor: Int32, _ name: String, _ bytes: UnsafeRawPointer, count: Int, position: Int) throws(DiskError) {
        // Unsafe: `name`'s C string and `bytes` to `fsetxattr`. Safe: the string's temporary lasts for the call;
        // `bytes` is the caller's `count` readable bytes, valid for this call (the contract), read only during it.
        if unsafe Sys.fsetxattr(descriptor, name, bytes, count, position) != 0 {
            throw .system(name == Decmpfs.resourceFork ? "setxattr fork" : "setxattr decmpfs", path: pathRef, code: errno)
        }
    }

    func setHeader(_ descriptor: Int32, type: UInt32, size: Int) throws(DiskError) {
        let header = Decmpfs.header(type: type, size: size)
        try header.span.withUnsafeBytes { (bytes) throws(DiskError) in
            // Unsafe: the buffer's base pointer to `setAttribute`. Safe: the header's 16 bytes (`headerSize`), so not
            // `nil`, valid inside `withUnsafeBytes`; `setAttribute` reads them before it returns.
            try unsafe setAttribute(descriptor, Decmpfs.attribute, bytes.baseAddress!, count: Decmpfs.headerSize, position: 0)
        }
    }

    /// Writes a batched file's table (unless `writesTable` is off: pieces wrote theirs) and header after its chunks, or, if the fork doesn't pay, rewrites it plain
    /// (from `data` if it's still in memory, else from the fork).
    ///
    /// - Returns: Whether it stayed compressed.
    mutating func finishFork(_ descriptor: Int32, end: Int, size: Int, policy: StoragePolicy, data: UnsafeRawPointer?, writesTable: Bool = true) throws(DiskError) -> Bool {
        // The caller's contract: `data`, if any, is the whole file (`size` bytes, valid for the call); with
        // `writesTable`, `reserveTable` has made room for the file's `chunkCount + 1` entries, the chunks' filled in.
        let chunkCount = (size + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
        if !policy.pays(end, size) {
            // Unsafe: reads the optional pointer. Safe: only its value, tested for `nil`.
            if let data = unsafe data {
                // Unsafe: a C string to `fremovexattr`. Safe: a string constant's, valid for the call.
                if unsafe Sys.fremovexattr(descriptor, Decmpfs.resourceFork) != 0 { throw .system("removexattr", path: pathRef, code: errno) }
                // Unsafe: `data` to `writeFully`. Safe: the whole file's `size` bytes, the caller's, read during the
                // call.
                try unsafe FileIO.writeFully(descriptor, data, count: size, at: 0, path: pathRef)
            } else {
                // Streamed: the table is still in memory (pieces wrote theirs into the fork as they went). Writing it lets
                // the unpacker read every chunk back: a rare path (Xcode has one such file).
                if writesTable {
                    // Unsafe: stores the table's last entry (the fork's end). Safe: entry `chunkCount`, the last of
                    // the `chunkCount + 1` reserved; the table storage is the core's.
                    unsafe table.base.storeBytes(of: UInt32(end).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
                    // Unsafe: the table's base to `setAttribute`. Safe: its `chunkCount + 1` entries, all stored by
                    // now, in the core's storage; read during the call.
                    try unsafe setAttribute(descriptor, Decmpfs.resourceFork, table.base, count: (chunkCount + 1) * 4, position: 0)
                }
                if unpacker == nil { unpacker = ForkUnpacker() }
                try unpacker!.unpack(descriptor, size: size, chunkCount: chunkCount, codec: policy.codec, path: pathRef)
            }
            return false
        }
        if writesTable {
            // Unsafe: stores the table's last entry (the fork's end). Safe: entry `chunkCount`, the last of the
            // `chunkCount + 1` reserved; the table storage is the core's.
            unsafe table.base.storeBytes(of: UInt32(end).littleEndian, toByteOffset: chunkCount * 4, as: UInt32.self)
            // Unsafe: the table's base to `setAttribute`. Safe: its `chunkCount + 1` entries, all stored by now, in
            // the core's storage; read during the call.
            try unsafe setAttribute(descriptor, Decmpfs.resourceFork, table.base, count: (chunkCount + 1) * 4, position: 0)
        }
        try setHeader(descriptor, type: policy.codec.types.fork, size: size)
        return true
    }

    /// Closes and removes a file that failed partway (its name: the path buffer from `leaf` in `directory`).
    func abandon(_ descriptor: Int32, directory: Int32, leaf: Int) {
        Sys.close(descriptor)
        // Unsafe: a C string from `leaf` bytes into the path buffer, to `unlinkat`. Safe: the buffer still holds the
        // failed file's NUL-terminated path, and `leaf` is where its last component starts (as for `create`).
        _ = unsafe Sys.unlinkat(directory, path.advanced(by: leaf).assumingMemoryBound(to: CChar.self), AT_SYMLINK_NOFOLLOW_ANY)
    }
}

/// Writes whole files synchronously on the calling thread: compression, then the calls. For an app or a tool writing
/// a few files; extractions use the scheduler (``Extraction``), whose writers run these same steps in parallel with
/// the calls limited.
///
/// ```swift
/// let destination = try Destination(FilePath("/tmp/out"))
/// var writer = FileWriter(destination)
/// try writer.writeFile(EntryPath(validating: "a/b.txt".utf8Span), contents: bytes.span.bytes,
///                      metadata: EntryMetadata(mode: 0o644), storage: .compressed(.appleArchive))
/// ```
///
/// Not `Sendable`: one per thread (it owns its scratch and encoders: about 1.2 MB, plus the staging capacity).
public struct FileWriter: ~Copyable {
    var core: WriterCore

    public init(_ destination: Destination) {
        core = WriterCore(destination, stagingCapacity: 1)
    }

    /// Writes a file (making missing parents), compressed as `storage` says.
    ///
    /// - Returns: How it was stored.
    @discardableResult
    public mutating func writeFile(_ path: EntryPath, contents: RawSpan, metadata: EntryMetadata = .init(), storage: Storage = .plain) throws(DiskError) -> StoredForm {
        guard !path.isRoot else { throw .unsafePath("") }
        let count = contents.byteCount
        // Unsafe: the path's bytes, as a pointer, to `setPath`. Safe: not empty (checked above), so not `nil`; an
        // `EntryPath`'s bytes, under `PATH_MAX`, as `setPath` needs; valid inside `withUnsafeBytes`, and copied there.
        path.bytes.withUnsafeBytes { unsafe core.setPath($0.baseAddress!, count: $0.count) }
        // `data` below is the contents' `count` bytes (or `nil` for none), valid inside this closure, which every use
        // of it returns within.
        return try contents.withUnsafeBytes { (bytes) throws(DiskError) -> StoredForm in
            let data = bytes.baseAddress
            // Unsafe: `data` to `prepare`. Safe: the span's `count` bytes, as above; `prepare` only reads them.
            let form = unsafe core.prepare(data, count: count, storage: storage)
            let final = core.destination.finalMode(metadata.mode, default: 0o644)
            let descriptor = try core.createMakingParents(count: path.bytes.byteCount, mode: final)
            if descriptor < 0 { return .skipped }
            do throws(DiskError) {
                var compressed: Bool
                var stored: StoredForm
                // Unsafe: reads the optional pointer. Safe: only its value, tested for `nil`.
                if case .batches(let policy) = form, let data = unsafe data {
                    let chunkCount = (count + Decmpfs.chunkSize - 1) / Decmpfs.chunkSize
                    core.reserveTable(chunkCount + 1)
                    var forkOffset = (chunkCount + 1) * 4
                    var chunk = 0
                    while chunk < chunkCount {
                        let end = min(chunkCount, chunk + Decmpfs.batchChunks)
                        // Unsafe: `data` to `compressBatch`. Safe: the whole file's `count` bytes; `chunk..<end` are at
                        // most 16 of its `chunkCount` chunks, and the table was reserved for all of them just above.
                        let written = unsafe core.compressBatch(data, count: count, chunks: chunk..<end, forkOffset: forkOffset, policy: policy)
                        // Unsafe: the output's base to `setAttribute`. Safe: the `written` bytes `compressBatch` just
                        // put there, in the core's storage; read during the call.
                        try unsafe core.setAttribute(descriptor, Decmpfs.resourceFork, core.output.base, count: written, position: forkOffset)
                        forkOffset += written
                        chunk = end
                    }
                    // Unsafe: `data` to `finishFork`. Safe: the whole file's `count` bytes, valid in this closure; the
                    // table has the `chunkCount + 1` entries reserved above, every chunk's stored by the batches.
                    compressed = try unsafe core.finishFork(descriptor, end: forkOffset, size: count, policy: policy, data: data)
                    stored = compressed ? .resourceFork : .plain
                } else {
                    // Unsafe: `data` to `write`. Safe: the contents' `count` bytes (or `nil`), valid in this closure;
                    // `form` is what `prepare` just made from them, its bytes still in the output.
                    compressed = try unsafe core.write(descriptor, form: form, data: data, count: count)
                    switch form {
                    case .inline: stored = .inline
                    case .fork: stored = .resourceFork
                    default: stored = .plain
                    }
                }
                try core.finish(descriptor, metadata: metadata, mode: final, compressed: compressed, deferred: false)
                Sys.close(descriptor)
                return stored
            } catch {
                core.abandon(descriptor, directory: core.destination.root, leaf: 0)
                throw error
            }
        }
    }
}
