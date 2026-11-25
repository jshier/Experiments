/// A table of a power-of-two count of entries indexed by any integer: `table[index]` is entry `index & (count − 1)`.
/// For hash tables, rings, and bucket arrays, whose indices are hashes or counters: the mask is the bounds check, so
/// an access is an `and` and the load or store, with nothing to trap, and no `and` at all where the optimizer can see
/// the index is already in range (a hash's top bits, a value masked by hand).
///
/// ```swift
/// var heads = MaskedTable<Int16>(count: 1 << 15, repeating: .min)
/// let bucket = Int(truncatingIfNeeded: (word &* 0x1E35_A7BD) &>> 17)   // 15 bits
/// let previous = heads[bucket]
/// heads[bucket] = Int16(truncatingIfNeeded: position)
/// ```
///
/// The memory is whole 64-byte lines at a 64-byte boundary (a cache line), so a fill a SIMD group at a time
/// (``fill(_:groupedAs:)``) can't start misaligned or end inside a group: the alignment is the table's own, not
/// `malloc`'s, whatever the entries' type promises.
///
/// Loops that a table's count would otherwise leave guessing can state it once (`precondition(table.count == 1 << 16)`):
/// the optimizer then knows the mask, and drops it from indices it can see are in range.
///
/// Noncopyable: it owns its memory and frees it on `deinit`. `Sendable` when its entries are: only its owner writes
/// (every write is `mutating`).
@frozen @safe
public struct MaskedTable<Element: BitwiseCopyable>: ~Copyable {
    @usableFromInline let base: UnsafeMutablePointer<Element>
    /// The number of entries less 1: the bits an index keeps.
    public let mask: Int

    /// A table of `count` entries, uninitialized: write each entry before reading it, or fill the table first.
    ///
    /// - Precondition: `count` is a power of two.
    @inlinable
    public init(uninitializedCount count: Int) {
        precondition(count > 0 && count & (count &- 1) == 0, "A masked table's count is a power of two")
        mask = count &- 1
        // Whole 64-byte lines (checked arithmetic: a count too large to allocate traps here, not in a fill).
        let byteCount = (count * MemoryLayout<Element>.stride + 63) & ~63
        // Unsafe: a raw allocation, bound to `count` entries. Safe: this table owns it and frees it once, in `deinit`.
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: Swift.max(64, MemoryLayout<Element>.alignment)
        )
        unsafe base = memory.bindMemory(to: Element.self, capacity: count)
    }

    /// A table of `count` entries, each `value`.
    ///
    /// - Precondition: `count` is a power of two.
    @inlinable
    public init(count: Int, repeating value: Element) {
        self.init(uninitializedCount: count)
        // Unsafe: initializing the fresh allocation. Safe: it holds `count` entries.
        unsafe base.initialize(repeating: value, count: count)
    }

    @inlinable
    deinit {
        // Unsafe: frees the allocation `init` made. Safe: once, here; the table is noncopyable, so nothing else owns it.
        unsafe base.deallocate()
    }

    /// The number of entries: a power of two.
    @inlinable
    public var count: Int {
        @inline(__always) get { mask &+ 1 }
    }

    /// Entry `index & (count − 1)`.
    @inlinable
    public subscript(index: Int) -> Element {
        @inline(__always) get {
            // Unsafe: an unchecked read. Safe: `index & mask` is below `count`, which the allocation holds.
            unsafe base[index & mask]
        }
        @inline(__always) set {
            // Unsafe and safe as the getter's read.
            unsafe base[index & mask] = newValue
        }
    }

    /// The entries, for work on the whole table (a rebase, a scan).
    @inlinable
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
    @inlinable
    public var mutableSpan: MutableSpan<Element> {
        @_lifetime(&self)
        @inline(__always) mutating get {
            // Unsafe and safe as `span`'s; the span holds the table's exclusive access.
            let span = unsafe MutableSpan(_unsafeStart: base, count: count)
            return unsafe _overrideLifetime(span, mutating: &self)
        }
    }

    /// Sets every entry to `value`. (A value whose bytes are all the same, as 0 or -1, becomes one `memset`.)
    @inlinable @inline(__always)
    public mutating func fill(_ value: Element) {
        // Unsafe: initializing every entry. Safe: the allocation holds `count`.
        unsafe base.initialize(repeating: value, count: count)
    }

    /// Sets every entry to `value`, a `Group` at a time: one 16-byte store (`str q`) or a pair (`stp q, q`) per group,
    /// for values a `memset` can't make (DEFLATE's `Int16.min`).
    ///
    /// A table of fewer entries than a group fills its first group, which its 64-byte line holds.
    ///
    /// - Precondition: `Group`'s stride divides 64 (16, 32, or 64 bytes), and is its lanes' (no padding lane: a
    ///   `SIMD3`'s fourth would be stored over every fourth entry).
    @inlinable @inline(__always)
    public mutating func fill<Group: SIMD>(_ value: Element, groupedAs _: Group.Type) where Group.Scalar == Element {
        let stride = MemoryLayout<Group>.stride
        precondition(64 % stride == 0, "A group that doesn't divide a 64-byte line")
        precondition(stride == Group.scalarCount &* MemoryLayout<Element>.stride, "A group with a padding lane")
        let group = Group(repeating: value)
        // A pointer that steps, so stores post-index (`str q0, [x9], #16`): with an offset, a 64-byte group's `stp`
        // pair, which has no register-offset form, cost an address `add` per group.
        // Unsafe: raw stores of whole groups. Safe: they start at the allocation, 64-byte aligned, step by a stride that
        // divides 64, and stop at the end of the entries rounded up to a group, within the allocation's whole 64-byte
        // lines; the stores write entries' bytes (any trivial type's memory takes raw stores).
        var address = unsafe UnsafeMutableRawPointer(base)
        let last = unsafe address + (count &* MemoryLayout<Element>.stride)
        while unsafe address < last {
            unsafe address.storeBytes(of: group, as: Group.self)
            unsafe address += stride
        }
    }
}

// Unchecked: the table holds a pointer, but owns the memory it points to, and only its owner, who has exclusive
// access, writes through it (every write is `mutating`); noncopyable, so it has one owner.
extension MaskedTable: @unchecked Sendable where Element: Sendable {}
