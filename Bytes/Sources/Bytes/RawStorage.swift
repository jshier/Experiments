#if canImport(Darwin)
internal import Darwin
#endif

/// Memory allocated once and freed on deinit: scratch for a worker, read buffers, a pool's storage. For buffers that
/// outlive a call and are shared by reference (what a span can't be), each used by one task at a time or in disjoint
/// ranges.
///
/// Large buffers used at varying sizes can keep only a floor resident between uses: ``giveBack(_:)`` after a use,
/// ``reuse(_:)`` before the next (32 read buffers of 16 MiB used mostly for small blocks: 170–230 MB less footprint,
/// no system time; NativeAEA/RESULTS.md, 2026-11-19).
///
/// ```swift
/// let scratch = RawStorage(byteCount: 16 << 20)
/// scratch.reuse(count)
/// // Unsafe: `count` bytes of the storage, which `scratch` keeps alive.
/// let read = unsafe pread(descriptor, scratch.base, count, offset)
/// scratch.giveBack(count)
/// ```
///
/// Unsafe to use, by design: ``base`` is a pointer, valid while the object lives, and nothing here synchronizes its
/// users (hence `@unchecked Sendable`: the object is immutable; who writes which bytes is its owner's rule).
@safe
public final class RawStorage: @unchecked Sendable {
    /// The start of the memory: valid while the object lives.
    public let base: UnsafeMutableRawPointer
    /// Its size in bytes (at least 1).
    public let byteCount: Int

    /// The page size large buffers are aligned to: Apple silicon's 16 KiB (a multiple of 4 KiB pages elsewhere).
    public static var pageSize: Int { 16_384 }

    /// The alignment for small buffers (paths, tables, headers): malloc's own 16 bytes, so they come from its small
    /// blocks with no padding and no page of their own.
    public static var small: Int { 16 }

    /// What ``giveBack(_:)`` leaves resident: pages past it are given back. Measured on Xcode's archives: 2 MiB took
    /// extraction's peak footprint from 1,398 to 1,228 MB (xip) and 1,597 to 1,363 MB (`.aea`) with system time
    /// unchanged; 0 and 1 MiB saved 15–35 MB more and cost 0.1 s of system time; 4 and 8 MiB saved less.
    public static var residentFloor: Int { 2 << 20 }

    /// Allocates `byteCount` bytes (at least 1), uninitialized.
    ///
    /// - Parameter alignment: Page-aligned by default, for large buffers (whose pages can be given back); ``small``
    ///   for small ones.
    @inlinable
    public init(byteCount: Int, alignment: Int = RawStorage.pageSize) {
        self.byteCount = max(byteCount, 1)
        // Unsafe: a raw allocation. Safe: this object owns it, and frees it once, in `deinit`.
        unsafe base = UnsafeMutableRawPointer.allocate(byteCount: self.byteCount, alignment: alignment)
    }

    @inlinable
    deinit {
        // Unsafe: frees the allocation `init` made. Safe: once, when the last reference goes.
        unsafe base.deallocate()
    }

    /// A pointer `offset` bytes in.
    ///
    /// - Precondition: `offset` is within the storage.
    @inlinable @inline(__always)
    public func pointer(_ offset: Int) -> UnsafeMutableRawPointer {
        // Unsafe: pointer arithmetic. Safe: within the allocation (the precondition); no access here.
        unsafe base + offset
    }

    /// Before writing `count` bytes from the start: takes back the pages past ``residentFloor`` that
    /// ``giveBack(_:)`` gave away (their contents are undefined: the kernel may have taken them). Nothing to do, and
    /// no call, for `count` up to the floor.
    ///
    /// - Precondition: The storage is page-aligned (the default).
    @inlinable @inline(__always)
    public func reuse(_ count: Int) {
        guard count > Self.residentFloor else { return }
        advise(count, reuse: true)
    }

    /// After using `count` bytes from the start: gives back the pages past ``residentFloor`` (the process's footprint
    /// drops at once; the kernel takes them only when it needs memory). Call ``reuse(_:)`` before writing them again.
    ///
    /// - Precondition: The storage is page-aligned (the default).
    @inlinable @inline(__always)
    public func giveBack(_ count: Int) {
        guard count > Self.residentFloor else { return }
        advise(count, reuse: false)
    }

    @usableFromInline
    func advise(_ count: Int, reuse: Bool) {
        #if canImport(Darwin)
        let page = Self.pageSize
        let end = min(byteCount, (count + page - 1) & ~(page - 1))
        guard end > Self.residentFloor else { return }
        // Unsafe: `madvise` on a raw range. Safe: within the allocation, from a page boundary (the base is
        // page-aligned and the floor a multiple of the page size); the advice changes no contents a user relies on
        // (pages past the floor are scratch between `giveBack` and `reuse`).
        _ = unsafe madvise(base + Self.residentFloor, end - Self.residentFloor, reuse ? MADV_FREE_REUSE : MADV_FREE_REUSABLE)
        #endif
    }
}
