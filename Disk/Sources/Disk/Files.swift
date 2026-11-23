import Bytes
import Darwin
public import System

// Single files outside a destination: the archive an extractor reads (mapped), and one file written at a path of the
// caller's choosing (a decrypted stream). Their errors are `Errno` and `DiskError` as the kernel gave them: these are
// the caller's own paths, so no link or containment rule applies.

/// A read-only memory mapping of a file, unmapped on deinit: an archive, read in place.
///
/// The bytes have a stable address for the life of the object, so work on them can span `await`s and tasks without
/// copying (unlike `Data(contentsOf:options: .alwaysMapped)`, whose bytes are reachable only inside a closure).
/// `Sendable`: the mapping is read-only and never changes.
///
/// ```swift
/// let archive = try MappedFile(path: FilePath("/tmp/a.zip"))
/// let directory = try parse(archive.bytes)          // a RawSpan borrowing `archive`
/// ```
///
/// If another process truncates the file while it's mapped, reading past its new end faults (`SIGBUS`), as with any
/// mapping: map files that stay put.
@safe
public final class MappedFile: Sendable {
    // Unsafe (the attribute): a raw pointer in a `Sendable` class. Safe: immutable, read-only memory that lives
    // exactly as long as `self`.
    @usableFromInline nonisolated(unsafe) let base: UnsafeRawPointer?
    /// The mapping's size in bytes.
    public let count: Int
    /// Bytes mapped before `base`: a range's start rounded down to a page (`mmap` maps from page boundaries).
    private let lead: Int

    /// How the mapping will be read: advice for the kernel's read-ahead.
    public enum Access: Sendable {
        /// Here and there (an index, then entries in any order): the kernel's default.
        case random
        /// Front to back, once (`MADV_SEQUENTIAL`): pages behind the reader can go.
        case sequential
    }

    /// What's mapped: the file itself, or a private copy of it that no one else can truncate.
    ///
    /// A mapped file truncated by someone else while it's read faults on some volumes: on FAT and exFAT (USB sticks, SD
    /// cards) a read past the new end raises `SIGBUS` and ends the process; on APFS and HFS+ the mapping keeps its
    /// bytes (measured on macOS 27, cold pages and cached alike: Disk/RESULTS.md, 2026-11-23).
    public enum Source: Sendable {
        /// The file itself on APFS and HFS+, a private copy elsewhere (FAT, exFAT, network volumes, anything else).
        case automatic
        /// The file itself, wherever it is: a truncation by someone else can end the process on some volumes.
        case file
        /// Always a private copy.
        case copy
    }

    /// Whether this maps a private copy of the file (an unlinked temporary file on the internal volume) rather than
    /// the file itself.
    public let isCopy: Bool

    /// Maps the whole file at `path` (Disk's ``InputFile``, then ``InputFile/map(access:)``), or a private copy of it
    /// where a truncated mapping would fault (`source`).
    ///
    /// The copy is the whole file read once, before the mapping returns: on a USB stick, the time it takes to read the
    /// archive, which a mapping would have spent in page faults later. It's made in the user's temporary directory and
    /// unlinked at once (its blocks go when the mapping does). If it can't be made (no room), the file itself is mapped.
    ///
    /// - Throws: ``DiskError/system(_:path:_:)`` with `open`'s, `fstat`'s, or `mmap`'s error.
    public convenience init(path: FilePath, access: Access = .random, source: Source = .automatic) throws(DiskError) {
        let file = try InputFile(path)
        // The mapping outlives the descriptor: closed as soon as the file is mapped.
        defer { file.close() }
        var descriptor = file.descriptorForMapping
        let copy = switch source {
        case .file: Int32(-1)
        case .copy: Self.privateCopy(of: descriptor)
        case .automatic: Self.truncationFaults(descriptor) ? Self.privateCopy(of: descriptor) : -1
        }
        if copy >= 0 { descriptor = copy }
        defer { if copy >= 0 { Sys.close(copy) } }
        let (base, lead): (UnsafeRawPointer?, Int)
        do throws(Errno) {
            // Unsafe: the mapping's address. Safe: handed straight to `self.init`, which owns it.
            unsafe (base, lead) = try Self.map(descriptor, range: 0..<file.count, access: access)
        } catch {
            throw .system("mmap", path: path.string, error)
        }
        // Unsafe: the mapping just made, `file.count` bytes after `lead`. Safe: owned from here by `self`.
        unsafe self.init(base: base, count: file.count, lead: lead, isCopy: copy >= 0)
    }

    /// Whether a mapping of `descriptor`'s file can fault when someone else truncates it: true except on APFS and HFS+
    /// (and when the volume can't be asked).
    static func truncationFaults(_ descriptor: Int32) -> Bool {
        var volume = statfs()
        Sys.countOther()
        // Unsafe: a pointer to `volume` to `fstatfs`. Safe: it writes one `statfs` into the local, during the call.
        guard unsafe fstatfs(descriptor, &volume) == 0 else { return true }
        // Unsafe: the type's name, a NUL-terminated C string in the fixed-size field. Safe: `fstatfs` filled it,
        // terminated within `MFSTYPENAMELEN` bytes; read only inside the closure.
        let name = withUnsafeBytes(of: volume.f_fstypename) { unsafe String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        return name != "apfs" && name != "hfs"
    }

    /// A private copy of `descriptor`'s file: an open descriptor on an unlinked temporary file holding its bytes, or -1
    /// if one can't be made.
    static func privateCopy(of descriptor: Int32) -> Int32 {
        var directory = [CChar](repeating: 0, count: Int(PATH_MAX))
        // Unsafe: the array's buffer to `confstr`. Safe: `PATH_MAX` bytes, the most it writes with that size.
        let length = directory.withUnsafeMutableBufferPointer { unsafe confstr(_CS_DARWIN_USER_TEMP_DIR, $0.baseAddress, $0.count) }
        guard length > 0 else { return -1 }
        var template = Array(directory.prefix { $0 != 0 }) + Array("Disk-mapped-XXXXXX".utf8CString)
        // Unsafe: the template to `mkstemp`, which replaces its X's in place. Safe: NUL-terminated, the array's own.
        let copy = template.withUnsafeMutableBufferPointer { unsafe mkstemp($0.baseAddress!) }
        guard copy >= 0 else { return -1 }
        #if DEBUG
        SyscallFaults.recordOpen(copy)
        #endif
        // Unlinked at once: no one else can open (or truncate) it, and its blocks go with the last reference.
        // Unsafe: the name `mkstemp` wrote, to `unlink`. Safe: NUL-terminated, the array's own.
        _ = template.withUnsafeBufferPointer { unsafe unlink($0.baseAddress!) }
        Sys.countOther()
        // Two open descriptors; no state (`nil`, which `fcopyfile` allows).
        guard fcopyfile(descriptor, copy, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            Sys.close(copy)
            return -1
        }
        return copy
    }

    /// Maps the first `count` bytes of an open file. The descriptor isn't kept: the caller may close it.
    ///
    /// - Throws: `mmap`'s `Errno`.
    public convenience init(_ descriptor: FileDescriptor, count: Int, access: Access = .random) throws(Errno) {
        try self.init(descriptor, range: 0..<count, access: access)
    }

    /// Maps the bytes in `range` of an open file: ``bytes`` and ``buffer(_:)`` count from `range.lowerBound`. The
    /// descriptor isn't kept.
    ///
    /// - Throws: `mmap`'s `Errno`.
    /// - Precondition: `range` doesn't start below 0.
    public convenience init(_ descriptor: FileDescriptor, range: Range<Int>, access: Access = .random) throws(Errno) {
        // Unsafe: the mapping's address. Safe: handed straight to `self.init`, which owns it.
        let (base, lead) = try unsafe Self.map(descriptor.rawValue, range: range, access: access)
        // Unsafe: the mapping just made, `range.count` bytes after `lead`. Safe: owned from here by `self`.
        unsafe self.init(base: base, count: range.count, lead: lead)
    }

    /// Takes ownership of a mapping: `count` bytes at `base`, mapped from `lead` bytes before it.
    @unsafe
    private init(base: UnsafeRawPointer?, count: Int, lead: Int, isCopy: Bool = false) {
        // Unsafe: stores the pointer. Safe: the caller's mapping, valid until `deinit` unmaps it.
        unsafe self.base = base
        self.count = unsafe base == nil ? 0 : count
        self.lead = lead
        self.isCopy = isCopy
    }

    /// Maps `range` of `descriptor` read-only, from the page that holds its start: the address of its first byte and
    /// how far past the mapping's start that is. `nil` for an empty range (nothing to map).
    @unsafe
    private static func map(_ descriptor: Int32, range: Range<Int>, access: Access) throws(Errno) -> (UnsafeRawPointer?, lead: Int) {
        precondition(range.lowerBound >= 0, "a negative file offset")
        guard !range.isEmpty else { return (nil, 0) }
        let page = Int(getpagesize())
        let start = range.lowerBound & ~(page - 1)
        let lead = range.lowerBound - start
        Sys.countOther()
        // Unsafe: `mmap` returns a raw pointer. Safe: a private read-only mapping of `lead + range.count` bytes from a
        // page boundary, which the caller's `MappedFile` owns and unmaps in `deinit`.
        let mapping = unsafe mmap(nil, lead + range.count, PROT_READ, MAP_PRIVATE, descriptor, off_t(start))
        guard unsafe mapping != MAP_FAILED, let mapping = unsafe mapping else { throw Errno(rawValue: errno) }
        // Unsafe: advice on the mapping. Safe: exactly the range just mapped; advice changes no contents.
        if access == .sequential { _ = unsafe madvise(mapping, lead + range.count, MADV_SEQUENTIAL) }
        // Unsafe: an address in the mapping. Safe: `lead` is less than a page, within the mapping.
        return unsafe (UnsafeRawPointer(mapping + lead), lead)
    }

    deinit {
        // Unsafe: unmaps. Safe: the range `init` mapped (from `lead` bytes before `base`), once; spans and buffers of
        // it don't outlive `self` (theirs borrow it, and `buffer(_:)`'s callers promise).
        if let base = unsafe base { _ = unsafe munmap(UnsafeMutableRawPointer(mutating: base - lead), count + lead) }
    }

    /// The whole file. The span borrows `self`, which keeps the mapping alive.
    @inlinable
    public var bytes: RawSpan {
        @_lifetime(borrow self)
        get {
            // Unsafe: reads the stored pointer. Safe: only compared with `nil` here.
            guard let base = unsafe base else { return RawSpan() }
            // Unsafe: a span over raw memory, its lifetime set by hand. Safe: the mapping's `count` bytes, which live
            // as long as `self`, which the span borrows.
            let span = unsafe RawSpan(_unsafeStart: base, byteCount: count)
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    /// The bytes in `range`, at an address that stays valid as long as `self` is alive: for work that outlives a
    /// borrow of ``bytes`` (a decode loop across suspension points, another task). The caller keeps `self` alive
    /// while it uses the buffer.
    ///
    /// - Returns: A buffer over `range`; empty (with a `nil` base) for an empty file.
    /// - Precondition: `range` lies within `0...count`.
    @inlinable
    public func buffer(_ range: Range<Int>) -> UnsafeRawBufferPointer {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "a range outside the mapping")
        // Unsafe: an empty buffer. Safe: no memory.
        guard let base = unsafe base else { return unsafe UnsafeRawBufferPointer(start: nil, count: 0) }
        // Unsafe: a buffer into the mapping. Safe: within it (checked above); valid while `self` lives (the caller's
        // promise).
        return unsafe UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
    }
}

/// One file written at a path of the caller's choosing, outside any ``Destination``: a decrypted or converted stream.
/// Closed on deinit.
///
/// ```swift
/// let output = try OutputFile(FilePath("/tmp/payload.aar"), replacing: false)
/// try output.write(segment, at: offset)     // any order, from one task at a time per range
/// try output.close()                         // the end of its use, and close's error if any
/// ```
///
/// The path is the caller's own: links in it are followed, as `open` follows them. (Entries of an archive go through
/// a ``Destination``, which follows none.) Destroying it unclosed still closes it, but Disk's descriptor audit counts
/// that as a lifetime bug.
public final class OutputFile: Sendable {
    private let slot: DescriptorSlot
    /// The descriptor (-1 after ``close()``: writes then fail with `EBADF`).
    private var descriptor: Int32 { slot.descriptor }
    /// Where the file is.
    public let path: FilePath

    /// Creates the file.
    ///
    /// - Parameters:
    ///   - path: Where (the caller's path: links in it are followed, as `open` follows them).
    ///   - replacing: Whether an existing file is truncated and written over (otherwise it's an error:
    ///     ``DiskError/exists(_:)``).
    ///   - mode: Its permissions, before the umask.
    public init(_ path: FilePath, replacing: Bool, mode: FilePermissions = [.ownerReadWrite, .groupRead, .otherRead]) throws(DiskError) {
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (replacing ? O_TRUNC : O_EXCL)
        // Unsafe: `withPlatformString`'s C string passed to `open`. Safe: valid for the call.
        let descriptor = unsafe path.withPlatformString { unsafe Sys.openat(AT_FDCWD, $0, flags, mode.rawValue) }
        guard descriptor >= 0 else { throw .system("open", path: path.string, code: errno) }
        slot = DescriptorSlot(OwnedDescriptor(adopting: descriptor, kind: .outputFile))
        self.path = path
    }

    /// Closes the file: the end of its use. Safe to call more than once (later calls do nothing).
    ///
    /// - Throws: ``DiskError/system(_:path:_:)`` with `close`'s error (on some file systems the first report of a
    ///   failed write). The descriptor is released either way.
    public func close() throws(DiskError) {
        let code = slot.closeChecked()
        guard code == 0 else { throw .system("close", path: path.string, code: code) }
    }

    /// Writes all of `bytes` at `offset`, with as many positioned writes as it takes. Ranges that don't overlap can be
    /// written from several tasks at once (the kernel serializes writes to one file, so that gains nothing).
    public func write(_ bytes: RawSpan, at offset: Int) throws(DiskError) {
        try bytes.withUnsafeBytes { (buffer) throws(DiskError) in
            guard let base = buffer.baseAddress else { return }
            do throws(DiskError) {
                // Unsafe: the span's bytes, as a pointer, to `pwrite`. Safe: `buffer.count` bytes, valid inside this
                // closure, which the calls don't outlive.
                try unsafe FileIO.writeFully(descriptor, base, count: buffer.count, at: offset, path: .none)
            } catch {
                // The path, made only now that something failed.
                if case .system(let operation, _, let code) = error { throw .system(operation, path: path.string, code) }
                throw error
            }
        }
    }
}

extension Destination {
    /// Whether the destination's volume tells names apart by case (APFS volumes usually don't): a client that plans
    /// two entries whose names differ only in case needs to know they're one item.
    public var isCaseSensitive: Bool {
        fpathconf(root, _PC_CASE_SENSITIVE) == 1
    }
}
