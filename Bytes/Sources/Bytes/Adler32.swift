#if HardwareCRC
internal import CBytesCRC
#endif

/// The Adler-32 checksum of the zlib format (RFC 1950), computed incrementally.
///
/// ```swift
/// var adler = Adler32()
/// adler.update(chunk)          // as many times as needed
/// guard adler.value == expected else { … }
/// ```
///
/// Adler-32 is two sums modulo 65,521: `a`, of the bytes plus one, and `b`, of the successive values of
/// `a`. `b` weights each byte by how many bytes follow it, so a block of bytes adds to it a weighted sum
/// that vector code computes as column sums: 32 bytes per step in 16-bit lanes, reduced once per 2 KB.
// Not `@inlinable`, unlike most public API here: a checksum is a loop over the bytes, so a call costs nothing
// measurable, and the loop (with the build's hardware choice) stays compiled once, here.
public struct Adler32: Hashable, Sendable {
    /// The checksum of everything added so far: `b << 16 | a`.
    public private(set) var value: UInt32

    /// Creates a checksum of no bytes yet (1), or continuing from the checksum of earlier bytes.
    ///
    /// - Parameter value: The checksum of the earlier bytes; 1 for none.
    public init(continuing value: UInt32 = 1) {
        self.value = value
    }

    /// Adds `bytes` to the checksum.
    ///
    /// - Parameter bytes: The bytes to add.
    public mutating func update(_ bytes: RawSpan) {
        value = Self.checksum(bytes, continuing: value)
    }

    /// Computes the checksum of `bytes`.
    ///
    /// - Parameter bytes: The bytes to checksum.
    /// - Returns: The Adler-32 of `bytes`.
    public static func checksum(_ bytes: RawSpan) -> UInt32 {
        checksum(bytes, continuing: 1)
    }

    /// The modulus: the largest prime below 65,536.
    static var modulus: UInt32 { 65521 }

    /// The checksum of two pieces end to end, from each piece's checksum and the second's length (zlib's
    /// `adler32_combine`): for pieces checksummed in parallel.
    ///
    /// - Parameters:
    ///   - first: The first piece's checksum.
    ///   - second: The second piece's checksum (started from 1, as ``checksum(_:)`` does).
    ///   - length: The second piece's length in bytes.
    /// - Returns: The checksum of the first piece followed by the second.
    public static func combine(_ first: UInt32, _ second: UInt32, secondLength length: Int) -> UInt32 {
        precondition(length >= 0, "Negative length")
        let base = UInt64(modulus)
        let remainder = UInt64(length) % base
        var sum1 = UInt64(first & 0xFFFF)
        var sum2 = remainder &* sum1 % base
        sum1 &+= UInt64(second & 0xFFFF) &+ base &- 1
        sum2 &+= UInt64(first &>> 16) &+ UInt64(second &>> 16) &+ base &- remainder
        if sum1 >= base { sum1 &-= base }
        if sum1 >= base { sum1 &-= base }
        if sum2 >= base &<< 1 { sum2 &-= base &<< 1 }
        if sum2 >= base { sum2 &-= base }
        return UInt32(truncatingIfNeeded: sum1 | sum2 &<< 16)
    }

    /// 32-byte blocks per reduction: 64 keeps the sum of four column totals below 65,536 (4 × 64 × 255).
    static var blocksPerChunk: Int { 64 }

    /// Continues the checksum of earlier bytes with `bytes`.
    ///
    /// For a chunk of `m` 32-byte blocks (`n = 32m` bytes, byte `j` of block `k` at position `32k + j`),
    /// `a` grows by the sum of the bytes and `b` by `n·a + Σ (n − position)·byte`. Splitting the weight
    /// `32(m − k) − j`: `Σ (m − k)·byte` over a column is the sum of that column's running totals after each
    /// block, so the loop keeps the column totals and the grand total of their running totals (only that
    /// total matters, so columns are summed before accumulating it); the `j` part is a weighted sum of the
    /// final column totals.
    ///
    /// - Parameters:
    ///   - bytes: The bytes that follow the earlier ones.
    ///   - value: The checksum of the earlier bytes.
    /// - Returns: The Adler-32 of the earlier bytes followed by `bytes`.
    public static func checksum(_ bytes: RawSpan, continuing value: UInt32) -> UInt32 {
        var a = value & 0xFFFF
        var b = value &>> 16
        var offset = 0
        let count = bytes.byteCount
        let byteMask = SIMD8<UInt16>(repeating: 0xFF)
        let byteShift = SIMD8<UInt16>(repeating: 8)
        let halfMask = SIMD4<UInt32>(repeating: 0xFFFF)
        let halfShift = SIMD4<UInt32>(repeating: 16)
        #if HardwareCRC && arch(arm64) && !Portable
        // Whole 64-byte blocks with UDOT (two at a time, then an odd one); the vector loop below takes the (at most one)
        // 32-byte block left, and the bytes loop the rest.
        if count >= 64 { _updateDotProduct(bytes, offset: &offset, a: &a, b: &b) }
        #endif
        while count &- offset >= 32 {
            let blocks = min((count &- offset) &>> 5, blocksPerChunk)
            // Column totals. Each block is loaded as 16-bit lanes and split into its even bytes (`& 0xFF`)
            // and odd bytes (`>> 8`): widening without `SIMD16<UInt16>(truncatingIfNeeded:)`, which Swift
            // 6.4 calls out of line. Which column lands in which lane doesn't matter until the weighting.
            var even0 = SIMD8<UInt16>() // Bytes 0, 2, …, 14 of each block (little-endian lanes).
            var odd0 = SIMD8<UInt16>() // Bytes 1, 3, …, 15.
            var even1 = SIMD8<UInt16>() // Bytes 16, 18, …, 30.
            var odd1 = SIMD8<UInt16>() // Bytes 17, 19, …, 31.
            // The running totals of all 32 columns after each block, summed, in two sets of 32-bit lanes (the
            // 16-bit sum of four columns, split the same way).
            var runningEven = SIMD4<UInt32>()
            var runningOdd = SIMD4<UInt32>()
            for _ in 0..<blocks {
                // Unsafe: unchecked loads. Safe: `blocks` 32-byte blocks remain from `offset`, checked above.
                let first = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD8<UInt16>.self)
                let second = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 16, as: SIMD8<UInt16>.self)
                even0 &+= first & byteMask
                odd0 &+= first &>> byteShift
                even1 &+= second & byteMask
                odd1 &+= second &>> byteShift
                // At most 4 · 255 · 64 = 65,280: fits, with `blocksPerChunk` 64.
                let total = (even0 &+ odd0) &+ (even1 &+ odd1)
                // Eight 16-bit lanes as four 32-bit ones: the same 16 bytes.
                let pairs = bitCast(total, to: SIMD4<UInt32>.self)
                runningEven &+= pairs & halfMask
                runningOdd &+= pairs &>> halfShift
                offset &+= 32
            }
            let columns0 = SIMD16<UInt32>(lowHalf: SIMD8(truncatingIfNeeded: even0), highHalf: SIMD8(truncatingIfNeeded: odd0))
            let columns1 = SIMD16<UInt32>(lowHalf: SIMD8(truncatingIfNeeded: even1), highHalf: SIMD8(truncatingIfNeeded: odd1))
            let sum = (columns0 &+ columns1).wrappedSum() // At most 522,240.
            let weighted = (columns0 &* Self.columnWeights &+ columns1 &* (Self.columnWeights &+ 16)).wrappedSum()
            let running = UInt64((runningEven &+ runningOdd).wrappedSum()) // At most 255 · 32 · 64 · 65 / 2.
            let n = UInt64(blocks &<< 5)
            b = UInt32((UInt64(b) &+ n &* UInt64(a) &+ 32 &* running &- UInt64(weighted)) % UInt64(modulus))
            a = (a &+ sum) % modulus
        }
        // Fewer than 32 bytes: the definition, one at a time.
        while offset < count {
            a &+= UInt32(bytes.load(fromByteOffset: offset, as: UInt8.self))
            b &+= a
            offset &+= 1
        }
        return (b % modulus) &<< 16 | a % modulus
    }

    /// The column of each lane of `columns0`: the even bytes of the first 16, then the odd bytes, as the
    /// 16-bit lanes split them (on a little-endian CPU; on a big-endian one each lane holds the other byte
    /// first).
    @inline(__always)
    static var columnWeights: SIMD16<UInt32> {
        #if _endian(little)
        SIMD16(0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15)
        #else
        SIMD16(1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 14)
        #endif
    }
}

// MARK: - Apple silicon

#if HardwareCRC && arch(arm64) && !Portable
extension Adler32 {
    /// 128-byte steps per reduction (64 KiB). A step adds at most 128 × 255 = 32,640 to the four lanes of `sum`
    /// together, and `prefix` adds `sum` before each step, so after `m` steps `prefix`'s lanes total at most
    /// 32,640 · m(m − 1)/2: below 2^32 for m ≤ 513. The weighted sums grow by at most 255 × (128 + 127 + … + 1) =
    /// 2,105,280 a step (below 2^32 for m ≤ 2,040), and `sum` by 32,640. So no 32-bit lane, and no horizontal sum of a
    /// vector's (or the eight weighted vectors') lanes, overflows.
    static var dotProductStepsPerChunk: Int { 512 }

    /// Adds whole 64-byte blocks of `bytes` from `offset` with UDOT, which sums four bytes into a 32-bit lane in
    /// one instruction: the byte sums against a vector of ones, the position-weighted sums against 128, 127, …, 1.
    ///
    /// For a chunk of `m` 128-byte steps, byte `j` of step `k` is followed by `128(m − k) − j − 1` bytes within the
    /// chunk, so `b` grows by `128m·a + Σ (128(m − k) − j)·byte`. Split as `128·Σ (m − 1 − k)·byte` (`prefix`, which
    /// adds before each step the byte sum of the steps before it) plus the weighted sum `Σ (128 − j)·byte` of each
    /// step. A last odd 64-byte block is added alone, with the weights 64, …, 1.
    ///
    /// The loop is bound by the vector pipes, not by UDOT's latency (3 cycles on the M3 and M1): a step is 16 UDOTs, two
    /// adds, and the zeroing of a register, 19 vector operations for four pipes, about 4.75 cycles. Each of the eight
    /// weighted accumulators takes one UDOT a step. The byte sum of a step is one chain of eight UDOTs started from
    /// zero, which no later step waits on: only the two adds (`prefix`, `sum`) carry over. (Eight accumulators for the
    /// byte sums, as the weighted sums have, would cost eight adds a step to form `prefix`: 24 operations.)
    ///
    /// - Parameters:
    ///   - bytes: The bytes to checksum.
    ///   - offset: Where to start; advanced past the whole blocks added. At most 63 bytes remain after it.
    ///   - a: The running sum of the bytes plus one, below the modulus; updated.
    ///   - b: The running sum of `a`, below the modulus; updated.
    @inline(__always)
    static func _updateDotProduct(_ bytes: RawSpan, offset: inout Int, a: inout UInt32, b: inout UInt32) {
        let count = bytes.byteCount
        let ones = SIMD16<UInt8>(repeating: 1)
        let zero = SIMD4<UInt32>()
        let weights0 = bytes_adler_weights(0)
        let weights1 = bytes_adler_weights(1)
        let weights2 = bytes_adler_weights(2)
        let weights3 = bytes_adler_weights(3)
        let weights4 = bytes_adler_weights(4)
        let weights5 = bytes_adler_weights(5)
        let weights6 = bytes_adler_weights(6)
        let weights7 = bytes_adler_weights(7)
        while count &- offset >= 128 {
            let steps = min((count &- offset) &>> 7, dotProductStepsPerChunk)
            var sum = zero, prefix = zero
            var weighted0 = zero, weighted1 = zero, weighted2 = zero, weighted3 = zero
            var weighted4 = zero, weighted5 = zero, weighted6 = zero, weighted7 = zero
            for _ in 0..<steps {
                // Unsafe: unchecked loads. Safe: `steps` 128-byte steps remain from `offset`, checked above.
                let data0 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
                let data1 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
                let data2 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 32, as: SIMD16<UInt8>.self)
                let data3 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 48, as: SIMD16<UInt8>.self)
                let data4 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 64, as: SIMD16<UInt8>.self)
                let data5 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 80, as: SIMD16<UInt8>.self)
                let data6 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 96, as: SIMD16<UInt8>.self)
                let data7 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 112, as: SIMD16<UInt8>.self)
                prefix &+= sum // The byte sum of the steps before this one.
                // This step's byte sum, from zero: the chain's latency overlaps the next steps'.
                var step = bytes_crc_udot(zero, data0, ones)
                step = bytes_crc_udot(step, data1, ones)
                step = bytes_crc_udot(step, data2, ones)
                step = bytes_crc_udot(step, data3, ones)
                step = bytes_crc_udot(step, data4, ones)
                step = bytes_crc_udot(step, data5, ones)
                step = bytes_crc_udot(step, data6, ones)
                step = bytes_crc_udot(step, data7, ones)
                sum &+= step
                weighted0 = bytes_crc_udot(weighted0, data0, weights0)
                weighted1 = bytes_crc_udot(weighted1, data1, weights1)
                weighted2 = bytes_crc_udot(weighted2, data2, weights2)
                weighted3 = bytes_crc_udot(weighted3, data3, weights3)
                weighted4 = bytes_crc_udot(weighted4, data4, weights4)
                weighted5 = bytes_crc_udot(weighted5, data5, weights5)
                weighted6 = bytes_crc_udot(weighted6, data6, weights6)
                weighted7 = bytes_crc_udot(weighted7, data7, weights7)
                offset &+= 128
            }
            // Each total is below 2^32 (see `dotProductStepsPerChunk`); `prefix` is shifted in 64 bits.
            let total = UInt64(sum.wrappedSum())
            let weighted = UInt64(
                (((weighted0 &+ weighted1) &+ (weighted2 &+ weighted3)) &+ ((weighted4 &+ weighted5) &+ (weighted6 &+ weighted7)))
                    .wrappedSum()
            )
            let before = UInt64(prefix.wrappedSum())
            let n = UInt64(steps &<< 7)
            b = UInt32((UInt64(b) &+ n &* UInt64(a) &+ before &<< 7 &+ weighted) % UInt64(modulus))
            a = UInt32((UInt64(a) &+ total) % UInt64(modulus))
        }
        if count &- offset >= 64 {
            // One block left: `b` grows by `64·a` plus the bytes weighted 64, …, 1 (the last four weight vectors).
            // Unsafe: unchecked loads. Safe: 64 bytes remain from `offset`, checked above.
            let data0 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
            let data1 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
            let data2 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 32, as: SIMD16<UInt8>.self)
            let data3 = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 48, as: SIMD16<UInt8>.self)
            var sum = bytes_crc_udot(zero, data0, ones)
            sum = bytes_crc_udot(sum, data1, ones)
            sum = bytes_crc_udot(sum, data2, ones)
            sum = bytes_crc_udot(sum, data3, ones)
            var weighted = bytes_crc_udot(zero, data0, weights4)
            weighted = bytes_crc_udot(weighted, data1, weights5)
            weighted = bytes_crc_udot(weighted, data2, weights6)
            weighted = bytes_crc_udot(weighted, data3, weights7)
            b = UInt32((UInt64(b) &+ 64 &* UInt64(a) &+ UInt64(weighted.wrappedSum())) % UInt64(modulus))
            a = UInt32((UInt64(a) &+ UInt64(sum.wrappedSum())) % UInt64(modulus))
            offset &+= 64
        }
    }
}
#endif
