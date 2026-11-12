/// A cursor that writes binary data into borrowed memory, field by field, at bit or byte granularity: the
/// counterpart of ``BytesReader``.
///
/// ```swift
/// let packet = try [UInt8](byteCapacity: 64) { writer in
///     try writer.write(0x50_4B_03_04 as Byte4)
///     try writer.write(20, as: Byte2.self, .littleEndian)
///     try writer.write(Nibble(0b0011))
///     try writer.write(Nibble(0b0000))
/// }
/// ```
///
/// Writes are packed like reads: after a bit-level write, multi-byte writes continue mid-byte, each byte
/// made of the next 8 bits in ``bitOrder``; ``alignToByte()`` pads to the next byte with zeros. A bit-level
/// write zeroes the rest of the byte it ends in, which is what appending wants.
///
/// Every write stays within the bytes it writes (odd widths use two overlapping stores, never a wider
/// one), so a writer over existing data never touches memory past the byte its cursor is in. The
/// exceptions are the section writers, whose `body` writes ahead of the length, and the `allowingOverrun`
/// forms, which may overwrite scratch bytes after what they write.
///
/// A single value too large for the field it's written as (`write(0x0100_0000, as: Byte3.self,
/// .bigEndian)`) is a programming error: debug builds trap, and release builds write the low bytes. Bulk
/// and generating writes always write the low bytes, unchecked, so their loops vectorize, and so does
/// ``write(_:bitCount:)``, by design, like `init(truncatingIfNeeded:)`.
///
/// A write that throws (``BytesError/insufficientCapacity``, or ``BytesError/invalidValue`` and
/// ``BytesError/misaligned`` where documented) writes nothing and doesn't move the cursor.
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
    ///
    /// - Parameters:
    ///   - bytes: The memory to write into; the writer's capacity is its length.
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
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
    ///
    /// - Parameters:
    ///   - bytes: The memory to write into; the writer's capacity is its length.
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    @inlinable
    @_lifetime(&bytes)
    public init(_ bytes: inout MutableSpan<UInt8>, bitOrder: BitOrder = .mostSignificantFirst) {
        self.init(MutableRawSpan(mutating: &bytes), bitOrder: bitOrder)
    }

    /// Creates a writer over `bytes` whose first `offset` bytes are already written (a prefix, or a
    /// decompressor's history window): the next write is at `offset`, and ``byteCount`` and
    /// ``writtenBytes`` include them. For resuming into a buffer passed `inout`, without reborrowing it.
    ///
    /// ```swift
    /// var writer = try BytesWriter(&output, atByteOffset: end)
    /// ```
    ///
    /// Always inlined: as a call, NativeZip's decode loop received the writer through memory (its function
    /// grew from 789 to 891 instructions).
    ///
    /// - Parameters:
    ///   - bytes: The memory to write into, borrowed for the writer's lifetime.
    ///   - offset: The number of bytes already written, 0 through `bytes.byteCount`.
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    /// - Throws: ``BytesError/invalidValue`` if `offset` is negative,
    ///   ``BytesError/insufficientCapacity`` if it's past the end of `bytes`.
    @inlinable @inline(__always)
    @_lifetime(&bytes)
    public init(_ bytes: inout MutableRawSpan, atByteOffset offset: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError) {
        guard offset >= 0 else { throw .invalidValue }
        guard offset <= bytes.byteCount else { throw .insufficientCapacity }
        self.init(bytes._mutatingExtracting(...), bitOrder: bitOrder)
        _byteOffset = offset
    }
}

// MARK: - Position

public extension BytesWriter {
    /// The number of bytes written so far, including a partly written last byte.
    @inlinable
    var byteCount: Int { _byteOffset &+ (_bitOffset == 0 ? 0 : 1) }

    /// The offset of the byte the next write starts in.
    @inlinable
    var byteOffset: Int { _byteOffset }

    /// The number of bits already written into the byte at ``byteOffset``, from 0 through 7.
    @inlinable
    var bitOffset: Int { _bitOffset }

    /// The capacity, in bytes.
    @inlinable
    var capacity: Int { _bytes.byteCount }

    /// The number of bits that can still be written.
    @inlinable
    var remainingBitCount: Int { (_bytes.byteCount &- _byteOffset) &<< 3 &- _bitOffset }

    /// The number of whole bytes that can still be written. A partly written byte doesn't count.
    @inlinable
    var remainingByteCount: Int { _bytes.byteCount &- _byteOffset &- (_bitOffset == 0 ? 0 : 1) }

    /// Whether the next write starts at the beginning of a byte.
    @inlinable
    var isByteAligned: Bool { _bitOffset == 0 }

    /// Whether every bit has been written.
    @inlinable
    var isFull: Bool { _byteOffset == _bytes.byteCount }

    /// The bytes written so far.
    @inlinable
    var writtenBytes: RawSpan {
        @_lifetime(borrow self)
        get { _bytes.bytes.extracting(first: byteCount) }
    }

    /// A place in the output this writer was at: see ``position`` and ``rewind(to:)``.
    struct Position: Hashable, Sendable {
        /// The offset of the byte the next write started in.
        public let byteOffset: Int
        /// The bits already written into that byte, from 0 through 7.
        public let bitOffset: Int
        /// That byte as written so far.
        @usableFromInline let _partial: UInt64

        @inlinable
        init(byteOffset: Int, bitOffset: Int, partial: UInt64) {
            self.byteOffset = byteOffset
            self.bitOffset = bitOffset
            _partial = partial
        }

        /// The position in bits: `8 × byteOffset + bitOffset`.
        @inlinable
        public var bitPosition: Int { byteOffset &<< 3 | bitOffset }
    }

    /// Where the next write starts, to come back to with ``rewind(to:)``.
    @inlinable
    var position: Position { Position(byteOffset: _byteOffset, bitOffset: _bitOffset, partial: _partial) }

    /// Moves back to `position`, taken from this writer's ``position`` earlier: everything written after it
    /// no longer counts (``byteCount`` and ``writtenBytes`` end there, and the array builders keep only what's
    /// before it). For writes that turn out to be invalid partway, such as a decoder that finds a bad
    /// character after writing what came before it. Two or three stores; it can't fail.
    ///
    /// ```swift
    /// let start = writer.position
    /// do throws(BytesError) {
    ///     try writeMessage(&writer)
    /// } catch {
    ///     writer.rewind(to: start)   // All or nothing.
    ///     throw error
    /// }
    /// ```
    ///
    /// The bytes after `position` keep whatever was written there until they're written again.
    ///
    /// - Parameter position: A ``position`` this writer returned earlier.
    /// - Precondition: `position` is at or before the current position.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func rewind(to position: Position) {
        // Keeps the invariant: a position no later than this writer's is within its span, and a `Position`
        // only comes from a writer, so its bit offset is 0 through 7.
        precondition(position.bitPosition <= _byteOffset &<< 3 | _bitOffset, "Rewinding to a position after the writer")
        _byteOffset = position.byteOffset
        _bitOffset = position.bitOffset
        _partial = position._partial
    }

    /// Pads with zero bits to the start of the next byte, unless already at the start of one.
    @inlinable
    @_lifetime(self: copy self)
    mutating func alignToByte() {
        // Bit writes zero the rest of the byte they end in, so the padding is already there.
        if _bitOffset != 0 {
            _byteOffset &+= 1
            _bitOffset = 0
            _partial = 0
        }
    }

    /// See ``BytesReader/_assumeInvariant()``; the same reasoning applies.
    @inlinable @inline(__always)
    internal func _assumeInvariant() {
        unsafe assume(_byteOffset <= _bytes.byteCount)
        unsafe assume(_bitOffset >= 0)
        unsafe assume(_bitOffset < 8)
    }
}

// MARK: - Byte groups

public extension BytesWriter {
    /// Writes `value`'s `T.byteCount` bytes, in memory order. Works mid-byte after a bit-level write.
    ///
    /// - Parameter value: The byte group to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `T.byteCount` whole bytes remain.
    ///   Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteGroup>(_ value: T) throws(BytesError) {
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
    ///
    /// - Parameters:
    ///   - value: The integer to write. It should fit in `T.byteCount` bytes: debug builds trap if it
    ///     doesn't, release builds write its low bytes.
    ///   - type: The ``ByteGroup`` type, which sets the width.
    ///   - byteOrder: The order to write the bytes in.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `T.byteCount` whole bytes remain.
    ///   Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteGroup>(_ value: T.Integer, as _: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        assert(value <= T._mask, "\(value) doesn't fit in \(T.byteCount) bytes")
        try write(T(value, byteOrder))
    }

    /// Writes `count` bytes of `bytes` (little-endian: first byte lowest) when not byte-aligned, each as the
    /// next 8 bits. Capacity already checked.
    ///
    /// Out of line and static, taking the offsets as values: a `mutating` method would need the writer's
    /// address, keeping it in memory in every caller (its offset stored every iteration of a write loop)
    /// and hiding from the optimizer that the bit offset stays zero, so loops couldn't vectorize.
    ///
    /// - Parameters:
    ///   - bytes: The bytes, first byte in the lowest bits.
    ///   - count: The number of bytes, 1 through 16.
    ///   - span: The memory written to.
    ///   - position: The cursor's byte offset, bit offset, and partly written byte.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The new position.
    @usableFromInline
    internal static func _writeUnalignedBytes(
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
    ///
    /// - Parameter value: The bits to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `width` bits remain. Nothing is written.
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

    /// Writes `flag` as one bit: 1 for `true`.
    ///
    /// ```swift
    /// try writer.write(reading.timestamp != nil)
    /// ```
    ///
    /// Several flags that fill a byte are cheaper packed into one ``Byte`` first (`[bit:]`), then written
    /// once.
    ///
    /// - Parameter flag: The flag to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if no bit remains. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ flag: Bool) throws(BytesError) {
        try write(Bit(flag))
    }

    /// Writes the low `bitCount` bits of `value`. The first bit written is the most significant of them for
    /// ``BitOrder/mostSignificantFirst``, the least significant otherwise. Higher bits of `value` are
    /// ignored.
    ///
    /// - Parameters:
    ///   - value: The integer whose low bits are written.
    ///   - bitCount: The number of bits, 0 through 64.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `bitCount` bits remain. Nothing is
    ///   written.
    /// - Precondition: `bitCount` is 0 through 64.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func write(_ value: UInt64, bitCount: Int) throws(BytesError) {
        precondition(bitCount >= 0 && bitCount <= 64, "Bit count must be 0 through 64")
        _assumeInvariant()
        guard likely(remainingBitCount >= bitCount) else { throw .insufficientCapacity }
        guard bitCount > 0 else { return }
        // Not `keepingLowBits(bitCount)`, though it's the same value: with a run-time `bitCount`, LLVM then
        // split this function's paths differently, and a loop of these writes grew from 146 to 169
        // instructions (the mask alone is shorter, 6 against 8).
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

    /// Writes `count` bits of `value` at the cursor. See the static version.
    ///
    /// - Parameters:
    ///   - value: The bits, already masked to `count` bits.
    ///   - count: The number of bits, 1 through 57.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func _writeBits(_ value: UInt64, count: Int) {
        (_byteOffset, _bitOffset, _partial) = Self._writeBits(
            value, count: count, to: &_bytes, at: (_byteOffset, _bitOffset, _partial), bitOrder: bitOrder
        )
    }

    /// A writer's position: byte offset, bit offset, and the partly written byte (see `_partial`).
    @usableFromInline typealias _Position = (byteOffset: Int, bitOffset: Int, partial: UInt64)

    /// Writes bits at a position: merges them with the partly written current byte and stores exactly the
    /// bytes they reach. Capacity already checked. Bits past the end of the last byte written are zero.
    ///
    /// - Parameters:
    ///   - value: The bits, already masked to `count` bits.
    ///   - count: The number of bits, 1 through 57.
    ///   - span: The memory written to.
    ///   - position: The cursor's byte offset, bit offset, and partly written byte.
    ///   - bitOrder: The order of bits within each byte.
    /// - Returns: The new position.
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

public extension BytesWriter {
    /// Writes `value`'s raw bytes, in memory order. See ``ByteRepresentable``.
    ///
    /// - Parameter value: The value to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer whole bytes remain than `value`'s raw bytes.
    ///   Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteRepresentable>(_ value: T) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
        try store(value.rawBytes)
    }

    /// Writes `value`'s `MemoryLayout<T>.size` bytes in native byte order (little-endian on Apple
    /// platforms): the counterpart of ``BytesReader/load(_:)``.
    ///
    /// - Parameter value: The value to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `MemoryLayout<T>.size` whole bytes
    ///   remain. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func store<T: ConvertibleToBytes & BitwiseCopyable>(_ value: T) throws(BytesError) {
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
    ///
    /// Always inlined, with copies of more than 64 bytes out of line: as a call, the whole function cost each
    /// short copy a call and its cursor a trip through memory (MQTT's encoder made three per packet).
    ///
    /// - Parameter bytes: The bytes to copy.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `bytes.byteCount` bytes remain. Nothing is
    ///   written.
    /// - Precondition: The writer is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ bytes: RawSpan) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing a span requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        guard likely(_bytes.byteCount &- _byteOffset >= bytes.byteCount) else { throw .insufficientCapacity }
        let count = bytes.byteCount
        let offset = _byteOffset
        // Short spans (strings, small payloads, a block kernel's last block) are copied inline with
        // overlapping loads and stores, as `memcpy` does internally: a call would cost more than the copy
        // (Base64's 47-byte inputs took 43% longer with `memmove` for their 33-to-64-byte copies). Longer
        // ones call `memmove`, out of line.
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
        case 33...64:
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, 0, to: &_bytes, offset)
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, 16, to: &_bytes, offset)
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, count &- 32, to: &_bytes, offset)
            unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, count &- 16, to: &_bytes, offset)
        default:
            unsafe Self._copyLong(bytes, to: &_bytes, at: offset)
        }
        _byteOffset &+= count
    }

    /// Copies all of `source` to `offset` in `destination` with `memmove`. Capacity already checked.
    ///
    /// Unsafe: `memmove`. Safe: the caller's capacity check covers the destination, and the source is the
    /// whole of `source`. The standard library has no safe copy from a `RawSpan` into a `MutableRawSpan`, and
    /// a loop of checked moves would be far slower than `memmove` for long spans. Out of line and static,
    /// like the other slow paths, so the inlined `write(_: RawSpan)` stays small.
    ///
    /// - Parameters:
    ///   - source: The bytes to copy.
    ///   - destination: The memory written to.
    ///   - offset: Where in `destination` the copy starts.
    @unsafe @usableFromInline @inline(never)
    internal static func _copyLong(_ source: RawSpan, to destination: inout MutableRawSpan, at offset: Int) {
        destination.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { source in
                unsafe destination.baseAddress!.advanced(by: offset)
                    .copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
    }

    /// Copies the `T` at `sourceOffset` in `source` to the same offset after `offset` in `destination`.
    /// Bounds already checked.
    ///
    /// - Parameters:
    ///   - type: The type copied, which sets the number of bytes.
    ///   - source: The bytes to copy from.
    ///   - sourceOffset: Where in `source` to read.
    ///   - destination: The memory written to.
    ///   - offset: The destination offset to which `sourceOffset` is added.
    @unsafe @inlinable @inline(__always)
    internal static func _copy<T: ConvertibleFromBytes & ConvertibleToBytes & BitwiseCopyable>(
        _: T.Type, from source: RawSpan, _ sourceOffset: Int, to destination: inout MutableRawSpan, _ offset: Int
    ) {
        let value = unsafe source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset, as: T.self)
        unsafe destination.storeBytes(of: value, toUncheckedByteOffset: offset &+ sourceOffset, as: T.self)
    }

    /// Writes `bytes` as they are. Requires byte alignment.
    ///
    /// - Parameter bytes: The bytes to copy.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `bytes.count` bytes remain. Nothing is
    ///   written.
    /// - Precondition: The writer is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write(_ bytes: Span<UInt8>) throws(BytesError) {
        try write(bytes.bytes)
    }
}

// MARK: - Skipping and back-references

public extension BytesWriter {
    /// Moves the cursor forward over `byteCount` bytes, leaving them as they are: for writing after a prefix
    /// that's already in place, such as a decompressor's history window. Requires byte alignment.
    ///
    /// - Parameter byteCount: The number of bytes to skip, 0 or more.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `byteCount` bytes remain. The cursor
    ///   doesn't move.
    /// - Precondition: `byteCount` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func skip(byteCount: Int) throws(BytesError) {
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
    /// Copies in 16-, 8-, or 4-byte steps, with an overlapping last step, when `distance` allows it;
    /// distances below 8 repeat the last `distance` bytes 16 bytes at a time, as
    /// ``write(repeating:byteCount:count:)`` does. Never writes past the `count` bytes.
    ///
    /// - Parameters:
    ///   - distance: How far back the copy starts, in bytes: 1 through ``byteOffset``.
    ///   - count: The number of bytes to write, 0 or more.
    /// - Throws: ``BytesError/invalidValue`` if `distance` is 0 or reaches before the start of the buffer,
    ///   ``BytesError/insufficientCapacity`` if fewer than `count` bytes remain. Nothing is written.
    /// - Precondition: `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func copy(fromDistance distance: Int, count: Int) throws(BytesError) {
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
    ///
    /// - Parameters:
    ///   - value: The integer whose low bytes are written.
    ///   - byteCount: The number of bytes to write, 0 through 8. The cursor advances by this much.
    ///   - allowingOverrun: Whether the `8 - byteCount` bytes after the written ones may be overwritten with
    ///     arbitrary values, when 8 bytes of room remain.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `byteCount` bytes remain. Nothing is
    ///   written.
    /// - Precondition: `byteCount` is 0 through 8, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func write(_ value: UInt64, byteCount: Int, allowingOverrun: Bool) throws(BytesError) {
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
    static var copyOverrun: Int { 32 }

    /// Like ``copy(fromDistance:count:)``, but may also overwrite up to ``copyOverrun`` bytes after the copy
    /// with arbitrary values, when `allowingOverrun` and there's room for them. Use it when the bytes after
    /// the cursor are scratch, such as a decoder's output buffer.
    ///
    /// Then a copy of up to 32 bytes (most LZ77 matches) is two 16-byte moves, or four 8-byte moves for
    /// distances 8 to 15, whatever its length: straight-line code with no branch on the length for the
    /// processor to mispredict, as in libdeflate. Longer copies continue in a loop. Without room for the
    /// overrun, or for distances below 8, it copies exactly.
    ///
    /// - Parameters:
    ///   - distance: How far back the copy starts, in bytes: 1 through ``byteOffset``.
    ///   - count: The number of bytes to write, 0 or more.
    ///   - allowingOverrun: Whether bytes after the copy may be overwritten.
    /// - Throws: ``BytesError/invalidValue`` if `distance` is 0 or reaches before the start of the buffer,
    ///   ``BytesError/insufficientCapacity`` if fewer than `count` bytes remain. Nothing is written.
    /// - Precondition: `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func copy(fromDistance distance: Int, count: Int, allowingOverrun: Bool) throws(BytesError) {
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
    ///
    /// - Parameters:
    ///   - distance: How far back the copy starts, in bytes.
    ///   - count: The number of bytes to write.
    ///   - bytes: The memory copied within.
    ///   - offset: Where the copy is written.
    @unsafe @inlinable @inline(always)
    internal static func _copyBack(distance: Int, count: Int, in bytes: inout MutableRawSpan, at offset: Int) {
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
        } else if distance < 8, count > 0 {
            unsafe _copyRepeating(distance: distance, count: count, in: &bytes, at: offset)
        } else {
            // At least 8 back but fewer than 4 bytes: byte by byte.
            for index in 0..<count {
                unsafe _move(UInt8.self, from: source &+ index, to: offset &+ index, in: &bytes)
            }
        }
    }

    /// A back-reference 2 to 7 bytes back: it repeats the last `distance` bytes, so it's a run of them, as
    /// `write(repeating:)` writes: load them once and store 16 bytes at a time. (Copied a byte at a time,
    /// each byte depended on one just written.) Bounds already checked.
    ///
    /// Out of line, like the other slow paths: inlined, the fill made DEFLATE's decode loop 15% longer
    /// (743 → 853 instructions) and cost 12–14% more instructions on text, whose matches are almost all 8 or
    /// more bytes back. Distance 1 stays a `memset` in the caller: through this function's call, short runs
    /// gained nothing and long ones cost 21% more.
    ///
    /// - Parameters:
    ///   - distance: How far back the run starts, 2 through 7.
    ///   - count: The number of bytes to write.
    ///   - bytes: The memory copied within.
    ///   - offset: Where the copy is written.
    @unsafe @usableFromInline @inline(never)
    internal static func _copyRepeating(distance: Int, count: Int, in bytes: inout MutableRawSpan, at offset: Int) {
        // Unsafe: an unchecked load. Safe: it ends at `offset`, before the bytes this writes.
        let element = unsafe Load.block(distance, from: bytes.bytes, at: offset &- distance)
        unsafe _fill(UInt128(element), period: distance, byteCount: count, in: &bytes, at: offset)
    }

    @unsafe @inlinable @inline(always)
    internal static func _move<T: ConvertibleFromBytes & ConvertibleToBytes & BitwiseCopyable>(_: T.Type, from source: Int, to destination: Int, in bytes: inout MutableRawSpan) {
        let value = unsafe bytes.bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: source, as: T.self)
        unsafe bytes.storeBytes(of: value, toUncheckedByteOffset: destination, as: T.self)
    }
}

// MARK: - Runs and copies from a reader

public extension BytesWriter {
    /// Writes `byte` `count` times: padding, filler, a run of a run-length encoding. Requires byte alignment.
    ///
    /// ```swift
    /// try writer.write(repeating: 0, count: padding)
    /// ```
    ///
    /// - Parameters:
    ///   - byte: The byte to repeat.
    ///   - count: The number of copies, 0 or more.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count` bytes remain. Nothing is written.
    /// - Precondition: `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func write(repeating byte: Byte, count: Int) throws(BytesError) {
        try write(repeating: UInt64(byte.rawValue), byteCount: 1, count: count)
    }

    /// Writes `value`'s bytes, in memory order, `count` times. Requires byte alignment.
    ///
    /// ```swift
    /// try writer.write(repeating: pixel as Byte3, count: run) // RGB, RGB, …
    /// ```
    ///
    /// - Parameters:
    ///   - value: The byte group to repeat.
    ///   - count: The number of copies, 0 or more.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count * T.byteCount` bytes remain.
    ///   Nothing is written.
    /// - Precondition: `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteGroup>(repeating value: T, count: Int) throws(BytesError) {
        try _write(repeating: UInt128(truncatingIfNeeded: value.littleEndian), period: T.byteCount, count: count)
    }

    /// Writes the low `byteCount` bytes (1 through 8) of `value`, least significant first, `count` times:
    /// the form for an element size known only at run time, such as an image's channel count. Requires byte
    /// alignment.
    ///
    /// ```swift
    /// try writer.write(repeating: UInt64(bitCast(pixel, to: UInt32.self)), byteCount: channels, count: run)
    /// ```
    ///
    /// - Parameters:
    ///   - value: The integer whose low bytes are repeated.
    ///   - byteCount: The element size in bytes, 1 through 8.
    ///   - count: The number of copies, 0 or more.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count * byteCount` bytes remain (or the
    ///   product overflows). Nothing is written.
    /// - Precondition: `byteCount` is 1 through 8, `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func write(repeating value: UInt64, byteCount: Int, count: Int) throws(BytesError) {
        precondition(byteCount >= 1 && byteCount <= 8, "Byte count must be 1 through 8")
        let element = value.keepingLowBits(8 &* byteCount)
        try _write(repeating: UInt128(element), period: byteCount, count: count)
    }

    /// `count` copies of the low `period` bytes (1 through 16) of `element`, the rest of which are zero.
    ///
    /// Capacity is checked once. The element is repeated across 16 bytes, as many whole copies as fit, and
    /// stored 16 bytes at a time, each store starting where the last one's last whole copy ended; the last
    /// 0 to 15 bytes take one or two more stores. A loop of single-element writes checked capacity and
    /// stored once per element: QOI's runs took 3x the instructions. Long runs of one byte call `memset`.
    ///
    /// - Parameters:
    ///   - element: The element, in its low `period` bytes.
    ///   - period: The element size in bytes, 1 through 16.
    ///   - count: The number of copies.
    /// - Throws: ``BytesError/insufficientCapacity`` if the run doesn't fit. Nothing is written.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    internal mutating func _write(repeating element: UInt128, period: Int, count: Int) throws(BytesError) {
        precondition(count >= 0, "Negative count")
        precondition(_bitOffset == 0, "Writing a run requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let (total, overflow) = count.multipliedReportingOverflow(by: period)
        guard likely(!overflow && _bytes.byteCount &- _byteOffset >= total) else { throw .insufficientCapacity }
        if period == 1, total > 256 {
            var run = _bytes._mutatingExtracting(_byteOffset..<(_byteOffset &+ total))
            run.storeBytes(repeating: UInt8(truncatingIfNeeded: element), count: total, as: UInt8.self) // `memset`
        } else {
            unsafe Self._fill(element, period: period, byteCount: total, in: &_bytes, at: _byteOffset)
        }
        _byteOffset &+= total
    }

    /// The low `period` bytes (1 through 8) of `element` (the rest zero) repeated across 16 bytes, and the
    /// whole copies in them, in bytes (16, or 15 for 3 and 5, 12 for 6, 14 for 7).
    ///
    /// Each half is one multiply: the element times a constant with a 1 at each copy's first bit. Copies past
    /// 8 bytes fall off the top, so the low half is right, and the high half, bytes 8 to 15, is the same with
    /// the element rotated by `8 % period` bytes (where byte 8 falls in a copy). The constants come from one
    /// table, so a period known only at run time costs a load and two multiplies, and a known one folds.
    /// (Doubling a 128-bit pattern instead took 16 instructions per doubling, two for 3- and 4-byte elements.)
    ///
    /// - Parameters:
    ///   - element: The element, in its low `period` bytes.
    ///   - period: The element size in bytes, 1 through 8.
    /// - Returns: The 16-byte pattern and its step.
    @inlinable @inline(always)
    internal static func _pattern(_ element: UInt64, period: Int) -> (pattern: UInt128, step: Int) {
        let (multiplier, rotation, step): (UInt64, Int, Int) = switch period {
        case 1: (0x0101_0101_0101_0101, 0, 16)
        case 2: (0x0001_0001_0001_0001, 0, 16)
        case 3: (0x0001_0000_0100_0001, 2, 15)
        case 4: (0x0000_0001_0000_0001, 0, 16)
        case 5: (0x0000_0100_0000_0001, 3, 15)
        case 6: (0x0001_0000_0000_0001, 2, 12)
        case 7: (0x0100_0000_0000_0001, 1, 14)
        default: (1, 0, 16)
        }
        // The copies don't overlap, so the multiply only places them: no carries.
        let low = element &* multiplier
        let rotated: UInt64 = rotation == 0
            ? element
            : (element &>> UInt64(8 &* rotation) | element &<< UInt64(8 &* (period &- rotation)))
            .keepingLowBits(8 &* period)
        return (UInt128(rotated &* multiplier) &<< 64 | UInt128(low), step)
    }

    /// Stores `byteCount` bytes at `offset`: the low `period` bytes (1 through 16) of `element` (the rest
    /// zero), repeated. Capacity already checked.
    ///
    /// - Parameters:
    ///   - element: The element, in its low `period` bytes.
    ///   - period: The element size in bytes, 1 through 16.
    ///   - byteCount: The number of bytes to store.
    ///   - bytes: The memory written to.
    ///   - offset: Where the first store starts.
    @unsafe @inlinable @inline(always)
    internal static func _fill(_ element: UInt128, period: Int, byteCount: Int, in bytes: inout MutableRawSpan, at offset: Int) {
        // Whole copies across 16 bytes; copies cut off at 16 bytes are never stored as such: see `step`.
        let pattern: UInt128
        // Each store starts a copy: it advances by the whole copies in 16 bytes.
        let step: Int
        if period <= 8 {
            (pattern, step) = _pattern(UInt64(truncatingIfNeeded: element), period: period)
        } else {
            // 9- to 16-byte groups, whose size is always a constant: one doubling, folded.
            pattern = element | element &<< UInt128(8 &* period)
            step = period
        }
        var index = 0
        while byteCount &- index >= 16 {
            unsafe Store.little(pattern, to: &bytes, at: offset &+ index)
            index &+= step
        }
        let rest = byteCount &- index
        guard rest > 0 else { return }
        if step == 16, index > 0, (byteCount &- 16) & (period &- 1) == 0 {
            // Copies tile 16 bytes exactly (the period is 1, 2, 4, 8, or 16), so any offset that's a multiple
            // of the period starts one: end with one store overlapping the last, when the last 16 bytes start
            // at such an offset. (Always for runs, whole copies; not for back-references of any length.)
            unsafe Store.little(pattern, to: &bytes, at: offset &+ byteCount &- 16)
        } else if rest >= 8 {
            // The rest starts a copy, so it's the pattern's first `rest` bytes: two overlapping 8-byte stores.
            unsafe Store.little(UInt64(truncatingIfNeeded: pattern), to: &bytes, at: offset &+ index)
            unsafe Store.little(
                UInt64(truncatingIfNeeded: pattern &>> UInt128(8 &* (rest &- 8))), to: &bytes, at: offset &+ index &+ rest &- 8
            )
        } else {
            unsafe Store.block(UInt64(truncatingIfNeeded: pattern), count: rest, to: &bytes, at: offset &+ index)
        }
    }

    /// Copies `reader`'s next `byteCount` bytes, advancing both cursors by `byteCount`: LZ4's and Snappy's
    /// literal runs. Requires both to be byte-aligned.
    ///
    /// With `allowingOverrun`, when the reader has `byteCount` rounded up to a multiple of 16 bytes left
    /// (at least 16), and the writer room for as many, it copies 16 bytes at a time: one load and one store
    /// for up to 16 bytes, two for up to 32, whatever the length, with no branch on it for the processor to
    /// mispredict, as LZ4's reference decoder does. The up to 15 bytes after the copy are then overwritten
    /// with arbitrary values. Use it when those bytes are scratch, such as a decoder's output buffer.
    /// Otherwise it copies exactly, like `write(reader.read(byteCount: byteCount))`.
    ///
    /// ```swift
    /// try writer.write(from: &reader, byteCount: literalCount, allowingOverrun: true)
    /// ```
    ///
    /// - Parameters:
    ///   - reader: The cursor to copy from; advances by `byteCount`.
    ///   - byteCount: The number of bytes to copy, 0 or more.
    ///   - allowingOverrun: Whether the writer may overwrite up to 15 bytes after the copy with arbitrary
    ///     values, when both cursors have room for the 16-byte steps.
    /// - Throws: ``BytesError/insufficientData`` if the reader has fewer than `byteCount` bytes,
    ///   ``BytesError/insufficientCapacity`` if the writer has less room. Neither cursor moves and nothing
    ///   is written.
    /// - Precondition: `byteCount` isn't negative, and both cursors are byte-aligned.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    @_lifetime(reader: copy reader)
    mutating func write(from reader: inout BytesReader, byteCount: Int, allowingOverrun: Bool) throws(BytesError) {
        precondition(byteCount >= 0, "Negative byte count")
        precondition(_bitOffset == 0, "Copying requires byte alignment: call alignToByte() first")
        precondition(reader._bitOffset == 0, "Copying requires byte alignment: call alignToByte() on the reader first")
        _assumeInvariant()
        reader._assumeInvariant()
        let available = reader.span.byteCount &- reader._byteOffset
        let room = _bytes.byteCount &- _byteOffset
        guard likely(available >= byteCount) else { throw .insufficientData }
        guard likely(room >= byteCount) else { throw .insufficientCapacity }
        // The bytes the 16-byte steps touch: at least one step.
        let stepped = byteCount <= 16 ? 16 : (byteCount &+ 15) & ~15
        if allowingOverrun, likely(available >= stepped), likely(room >= stepped) {
            var index = 0
            repeat {
                // Unsafe: unchecked load and store. Safe: `stepped` bytes from each cursor are within the
                // reader's span and the writer's (checked above), and `index` stays below `stepped`.
                let chunk = unsafe reader.span.unsafeLoadUnaligned(
                    fromUncheckedByteOffset: reader._byteOffset &+ index, as: SIMD16<UInt8>.self
                )
                unsafe _bytes.storeBytes(of: chunk, toUncheckedByteOffset: _byteOffset &+ index, as: SIMD16<UInt8>.self)
                index &+= 16
            } while index < byteCount
            reader._byteOffset &+= byteCount
            _byteOffset &+= byteCount
        } else {
            try write(reader.read(byteCount: byteCount))
        }
    }
}

// MARK: - Bulk

// The generating forms (`count:` plus a closure from index to value) are the write-side counterpart of
// `BytesReader.forEach`: always inlined, so the closure is fused into one counted loop with a single capacity
// check, and nothing is staged in memory first. The span forms are thin wrappers over them. The closures
// can't throw: capacity is checked once up front, so a write either happens in full or not at all.
// Values too large for `T` are truncated without a check here, unlike single writes in debug builds: a
// check in the loop would stop it vectorizing.

public extension BytesWriter {
    /// Writes `count` values as `T` in `byteOrder`, each produced by `value` from its index, in order.
    /// Values too large for `T` are truncated to its low bytes, unchecked.
    ///
    /// ```swift
    /// try writer.write(Byte4.self, .bigEndian, count: records.count) { records[$0].id }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The ``ByteGroup`` type, which sets the width.
    ///   - byteOrder: The order to write each value's bytes in.
    ///   - count: The number of values, 0 or more.
    ///   - value: Called once per index from 0 up to `count`, in order, to produce that value. It can't throw.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count * T.byteCount` whole bytes remain.
    ///   Nothing is written and `value` isn't called.
    /// - Precondition: `count` isn't negative.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteGroup>(
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
    ///
    /// - Parameters:
    ///   - values: The integers to write.
    ///   - type: The ``ByteGroup`` type, which sets the width.
    ///   - byteOrder: The order to write each value's bytes in.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `values.count * T.byteCount` whole bytes
    ///   remain. Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteGroup>(_ values: Span<T.Integer>, as _: T.Type, _ byteOrder: ByteOrder) throws(BytesError) {
        try write(T.self, byteOrder, count: values.count) { unsafe values[unchecked: $0] }
    }

    /// Writes `count` values of `width` bits, packed in ``bitOrder``, each produced by `value` from its
    /// index, in order.
    ///
    /// Writing bits one at a time is inherently sequential: each write merges with the byte the previous
    /// one left partly written. This packs whole blocks instead (one byte when `width` divides 8, otherwise
    /// 8 values into `width` bytes) with constant shifts, in a counted loop that vectorizes.
    ///
    /// - Parameters:
    ///   - type: The ``Bits`` type, which sets the width.
    ///   - count: The number of values, 0 or more.
    ///   - value: Called once per index from 0 up to `count`, in order, to produce that value. It can't throw.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count * width` bits remain. Nothing is
    ///   written and `value` isn't called.
    /// - Precondition: `count` isn't negative.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<let width: Int>(
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
    ///
    /// - Parameter values: The values to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `values.count * width` bits remain.
    ///   Nothing is written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<let width: Int>(_ values: Span<Bits<width>>) throws(BytesError) {
        try write(Bits<width>.self, count: values.count) { unsafe values[unchecked: $0] }
    }

    /// Writes `count` values' raw bytes, each produced by `value` from its index, in order.
    ///
    /// - Parameters:
    ///   - type: The ``ByteRepresentable`` type.
    ///   - count: The number of values, 0 or more.
    ///   - value: Called once per index from 0 up to `count`, in order, to produce that value. It can't throw.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than `count` values' raw bytes remain. Nothing
    ///   is written and `value` isn't called.
    /// - Precondition: `count` isn't negative.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteRepresentable>(
        _: T.Type, count: Int, _ value: (Int) -> T
    ) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
        precondition(count >= 0, "Negative count")
        _assumeInvariant()
        let size = MemoryLayout<T.RawBytes>.size
        precondition(size > 0, "\(T.self).RawBytes has no bytes") // Constant-folded.
        guard likely(remainingByteCount / size >= count) else { throw .insufficientCapacity }
        guard likely(_bitOffset == 0) else {
            for index in 0..<count {
                try write(value(index))
            }
            return
        }
        let start = _byteOffset
        for index in 0..<count {
            unsafe Store.rawBytes(value(index).rawBytes, to: &_bytes, at: start &+ index &* size)
        }
        _byteOffset &+= count &* size
    }

    /// Writes each of `values`' raw bytes.
    ///
    /// - Parameter values: The values to write.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room for all of them. Nothing is
    ///   written.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ByteRepresentable>(_ values: Span<T>) throws(BytesError) where T.RawBytes: ConvertibleToBytes {
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
    /// - Parameters:
    ///   - type: The element type.
    ///   - count: The number of elements, 0 or more.
    ///   - body: Receives a mutable span of `count` elements over the writer's next bytes. It can't throw;
    ///     its result is returned.
    /// - Returns: What `body` returns.
    /// - Throws: ``BytesError/insufficientCapacity`` if there isn't room, ``BytesError/misaligned`` if the
    ///   bytes aren't aligned for `T` (never for types with an alignment of 1, such as
    ///   `InlineArray<N, UInt8>`). Either way, `body` isn't called and nothing is written.
    /// - Precondition: `count` isn't negative, and the writer is byte-aligned.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func write<T: ConvertibleFromBytes & ConvertibleToBytes, R: ~Copyable>(
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

public extension OutputSpan where Element == UInt8 {
    /// Appends what `body` writes with a ``BytesWriter`` over the free capacity. Only the bytes written are
    /// added; if `body` throws, nothing is.
    ///
    /// ```swift
    /// let bytes = try [UInt8](capacity: 1_024) { output in
    ///     try output.withBytesWriter { writer in try writer.write(header) }
    /// }
    /// ```
    ///
    /// For an array, ``Swift/Array/init(byteCapacity:bitOrder:writing:)`` and
    /// ``Swift/Array/append(byteCapacity:bitOrder:writing:)`` do this in one closure.
    ///
    /// - Parameters:
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    ///   - body: Receives a writer over the free capacity. If it throws, nothing is added.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withBytesWriter<R: ~Copyable, E: Error>(
        bitOrder: BitOrder = .mostSignificantFirst,
        _ body: (inout BytesWriter) throws(E) -> R
    ) throws(E) -> R {
        // Unsafe: a span over the output's uninitialized capacity, which no safe API exposes. Safe: the span
        // covers exactly that capacity and ends with the closure; `UInt8` needs no initialization beyond the
        // stores, and only the bytes the writer reports writing are counted as initialized.
        try unsafe withUnsafeMutableBufferPointer { buffer, initializedCount throws(E) -> R in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[initializedCount...])
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: free), bitOrder: bitOrder)
            let result = try body(&writer)
            initializedCount &+= writer.byteCount
            return result
        }
    }
}

public extension OutputRawSpan {
    /// Appends what `body` writes with a ``BytesWriter`` over the free capacity. Only the bytes written are
    /// added; if `body` throws, nothing is.
    ///
    /// - Parameters:
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    ///   - body: Receives a writer over the free capacity. If it throws, nothing is added.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    @_lifetime(self: copy self)
    mutating func withBytesWriter<R: ~Copyable, E: Error>(
        bitOrder: BitOrder = .mostSignificantFirst,
        _ body: (inout BytesWriter) throws(E) -> R
    ) throws(E) -> R {
        // Unsafe and safe as for `OutputSpan<UInt8>` above.
        try unsafe withUnsafeMutableBytes { buffer, initializedCount throws(E) -> R in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...])
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: free), bitOrder: bitOrder)
            let result = try body(&writer)
            initializedCount &+= writer.byteCount
            return result
        }
    }
}

public extension [UInt8] {
    /// A new array of what `body` writes with a ``BytesWriter`` over `byteCapacity` bytes: exactly the bytes
    /// written. If `body` throws, so does this.
    ///
    /// ```swift
    /// let bytes = try [UInt8](byteCapacity: packet.encodedByteCount) { writer in try packet.write(to: &writer) }
    /// ```
    ///
    /// One closure where `[UInt8](capacity:)` and ``Swift/OutputSpan/withBytesWriter(bitOrder:_:)`` take
    /// two, usually with their types spelled out, and cheaper: about 470 instructions less per array than
    /// `[UInt8](capacity:)`, whose allocation goes through an unspecialized standard library function (1,000
    /// 38-byte arrays: 1,228 K instructions against 1,696 K). This reserves an empty array and appends.
    ///
    /// Annotating the closure's error type, `{ (writer) throws(BytesError) in … }`, no longer matters here:
    /// both forms measured the same. (Through `init(capacity:)`, an unannotated closure, inferred as
    /// `throws(any Error)`, wasn't inlined, +3%.)
    ///
    /// - Parameters:
    ///   - byteCapacity: The most bytes `body` can write; also the array's reserved capacity.
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    ///   - body: Receives a writer over `byteCapacity` bytes.
    /// - Throws: What `body` throws. A write that exceeds `byteCapacity` throws
    ///   ``BytesError/insufficientCapacity`` inside `body`.
    @inlinable @inline(always)
    init<E: Error>(
        byteCapacity: Int, bitOrder: BitOrder = .mostSignificantFirst, writing body: (inout BytesWriter) throws(E) -> Void
    ) throws(E) {
        // An empty array, reserved, then appended to: `init(capacity:initializingWith:)` called the standard
        // library's unspecialized `ContiguousArray._allocateBufferUninitialized`, about 500 instructions
        // (27 ns) more per array, whatever its size.
        var array: [UInt8] = []
        array.reserveCapacity(byteCapacity)
        try array.append(addingCapacity: byteCapacity) { (output: inout OutputSpan<UInt8>) throws(E) in
            try output._withBytesWriter(bitOrder: bitOrder, body)
        }
        self = array
    }

    /// Appends what `body` writes with a ``BytesWriter`` over `byteCapacity` more bytes: exactly the bytes
    /// written. If `body` throws, nothing is appended.
    ///
    /// ```swift
    /// try output.append(byteCapacity: blockMaximum) { writer in try decodeBlock(block, into: &writer) }
    /// ```
    ///
    /// Through the standard library's specialized `append(addingCapacity:)`, as
    /// ``init(byteCapacity:bitOrder:writing:)`` is.
    ///
    /// - Parameters:
    ///   - byteCapacity: The most bytes `body` can write.
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    ///   - body: Receives a writer over `byteCapacity` bytes.
    /// - Throws: What `body` throws. A write that exceeds `byteCapacity` throws
    ///   ``BytesError/insufficientCapacity`` inside `body`.
    @inlinable @inline(always)
    mutating func append<E: Error>(
        byteCapacity: Int, bitOrder: BitOrder = .mostSignificantFirst, writing body: (inout BytesWriter) throws(E) -> Void
    ) throws(E) {
        try append(addingCapacity: byteCapacity) { (output: inout OutputSpan<UInt8>) throws(E) in
            try output._withBytesWriter(bitOrder: bitOrder, body)
        }
    }
}

extension OutputSpan where Element == UInt8 {
    /// ``withBytesWriter(bitOrder:_:)``, always inlined, for the array builders.
    ///
    /// - Parameters:
    ///   - bitOrder: The order of bits within each byte, for bit-level writes.
    ///   - body: Receives a writer over the free capacity. If it throws, nothing is added.
    /// - Throws: What `body` throws.
    @inlinable @inline(always)
    @_lifetime(self: copy self)
    mutating func _withBytesWriter<E: Error>(
        bitOrder: BitOrder, _ body: (inout BytesWriter) throws(E) -> Void
    ) throws(E) {
        // Unsafe and safe as for `withBytesWriter`.
        try unsafe withUnsafeMutableBufferPointer { buffer, initializedCount throws(E) in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[initializedCount...])
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: free), bitOrder: bitOrder)
            try body(&writer)
            initializedCount &+= writer.byteCount
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
    @unsafe @inlinable @inline(__always)
    static func little<I: FixedWidthInteger & ConvertibleToBytes & BitwiseCopyable>(_ value: I, to bytes: inout MutableRawSpan, at offset: Int) {
        unsafe bytes.storeBytes(of: value.littleEndian, toUncheckedByteOffset: offset, as: I.self)
    }

    /// The low `count` (1 through 8) bytes of `value`, least significant first. Odd counts use two
    /// overlapping stores of the next size down, which write the shared bytes twice with the same values.
    ///
    /// - Parameters:
    ///   - value: The integer whose low bytes are stored.
    ///   - count: The number of bytes, 1 through 8.
    ///   - bytes: The memory written to.
    ///   - offset: Where the first byte is stored.
    @unsafe @inlinable @inline(__always)
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

    /// Stores `value`'s `T.byteCount` bytes, in memory order.
    ///
    /// - Parameters:
    ///   - value: The byte group.
    ///   - bytes: The memory written to.
    ///   - offset: Where the first byte is stored.
    @unsafe @inlinable @inline(__always)
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
    ///
    /// - Parameters:
    ///   - value: The byte group.
    ///   - bytes: The memory written to.
    ///   - offset: Where the first byte is stored.
    @unsafe @inlinable @inline(__always)
    static func streamingGroup<T: ByteGroup>(_ value: T, to bytes: inout MutableRawSpan, at offset: Int) {
        guard T.byteCount == 3 else { return unsafe group(value, to: &bytes, at: offset) }
        let littleEndian = UInt32(truncatingIfNeeded: value.littleEndian)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian), to: &bytes, at: offset)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian &>> 8), to: &bytes, at: offset &+ 1)
        unsafe little(UInt8(truncatingIfNeeded: littleEndian &>> 16), to: &bytes, at: offset &+ 2)
    }

    /// `value`'s bytes. Integer-sized values are stored as that integer (through `bitCast`), like
    /// ``Load/rawBytes(_:from:at:)``; other sizes directly.
    ///
    /// - Parameters:
    ///   - value: The value whose bytes are stored.
    ///   - bytes: The memory written to.
    ///   - offset: Where the first byte is stored.
    @unsafe @inlinable @inline(__always)
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
