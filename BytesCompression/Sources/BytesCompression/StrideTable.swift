// Tables typed by their store stride: a codec's hash table or probability model, filled and cleared a SIMD group at a
// time. The group is the table's unit of size, alignment, and fills, so a fill can't start misaligned or end in the
// middle of a group: the type allocates whole groups at a 64-byte boundary (a cache line), and every group's address
// is a multiple of its stride from there.
//
// Why a type: `storeBytes(repeating:count:as:)` on a `UniqueArray<Int16>`'s span requires the start aligned for the
// stored type, and the array promises only its element's alignment (2 bytes); DEFLATE's encoder checked the address
// at run time before every clear, and LZMA's workspace kept its own copy of this pattern (RESULTS.md, 2026-11-24).

/// An encoder's staged output or input window: bytes written before they're read. The parallel encoders swap these
/// with their lanes' (`ChunkSlot`).
typealias StagingBuffer = UninitializedBuffer<UInt8>

/// Storage for `count` trivial values that are written before they're read (an encoder's window, staged output,
/// sequence or command list), allocated uninitialized at a 64-byte boundary: making a coder doesn't zero it, and pages
/// a small stream never reaches are never touched. (Zeroing them was most of making a coder: RESULTS.md, 2026-11-24.)
///
/// Every read must be of a value written since the allocation: the owners' layouts say why each is.
@safe @usableFromInline // Exported for clients' destroys, as `CodecWorkspace`.
package struct UninitializedBuffer<Element: BitwiseCopyable>: ~Copyable {
    private let memory: CodecWorkspace
    /// The number of values it holds.
    package let count: Int

    /// Whether it holds no values (a placeholder, before first use).
    package var isEmpty: Bool {
        count == 0
    }

    /// Room for `count` values, uninitialized.
    package init(count: Int) {
        self.count = count
        memory = CodecWorkspace(
            byteCount: count &* MemoryLayout<Element>.stride, alignment: max(64, MemoryLayout<Element>.alignment), zeroed: false
        )
        // Unsafe: binding the fresh allocation. Safe: it holds `count` values.
        _ = unsafe memory.base.bindMemory(to: Element.self, capacity: count)
    }

    /// The values, for loops that address them through a pointer. Valid while the buffer lives.
    package var base: UnsafeMutablePointer<Element> {
        // Unsafe: the allocation as values. Safe: `init` bound it to `Element`, `count` of them.
        @inline(__always) get { unsafe memory.base.assumingMemoryBound(to: Element.self) }
    }

    /// The values (read only the written ones).
    package var span: Span<Element> {
        @_lifetime(borrow self)
        @inline(__always) get {
            // Unsafe: a span over the allocation. Safe: it holds `count` values, and the span borrows the buffer, which
            // owns the memory.
            let span = unsafe Span(_unsafeStart: base, count: count)
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    /// The values, to write.
    package var mutableSpan: MutableSpan<Element> {
        @_lifetime(&self)
        @inline(__always) mutating get {
            // Unsafe and safe as `span`; the span holds the buffer's exclusive access.
            let span = unsafe MutableSpan(_unsafeStart: base, count: count)
            return unsafe _overrideLifetime(span, mutating: &self)
        }
    }
}

/// A table of `Group.Scalar` entries stored in whole `Group`s (`SIMD8<UInt16>`: 8 entries, 16 bytes;
/// `SIMD32<Int16>`: 32 entries, 64 bytes), allocated by the table at a 64-byte boundary so every group starts aligned
/// by construction, not by a check.
///
/// The memory is bound to the entries' type: loops read and write entries through ``span``, ``mutableSpan``, or
/// ``base``. ``fill(_:)`` stores whole groups (raw stores, which memory of any trivial type takes): `str q` per
/// 16-byte group, `stp q, q` pairs for wider ones. ``clear()`` zeroes the table with `memset`, which is faster than
/// any store loop for large tables (it zeroes whole cache lines).
@safe @usableFromInline // Exported for clients' destroys, as `CodecWorkspace`.
package struct StrideTable<Group: SIMD & BitwiseCopyable>: ~Copyable {
    package typealias Element = Group.Scalar

    private var memory: CodecWorkspace
    /// The groups it holds.
    package private(set) var groupCount: Int

    /// A table of `groups` groups whose entries are uninitialized: for tables their owner fills (``fill(_:)``,
    /// ``clear()``) before reading any entry, or whose every entry is written before it's read.
    package init(uninitializedGroups groups: Int) {
        groupCount = groups
        memory = Self.allocate(groups)
    }

    /// A table of at least `count` entries (whole groups), each `value`.
    package init(minimumCount count: Int, repeating value: Element) {
        self.init(uninitializedGroups: Self.groups(count))
        fill(value)
    }

    /// The groups that hold `count` (at least 0) entries.
    @inline(__always)
    package static func groups(_ count: Int) -> Int {
        // Unsigned: a shift (`scalarCount` is a power of two), where a signed division rounds negative numbers too.
        Int(bitPattern: UInt(bitPattern: count &+ Group.scalarCount &- 1) / UInt(bitPattern: Group.scalarCount))
    }

    /// The number of entries: whole groups.
    package var count: Int {
        @inline(__always) get { groupCount &* Group.scalarCount }
    }

    /// Whether it holds no entries.
    package var isEmpty: Bool {
        @inline(__always) get { groupCount == 0 }
    }

    /// The entries, for loops that address the table through a pointer (a hot loop's tables, checked by its own
    /// invariants). Valid while the table lives and isn't replaced (``reserve(groups:)``).
    package var base: UnsafeMutablePointer<Element> {
        // Unsafe: the allocation as entries. Safe: `allocate` bound it to `Element`, `count` of them.
        @inline(__always) get { unsafe memory.base.assumingMemoryBound(to: Element.self) }
    }

    /// The entries.
    package var span: Span<Element> {
        @_lifetime(borrow self)
        @inline(__always) get {
            // Unsafe: a span over the allocation. Safe: it holds `count` entries, and the span borrows the table,
            // which owns the memory.
            let span = unsafe Span(_unsafeStart: base, count: count)
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    /// The entries, to change.
    package var mutableSpan: MutableSpan<Element> {
        @_lifetime(&self)
        @inline(__always) mutating get {
            // Unsafe and safe as `span`; the span holds the table's exclusive access.
            let span = unsafe MutableSpan(_unsafeStart: base, count: count)
            return unsafe _overrideLifetime(span, mutating: &self)
        }
    }

    /// Makes room for at least `groups` groups, discarding the entries if it reallocates (the new ones are
    /// uninitialized: fill them before reading).
    package mutating func reserve(groups: Int) {
        guard groups > groupCount else { return }
        memory = Self.allocate(groups)
        groupCount = groups
    }

    /// Sets every entry to `value`, a group per store.
    @inline(__always)
    package func fill(_ value: Element) {
        fill(value, groups: groupCount)
    }

    /// Sets the entries of the first `groups` groups to `value`, a group per store.
    ///
    /// - Precondition: `groups` is at most ``groupCount``.
    @inline(__always)
    package func fill(_ value: Element, groups: Int) {
        let stride = MemoryLayout<Group>.stride
        let end = groups &* stride
        precondition(UInt(bitPattern: groups) <= UInt(bitPattern: groupCount), "A fill past a table's end")
        let group = Group(repeating: value)
        // A pointer that steps (a post-indexed store, `str q0, [x9], #16`): with an offset, a 64-byte group's `stp`
        // pair, which has no register-offset form, cost an address `add` per group.
        // Unsafe: pointer arithmetic and a group's store per step. Safe: `address + stride <= last`, which is within the
        // allocation (checked above), and steps of the stride from the allocation's 64-byte-aligned start keep every
        // group aligned.
        var address = unsafe memory.base
        let last = unsafe address + end
        while unsafe address < last {
            unsafe address.storeBytes(of: group, as: Group.self)
            unsafe address += stride
        }
    }

    /// Sets every entry to zero: one `memset` (LLVM turns a zero fill into one; typed, the memory stays bound to the
    /// entries).
    @inline(__always)
    package func clear() {
        clear(groups: groupCount)
    }

    /// Sets the entries of the first `groups` groups to zero (`memset`).
    ///
    /// - Precondition: `groups` is at most ``groupCount``.
    @inline(__always)
    package func clear(groups: Int) {
        precondition(UInt(bitPattern: groups) <= UInt(bitPattern: groupCount), "A clear past a table's end")
        // Unsafe: initializing entries. Safe: the allocation holds `groupCount` groups (checked above), bound to
        // `Element`.
        unsafe base.initialize(repeating: Group()[0], count: groups &* Group.scalarCount)
    }

    /// `groups` groups of memory, bound to entries but uninitialized.
    private static func allocate(_ groups: Int) -> CodecWorkspace {
        let memory = CodecWorkspace(byteCount: groups &* MemoryLayout<Group>.stride, alignment: 64, zeroed: false)
        // Unsafe: binding the fresh allocation. Safe: it holds `groups` groups of `Group.scalarCount` entries each.
        _ = unsafe memory.base.bindMemory(to: Element.self, capacity: groups &* Group.scalarCount)
        return memory
    }
}
