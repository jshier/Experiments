// The codecs' raw memory: tables, models, scratch, and windows that a decoder or encoder allocates once and owns
// for its life. Raw memory, so the hot loops address it through pointers with no bounds checks or reference
// counting; each codec's layout (its regions' offsets and sizes) stays in its own type, which holds one of these.

#if canImport(Darwin)
internal import Darwin
#endif

/// Where the workspaces' memory comes from: malloc for most, the system's own pages for large ones.
///
/// malloc keeps a freed large block for its next allocation of that size, still counted in the process's footprint: a
/// touched 96 MiB window, freed, stayed in it (as did four of them, 385 MB), and neither time nor
/// `malloc_zone_pressure_relief` gave it back (2026-11-25, RESULTS.md). Pages mapped here go back to the system when
/// they're unmapped, so a decoder freeing a large window gives its memory back at once. They also start zeroed.
enum CodecMemory {
    /// Allocations at least this large are mapped: streaming windows for large dictionaries (Zstandard's past 8 MiB, raw
    /// LZMA's and xz's from `xz -5`'s 12 MiB window), not the codecs' tables (bzip2's 7.8 MB is the largest) or HTTP's
    /// windows (8 MiB at most, RFC 9659, plus a 128 KiB block), whose owners make one per message and reuse what malloc
    /// kept. Mapped memory isn't seen by malloc's counters or `MallocScribble` (it reads as zeros, not 0xAA).
    static var mappedThreshold: Int { 9 << 20 }

    /// Allocates `byteCount` bytes (at least 1) aligned to `alignment` (at most a page).
    ///
    /// - Returns: The memory, and whether it's already zeroed (mapped pages are).
    static func allocate(byteCount: Int, alignment: Int) -> (base: UnsafeMutableRawPointer, isZeroed: Bool) {
        let byteCount = max(byteCount, 1)
        #if canImport(Darwin)
        if byteCount >= mappedThreshold {
            // Unsafe: an anonymous private mapping. Safe: `byteCount` bytes, page-aligned (more than any alignment
            // asked here), zero-filled, owned by the caller until `deallocate` unmaps it.
            let mapped: UnsafeMutableRawPointer? = unsafe mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            // As malloc does, a failure to allocate traps.
            guard let mapped = unsafe mapped, unsafe mapped != MAP_FAILED else { fatalError("mmap of \(byteCount) bytes failed: \(errno)") }
            precondition(alignment <= Int(getpagesize()), "an alignment beyond a page")
            return unsafe (mapped, true)
        }
        #endif
        // The caller owns the allocation and frees it once, with `deallocate`.
        return (UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment), false)
    }

    /// Frees what ``allocate(byteCount:alignment:)`` returned for the same `byteCount`.
    static func deallocate(_ base: UnsafeMutableRawPointer, byteCount: Int) {
        #if canImport(Darwin)
        if max(byteCount, 1) >= mappedThreshold {
            // Unsafe: unmapping. Safe: exactly the mapping `allocate` made for this size, unmapped once.
            _ = unsafe munmap(base, byteCount)
            return
        }
        #endif
        // Unsafe: freeing. Safe: the allocation `allocate` made for this size, freed once.
        unsafe base.deallocate()
    }
}

/// A fixed allocation, made at creation and freed on `deinit`: a codec's tables, model, or scratch.
///
/// The codecs load ``base`` once per call and pass pointers into it to their loops.
// `@usableFromInline` exports the type's metadata: with cross-module optimization, clients destroying a decoder
// reference it for its `deinit` (a release build of the tests failed to link without it, for `ZstdWorkspace`).
@frozen @safe @usableFromInline
struct CodecWorkspace: ~Copyable {
    /// The start of the memory: valid while the workspace lives.
    @usableFromInline let base: UnsafeMutableRawPointer
    /// Its size in bytes (at least 1).
    @usableFromInline let byteCount: Int

    /// Allocates `byteCount` bytes (at least 1).
    ///
    /// - Parameters:
    ///   - byteCount: The size.
    ///   - alignment: The alignment: 64 (a cache line) unless a layout says otherwise.
    ///   - zeroed: Whether to fill it with zeros. Layouts whose loops read past what they write (wild copies'
    ///     slack, links kept in range) need it; tables the owner fills at once don't.
    init(byteCount: Int, alignment: Int = 64, zeroed: Bool = true) {
        self.byteCount = max(byteCount, 1)
        // Unsafe: a raw allocation. Safe: this workspace owns it and frees it once, in `deinit`.
        let (base, isZeroed) = unsafe CodecMemory.allocate(byteCount: self.byteCount, alignment: alignment)
        unsafe self.base = base
        if zeroed && !isZeroed {
            // Unsafe: initializing fresh memory. Safe: `byteCount` bytes were just allocated.
            unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: self.byteCount)
        }
    }

    /// A pointer `offset` bytes in.
    @inline(__always)
    func pointer(_ offset: Int) -> UnsafeMutableRawPointer {
        // Unsafe: pointer arithmetic. Safe: callers pass offsets within their layout, which the allocation holds;
        // no access here.
        unsafe base + offset
    }

    /// A typed pointer `offset` bytes in, for a span over a region of the layout
    /// (`MutableSpan(_unsafeStart: workspace.pointer(offset, as: T.self), count: n)`): code that works on the region
    /// then has checked accesses.
    @unsafe @inline(__always)
    func pointer<T>(_ offset: Int, as type: T.Type) -> UnsafeMutablePointer<T> {
        // Unsafe: pointer arithmetic, as `pointer(_:)`; the callers' layouts align each region for its type.
        unsafe (base + offset).assumingMemoryBound(to: T.self)
    }

    deinit {
        // Unsafe: freeing the allocation. Safe: only `deinit` frees it, once.
        unsafe CodecMemory.deallocate(base, byteCount: byteCount)
    }
}

/// An allocation that grows: a streaming window, or a buffer sized by the input. Starts empty; grows by
/// replacement, keeping a prefix or nothing. One of ``CodecMemory/mappedThreshold`` or more is mapped, so freeing it
/// (``free()``, or dropping its owner) gives the memory back to the system at once.
@frozen @safe @usableFromInline // Exported for clients' destroys, as `CodecWorkspace`.
struct GrowableWorkspace: ~Copyable {
    /// The start of the memory, `nil` until the first allocation.
    @usableFromInline private(set) var base: UnsafeMutableRawPointer?
    /// Its size in bytes.
    @usableFromInline private(set) var byteCount = 0

    init() {}

    /// Makes room for at least `byteCount` bytes, discarding the contents if it reallocates.
    ///
    /// - Parameters:
    ///   - byteCount: The size needed.
    ///   - zeroed: Whether new memory is filled with zeros.
    mutating func reserve(_ byteCount: Int, zeroed: Bool = true) {
        guard byteCount > self.byteCount else { return }
        replace(byteCount: byteCount, preserving: 0, zeroed: zeroed)
    }

    /// Grows to `byteCount` bytes, keeping the first `preserving`.
    ///
    /// - Parameters:
    ///   - byteCount: The new size; nothing happens unless it's larger.
    ///   - preserving: How many bytes at the start to keep (at most the current size).
    ///   - zeroed: Whether the rest is filled with zeros.
    mutating func grow(to byteCount: Int, preserving: Int, zeroed: Bool = true) {
        guard byteCount > self.byteCount else { return }
        replace(byteCount: byteCount, preserving: min(preserving, self.byteCount), zeroed: zeroed)
    }

    private mutating func replace(byteCount: Int, preserving: Int, zeroed: Bool) {
        // Unsafe: replacing the allocation. Safe: the new one holds `byteCount` bytes, the first `preserving`
        // copied from the old (which holds them), the rest zeroed if asked; the old one is freed exactly once.
        let (memory, isZeroed) = unsafe CodecMemory.allocate(byteCount: byteCount, alignment: 64)
        if let base = unsafe base {
            if preserving > 0 { unsafe memory.copyMemory(from: base, byteCount: preserving) }
            unsafe CodecMemory.deallocate(base, byteCount: self.byteCount)
        }
        if zeroed && !isZeroed {
            unsafe (memory + preserving).initializeMemory(as: UInt8.self, repeating: 0, count: byteCount &- preserving)
        }
        unsafe base = memory
        self.byteCount = byteCount
    }

    /// Frees the memory, leaving the workspace empty.
    mutating func free() {
        // Unsafe: freeing the allocation. Safe: it's forgotten at once, so it's freed once.
        if let base = unsafe base { unsafe CodecMemory.deallocate(base, byteCount: byteCount) }
        unsafe base = nil
        byteCount = 0
    }

    deinit {
        // Unsafe: freeing the allocation. Safe: only `deinit`, `free`, and `replace` free it, each once.
        if let base = unsafe base { unsafe CodecMemory.deallocate(base, byteCount: byteCount) }
    }
}
