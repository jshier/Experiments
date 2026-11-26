#if NEONShuffle
// Public: inlinable code calls the header's `static inline` movemask.
public import CBytesNEON
#endif

// MARK: - Testing 64 bytes at once

/// Sixty-four bytes of a span, tested together into a 64-bit mask (byte i in bit i): the building block of a
/// structural index, which finds every delimiter of a block at once and then walks the mask with
/// `trailingZeroBitCount`, instead of scanning from each delimiter to the next.
///
/// ```swift
/// // An HTTP head: line ends and colons, a block at a time.
/// let block = head.byteBlock(at: offset)
/// let lineEnds = block.mask { $0.matching(0x0A) }
/// let colons = block.mask { $0.matching(UInt8(ascii: ":")) }
/// ```
///
/// A mask costs the test's instructions on each of the four ``ByteLanes`` plus one gather of their results: on NEON
/// a weighted sum by pairwise adds (`addp`, the CBytesNEON module: 9 vector instructions for 64 bytes, each lane's high
/// bit spread through it first unless the test's lanes are already all ones or zeros, as a comparison's are), elsewhere
/// four ``ByteMatches/bitmask``s. Measured on HTTP/1 heads (HTTPBytes/RESULTS.md): parsing by walking such masks took
/// 0.44 cycles a byte on real requests, against 0.93 for a `RawSpan.firstByteOffset(where:)` scan from each
/// delimiter to the next (whose many short scans mispredict) and 1.22 for picohttpparser.
@frozen
public struct ByteBlock: Sendable {
    /// Bytes 0–15.
    public var lanes0: ByteLanes
    /// Bytes 16–31.
    public var lanes1: ByteLanes
    /// Bytes 32–47.
    public var lanes2: ByteLanes
    /// Bytes 48–63.
    public var lanes3: ByteLanes

    /// The block's size: 64 bytes.
    @inlinable @inline(__always)
    public static var byteCount: Int { 64 }

    /// Wraps 64 bytes, as four vectors in order.
    @inlinable @inline(__always)
    public init(_ lanes0: SIMD16<UInt8>, _ lanes1: SIMD16<UInt8>, _ lanes2: SIMD16<UInt8>, _ lanes3: SIMD16<UInt8>) {
        self.lanes0 = ByteLanes(lanes0)
        self.lanes1 = ByteLanes(lanes1)
        self.lanes2 = ByteLanes(lanes2)
        self.lanes3 = ByteLanes(lanes3)
    }

    /// Wraps 64 bytes held by value: an element of `RawSpan.chunks(of:)`'s 64-byte chunks, or a block built on
    /// the stack. Two 32-byte loads (`ldp`), no checks.
    ///
    /// ```swift
    /// let blocks = bytes.chunks(of: InlineArray<64, UInt8>.self)
    /// for index in blocks.indices {
    ///     let lineEnds = ByteBlock(blocks[index]).mask { $0.matching(0x0A) }
    ///     …
    /// }
    /// ```
    ///
    /// - Parameter bytes: The block's bytes, in order.
    @inlinable @inline(__always)
    public init(_ bytes: InlineArray<64, UInt8>) {
        let vector = bitCast(bytes, to: SIMD64<UInt8>.self)
        self.init(vector.lowHalf.lowHalf, vector.lowHalf.highHalf, vector.highHalf.lowHalf, vector.highHalf.highHalf)
    }

    /// The bytes that pass `test`, one bit each: byte i in bit i.
    ///
    /// - Parameter test: Builds the matches for 16 bytes, as for `RawSpan.firstByteOffset(where:)`.
    /// - Returns: A mask with bit i set where byte i matched.
    @inlinable @inline(__always)
    public func mask(_ test: (ByteLanes) -> ByteMatches) -> UInt64 {
        Self.gather(test(lanes0), test(lanes1), test(lanes2), test(lanes3))
    }

    /// Four sets of 16 matches as one 64-bit mask: lane i of `first` in bit i, of `second` in bit 16 + i, and so on.
    @inlinable @inline(__always)
    public static func gather(_ first: ByteMatches, _ second: ByteMatches, _ third: ByteMatches, _ fourth: ByteMatches) -> UInt64 {
        #if NEONShuffle
        bytes_movemask64(first.fullLanes, second.fullLanes, third.fullLanes, fourth.fullLanes)
        #else
        UInt64(first.bitmask) | UInt64(second.bitmask) &<< 16 | UInt64(third.bitmask) &<< 32 | UInt64(fourth.bitmask) &<< 48
        #endif
    }
}

extension ByteMatches {
    /// Each lane's high bit spread through the lane: 0xFF where it matched, 0 elsewhere. (One `sshr`, which LLVM drops
    /// when the lanes come from a comparison and are already all ones or zeros.)
    @inlinable @inline(__always)
    var fullLanes: SIMD16<UInt8> {
        bitCast(bitCast(highBits, to: SIMD16<Int8>.self) &>> 7, to: SIMD16<UInt8>.self)
    }
}

public extension RawSpan {
    /// The 64 bytes at `offset`.
    ///
    /// - Precondition: `offset >= 0` and `offset + 64 <= byteCount`.
    @inlinable @inline(__always)
    func byteBlock(at offset: Int) -> ByteBlock {
        // One range check for the block. (Four checked loads kept their own compares and branches in callers' loops,
        // not folded into this one: HTTPBytes' long-field scan was 48 instructions a block against 29.)
        precondition(offset >= 0 && offset <= byteCount &- 64, "a 64-byte block past the span's end")
        // Unsafe: unchecked loads. Safe: the precondition puts bytes `offset` through `offset + 63` inside the span.
        return unsafe ByteBlock(unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self),
                                unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 16, as: SIMD16<UInt8>.self),
                                unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 32, as: SIMD16<UInt8>.self),
                                unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 48, as: SIMD16<UInt8>.self))
    }

    /// The bytes from `offset` to the end, at most 64, followed by `padding` to fill the block: for a span's last,
    /// partial block. Choose a padding byte that every test of the block treats as a stop (a byte the format never
    /// allows there), so a walk over the masks ends at the data's end.
    ///
    /// The partial block is copied once into 64 bytes of stack filled with `padding`, in at most four 16-byte words (the
    /// last overlapping) or two smaller ones, not a byte at a time or by `memcpy`. A span of 64 bytes or more can avoid
    /// the copy: test the block that ends at the span's end and shift its mask (`mask >> (offset - (byteCount - 64)) |
    /// ~0 << (byteCount - offset)` makes the padding match).
    ///
    /// - Precondition: `0 <= offset <= byteCount`.
    @inlinable
    func byteBlock(at offset: Int, padding: UInt8) -> ByteBlock {
        precondition(offset >= 0 && offset <= byteCount, "a block offset past the span's end")
        if offset <= byteCount &- 64 { return byteBlock(at: offset) }
        // Below 64 bytes (the full-block case returned above), loaded from `self` at `offset` on. `min` states the bound
        // to the optimizer, so the stores' checks fold away.
        let available = Swift.min(byteCount &- offset, 63)
        var padded = InlineArray<64, UInt8>(repeating: padding)
        if available > 0 {
            var span = padded.mutableSpan
            var to = span.mutableBytes
            // The tail copied inline (16-, 8-, or 4-byte words, the last overlapping), not by `memcpy`: a call for a
            // few dozen bytes cost more than the copy, on every head that ends inside its last block. (Written out, not
            // as loops: LLVM turned a loop of 16-byte copies back into `memcpy`.)
            if available >= 16 {
                // The first word, then up to three ending at the data's end (offsets the loads' checks fold for).
                to.storeBytes(of: load(fromByteOffset: offset, as: SIMD16<UInt8>.self), toByteOffset: 0, as: SIMD16<UInt8>.self)
                if available >= 48 {
                    to.storeBytes(of: load(fromByteOffset: byteCount &- 48, as: SIMD16<UInt8>.self),
                                  toByteOffset: available &- 48, as: SIMD16<UInt8>.self)
                }
                if available >= 32 {
                    to.storeBytes(of: load(fromByteOffset: byteCount &- 32, as: SIMD16<UInt8>.self),
                                  toByteOffset: available &- 32, as: SIMD16<UInt8>.self)
                }
                to.storeBytes(of: load(fromByteOffset: byteCount &- 16, as: SIMD16<UInt8>.self),
                              toByteOffset: available &- 16, as: SIMD16<UInt8>.self)
            } else if available >= 8 {
                to.storeBytes(of: load(fromByteOffset: offset, as: UInt64.self), toByteOffset: 0, as: UInt64.self)
                to.storeBytes(of: load(fromByteOffset: byteCount &- 8, as: UInt64.self), toByteOffset: available &- 8, as: UInt64.self)
            } else if available >= 4 {
                to.storeBytes(of: load(fromByteOffset: offset, as: UInt32.self), toByteOffset: 0, as: UInt32.self)
                to.storeBytes(of: load(fromByteOffset: byteCount &- 4, as: UInt32.self), toByteOffset: available &- 4, as: UInt32.self)
            } else {
                // 1 to 3 bytes: the first, the middle, and the last cover them.
                to.storeBytes(of: load(fromByteOffset: offset, as: UInt8.self), toByteOffset: 0, as: UInt8.self)
                let middle = available &>> 1
                to.storeBytes(of: load(fromByteOffset: offset &+ middle, as: UInt8.self), toByteOffset: middle, as: UInt8.self)
                to.storeBytes(of: load(fromByteOffset: byteCount &- 1, as: UInt8.self), toByteOffset: available &- 1, as: UInt8.self)
            }
        }
        return ByteBlock(padded)
    }

    /// The span's whole `n`-byte chunks, as elements, leaving out the last `byteCount % n` bytes: a typed view for loops
    /// over fixed-size blocks (a hash's 64-byte blocks, a checksum's 8-byte words), whose element reads need no checks
    /// within an element and whose loop needs one bound for the whole view.
    ///
    /// ```swift
    /// let blocks = message.chunks(of: InlineArray<64, UInt8>.self)
    /// for index in blocks.indices {
    ///     let block = ByteBlock(blocks[index])                       // four vectors
    ///     …
    /// }
    /// let words = message.chunks(of: InlineArray<8, UInt8>.self)
    /// for index in words.indices {
    ///     let word = UInt64(littleEndian: bitCast(words[index], to: UInt64.self))
    ///     …
    /// }
    /// ```
    ///
    /// Read an element by `bitCast` to the vector or integer of its size: through the element's own `span`, a read
    /// put a stack copy (and a stack protector) in the loop. A 64-byte loop of four vector loads compiled to 9
    /// instructions this way, against 31 with checked offset loads; setting the view up costs about 6, so for spans of a
    /// few dozen bytes, offset loads can be cheaper.
    ///
    /// - Parameter type: The chunk type: `InlineArray<n, UInt8>.self`.
    /// - Returns: The `byteCount / n` whole chunks, in order.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    func chunks<let n: Int>(of type: InlineArray<n, UInt8>.Type) -> Span<InlineArray<n, UInt8>> {
        precondition(n > 0, "chunks of no bytes") // Folds: `n` is known where this is specialized.
        // Byte arrays: any address is aligned for them, and the length is a whole number of them.
        return Span(viewing: extracting(first: byteCount &- byteCount % n))
    }
}
