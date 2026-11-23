// HPACK's and QPACK's static tables (RFC 7541 Appendix A, RFC 9204 Appendix A), by address, in coder-owned memory.

/// A static table entry by address: its name's and value's bytes (constant data that lives forever) and lengths, and
/// its name's ``HTTPFieldName/index``.
@frozen @usableFromInline @safe
package struct StaticFieldEntry {
    @usableFromInline package let name: UnsafeRawPointer
    @usableFromInline package let value: UnsafeRawPointer
    @usableFromInline package let nameCount: Int32
    @usableFromInline package let valueCount: Int32
    @usableFromInline package let knownName: UInt8

    @inlinable
    package init(name: UnsafeRawPointer, value: UnsafeRawPointer, nameCount: Int32, valueCount: Int32, knownName: UInt8) {
        unsafe self.name = name
        unsafe self.value = value
        self.nameCount = nameCount
        self.valueCount = valueCount
        self.knownName = knownName
    }
}

/// A static table as the coders read it per field: one load of an entry for its name's and value's addresses and
/// lengths, and, for the encoders, a known name's first static index by its ``HTTPFieldName/index`` and the next index
/// with the same name.
///
/// Built when a coder is made, from the generated tables, into memory the coder owns: read through the tables'
/// accessors and `HTTPFieldName.lowercaseBytes`, the same per field cost two cross-module calls (the statics' addressors
/// and the name getter: `Tools/calls` on the first HPACK decoder).
@safe @usableFromInline
package struct StaticFieldEntries: ~Copyable {
    /// The entries by the table's own index (HPACK's from 1, entry 0 a copy of entry 1; QPACK's from 0).
    @usableFromInline package let entries: UnsafeMutablePointer<StaticFieldEntry>
    /// Per ``HTTPFieldName/index`` (256 slots), the name's first static index, or `noIndex`.
    @usableFromInline package let indexByName: UnsafeMutablePointer<UInt8>
    /// Per entry, the next entry with the same name, or `noIndex` (QPACK's table doesn't keep a name's entries together).
    @usableFromInline package let nextWithName: UnsafeMutablePointer<UInt8>
    /// The number of slots in `entries`.
    @usableFromInline package let slots: Int
    /// `indexByName`'s and `nextWithName`'s "none": 0 for HPACK (whose index 0 is never an entry), 0xFF for QPACK.
    @usableFromInline package let noIndex: UInt8

    /// HPACK's table (RFC 7541 Appendix A): entries 1–61.
    @inlinable
    package static func hpack() -> StaticFieldEntries {
        // Unsafe: the description hands out addresses of constant data (string literals), which live forever.
        unsafe StaticFieldEntries(slots: 62, noIndex: 0) { index in
            let entryIndex = Swift.max(index, 1)
            let start = Int(HPACKStaticTable.valueOffsets[entryIndex &- 1])
            let end = Int(HPACKStaticTable.valueOffsets[entryIndex])
            // Unsafe: an address in a string literal's bytes, constant data that lives forever; the offsets are within it.
            let value = unsafe UnsafeRawPointer(HPACKStaticTable.values.utf8Start + start)
            return unsafe (HPACKStaticTable.names[entryIndex &- 1], value, end &- start, index > 0)
        }
    }

    /// QPACK's table (RFC 9204 Appendix A): entries 0–98.
    @inlinable
    package static func qpack() -> StaticFieldEntries {
        // Unsafe: as in `hpack()`.
        unsafe StaticFieldEntries(slots: 99, noIndex: 0xFF) { index in
            let start = Int(QPACKStaticTable.valueOffsets[index])
            let end = Int(QPACKStaticTable.valueOffsets[index &+ 1])
            // Unsafe: as in `hpack()`.
            let value = unsafe UnsafeRawPointer(QPACKStaticTable.values.utf8Start + start)
            return unsafe (QPACKStaticTable.names[index], value, end &- start, true)
        }
    }

    /// A table of `slots` entries, each described by `describe` (its known name, value address and length, and whether
    /// it's a real entry the name indexes should list).
    @inlinable
    init(slots: Int, noIndex: UInt8, _ describe: (Int) -> (UInt8, UnsafeRawPointer, Int, Bool)) {
        self.slots = slots
        self.noIndex = noIndex
        // Unsafe: allocations owned by this value, freed in `deinit`, every slot initialized here.
        unsafe entries = UnsafeMutablePointer<StaticFieldEntry>.allocate(capacity: slots)
        unsafe indexByName = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        unsafe nextWithName = UnsafeMutablePointer<UInt8>.allocate(capacity: slots)
        unsafe indexByName.initialize(repeating: noIndex, count: 256)
        unsafe nextWithName.initialize(repeating: noIndex, count: slots)
        // Each name's last entry so far, to link the next one to it.
        var lastByName = InlineArray<256, UInt8>(repeating: 0xFF)
        for index in 0..<slots {
            let (known, value, valueCount, listed) = unsafe describe(index)
            let nameBytes = HTTPFieldName(tableIndex: known).lowercaseBytes
            // The address of a known name's bytes escapes the closure, which is fine: they're a string literal's
            // (`lowercaseBytes` is an immortal span), constant data that lives forever.
            let name = nameBytes.withUnsafeBytes { $0.baseAddress! }
            unsafe (entries + index).initialize(to: StaticFieldEntry(
                name: name, value: value, nameCount: Int32(nameBytes.byteCount), valueCount: Int32(valueCount), knownName: known))
            guard listed else { continue }
            let last = lastByName[Int(known)]
            if last == 0xFF {
                unsafe indexByName[Int(known)] = UInt8(index)
            } else {
                unsafe nextWithName[Int(last)] = UInt8(index)
            }
            lastByName[Int(known)] = UInt8(index)
        }
    }

    deinit {
        // Unsafe: frees this value's own allocations (it's noncopyable; the entries are plain values).
        unsafe entries.deallocate()
        unsafe indexByName.deallocate()
        unsafe nextWithName.deallocate()
    }

    /// Entry `index` (the caller checks it's below the table's slot count).
    @inlinable @inline(__always)
    package subscript(index: Int) -> StaticFieldEntry {
        // Unsafe: an unchecked read. Safe: the caller checked the index (HPACK: 1 ≤ index ≤ 61; QPACK: index < 99).
        unsafe entries[index]
    }

    /// The first static index of the known name `knownName` (an ``HTTPFieldName/index``, or 0xFF), or ``noIndex``.
    @inlinable @inline(__always)
    package func index(ofName knownName: UInt8) -> Int {
        // Unsafe: an unchecked read. Safe: any UInt8 indexes the 256 slots.
        Int(unsafe indexByName[Int(knownName)])
    }

    /// The next static index with entry `index`'s name, or ``noIndex``.
    @inlinable @inline(__always)
    package func next(afterIndex index: Int) -> Int {
        // Unsafe: an unchecked read. Safe: callers pass indexes of entries (below the slot count).
        Int(unsafe nextWithName[index])
    }
}
