import Bytes
import Darwin
public import System

/// A file opened for reading at a path of the caller's choosing: an archive's headers and blocks, read with positioned
/// reads, or mapped (``map(access:)``). Close it with ``close()`` when the last read is done (destroying it unclosed
/// still closes it, but Disk's descriptor audit counts that as a lifetime bug). Small files (keys, passwords) are read
/// whole with ``contents(of:maximumCount:)``.
///
/// ```swift
/// let archive = try InputFile(FilePath("/tmp/a.aar"))
/// let header = try archive.read(at: 0, count: 64)       // [UInt8]: no more than the file holds
/// var block = MutableRawSpan(mutating: &span)          // any span: a pool's buffer, an array's
/// try archive.read(at: offset, into: &block)            // fills it
/// ```
///
/// Reads keep no file position (`pread`), so several tasks can read one file at once. The path is the caller's own:
/// links in it are followed, as `open` follows them. (Entries of an archive go through a ``Destination``.)
public final class InputFile: Sendable {
    private let slot: DescriptorSlot
    /// The descriptor (-1 after ``close()``: reads then fail with `EBADF`).
    private var descriptor: Int32 { slot.descriptor }
    /// Where the file is.
    public let path: FilePath
    /// The file's size in bytes when it was opened (`fstat`): what reads are checked against.
    public let count: Int
    /// Whether the file was empty when it was opened.
    public var isEmpty: Bool {
        count == 0
    }

    /// Opens the file read-only.
    ///
    /// - Throws: ``DiskError/system(_:path:_:)`` with `open`'s or `fstat`'s error.
    public init(_ path: FilePath) throws(DiskError) {
        // Unsafe: `withPlatformString`'s C string passed to `open`. Safe: valid for the call.
        let descriptor = unsafe path.withPlatformString { unsafe Sys.openat(AT_FDCWD, $0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw .system("open", path: path.string, Errno(rawValue: errno)) }
        var info = stat()
        guard Sys.fstat(descriptor, &info) == 0 else {
            let code = errno
            Sys.close(descriptor)
            throw .system("fstat", path: path.string, Errno(rawValue: code))
        }
        slot = DescriptorSlot(OwnedDescriptor(adopting: descriptor, kind: .inputFile))
        self.path = path
        count = Int(info.st_size)
    }

    /// Closes the file: the end of its use (reads after it fail). Safe to call more than once, from any thread.
    public func close() {
        slot.close()
    }

    /// Fills `bytes` from `offset`, with as many positioned reads as it takes (one, unless the kernel returns less).
    ///
    /// - Throws: ``DiskError/endOfFile(_:)`` if the file ends first (the bytes before its end are read), or
    ///   ``DiskError/system(_:path:_:)`` with `read`'s error. Interrupted reads are retried.
    /// - Precondition: `offset` isn't negative.
    public func read(at offset: Int, into bytes: inout MutableRawSpan) throws(DiskError) {
        precondition(offset >= 0, "a negative file offset")
        try bytes.withUnsafeMutableBytes { buffer throws(DiskError) in
            // Unsafe: the span's memory, as a pointer, to `pread`. Safe: `buffer.count` writable bytes, valid inside
            // this closure, which the calls don't outlive.
            try unsafe readFully(buffer, at: offset)
        }
    }

    /// Appends `count` bytes from `offset` to `output`.
    ///
    /// - Throws: As the span form; nothing is appended if it throws.
    /// - Precondition: `count` fits `output`'s free capacity; `offset` and `count` aren't negative.
    public func read(at offset: Int, count: Int, into output: inout OutputRawSpan) throws(DiskError) {
        try output.withFreeCapacity(byteCount: count) { span, written throws(DiskError) in
            try read(at: offset, into: &span)
            written = count
        }
    }

    /// `count` bytes from `offset`, as an array: checked against the file's size first, so a size read from the file
    /// itself can't make it allocate past what the file holds.
    ///
    /// - Throws: ``DiskError/endOfFile(_:)`` if the range isn't within ``count`` (or the file has shrunk), or `read`'s
    ///   error.
    /// - Precondition: `offset` and `count` aren't negative.
    public func read(at offset: Int, count: Int) throws(DiskError) -> [UInt8] {
        precondition(offset >= 0 && count >= 0, "a negative file offset or count")
        guard offset <= self.count, count <= self.count - offset else { throw .endOfFile(path.string) }
        var bytes = [UInt8](repeating: 0, count: count)
        var span = bytes.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        try read(at: offset, into: &raw)
        return bytes
    }

    /// Maps the file's ``count`` bytes read-only. The mapping stays valid after this object closes the file.
    ///
    /// - Throws: ``DiskError/system(_:path:_:)`` with `mmap`'s error.
    public func map(access: MappedFile.Access = .random) throws(DiskError) -> MappedFile {
        try map(range: 0..<count, access: access)
    }

    /// Maps the bytes in `range` read-only (an archive's part that's read in place: a `.xip`'s content): the mapping's
    /// ``MappedFile/bytes`` start at `range.lowerBound`. It stays valid after this object closes the file.
    ///
    /// - Throws: ``DiskError/endOfFile(_:)`` if `range` isn't within ``count``, or ``DiskError/system(_:path:_:)`` with
    ///   `mmap`'s error.
    /// - Precondition: `range` doesn't start below 0.
    public func map(range: Range<Int>, access: MappedFile.Access = .random) throws(DiskError) -> MappedFile {
        precondition(range.lowerBound >= 0, "a negative file offset")
        // Pages past the file's end would fault (`SIGBUS`) when read: refuse them here.
        guard range.upperBound <= count else { throw .endOfFile(path.string) }
        do throws(Errno) {
            return try MappedFile(FileDescriptor(rawValue: descriptor), range: range, access: access)
        } catch {
            throw .system("mmap", path: path.string, error)
        }
    }

    /// The descriptor, for ``MappedFile/init(path:access:)``, which maps the file before this object closes it.
    var descriptorForMapping: Int32 { descriptor }

    /// Fills `buffer` from `offset`, with as many positioned reads as it takes: memory a caller manages itself (a pool's
    /// buffers), read into without making a span of it first.
    ///
    /// - Throws: As the span form.
    /// - Precondition: `offset` isn't negative; `buffer` is valid for writes for the call.
    @unsafe
    public func read(at offset: Int, into buffer: UnsafeMutableRawBufferPointer) throws(DiskError) {
        precondition(offset >= 0, "a negative file offset")
        // Unsafe: the caller's buffer to `pread`. Safe: valid for writes for this call (the precondition).
        try unsafe readFully(buffer, at: offset)
    }

    /// The whole file at `path`: a key, a password, a small configuration file. Read to its end whatever its size says,
    /// so pipes (`/dev/stdin`, a shell's `<(…)`) work too.
    ///
    /// - Parameters:
    ///   - path: The file (or pipe).
    ///   - maximumCount: The most bytes accepted.
    /// - Throws: ``DiskError/tooLarge(_:limit:)`` for a longer file (before reading it, when its size says so), or
    ///   ``DiskError/system(_:path:_:)`` with `open`'s or `read`'s error.
    public static func contents(of path: FilePath, maximumCount: Int) throws(DiskError) -> [UInt8] {
        precondition(maximumCount >= 0, "a negative maximum count")
        let file = try InputFile(path)
        defer { file.close() }
        guard file.count <= maximumCount else { throw .tooLarge(path.string, limit: maximumCount) }
        // Room for one byte past the limit, to see a file that grew (or a pipe) go over it.
        let cap = maximumCount < Int.max ? maximumCount + 1 : maximumCount
        var bytes = [UInt8](repeating: 0, count: min(cap, max(file.count + 1, 4_096)))
        var filled = 0
        while true {
            if filled == bytes.count {
                guard bytes.count < cap else { throw .tooLarge(path.string, limit: maximumCount) }
                bytes.append(contentsOf: repeatElement(0, count: min(cap, bytes.count * 2) - bytes.count))
            }
            let start = filled
            var span = bytes.mutableSpan
            let got = try span.withUnsafeMutableBytes { buffer throws(DiskError) -> Int in
                // Unsafe: the array's free bytes to `read`. Safe: `start < buffer.count` (grown above), so the
                // `buffer.count - start` bytes from there are within the array, valid inside this closure.
                try unsafe file.readSome(buffer.baseAddress! + start, count: buffer.count - start)
            }
            if got == 0 { break }
            filled += got
        }
        bytes.removeSubrange(filled...)
        return bytes
    }

    // MARK: The calls

    /// Fills `buffer` from `offset` with positioned reads.
    private func readFully(_ buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DiskError) {
        guard let base = buffer.baseAddress else { return }
        var done = 0
        while done < buffer.count {
            // Unsafe: `base + done` to `pread`. Safe: `done < buffer.count`, so the `buffer.count - done` bytes from
            // there are the rest of the caller's writable buffer.
            let got = unsafe Sys.pread(descriptor, base + done, buffer.count - done, offset + done)
            if got < 0 {
                if errno == EINTR { continue }
                throw .system("read", path: path.string, Errno(rawValue: errno))
            }
            if got == 0 { throw .endOfFile(path.string) }
            done += got
        }
    }

    /// One sequential read (from the file's position, for ``contents(of:maximumCount:)``), retried when interrupted.
    private func readSome(_ base: UnsafeMutableRawPointer, count: Int) throws(DiskError) -> Int {
        while true {
            // Unsafe: `base` to `read`. Safe: the caller's `count` writable bytes, written only during the call.
            let got = unsafe Sys.read(descriptor, base, count)
            if got >= 0 { return got }
            if errno != EINTR { throw .system("read", path: path.string, Errno(rawValue: errno)) }
        }
    }
}
