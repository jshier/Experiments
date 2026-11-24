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

    /// The 64 bytes at `offset` in `bytes`. Each load is checked; under a caller's check that the 64 bytes are inside
    /// `bytes`, the four checks fold away.
    @inlinable @inline(__always)
    init(loading bytes: RawSpan, at offset: Int) {
        self.init(bytes.load(fromByteOffset: offset, as: SIMD16<UInt8>.self),
                  bytes.load(fromByteOffset: offset &+ 16, as: SIMD16<UInt8>.self),
                  bytes.load(fromByteOffset: offset &+ 32, as: SIMD16<UInt8>.self),
                  bytes.load(fromByteOffset: offset &+ 48, as: SIMD16<UInt8>.self))
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
        // One range check for the block; the four loads' own checks fold into it.
        precondition(offset >= 0 && offset <= byteCount &- 64, "a 64-byte block past the span's end")
        return ByteBlock(loading: self, at: offset)
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
        return ByteBlock(loading: padded.span.bytes, at: 0)
    }
}
