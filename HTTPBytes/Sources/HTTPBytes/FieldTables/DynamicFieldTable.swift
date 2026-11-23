// HPACK's and QPACK's dynamic table (RFC 7541 §2.3.2, §4; RFC 9204 §3.2), as their decoders and encoders keep it.

/// One dynamic table entry: where its bytes are (name, then value), and its name's ``HTTPFieldName`` index when it's a known
/// name.
@frozen @usableFromInline
package struct DynamicFieldTableEntry: Sendable {
    /// The offset of the entry's bytes (its name's, then its value's) in the table's byte store.
    @usableFromInline package var offset: UInt32
    /// The name's length.
    @usableFromInline package var nameCount: UInt32
    @usableFromInline package var valueCount: UInt32
    /// The name's ``HTTPFieldName/index``, or 0xFF.
    @usableFromInline package var knownName: UInt8
    /// The decoder's verdict on its characters (RFC 9113 §8.2.1, RFC 9114 §4.2), made when it was inserted: `nameIsValid`
    /// and `valueIsValid` bits. The encoders don't use them.
    @usableFromInline package var flags: UInt8

    @inlinable package static var nameIsValid: UInt8 { 1 }
    @inlinable package static var valueIsValid: UInt8 { 2 }

    @inlinable @inline(__always)
    package init(offset: UInt32, nameCount: UInt32, valueCount: UInt32, knownName: UInt8, flags: UInt8) {
        self.flags = flags
        self.offset = offset
        self.nameCount = nameCount
        self.valueCount = valueCount
        self.knownName = knownName
    }

    /// The entry's size as RFC 7541 §4.1 and RFC 9204 §3.2.1 count it.
    @inlinable package var size: Int { Int(nameCount) &+ Int(valueCount) &+ 32 }
    /// The bytes stored for it.
    @inlinable package var storedCount: Int { Int(nameCount) &+ Int(valueCount) }
    /// The value's offset in the byte store.
    @inlinable package var valueOffset: Int { Int(offset) &+ Int(nameCount) }
}

/// A dynamic table (HPACK's, RFC 7541 §2.3.2 and §4; QPACK's, RFC 9204 §3.2): entries' bytes in one store, each entry
/// contiguous (one span), and the entries' descriptors in a ring.
///
/// Entries are numbered by insertion (absolute numbers that never change: QPACK's absolute index; HPACK's index 1 is the
/// newest, `inserted − 1`), so inserting and evicting renumber nothing. The byte store is twice the largest table size
/// allowed: an entry that would straddle the end goes to the start instead, leaving a gap. That always fits: the live
/// bytes are at most the maximum size S less 32 per entry, and an entry at most S − 32, so live bytes, gap, and the new
/// entry stay within 2S (the argument is in `place(_:)`). An entry keeps its name's known index too (resolved once, when
/// it's inserted).
///
/// Memory is allocated once, for the largest size the endpoint allows; nothing is allocated per entry.
@safe @usableFromInline
package struct DynamicFieldTable: ~Copyable {
    @usableFromInline package let bytes: UnsafeMutableRawPointer
    @usableFromInline package let byteCapacity: Int
    @usableFromInline package let entries: UnsafeMutablePointer<DynamicFieldTableEntry>
    /// The ring's slot count less 1 (a power of two less 1).
    @usableFromInline package let entryMask: Int
    /// The largest size the table may have (the HPACK or QPACK setting this memory was made for).
    @usableFromInline package let capacity: Int
    /// The oldest entry's insertion number.
    @usableFromInline package var oldest = 0
    /// The next entry's insertion number (QPACK's Insert Count).
    @usableFromInline package var inserted = 0
    /// Where the next entry's bytes go (if they fit before the end).
    @usableFromInline package var head = 0
    /// The entries' size (RFC 7541 §4.1).
    @usableFromInline package var size = 0
    /// The current maximum size, set by HPACK's size updates (RFC 7541 §4.2) or QPACK's Set Dynamic Table Capacity
    /// (RFC 9204 §4.3.1): at most `capacity`.
    @usableFromInline package var maximumSize: Int

    /// A table for sizes up to `capacity`, starting at `capacity`.
    @inlinable
    package init(capacity: Int) {
        precondition(capacity >= 0 && capacity <= 1 << 30, "a table size is 0 through 2³⁰")
        self.capacity = capacity
        maximumSize = capacity
        byteCapacity = Swift.max(2 &* capacity, 8)
        // At most one entry per 32 bytes of size, plus one: the ring never wraps onto a live entry.
        var slots = 2
        while slots <= capacity / 32 &+ 1 { slots &<<= 1 }
        entryMask = slots &- 1
        // Unsafe: allocations owned by this table and freed in `deinit`.
        unsafe bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCapacity, alignment: 16)
        unsafe entries = UnsafeMutablePointer<DynamicFieldTableEntry>.allocate(capacity: slots)
    }

    deinit {
        // Unsafe: frees this table's own allocations, which nothing else holds (the table is noncopyable).
        unsafe bytes.deallocate()
        unsafe entries.deallocate()
    }

    /// The number of entries.
    @inlinable package var count: Int { inserted &- oldest }

    /// The entry at HPACK's dynamic index `index` (1 is the newest). The caller checks `1 <= index <= count`.
    @inlinable @inline(__always)
    package func entry(at index: Int) -> DynamicFieldTableEntry {
        // Unsafe: an unchecked read. Safe: the slot is masked into the ring, and the caller checked the index.
        unsafe entries[(inserted &- index) & entryMask]
    }

    /// The entry inserted as number `number` (QPACK's absolute index).
    @inlinable @inline(__always)
    package func entry(number: Int) -> DynamicFieldTableEntry {
        // Unsafe: an unchecked read. Safe: the slot is masked into the ring.
        unsafe entries[number & entryMask]
    }

    /// Whether entry `number` is in the table (inserted and not evicted).
    @inlinable @inline(__always)
    package func contains(number: Int) -> Bool {
        number >= oldest && number < inserted
    }

    /// The address of a byte in the store.
    @inlinable @inline(__always)
    package func address(_ offset: Int) -> UnsafeRawPointer {
        // Unsafe: an address in the store. Safe: offsets come from entries, which lie within it.
        unsafe UnsafeRawPointer(bytes + offset)
    }

    /// Evicts the oldest entry.
    @inlinable @inline(__always)
    package mutating func evictOldest() {
        size &-= entry(number: oldest).size
        oldest &+= 1
        if oldest == inserted { head = 0 }
    }

    /// Sets the maximum size (a size update, a capacity instruction, or a new setting), evicting entries until the table
    /// fits.
    @inlinable
    package mutating func setMaximumSize(_ newValue: Int) {
        maximumSize = newValue
        while size > newValue { evictOldest() }
    }

    /// Removes every entry.
    @inlinable
    package mutating func removeAll() {
        oldest = inserted
        size = 0
        head = 0
    }

    /// Removes every entry and starts numbering again from 0 (QPACK's new connection: absolute indexes start at 0).
    @inlinable
    package mutating func removeAllNumberingFromZero() {
        oldest = 0
        inserted = 0
        size = 0
        head = 0
    }

    /// Where an entry of `stored` bytes goes, after evicting for its size. Always fits (see the type's comment):
    /// unwrapped (head at or after the oldest entry's bytes), `[head, head + stored)` is free if it's before the end;
    /// otherwise the entry goes to 0, and the oldest entry starts at least S bytes in (head > 2S − stored and live bytes
    /// ≤ S − stored). Wrapped (head before the oldest), the free run from head is 2S − live − gap ≥ stored.
    @inlinable @inline(__always)
    package func place(_ stored: Int) -> Int {
        head &+ stored <= byteCapacity ? head : 0
    }

    /// Inserts an entry (RFC 7541 §4.4, RFC 9204 §3.2.2): evicts until it fits, or empties the table if it's larger than
    /// the maximum size (HPACK's rule; QPACK's decoder rejects such an entry first). The name is `nameCount` bytes at
    /// `name` (which may be in this table, even in an entry this insertion evicts: it's moved first, with overlap
    /// allowed), whose known name is `knownName`; the value is `valueCount` bytes at `value`, which mustn't be in this
    /// table unless it directly follows the name (an entry's own bytes, as QPACK's Duplicate inserts them: then both
    /// move together).
    /// - Returns: The new entry's number, or -1 if it was too large (the table is then empty).
    @inlinable
    package mutating func insert(name: UnsafeRawPointer?, nameCount: Int, knownName: UInt8, value: UnsafeRawPointer?, valueCount: Int,
                                 flags: UInt8 = 0) -> Int {
        let entrySize = nameCount &+ valueCount &+ 32
        guard entrySize <= maximumSize else {
            removeAll()
            return -1
        }
        while size &+ entrySize > maximumSize { evictOldest() }
        let storedName = nameCount
        let at = place(storedName &+ valueCount)
        // Unsafe: compares addresses only.
        if storedName > 0, valueCount > 0, let name = unsafe name, unsafe value == name + storedName {
            // Unsafe: moves the name and value together into [at, at + stored), free by `place`; a move, since they may
            // be an evicted entry's bytes there.
            unsafe (bytes + at).copyMemory(from: name, byteCount: storedName &+ valueCount)
        } else {
            if storedName > 0 {
                // Unsafe: copies the name into [at, at + nameCount), free by `place`; a move, since the name may be an
                // evicted entry's bytes there.
                unsafe (bytes + at).copyMemory(from: name.unsafelyUnwrapped, byteCount: storedName)
            }
            if valueCount > 0 {
                // Unsafe: copies the value after the name, within the free run `place` found.
                unsafe (bytes + (at &+ storedName)).copyMemory(from: value.unsafelyUnwrapped, byteCount: valueCount)
            }
        }
        let number = inserted
        // Unsafe: an unchecked store into the ring. Safe: the slot is masked; at most `capacity / 32` entries are live,
        // fewer than the ring's slots, so it isn't a live entry's.
        unsafe entries[number & entryMask] = DynamicFieldTableEntry(
            offset: UInt32(truncatingIfNeeded: at), nameCount: UInt32(truncatingIfNeeded: nameCount),
            valueCount: UInt32(truncatingIfNeeded: valueCount), knownName: knownName, flags: flags)
        inserted &+= 1
        head = at &+ storedName &+ valueCount
        size &+= entrySize
        return number
    }
}
