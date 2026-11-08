#if NEONShuffle
import CBytesNEON
#endif

// MARK: - Looking up 16 bytes at once

extension ByteLanes {
    /// Whether ``lookup(in:)-(SIMD16<UInt8>,SIMD16<UInt8>,SIMD16<UInt8>)`` is a single instruction: on ARM64
    /// with the `NEONShuffle` trait. Otherwise lookups go a lane at a time, and code that has another way
    /// (arithmetic, say) should use it. A constant, so a branch on it folds away.
    @inlinable @inline(__always)
    public static var isLookupVectorized: Bool {
        #if NEONShuffle && arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Each lane's byte in a 48-byte table: lane `i` of the result is byte `vector[i]` of `table`'s three
    /// vectors in order, or 0 if `vector[i]` is 48 or more. One NEON `tbl` (`vqtbl3q_u8`).
    ///
    /// With constant indices, a lookup is a shuffle: picking every third byte of 48 deinterleaves them, as
    /// `ld3` does when loading.
    ///
    /// Swift can't express `tbl` itself (`SIMD16`'s dynamic subscript compiles a lane at a time), so this
    /// goes through the CBytesNEON C module (the `NEONShuffle` trait, on by default), which inlines into
    /// the caller. Without the trait, or on other CPUs, the same results come a lane at a time.
    @inlinable @inline(__always)
    public func lookup(in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table3(table.0, table.1, table.2, vector)
        #else
        Self._lookup(vector, count: 48) { index in
            index < 16 ? table.0[index] : index < 32 ? table.1[index &- 16] : table.2[index &- 32]
        }
        #endif
    }

    /// Each lane's byte in a 64-byte table: lane `i` of the result is byte `vector[i]` of `table`'s four
    /// vectors in order, or 0 if `vector[i]` is 64 or more. One NEON `tbl` (`vqtbl4q_u8`).
    ///
    /// ```swift
    /// // Base64: a 6-bit value per lane to its character.
    /// let characters = ByteLanes(values).lookup(in: alphabet)
    /// ```
    @inlinable @inline(__always)
    public func lookup(in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table4(table.0, table.1, table.2, table.3, vector)
        #else
        Self._lookup(vector, count: 64) { index in
            index < 32 ? (index < 16 ? table.0[index] : table.1[index &- 16])
                : (index < 48 ? table.2[index &- 32] : table.3[index &- 48])
        }
        #endif
    }

    /// Splits 48 bytes into every third byte, as NEON's `ld3` loads them: bytes 0, 3, 6, … 45 of `a`, `b`,
    /// and `c` in order, then 1, 4, … 46, then 2, 5, … 47. Three lookups (one `tbl` each).
    ///
    /// ```swift
    /// let (red, green, blue) = ByteLanes.deinterleave(pixels.0, pixels.1, pixels.2) // 16 RGB pixels
    /// ```
    @inlinable @inline(__always)
    public static func deinterleave(
        _ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        let first: SIMD16<UInt8> = [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45]
        return (ByteLanes(first).lookup(in: (a, b, c)),
                ByteLanes(first &+ 1).lookup(in: (a, b, c)),
                ByteLanes(first &+ 2).lookup(in: (a, b, c)))
    }

    /// The bytes of four vectors interleaved, as NEON's `st4` stores them: `a[0]`, `b[0]`, `c[0]`, `d[0]`,
    /// `a[1]`, … `d[15]`, in the four result vectors in order. Eight `zip`s.
    ///
    /// Written in Swift, the two rounds of zips get merged into four-vector shuffles, which ARM64 builds a
    /// lane at a time, so this goes through the CBytesNEON C module (see `lookup(in:)`).
    @inlinable @inline(__always)
    public static func interleave(
        _ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>, _ d: SIMD16<UInt8>
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        #if NEONShuffle
        let result = bytes_interleave4(a, b, c, d)
        return (result.v0, result.v1, result.v2, result.v3)
        #else
        var result = (SIMD16<UInt8>(), SIMD16<UInt8>(), SIMD16<UInt8>(), SIMD16<UInt8>())
        for index in 0..<16 {
            let lanes = (a[index], b[index], c[index], d[index])
            let start = index % 4 &* 4
            switch index / 4 {
            case 0: (result.0[start], result.0[start + 1], result.0[start + 2], result.0[start + 3]) = lanes
            case 1: (result.1[start], result.1[start + 1], result.1[start + 2], result.1[start + 3]) = lanes
            case 2: (result.2[start], result.2[start + 1], result.2[start + 2], result.2[start + 3]) = lanes
            default: (result.3[start], result.3[start + 1], result.3[start + 2], result.3[start + 3]) = lanes
            }
        }
        return result
        #endif
    }

    /// The lane-at-a-time fallback.
    @inlinable @inline(__always)
    static func _lookup(_ indices: SIMD16<UInt8>, count: Int, _ byte: (Int) -> UInt8) -> SIMD16<UInt8> {
        var result = SIMD16<UInt8>()
        for lane in 0..<16 where Int(indices[lane]) < count {
            result[lane] = byte(Int(indices[lane]))
        }
        return result
    }
}
