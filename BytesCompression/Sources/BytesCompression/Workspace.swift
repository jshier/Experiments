// The codecs' raw memory: tables, models, scratch, and windows that a decoder or encoder allocates once and owns
// for its life. Raw memory, so the hot loops address it through pointers with no bounds checks or reference
// counting; each codec's layout (its regions' offsets and sizes) stays in its own type, which holds one of these.

/// A fixed allocation, made at creation and freed on `deinit`: a codec's tables, model, or scratch.
///
/// The codecs load ``base`` once per call and pass pointers into it to their loops.
// `@usableFromInline` exports the type's metadata: with cross-module optimization, clients destroying a decoder
// reference it for its `deinit` (a release build of the tests failed to link without it, for `ZstdWorkspace`).
@frozen @safe @usableFromInline
struct CodecWorkspace: ~Copyable {
    /// The start of the memory: valid while the workspace lives.
    @usableFromInline let base: UnsafeMutableRawPointer

    /// Allocates `byteCount` bytes (at least 1).
    ///
    /// - Parameters:
    ///   - byteCount: The size.
    ///   - alignment: The alignment: 64 (a cache line) unless a layout says otherwise.
    ///   - zeroed: Whether to fill it with zeros. Layouts whose loops read past what they write (wild copies'
    ///     slack, links kept in range) need it; tables the owner fills at once don't.
    init(byteCount: Int, alignment: Int = 64, zeroed: Bool = true) {
        let byteCount = max(byteCount, 1)
        // Unsafe: a raw allocation. Safe: this workspace owns it and frees it once, in `deinit`.
        unsafe base = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
        if zeroed {
            // Unsafe: initializing fresh memory. Safe: `byteCount` bytes were just allocated.
            unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
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
        unsafe base.deallocate()
    }
}

/// An allocation that grows: a streaming window, or a buffer sized by the input. Starts empty; grows by
/// replacement, keeping a prefix or nothing.
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
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        if let base = unsafe base {
            if preserving > 0 { unsafe memory.copyMemory(from: base, byteCount: preserving) }
            unsafe base.deallocate()
        }
        if zeroed {
            unsafe (memory + preserving).initializeMemory(as: UInt8.self, repeating: 0, count: byteCount &- preserving)
        }
        unsafe base = memory
        self.byteCount = byteCount
    }

    /// Frees the memory, leaving the workspace empty.
    mutating func free() {
        // Unsafe: freeing the allocation. Safe: it's forgotten at once, so it's freed once.
        unsafe base?.deallocate()
        unsafe base = nil
        byteCount = 0
    }

    deinit {
        // Unsafe: freeing the allocation. Safe: only `deinit`, `free`, and `replace` free it, each once.
        unsafe base?.deallocate()
    }
}
