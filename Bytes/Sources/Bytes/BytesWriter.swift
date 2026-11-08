/// A cursor that writes binary data into borrowed memory, field by field, at bit or byte granularity: the
/// counterpart of ``BytesReader``.
///
/// ```swift
/// let packet = try [UInt8](capacity: 64) { output in
///     try output.withBytesWriter { writer in
///         try writer.write(0x50_4B_03_04 as Byte4)
///         try writer.write(20, as: Byte2.self, .littleEndian)
///         try writer.write(Nibble(0b0011))
///         try writer.write(Nibble(0b0000))
///     }
/// }
/// ```
///
/// Writes are packed like reads: after a bit-level write, multi-byte writes continue mid-byte, each byte
/// made of the next 8 bits in ``bitOrder``; ``alignToByte()`` pads to the next byte with zeros. A bit-level
/// write zeroes the rest of the byte it ends in, which is what appending wants.
///
/// Every write stays within the bytes it writes (odd widths use two overlapping stores, never a wider
/// one), so a writer over existing data never touches memory past the byte its cursor is in. The
/// exceptions are the section writers, whose `body` writes ahead of the length.
///
/// A single value too large for the field it's written as (`write(0x0100_0000, as: Byte3.self,
/// .bigEndian)`) is a programming error: debug builds trap, and release builds write the low bytes. Bulk
/// and generating writes always write the low bytes, unchecked, so their loops vectorize, and so does
/// ``write(_:bitCount:)``, by design, like `init(truncatingIfNeeded:)`.
///
/// A write that throws ``BytesError/insufficientCapacity`` writes nothing.
@safe
public struct BytesWriter: ~Copyable, ~Escapable {
    @usableFromInline var _bytes: MutableRawSpan
    /// The order of bits within each byte, for ``Bits`` and ``write(_:bitCount:)``.
    public let bitOrder: BitOrder
    @usableFromInline var _byteOffset: Int
    /// Bits already written into the byte at `_byteOffset`: always 0 through 7.
    @usableFromInline var _bitOffset: Int
    /// The byte at `_byteOffset` as written so far (zero when `_bitOffset` is 0). Kept here so a bit write
    /// doesn't reload the byte the previous one stored: that reload made consecutive bit writes wait on
    /// store-to-load forwarding.
    @usableFromInline var _partial: UInt64

    /// Creates a writer at the start of `bytes`, overwriting them.
    @inlinable
    @_lifetime(copy bytes)
    public init(_ bytes: consuming MutableRawSpan, bitOrder: BitOrder = .mostSignificantFirst) {
        _bytes = bytes
        self.bitOrder = bitOrder
        _byteOffset = 0
        _bitOffset = 0
        _partial = 0
    }

    /// Creates a writer at the start of `bytes`, overwriting them.
    @inlinable
    @_lifetime(&bytes)
    public init(_ bytes: inout MutableSpan<UInt8>, bitOrder: BitOrder = .mostSignificantFirst) {
        self.init(MutableRawSpan(mutating: &bytes), bitOrder: bitOrder)
    }
}

// MARK: - Position

extension BytesWriter {
    /// The number of bytes written so far, including a partly written last byte.
    @inlinable
    public var byteCount: Int { _byteOffset &+ (_bitOffset == 0 ? 0 : 1) }

    /// The offset of the byte the next write starts in.
    @inlinable
    public var byteOffset: Int { _byteOffset }

    /// The number of bits already written into the byte at ``byteOffset``, from 0 through 7.
    @inlinable
    public var bitOffset: Int { _bitOffset }

    /// The capacity, in bytes.
    @inlinable
    public var capacity: Int { _bytes.byteCount }

    /// The number of bits that can still be written.
    @inlinable
    public var remainingBitCount: Int { (_bytes.byteCount &- _byteOffset) &<< 3 &- _bitOffset }

    /// The number of whole bytes that can still be written. A partly written byte doesn't count.
    @inlinable
    public var remainingByteCount: Int { _bytes.byteCount &- _byteOffset &- (_bitOffset == 0 ? 0 : 1) }

    /// Whether the next write starts at the beginning of a byte.
    @inlinable
    public var isByteAligned: Bool { _bitOffset == 0 }

    /// Whether every bit has been written.
    @inlinable
    public var isFull: Bool { _byteOffset == _bytes.byteCount }

    /// The bytes written so far.
    @inlinable
    public var writtenBytes: RawSpan {
        @_lifetime(borrow self)
        get { _bytes.bytes.extracting(first: byteCount) }
    }

    /// Pads with zero bits to the start of the next byte, unless already at the start of one.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func alignToByte() {
        // Bit writes zero the rest of the byte they end in, so the padding is already there.
        if _bitOffset != 0 {
            _byteOffset &+= 1
            _bitOffset = 0
            _partial = 0
        }
    }

    /// See ``BytesReader/_assumeInvariant()``; the same reasoning applies.
    @inlinable @inline(__always)
    func _assumeInvariant() {
        unsafe assume(_byteOffset <= _bytes.byteCount)
        unsafe assume(_bitOffset >= 0)
        unsafe assume(_bitOffset < 8)
    }
}

// MARK: - Byte groups

extension BytesWriter {
    /// Writes `value`'s `T.byteCount` bytes, in memory order.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteGroup>(_ value: T) throws(BytesError) {
        _assumeInvariant()
        if likely(_bitOffset == 0) {
            guard likely(_bytes.byteCount &- _byteOffset >= T.byteCount) else { throw .insufficientCapacity }
            unsafe Store.group(value, to: &_bytes, at: _byteOffset)
            _byteOffset &+= T.byteCount
            return
        }
        guard remainingByteCount >= T.byteCount else { throw .insufficientCapacity }
        (_byteOffset, _bitOffset, _partial) = Self._writeUnalignedBytes(
            UInt128(value.littleEndian), count: T.byteCount, to: &_bytes,
            at: (_byteOffset, _bitOffset, _partial), bitOrder: bitOrder
        )
    }

    /// Writes the low `T.byteCount` bytes of `value` in `byteOrder`.
    ///
    /// ```swift
    /// try writer.write(length, as: Byte3.self, .bigEndian)
    /// ```
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteGroup>(_ value: T.Integer, as _: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        assert(value <= T._mask, "\(value) doesn't fit in \(T.byteCount) bytes")
        try write(T(value, byteOrder))
    }

    /// `count` bytes of `bytes` (little-endian: first byte lowest) when not byte-aligned, each as the next 8
    /// bits. Capacity already checked. Returns the new offsets.
    ///
    /// Out of line and static, taking the offsets as values: a `mutating` method would need the writer's
    /// address, keeping it in memory in every caller (its offset stored every iteration of a write loop)
    /// and hiding from the optimizer that the bit offset stays zero, so loops couldn't vectorize.
    @usableFromInline
    static func _writeUnalignedBytes(
        _ bytes: UInt128, count: Int, to span: inout MutableRawSpan, at position: _Position, bitOrder: BitOrder
    ) -> _Position {
        var position = position
        for index in 0..<count {
            position = _writeBits(
                UInt64(UInt8(truncatingIfNeeded: bytes &>> (8 &* index))), count: 8,
                to: &span, at: position, bitOrder: bitOrder
            )
        }
        return position
    }
}

// MARK: - Bits

extension BytesWriter {
    /// Writes `value`'s `width` bits, in ``bitOrder``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<let width: Int>(_ value: Bits<width>) throws(BytesError) {
        Bits<width>._checkWidth()
        _assumeInvariant()
        if width == 8, likely(_bitOffset == 0) {
            guard likely(_byteOffset < _bytes.byteCount) else { throw .insufficientCapacity }
            unsafe _bytes.storeBytes(of: value.rawValue, toUncheckedByteOffset: _byteOffset, as: UInt8.self)
            _byteOffset &+= 1
            return
        }
        guard likely(remainingBitCount >= width) else { throw .insufficientCapacity }
        _writeBits(UInt64(value.rawValue), count: width)
    }

    /// Writes the low `bitCount` bits (0 through 64) of `value`. The first bit written is the most
    /// significant of them for ``BitOrder/mostSignificantFirst``, the least significant otherwise.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ value: UInt64, bitCount: Int) throws(BytesError) {
        precondition(bitCount >= 0 && bitCount <= 64, "Bit count must be 0 through 64")
        _assumeInvariant()
        guard likely(remainingBitCount >= bitCount) else { throw .insufficientCapacity }
        guard bitCount > 0 else { return }
        let value = bitCount == 64 ? value : value & ((1 &<< UInt64(bitCount)) &- 1)
        if likely(bitCount <= 57) {
            _writeBits(value, count: bitCount)
            return
        }
        // Beyond 57 bits, the bits plus a partial byte (up to 7 bits) can exceed 64: write them in two parts.
        switch bitOrder {
        case .mostSignificantFirst:
            _writeBits(value &>> 32, count: bitCount &- 32)
            _writeBits(value & 0xFFFF_FFFF, count: 32)
        case .leastSignificantFirst:
            _writeBits(value & 0xFFFF_FFFF, count: 32)
            _writeBits(value &>> 32, count: bitCount &- 32)
        }
    }

    /// Writes `count` (1 through 57) bits of `value` (already masked) at the cursor. See the static version.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func _writeBits(_ value: UInt64, count: Int) {
        (_byteOffset, _bitOffset, _partial) = Self._writeBits(
            value, count: count, to: &_bytes, at: (_byteOffset, _bitOffset, _partial), bitOrder: bitOrder
        )
    }

    /// A writer's position: byte offset, bit offset, and the partly written byte (see `_partial`).
    @usableFromInline typealias _Position = (byteOffset: Int, bitOffset: Int, partial: UInt64)

    /// Writes `count` (1 through 57) bits of `value` (already masked) at a position: merges them with the
    /// partly written current byte, stores exactly the bytes they reach, and returns the new position.
    /// Capacity already checked. Bits past the end of the last byte written are zero.
    @inlinable @inline(__always)
    static func _writeBits(
        _ value: UInt64, count: Int, to span: inout MutableRawSpan, at position: _Position, bitOrder: BitOrder
    ) -> _Position {
        let bitOffset = position.bitOffset
        let total = bitOffset &+ count
        let byteCount = (total &+ 7) &>> 3
        let lastByte = total &>> 3 // The byte the write ends in, if it ends mid-byte.
        let partial: UInt64
        switch bitOrder {
        case .mostSignificantFirst:
            // Big-endian window: the current byte's high bits, then the new bits, then zeros.
            let window = position.partial &<< 56 | value &<< (64 &- total)
            unsafe Store.block(window.byteSwapped, count: byteCount, to: &span, at: position.byteOffset)
            partial = window &>> (56 &- 8 &* lastByte) & 0xFF
        case .leastSignificantFirst:
            // Little-endian window: the current byte's low bits, then the new bits above them.
            let window = position.partial | value &<< bitOffset
            unsafe Store.block(window, count: byteCount, to: &span, at: position.byteOffset)
            partial = window &>> (8 &* lastByte) & 0xFF
        }
        return (position.byteOffset &+ lastByte, total & 7, total & 7 == 0 ? 0 : partial)
    }
}

// MARK: - Custom types, standard library types, and spans

extension BytesWriter {
    /// Writes `value`'s raw bytes, in memory order. See ``ByteRepresentable``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteRepresentable>(_ value: T) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
        try store(value.rawBytes)
    }

    /// Writes `value`'s `MemoryLayout<T>.size` bytes in native byte order (little-endian on Apple
    /// platforms): the counterpart of ``BytesReader/load(_:)``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func store<T: ConvertibleToBytes & BitwiseCopyable>(_ value: T) throws(BytesError) {
        _assumeInvariant()
        let size = MemoryLayout<T>.size
        if likely(_bitOffset == 0) {
            guard likely(_bytes.byteCount &- _byteOffset >= size) else { throw .insufficientCapacity }
            unsafe Store.rawBytes(value, to: &_bytes, at: _byteOffset)
            _byteOffset &+= size
            return
        }
        guard remainingByteCount >= size else { throw .insufficientCapacity }
        let storage: InlineArray<1, T> = [value]
        let valueBytes = storage.span.bytes
        for index in 0..<size {
            _writeBits(UInt64(valueBytes.load(fromByteOffset: index, as: UInt8.self)), count: 8)
        }
    }

    /// Writes `bytes` as they are. Requires byte alignment.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func write(_ bytes: RawSpan) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= bytes.byteCount) else { throw .insufficientCapacity }
        let count = bytes.byteCount
        let offset = _byteOffset
        // Short spans (strings, small payloads) are copied inline with two overlapping loads and stores,
        // as `memcpy` does internally: a call would cost more than the copy. Longer ones call `memmove`.
        switch count {
        case 0:
            // An empty span may have no memory behind it (`Data().span`): nothing to copy, nothing to unwrap.
            return
        case 1...3:
            unsafe Self._copy(UInt8.self, from: bytes, 0, to: &_bytes, offset)
            unsafe Self._copy(UInt8.self, from: bytes, count &>> 1, to: &_bytes, offset)
            unsafe Self._copy(UInt8.self, from: bytes, count &- 1, to: &_bytes, offset)
        case 4...7:
            unsafe Self._copy(UInt32.self, from: bytes, 0, to: &_bytes, offset)
            unsafe Self._copy(UInt32.self, from: bytes, count &- 4, to: &_bytes, offset)
        case 8...16:
            unsafe Self._copy(UInt64.self, from: bytes, 0, to: &_bytes, offset)
            unsafe Self._copy(UInt64.self, from: bytes, count &- 8, to: &_bytes, offset)
        case 17...32:
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, 0, to: &_bytes, offset)
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, count &- 16, to: &_bytes, offset)
        default:
            // Unsafe: `memmove`. Safe: the capacity check above covers the destination, and the source is
            // the whole of `bytes`. The standard library has no safe copy from a `RawSpan` into a
            // `MutableRawSpan`, and a loop of checked moves would be far slower than `memmove` for long spans.
            _bytes.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    unsafe destination.baseAddress!.advanced(by: offset)
                        .copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
        _byteOffset &+= count
    }

    /// Copies the `T` at `sourceOffset` in `source` to the same offset after `offset` in `destination`.
    /// Bounds already checked.
    @unsafe @inlinable @inline(__always)
    static func _copy<T: ConvertibleFromBytes & ConvertibleToBytes & BitwiseCopyable>(
        _: T.Type, from source: RawSpan, _ sourceOffset: Int, to destination: inout MutableRawSpan, _ offset: Int
    ) {
        let value = unsafe source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset, as: T.self)
        unsafe destination.storeBytes(of: value, toUncheckedByteOffset: offset &+ sourceOffset, as: T.self)
    }

    /// Writes `bytes` as they are. Requires byte alignment.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func write(_ bytes: Span<UInt8>) throws(BytesError) {
        try write(bytes.bytes)
    }
}

// MARK: - Skipping and back-references

extension BytesWriter {
    /// Moves the cursor forward over `byteCount` bytes, leaving them as they are: for writing after a prefix
    /// that's already in place, such as a decompressor's history window. Requires byte alignment.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    public mutating func skip(byteCount: Int) throws(BytesError) {
        precondition(byteCount >= 0, "Negative byte count")
        precondition(_bitOffset == 0, "Skipping requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= byteCount) else { throw .insufficientCapacity }
        _byteOffset &+= byteCount
    }

    /// Writes `count` bytes copied from `distance` bytes back in what's been written: an LZ77
    /// back-reference, as in DEFLATE, LZ4, and Snappy. Requires byte alignment.
    ///
    /// When `count` exceeds `distance`, the copy reads bytes it has just written, repeating the last
    /// `distance` bytes, as those formats require (`distance` 1 repeats one byte).
    ///
    /// ```swift
    /// try writer.write(Byte(0x61))
    /// try writer.copy(fromDistance: 1, count: 4) // "aaaaa"
    /// ```
    ///
    /// Throws ``BytesError/invalidValue`` if `distance` is 0 or reaches before the start, and
    /// ``BytesError/insufficientCapacity`` if there isn't room; either way nothing is written. Copies in
    /// 16-, 8-, or 4-byte steps, with an overlapping last step, when `distance` allows it, and never writes
    /// past the `count` bytes.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    public mutating func copy(fromDistance distance: Int, count: Int) throws(BytesError) {
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Copying requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(distance > 0 && distance <= _byteOffset) else { throw .invalidValue }
        guard likely(_bytes.byteCount &- _byteOffset >= count) else { throw .insufficientCapacity }
        unsafe Self._copyBack(distance: distance, count: count, in: &_bytes, at: _byteOffset)
        _byteOffset &+= count
    }

    /// Writes the low `byteCount` bytes (0 through 8) of `value`, least significant first. With
    /// `allowingOverrun` and 8 bytes of room, it's one 8-byte store, overwriting the `8 - byteCount` bytes
    /// after them with arbitrary values: for decoders that produce a variable number of bytes at a time
    /// (two literals or one, an LZ4 literal run), with no branch on how many. Otherwise exact.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    public mutating func write(_ value: UInt64, byteCount: Int, allowingOverrun: Bool) throws(BytesError) {
        precondition(byteCount >= 0 && byteCount <= 8, "Byte count must be 0 through 8")
        precondition(_bitOffset == 0, "Writing bytes requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        if allowingOverrun, likely(_bytes.byteCount &- _byteOffset >= 8) {
            unsafe Store.little(value, to: &_bytes, at: _byteOffset)
        } else {
            guard likely(_bytes.byteCount &- _byteOffset >= byteCount) else { throw .insufficientCapacity }
            if byteCount > 0 { unsafe Store.block(value, count: byteCount, to: &_bytes, at: _byteOffset) }
        }
        _byteOffset &+= byteCount
    }

    /// The most bytes after a copy that ``copy(fromDistance:count:allowingOverrun:)`` may overwrite: keep
    /// this much room past the longest copy to always take its fast path.
    public static var copyOverrun: Int { 32 }

    /// Like ``copy(fromDistance:count:)``, but may also overwrite up to ``copyOverrun`` bytes after the copy
    /// with arbitrary values, when `allowingOverrun` and there's room for them. Use it when the bytes after
    /// the cursor are scratch, such as a decoder's output buffer.
    ///
    /// Then a copy of up to 32 bytes (most LZ77 matches) is two 16-byte moves, or four 8-byte moves for
    /// distances 8 to 15, whatever its length: straight-line code with no branch on the length for the
    /// processor to mispredict, as in libdeflate. Longer copies continue in a loop. Without room for the
    /// overrun, or for distances below 8, it copies exactly.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    public mutating func copy(fromDistance distance: Int, count: Int, allowingOverrun: Bool) throws(BytesError) {
        guard allowingOverrun, distance >= 8, likely(_bytes.byteCount &- _byteOffset >= count &+ Self.copyOverrun) else {
            try copy(fromDistance: distance, count: count)
            return
        }
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Copying requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(distance <= _byteOffset) else { throw .invalidValue }
        let source = _byteOffset &- distance
        let destination = _byteOffset
        // A move of n bytes at `index` reads up to `destination + index + n - distance`, at most
        // `destination + index` when `distance >= n`: bytes already final. Moves past `count` write only
        // the overrun.
        if distance >= 16 {
            unsafe Self._move(SIMD16<UInt8>.self, from: source, to: destination, in: &_bytes)
            unsafe Self._move(SIMD16<UInt8>.self, from: source &+ 16, to: destination &+ 16, in: &_bytes)
            var index = 32
            while index < count {
                unsafe Self._move(SIMD16<UInt8>.self, from: source &+ index, to: destination &+ index, in: &_bytes)
                index &+= 16
            }
        } else {
            unsafe Self._move(UInt64.self, from: source, to: destination, in: &_bytes)
            unsafe Self._move(UInt64.self, from: source &+ 8, to: destination &+ 8, in: &_bytes)
            unsafe Self._move(UInt64.self, from: source &+ 16, to: destination &+ 16, in: &_bytes)
            unsafe Self._move(UInt64.self, from: source &+ 24, to: destination &+ 24, in: &_bytes)
            var index = 32
            while index < count {
                unsafe Self._move(UInt64.self, from: source &+ index, to: destination &+ index, in: &_bytes)
                index &+= 8
            }
        }
        _byteOffset &+= count
    }

    /// Copies `count` bytes from `distance` before `offset` to `offset`, forward. Bounds already checked.
    ///
    /// Each step reads only bytes already final: a step of `n` bytes at `i` reads up to `offset + i + n -
    /// distance`, which is at most `offset + i` when `distance >= n`. The last step overlaps the one before
    /// it and rewrites the same values.
    @unsafe @inlinable @inline(always)
    static func _copyBack(distance: Int, count: Int, in bytes: inout MutableRawSpan, at offset: Int) {
        let source = offset &- distance
        if distance >= 16, count >= 16 {
            var index = 0
            while index < count &- 16 {
                unsafe _move(SIMD16<UInt8>.self, from: source &+ index, to: offset &+ index, in: &bytes)
                index &+= 16
            }
            unsafe _move(SIMD16<UInt8>.self, from: source &+ count &- 16, to: offset &+ count &- 16, in: &bytes)
        } else if distance >= 8, count >= 8 {
            var index = 0
            while index < count &- 8 {
                unsafe _move(UInt64.self, from: source &+ index, to: offset &+ index, in: &bytes)
                index &+= 8
            }
            unsafe _move(UInt64.self, from: source &+ count &- 8, to: offset &+ count &- 8, in: &bytes)
        } else if distance >= 4, count >= 4, count <= 8 {
            unsafe _move(UInt32.self, from: source, to: offset, in: &bytes)
            unsafe _move(UInt32.self, from: source &+ count &- 4, to: offset &+ count &- 4, in: &bytes)
        } else if distance == 1, count > 0 {
            let byte = bytes.load(fromByteOffset: source, as: UInt8.self)
            var run = bytes._mutatingExtracting(offset..<(offset &+ count))
            run.storeBytes(repeating: byte, count: count, as: UInt8.self) // `memset`
        } else {
            // Short distances: the pattern repeats every `distance` bytes, so each byte depends on one just
            // written. Byte by byte.
            for index in 0..<count {
                unsafe _move(UInt8.self, from: source &+ index, to: offset &+ index, in: &bytes)
            }
        }
    }

    @unsafe @inlinable @inline(always)
    static func _move<T: ConvertibleFromBytes & ConvertibleToBytes & BitwiseCopyable>(_: T.Type, from source: Int, to destination: Int, in bytes: inout MutableRawSpan) {
        let value = unsafe bytes.bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: source, as: T.self)
        unsafe bytes.storeBytes(of: value, toUncheckedByteOffset: destination, as: T.self)
    }
}

// MARK: - Bulk

// The generating forms (`count:` plus a closure from index to value) are the write-side counterpart of
// `BytesReader.forEach`: always inlined, so the closure is fused into one counted loop with a single capacity
// check, and nothing is staged in memory first. The span forms are thin wrappers over them. The closures
// can't throw: capacity is checked once up front, so a write either happens in full or not at all.
// Values too large for `T` are truncated without a check here, unlike single writes in debug builds: a
// check in the loop would stop it vectorizing.

extension BytesWriter {
    /// Writes `count` values as `T` in `byteOrder`, each produced by `value` from its index, in order.
    /// Values too large for `T` are truncated to its low bytes, unchecked.
    ///
    /// ```swift
    /// try writer.write(Byte4.self, .bigEndian, count: records.count) { records[$0].id }
    /// ```
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteGroup>(
        _: T.Type, _ byteOrder: ByteOrder, count: Int, _ value: (Int) -> T.Integer
    ) throws(BytesError) {
        precondition(count >= 0, "Negative count")
        _assumeInvariant()
        guard likely(remainingByteCount / T.byteCount >= count) else { throw .insufficientCapacity }
        guard likely(_bitOffset == 0) else {
            for index in 0..<count {
                try write(T(value(index), byteOrder)) // Truncating, like the aligned path.
            }
            return
        }
        let start = _byteOffset
        // One loop per byte order, so each is straight-line conversion and stores. With the `NEONShuffle`
        // trait, odd widths first pack whole steps with table lookups; the loops finish the rest.
        var packed = 0
        switch byteOrder {
        case .littleEndian:
            #if NEONShuffle
            if Shuffle.handles(T.self) {
                packed = unsafe Shuffle.pack(T.self, bigEndian: false, count: count, to: &_bytes, at: start, value)
            }
            #endif
            for index in packed..<count {
                unsafe Store.streamingGroup(T(littleEndian: value(index)), to: &_bytes, at: start &+ index &* T.byteCount)
            }
        case .bigEndian:
            #if NEONShuffle
            if Shuffle.handles(T.self) {
                packed = unsafe Shuffle.pack(T.self, bigEndian: true, count: count, to: &_bytes, at: start, value)
            }
            #endif
            for index in packed..<count {
                unsafe Store.streamingGroup(T(bigEndian: value(index)), to: &_bytes, at: start &+ index &* T.byteCount)
            }
        }
        _byteOffset &+= count &* T.byteCount
    }

    /// Writes each of `values` as a `T` in `byteOrder`, truncated to its low bytes, unchecked.
    ///
    /// ```swift
    /// try writer.write(offsets.span, as: Byte4.self, .bigEndian)
    /// ```
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteGroup>(_ values: Span<T.Integer>, as _: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        try write(T.self, byteOrder, count: values.count) { unsafe values[unchecked: $0] }
    }

    /// Writes `count` values of `width` bits, packed in ``bitOrder``, each produced by `value` from its
    /// index, in order.
    ///
    /// Writing bits one at a time is inherently sequential: each write merges with the byte the previous
    /// one left partly written. This packs whole blocks instead (one byte when `width` divides 8, otherwise
    /// 8 values into `width` bytes) with constant shifts, in a counted loop that vectorizes.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<let width: Int>(
        _: Bits<width>.Type, count: Int, _ value: (Int) -> Bits<width>
    ) throws(BytesError) {
        Bits<width>._checkWidth()
        precondition(count >= 0, "Negative count")
        _assumeInvariant()
        let (bitCount, overflow) = count.multipliedReportingOverflow(by: width)
        guard !overflow, likely(remainingBitCount >= bitCount) else { throw .insufficientCapacity }
        var index = 0
        if likely(_bitOffset == 0) {
            let start = _byteOffset
            let order = bitOrder
            if 8 % width == 0 {
                let perByte = 8 / width
                let byteCount = count / perByte
                for byte in 0..<byteCount {
                    var packed: UInt8 = 0
                    for slot in 0..<perByte {
                        let shift = order == .mostSignificantFirst ? 8 &- width &* (slot &+ 1) : width &* slot
                        packed |= value(byte &* perByte &+ slot).rawValue &<< shift
                    }
                    unsafe _bytes.storeBytes(of: packed, toUncheckedByteOffset: start &+ byte, as: UInt8.self)
                }
                index = byteCount &* perByte
                _byteOffset &+= byteCount
            } else {
                let blockCount = count / 8
                for block in 0..<blockCount {
                    var packed: UInt64 = 0
                    for slot in 0..<8 {
                        let shift = order == .mostSignificantFirst ? 8 &* width &- width &* (slot &+ 1) : width &* slot
                        packed |= UInt64(value(block &* 8 &+ slot).rawValue) &<< shift
                    }
                    let littleEndian = order == .mostSignificantFirst
                        ? packed.byteSwapped &>> (64 &- 8 &* width) // The block's bytes, first byte lowest.
                        : packed
                    unsafe Store.block(littleEndian, count: width, to: &_bytes, at: start &+ block &* width)
                }
                index = blockCount &* 8
                _byteOffset &+= blockCount &* width
            }
        }
        while index < count {
            _writeBits(UInt64(value(index).rawValue), count: width)
            index &+= 1
        }
    }

    /// Writes each of `values`, packed, in ``bitOrder``.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<let width: Int>(_ values: Span<Bits<width>>) throws(BytesError) {
        try write(Bits<width>.self, count: values.count) { unsafe values[unchecked: $0] }
    }

    /// Writes `count` values' raw bytes, each produced by `value` from its index, in order.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteRepresentable>(
        _: T.Type, count: Int, _ value: (Int) -> T
    ) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
        precondition(count >= 0, "Negative count")
        _assumeInvariant()
        let size = MemoryLayout<T.RawBytes>.size
        precondition(size > 0, "\(T.self).RawBytes has no bytes") // Constant-folded.
        guard likely(remainingByteCount / size >= count) else { throw .insufficientCapacity }
        guard likely(_bitOffset == 0) else {
            for index in 0..<count { try write(value(index)) }
            return
        }
        let start = _byteOffset
        for index in 0..<count {
            unsafe Store.rawBytes(value(index).rawBytes, to: &_bytes, at: start &+ index &* size)
        }
        _byteOffset &+= count &* size
    }

    /// Writes each of `values`' raw bytes.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ByteRepresentable>(_ values: Span<T>) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
        try write(T.self, count: values.count) { unsafe values[unchecked: $0] }
    }

    /// Writes `count` values of `T` in place: `body` fills a typed view of the next `count` values' bytes,
    /// then the writer moves past them. The counterpart of ``BytesReader/read(_:count:)``: together they
    /// let a loop go from one typed span to another, which is the shape the compiler vectorizes best.
    ///
    /// ```swift
    /// // Base64: 3 bytes in, 4 characters out, per element. Compiles to NEON `ld3`/`st4`.
    /// let groups = try reader.read(InlineArray<3, UInt8>.self, count: count / 3)
    /// try writer.write(InlineArray<4, UInt8>.self, count: groups.count, filling: { output in
    ///     for index in groups.indices { output[index] = encode(groups[index]) }
    /// })
    /// ```
    ///
    /// The view starts with whatever bytes were there; `body` should set every element. `T` must accept any
    /// bytes (`ConvertibleFromBytes`) and be storable as bytes (`ConvertibleToBytes`): integers, `SIMD`
    /// vectors, and `InlineArray`s of them. Requires byte alignment.
    ///
    /// Throws ``BytesError/insufficientCapacity`` if there isn't room, and ``BytesError/misaligned`` if the
    /// bytes aren't aligned for `T` (never for types with an alignment of 1, such as `InlineArray<N, UInt8>`).
    /// Either way, `body` isn't called and nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write<T: ConvertibleFromBytes & ConvertibleToBytes, R: ~Copyable>(
        _: T.Type, count: Int, filling body: (inout MutableSpan<T>) -> R
    ) throws(BytesError) -> R {
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !overflow, likely(_bytes.byteCount &- _byteOffset >= byteCount) else { throw .insufficientCapacity }
        var bytes = _bytes._mutatingExtracting(_byteOffset..<(_byteOffset &+ byteCount))
        if MemoryLayout<T>.alignment > 1, byteCount > 0 {
            let address = bytes.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            guard address & UInt(MemoryLayout<T>.alignment &- 1) == 0 else { throw .misaligned }
        }
        var values = MutableSpan<T>(mutating: &bytes)
        let result = body(&values)
        _byteOffset &+= byteCount
        return result
    }
}

// MARK: - Writing into uninitialized memory

extension OutputSpan where Element == UInt8 {
    /// Appends what `body` writes with a ``BytesWriter`` over the free capacity. Only the bytes written are
    /// added; if `body` throws, nothing is.
    ///
    /// ```swift
    /// let bytes = try [UInt8](capacity: 1_024) { output in
    ///     try output.withBytesWriter { writer in try writer.write(header) }
    /// }
    /// ```
    @inlinable
    @_lifetime(self: copy self)
    public mutating func withBytesWriter<R: ~Copyable, E: Error>(
        bitOrder: BitOrder = .mostSignificantFirst,
        _ body: (inout BytesWriter) throws(E) -> R
    ) throws(E) -> R {
        // Unsafe: a span over the output's uninitialized capacity, which no safe API exposes. Safe: the span
        // covers exactly that capacity and ends with the closure; `UInt8` needs no initialization beyond the
        // stores, and only the bytes the writer reports writing are counted as initialized.
        try unsafe withUnsafeMutableBufferPointer { (buffer, initializedCount) throws(E) -> R in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[initializedCount...])
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: free), bitOrder: bitOrder)
            let result = try body(&writer)
            initializedCount &+= writer.byteCount
            return result
        }
    }
}

extension OutputRawSpan {
    /// Appends what `body` writes with a ``BytesWriter`` over the free capacity. Only the bytes written are
    /// added; if `body` throws, nothing is.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func withBytesWriter<R: ~Copyable, E: Error>(
        bitOrder: BitOrder = .mostSignificantFirst,
        _ body: (inout BytesWriter) throws(E) -> R
    ) throws(E) -> R {
        // Unsafe and safe as for `OutputSpan<UInt8>` above.
        try unsafe withUnsafeMutableBytes { (buffer, initializedCount) throws(E) -> R in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...])
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: free), bitOrder: bitOrder)
            let result = try body(&writer)
            initializedCount &+= writer.byteCount
            return result
        }
    }
}

// MARK: - Unchecked stores

/// Unchecked stores into a mutable span, mirroring ``Load``. Callers check capacity first. Every store
/// stays within `offset ..< offset + count`.
///
/// Unsafe for the same reason as ``Load``, with the same guarantee: each caller has checked the capacity
/// for everything it stores. `MutableRawSpan`'s checked `storeBytes` measured 42–144% more instructions
/// writing odd widths (`Byte3`, `Byte5`–`Byte15`), 28–47% more for packed bit fields, because its checks
/// aren't folded into the writer's. The copies below (``BytesWriter/_copy(_:from:_:to:_:)``, `_move`) are
/// unchecked for the same reason; the match copies they make are DEFLATE's hottest loop.
@usableFromInline @unsafe
enum Store {
    @inlinable @inline(__always)
    static func little<I: FixedWidthInteger & ConvertibleToBytes & BitwiseCopyable>(_ value: I, to bytes: inout MutableRawSpan, at offset: Int) {
        unsafe bytes.storeBytes(of: value.littleEndian, toUncheckedByteOffset: offset, as: I.self)
    }

    /// The low `count` (1 through 8) bytes of `value`, least significant first. Odd counts use two
    /// overlapping stores of the next size down, which write the shared bytes twice with the same values.
    @inlinable @inline(__always)
    static func block(_ value: UInt64, count: Int, to bytes: inout MutableRawSpan, at offset: Int) {
        switch count {
        case 1:
            unsafe little(UInt8(truncatingIfNeeded: value), to: &bytes, at: offset)
        case 2:
            unsafe little(UInt16(truncatingIfNeeded: value), to: &bytes, at: offset)
        case 3:
            unsafe little(UInt16(truncatingIfNeeded: value), to: &bytes, at: offset)
            unsafe little(UInt16(truncatingIfNeeded: value &>> 8), to: &bytes, at: offset &+ 1)
        case 4:
            unsafe little(UInt32(truncatingIfNeeded: value), to: &bytes, at: offset)
        case 5, 6, 7:
            unsafe little(UInt32(truncatingIfNeeded: value), to: &bytes, at: offset)
            unsafe little(UInt32(truncatingIfNeeded: value &>> (8 &* (count &- 4))), to: &bytes, at: offset &+ count &- 4)
        default:
            unsafe little(value, to: &bytes, at: offset)
        }
    }

    /// `value`'s `T.byteCount` bytes, in memory order.
    @inlinable @inline(__always)
    static func group<T: ByteGroup>(_ value: T, to bytes: inout MutableRawSpan, at offset: Int) {
        let count = T.byteCount
        let littleEndian = value.littleEndian
        switch count {
        case 2...8:
            unsafe block(UInt64(truncatingIfNeeded: littleEndian), count: count, to: &bytes, at: offset)
        case 16:
            unsafe little(UInt128(truncatingIfNeeded: littleEndian), to: &bytes, at: offset)
        case 9...15:
            let wide = UInt128(truncatingIfNeeded: littleEndian)
            unsafe little(UInt64(truncatingIfNeeded: wide), to: &bytes, at: offset)
            unsafe little(UInt64(truncatingIfNeeded: wide &>> (8 &* (count &- 8))), to: &bytes, at: offset &+ count &- 8)
        default:
            preconditionFailure("\(T.self).byteCount must be 2 through 16")
        }
    }

    /// Like ``group(_:to:at:)``, tuned for loops over consecutive groups: three-byte groups store each byte
    /// separately, which vectorizes as NEON `st3`, like ``Load/streamingGroup(_:from:at:)``.
    @inlinable @inline(__always)
    static func streamingGroup<T: ByteGroup>(_ value: T, to bytes: inout MutableRawSpan, at offset: Int) {
        guard T.byteCount == 3 else { return unsafe group(value, to: &bytes, at: offset) }
        let littleEndian = UInt32(truncatingIfNeeded: value.littleEndian)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian), to: &bytes, at: offset)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian &>> 8), to: &bytes, at: offset &+ 1)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian &>> 16), to: &bytes, at: offset &+ 2)
    }

    /// `value`'s bytes. Integer-sized values are stored as that integer (through `bitCast`), like
    /// ``Load/rawBytes(_:from:at:)``; other sizes directly.
    @inlinable @inline(__always)
    static func rawBytes<R: ConvertibleToBytes & BitwiseCopyable>(_ value: R, to bytes: inout MutableRawSpan, at offset: Int) {
        switch MemoryLayout<R>.size {
        case 1: unsafe bytes.storeBytes(of: bitCast(value, to: UInt8.self), toUncheckedByteOffset: offset, as: UInt8.self)
        case 2: unsafe bytes.storeBytes(of: bitCast(value, to: UInt16.self), toUncheckedByteOffset: offset, as: UInt16.self)
        case 4: unsafe bytes.storeBytes(of: bitCast(value, to: UInt32.self), toUncheckedByteOffset: offset, as: UInt32.self)
        case 8: unsafe bytes.storeBytes(of: bitCast(value, to: UInt64.self), toUncheckedByteOffset: offset, as: UInt64.self)
        case 16: unsafe bytes.storeBytes(of: bitCast(value, to: UInt128.self), toUncheckedByteOffset: offset, as: UInt128.self)
        default: unsafe bytes.storeBytes(of: value, toUncheckedByteOffset: offset, as: R.self)
        }
    }
}
