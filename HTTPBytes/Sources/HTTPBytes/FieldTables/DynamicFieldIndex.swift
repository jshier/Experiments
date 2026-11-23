// How HPACK's and QPACK's encoders find dynamic table entries: two hash chains per entry, and the output cursor they
// write through.

/// An encoder's index of its dynamic table: two small hash tables of chains (name and value; name only) linked by
/// insertion number, so evicting an entry costs nothing: a chain ends at the first entry older than the table's oldest.
@safe @usableFromInline
package struct DynamicFieldIndex: ~Copyable {
    /// Per ring slot: the entry's hash of name and value, and its name's hash.
    @usableFromInline package let fieldHashes: UnsafeMutablePointer<UInt64>
    @usableFromInline package let nameHashes: UnsafeMutablePointer<UInt64>
    /// Per ring slot: the previous (older) entry number in the same field or name bucket, or -1.
    @usableFromInline package let fieldLinks: UnsafeMutablePointer<Int>
    @usableFromInline package let nameLinks: UnsafeMutablePointer<Int>
    /// The newest entry number per bucket, or -1.
    @usableFromInline package let fieldBuckets: UnsafeMutablePointer<Int>
    @usableFromInline package let nameBuckets: UnsafeMutablePointer<Int>
    @usableFromInline package let bucketMask: Int

    /// An index for a table whose ring has `slots` slots.
    @inlinable
    package init(slots: Int) {
        var buckets = 16
        while buckets < 2 &* slots { buckets &<<= 1 }
        bucketMask = buckets &- 1
        // Unsafe: allocations owned by this index, freed in `deinit`; buckets start empty (-1).
        unsafe fieldHashes = UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        unsafe nameHashes = UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        unsafe fieldLinks = UnsafeMutablePointer<Int>.allocate(capacity: slots)
        unsafe nameLinks = UnsafeMutablePointer<Int>.allocate(capacity: slots)
        unsafe fieldBuckets = UnsafeMutablePointer<Int>.allocate(capacity: buckets)
        unsafe nameBuckets = UnsafeMutablePointer<Int>.allocate(capacity: buckets)
        unsafe fieldBuckets.initialize(repeating: -1, count: buckets)
        unsafe nameBuckets.initialize(repeating: -1, count: buckets)
    }

    deinit {
        // Unsafe: frees this index's own allocations, which nothing else holds (it's noncopyable).
        unsafe fieldHashes.deallocate()
        unsafe nameHashes.deallocate()
        unsafe fieldLinks.deallocate()
        unsafe nameLinks.deallocate()
        unsafe fieldBuckets.deallocate()
        unsafe nameBuckets.deallocate()
    }

    /// Empties every chain: for a table whose numbering starts again from 0 (chains end at numbers below the oldest
    /// entry's, so stale links to renumbered entries would otherwise look live).
    @inlinable
    package func removeAll() {
        // Unsafe: writes the buckets' own `bucketMask + 1` slots.
        unsafe fieldBuckets.update(repeating: -1, count: bucketMask &+ 1)
        unsafe nameBuckets.update(repeating: -1, count: bucketMask &+ 1)
    }

    // MARK: Hashing

    /// A name's hash: a known name's index, or its bytes' (the two can't collide: bytes hash with the top bit set).
    @inlinable @inline(__always)
    package static func nameHash(_ name: UnsafeRawPointer?, _ count: Int, _ knownName: UInt8) -> UInt64 {
        if knownName != 0xFF { return UInt64(knownName) &+ 1 }
        return unsafe bytesHash(name, count) | 1 &<< 63
    }

    /// A field's hash: its name's, mixed with its value's.
    @inlinable @inline(__always)
    package static func fieldHash(_ nameHash: UInt64, _ value: UnsafeRawPointer?, _ count: Int) -> UInt64 {
        let mixed = unsafe (nameHash &* 0x9E37_79B9_7F4A_7C15) ^ bytesHash(value, count)
        return mixed ^ mixed &>> 29
    }

    /// A quick hash of bytes: their count and first and last 8 (or 4, or 1–3) bytes, which differ between most values
    /// a table holds; collisions cost a comparison.
    @inlinable @inline(__always)
    package static func bytesHash(_ bytes: UnsafeRawPointer?, _ count: Int) -> UInt64 {
        guard count > 0, let bytes = unsafe bytes else { return 0x51_7CC1_B727_220A }
        let first: UInt64, last: UInt64
        if count >= 8 {
            // Unsafe: 8-byte loads at 0 and count − 8. Safe: count ≥ 8.
            first = unsafe bytes.loadUnaligned(as: UInt64.self)
            last = unsafe bytes.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)
        } else if count >= 4 {
            // Unsafe: 4-byte loads at 0 and count − 4. Safe: count ≥ 4.
            first = UInt64(unsafe bytes.loadUnaligned(as: UInt32.self))
            last = UInt64(unsafe bytes.loadUnaligned(fromByteOffset: count &- 4, as: UInt32.self))
        } else {
            // Unsafe: bytes 0, count / 2, count − 1. Safe: 1 ≤ count ≤ 3.
            first = UInt64(unsafe bytes.load(as: UInt8.self)) | UInt64(unsafe bytes.load(fromByteOffset: count &>> 1, as: UInt8.self)) &<< 8
            last = UInt64(unsafe bytes.load(fromByteOffset: count &- 1, as: UInt8.self))
        }
        let a = (first ^ UInt64(truncatingIfNeeded: count)) &* 0xFF51_AFD7_ED55_8CCD
        let b = (last &+ 0x2545_F491_4F6C_DD1D) &* 0xC4CE_B9FE_1A85_EC53
        return a ^ (b &>> 31 | b &<< 33)
    }

    // MARK: Matching

    /// Whether the entry's name is `name` (`knownName`, or the bytes).
    @inlinable @inline(__always)
    package static func nameMatches(_ entry: DynamicFieldTableEntry, in table: borrowing DynamicFieldTable,
                                    _ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8) -> Bool {
        if entry.knownName != knownName { return false }
        if knownName != 0xFF { return true }
        return unsafe Int(entry.nameCount) == nameCount && equalBytes(table.address(Int(entry.offset)), name, nameCount)
    }

    /// The number of the newest entry in `table` with this name and value (whose field hash is `hash`), or -1.
    @inlinable @inline(__always)
    package func fieldMatch(_ hash: UInt64, in table: borrowing DynamicFieldTable, _ name: UnsafeRawPointer?, _ nameCount: Int,
                            _ knownName: UInt8, _ value: UnsafeRawPointer?, _ valueCount: Int) -> Int {
        // Unsafe: unchecked reads of the buckets and per-slot arrays. Safe: indices are masked into them; a chain stops at
        // the first number older than the oldest entry, before reading a slot reused since.
        var number = unsafe fieldBuckets[Int(truncatingIfNeeded: hash) & bucketMask]
        while number >= table.oldest {
            let slot = number & table.entryMask
            if unsafe fieldHashes[slot] == hash {
                let entry = table.entry(number: number)
                if Int(entry.valueCount) == valueCount, unsafe Self.nameMatches(entry, in: table, name, nameCount, knownName),
                   unsafe equalBytes(table.address(entry.valueOffset), value, valueCount) {
                    return number
                }
            }
            number = unsafe fieldLinks[slot]
        }
        return -1
    }

    /// The number of the newest entry in `table` with this name (whose name hash is `hash`), or -1.
    @inlinable @inline(__always)
    package func nameMatch(_ hash: UInt64, in table: borrowing DynamicFieldTable, _ name: UnsafeRawPointer?, _ nameCount: Int,
                           _ knownName: UInt8) -> Int {
        // Unsafe and safe as in `fieldMatch`.
        var number = unsafe nameBuckets[Int(truncatingIfNeeded: hash) & bucketMask]
        while number >= table.oldest {
            let slot = number & table.entryMask
            if unsafe nameHashes[slot] == hash, unsafe Self.nameMatches(table.entry(number: number), in: table, name, nameCount, knownName) {
                return number
            }
            number = unsafe nameLinks[slot]
        }
        return -1
    }

    /// Links entry `number` (in a ring of `entryMask + 1` slots) into its two chains.
    @inlinable @inline(__always)
    package func add(number: Int, entryMask: Int, nameHash: UInt64, fieldHash: UInt64) {
        let slot = number & entryMask
        let fieldBucket = Int(truncatingIfNeeded: fieldHash) & bucketMask
        let nameBucket = Int(truncatingIfNeeded: nameHash) & bucketMask
        // Unsafe: unchecked stores into the per-slot arrays and buckets. Safe: indices are masked into them.
        unsafe fieldHashes[slot] = fieldHash
        unsafe nameHashes[slot] = nameHash
        unsafe fieldLinks[slot] = fieldBuckets[fieldBucket]
        unsafe nameLinks[slot] = nameBuckets[nameBucket]
        unsafe fieldBuckets[fieldBucket] = number
        unsafe nameBuckets[nameBucket] = number
    }
}

/// Whether `count` bytes at `a` and `b` are equal: 8-byte words, the last overlapping.
@inlinable @inline(__always)
package func equalBytes(_ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?, _ count: Int) -> Bool {
    guard count > 0, let a = unsafe a, let b = unsafe b else { return true }
    // Unsafe: unchecked loads below. Safe: every load is within [0, count) of both (the callers pass their lengths).
    if count >= 8 {
        var offset = 0
        while offset < count &- 8 {
            if unsafe a.loadUnaligned(fromByteOffset: offset, as: UInt64.self) != b.loadUnaligned(fromByteOffset: offset, as: UInt64.self) {
                return false
            }
            offset &+= 8
        }
        return unsafe a.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self) == b.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)
    }
    if count >= 4 {
        return unsafe a.loadUnaligned(as: UInt32.self) == b.loadUnaligned(as: UInt32.self)
            && a.loadUnaligned(fromByteOffset: count &- 4, as: UInt32.self) == b.loadUnaligned(fromByteOffset: count &- 4, as: UInt32.self)
    }
    for offset in 0..<count where unsafe a.load(fromByteOffset: offset, as: UInt8.self) != b.load(fromByteOffset: offset, as: UInt8.self) {
        return false
    }
    return true
}

/// An encoder's output: a pointer, a capacity, and the bytes written.
@frozen @usableFromInline @safe
package struct FieldEncoderOutput {
    @usableFromInline package let base: UnsafeMutablePointer<UInt8>
    @usableFromInline package let capacity: Int
    @usableFromInline package var count = 0

    @inlinable @inline(__always)
    package init(_ base: UnsafeMutablePointer<UInt8>, _ capacity: Int) {
        unsafe self.base = base
        self.capacity = capacity
    }

    /// A prefix integer.
    @inlinable @inline(__always)
    package mutating func integer(_ value: Int, mask: Int, flags: UInt8) -> Bool {
        // Unsafe: writes at `count`, below the capacity it's given (the rest), and reports what it wrote.
        let written = unsafe writePrefixInteger(value, mask: mask, flags: flags, base + count, capacity &- count)
        guard written > 0 else { return false }
        count &+= written
        return true
    }

    /// An HPACK string literal (7-bit length prefix, H at 0x80): Huffman-coded if that's shorter (and `huffman`), else raw.
    @inlinable @inline(__always)
    package mutating func string(_ bytes: UnsafeRawPointer?, _ length: Int, huffman: Bool) -> Bool {
        let input = unsafe bytes?.assumingMemoryBound(to: UInt8.self)
        // Unsafe: writes at `count`, below the capacity it's given, and reports what it wrote; reads `length` input bytes.
        let written = huffman
            ? unsafe huffmanStringLiteral(input, length, base + count, capacity &- count)
            : unsafe rawStringLiteral(input, length, base + count, capacity &- count, prefixMask: 0x7F, flags: 0)
        guard written > 0 else { return false }
        count &+= written
        return true
    }

    /// A string literal with a `prefixMask` (2^N − 1) length prefix whose H bit is `prefixMask + 1`, `flags` in the first
    /// byte's bits above it (QPACK's 3-, 5-, and 7-bit prefixes, RFC 9204 §4.1.2).
    @inlinable @inline(__always)
    package mutating func string(_ bytes: UnsafeRawPointer?, _ length: Int, huffman: Bool, prefixMask: Int, flags: UInt8) -> Bool {
        let input = unsafe bytes?.assumingMemoryBound(to: UInt8.self)
        // Unsafe: as in `string(_:_:huffman:)`.
        let written = huffman
            ? unsafe huffmanStringLiteral(input, length, base + count, capacity &- count, prefixMask: prefixMask, flags: flags)
            : unsafe rawStringLiteral(input, length, base + count, capacity &- count, prefixMask: prefixMask, flags: flags)
        guard written > 0 else { return false }
        count &+= written
        return true
    }
}

/// A raw string literal: the length (H clear) in a `prefixMask` prefix after `flags`, then the bytes.
/// - Returns: Bytes written, or -1 if they don't fit.
@usableFromInline
package func rawStringLiteral(_ input: UnsafePointer<UInt8>?, _ length: Int, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int,
                              prefixMask: Int, flags: UInt8) -> Int {
    let prefix = unsafe writePrefixInteger(length, mask: prefixMask, flags: flags, output, capacity)
    guard prefix > 0, length <= capacity &- prefix else { return -1 }
    // Unsafe: copies `length` bytes into the room checked above.
    if length > 0 { unsafe (output + prefix).update(from: input.unsafelyUnwrapped, count: length) }
    return prefix &+ length
}
