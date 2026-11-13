#if NEONShuffle
import CBytesNEON
#endif

// MARK: - Looking up 16 bytes at once

public extension ByteLanes {
    /// Whether `lookup(in:)` is a single `tbl` or `tbx`: true on ARM64 with the `NEONShuffle` trait and
    /// without `Portable`.
    /// Otherwise lookups go a lane at a time, and code with another way (arithmetic, say) should use it.
    /// A constant, so a branch on it folds away.
    @inlinable @inline(__always)
    static var isLookupVectorized: Bool {
        #if NEONShuffle && arch(arm64) && !Portable
        true
        #else
        false
        #endif
    }

    /// Looks up each lane in a 48-byte table: lane `i` of the result is byte `vector[i]` of `table`'s three
    /// vectors in order, or 0 if `vector[i]` is 48 or more. One NEON `tbl` (`vqtbl3q_u8`).
    ///
    /// With constant indices, a lookup is a shuffle: picking every third byte of 48 deinterleaves them, as
    /// `ld3` does when loading.
    ///
    /// Swift can't express `tbl` itself (`SIMD16`'s dynamic subscript compiles a lane at a time), so this
    /// goes through the CBytesNEON C module (the `NEONShuffle` trait, on by default), which inlines into
    /// the caller. Without the trait, or on other CPUs, the same results come a lane at a time.
    ///
    /// - Parameter table: The table's 48 bytes, as three vectors.
    /// - Returns: The table byte for each lane's index, 0 for indices of 48 or more.
    @inlinable @inline(__always)
    func lookup(in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table3(table.0, table.1, table.2, vector)
        #else
        Self._lookup(vector, count: 48) { index in
            index < 16 ? table.0[index] : index < 32 ? table.1[index &- 16] : table.2[index &- 32]
        }
        #endif
    }

    /// Looks up each lane in a 64-byte table: lane `i` of the result is byte `vector[i]` of `table`'s four
    /// vectors in order, or 0 if `vector[i]` is 64 or more. One NEON `tbl` (`vqtbl4q_u8`).
    ///
    /// ```swift
    /// // Base64: a 6-bit value per lane to its character.
    /// let characters = ByteLanes(values).lookup(in: alphabet)
    /// ```
    ///
    /// - Parameter table: The table's 64 bytes, as four vectors.
    /// - Returns: The table byte for each lane's index, 0 for indices of 64 or more.
    @inlinable @inline(__always)
    func lookup(in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table4(table.0, table.1, table.2, table.3, vector)
        #else
        Self._lookup(vector, count: 64) { index in
            index < 32 ? (index < 16 ? table.0[index] : table.1[index &- 16])
                : (index < 48 ? table.2[index &- 32] : table.3[index &- 48])
        }
        #endif
    }

    /// Looks up each lane in a 16-byte table, giving 0 where `vector[i]` is 16 or more. One NEON `tbl` of
    /// one register (`vqtbl1q_u8`), the cheapest lookup: a nibble's class, say.
    ///
    /// ```swift
    /// let classes = ByteLanes(characters &>> 4).lookup(in: highNibbleClasses)
    /// ```
    ///
    /// - Parameter table: The table's 16 bytes.
    /// - Returns: The table byte for each lane's index, 0 for indices of 16 or more.
    @inlinable @inline(__always)
    func lookup(in table: SIMD16<UInt8>) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table1(table, vector)
        #else
        Self._lookup(vector, count: 16) { table[$0] }
        #endif
    }

    /// Looks up each lane in a 16-byte table, keeping `fallback`'s lane where `vector[i]` is 16 or more.
    /// One NEON `tbx` (`vqtbx1q_u8`). Passing the result of a lookup in a larger table as `fallback`
    /// extends that table by 16 bytes: a 64-byte lookup, then this with the indices less 64, is an 80-byte
    /// table in five table registers.
    ///
    /// - Parameters:
    ///   - table: The table's 16 bytes.
    ///   - fallback: The result for each lane whose index is 16 or more.
    /// - Returns: The table byte for each lane's index, or `fallback`'s lane for indices of 16 or more.
    @inlinable @inline(__always)
    func lookup(in table: SIMD16<UInt8>, keepingOutOfRange fallback: SIMD16<UInt8>) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table1x(fallback, table, vector)
        #else
        var result = lookup(in: table)
        for lane in 0..<16 where vector[lane] >= 16 {
            result[lane] = fallback[lane]
        }
        return result
        #endif
    }

    /// Looks up each lane in a 48-byte table, keeping `fallback`'s lane where `vector[i]` is 48 or more.
    /// One NEON `tbx` (`vqtbx3q_u8`): the same cost as the `tbl` lookup in a 48-byte table, which gives 0
    /// there.
    ///
    /// ```swift
    /// // 48 bytes moved down by `count` lanes, with spaces shifted in.
    /// let iota: SIMD16<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    /// let first = ByteLanes(iota &+ SIMD16(repeating: count)).lookup(in: bytes, keepingOutOfRange: spaces)
    /// ```
    ///
    /// - Parameters:
    ///   - table: The table's 48 bytes, as three vectors.
    ///   - fallback: The result for each lane whose index is 48 or more.
    /// - Returns: The table byte for each lane's index, or `fallback`'s lane for indices of 48 or more.
    @inlinable @inline(__always)
    func lookup(
        in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), keepingOutOfRange fallback: SIMD16<UInt8>
    ) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table3x(fallback, table.0, table.1, table.2, vector)
        #else
        var result = lookup(in: table)
        for lane in 0..<16 where vector[lane] >= 48 {
            result[lane] = fallback[lane]
        }
        return result
        #endif
    }

    /// Looks up each lane in a 64-byte table, keeping `fallback`'s lane where `vector[i]` is 64 or more.
    /// One NEON `tbx` (`vqtbx4q_u8`).
    ///
    /// - Parameters:
    ///   - table: The table's 64 bytes, as four vectors.
    ///   - fallback: The result for each lane whose index is 64 or more.
    /// - Returns: The table byte for each lane's index, or `fallback`'s lane for indices of 64 or more.
    @inlinable @inline(__always)
    func lookup(
        in table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), keepingOutOfRange fallback: SIMD16<UInt8>
    ) -> SIMD16<UInt8> {
        #if NEONShuffle
        bytes_table4x(fallback, table.0, table.1, table.2, table.3, vector)
        #else
        var result = lookup(in: table)
        for lane in 0..<16 where vector[lane] >= 64 {
            result[lane] = fallback[lane]
        }
        return result
        #endif
    }

    /// Looks up each lane in a 128-byte table, giving 0 where `vector[i]` is 128 or more: an ASCII
    /// character to anything, such as a Base64 character to its value. A `tbl` on the first 64 bytes, then
    /// a `tbx` on the second 64 with the indices less 64 (`vqtbl4q_u8`, `vqtbx4q_u8`, and a subtraction).
    ///
    /// ```swift
    /// let values = ByteLanes(characters).lookup(in: (low, high))   // characters 0–63, then 64–127
    /// ```
    ///
    /// - Parameter table: The table's 128 bytes, as two halves of four vectors each.
    /// - Returns: The table byte for each lane's index, 0 for indices of 128 or more.
    @inlinable @inline(__always)
    func lookup(
        in table: (
            (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>),
            (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
        )
    ) -> SIMD16<UInt8> {
        // Indices of 64 and up give 0 from the first half; the second half's indices less 64 wrap to 192
        // and up below 64, which keeps that 0 or the first half's byte, and 128 and up stay out of range.
        ByteLanes(vector &- SIMD16(repeating: 64))
            .lookup(in: table.1, keepingOutOfRange: lookup(in: table.0))
    }

    /// Splits 48 bytes into every third byte, as NEON's `ld3` loads them: bytes 0, 3, 6, … 45 of `a`, `b`,
    /// and `c` in order, then 1, 4, … 46, then 2, 5, … 47. Three lookups (one `tbl` each).
    ///
    /// ```swift
    /// let (red, green, blue) = ByteLanes.deinterleave(pixels.0, pixels.1, pixels.2) // 16 RGB pixels
    /// ```
    ///
    /// - Parameters:
    ///   - a: Bytes 0 through 15.
    ///   - b: Bytes 16 through 31.
    ///   - c: Bytes 32 through 47.
    /// - Returns: The three vectors of every third byte, starting at byte 0, 1, and 2.
    @inlinable @inline(__always)
    static func deinterleave(
        _ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        let first: SIMD16<UInt8> = [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45]
        return (ByteLanes(first).lookup(in: (a, b, c)),
                ByteLanes(first &+ 1).lookup(in: (a, b, c)),
                ByteLanes(first &+ 2).lookup(in: (a, b, c)))
    }

    /// Splits 64 bytes into every fourth byte, as NEON's `ld4` loads them: bytes 0, 4, 8, … 60 of `a`, `b`,
    /// `c`, and `d` in order, then 1, 5, … 61, then 2, 6, … 62, then 3, 7, … 63. Eight `uzp`s.
    ///
    /// ```swift
    /// let (first, second, third, fourth) = ByteLanes.deinterleave(text.0, text.1, text.2, text.3) // Base64 groups
    /// ```
    ///
    /// Two rounds of `uzp1`/`uzp2` in the CBytesNEON C module, kept apart as in
    /// ``interleave(_:_:_:_:)``: cheaper than four 64-byte lookups (the lookups bound Base64's encoder).
    ///
    /// - Parameters:
    ///   - a: Bytes 0 through 15.
    ///   - b: Bytes 16 through 31.
    ///   - c: Bytes 32 through 47.
    ///   - d: Bytes 48 through 63.
    /// - Returns: The four vectors of every fourth byte, starting at byte 0, 1, 2, and 3.
    @inlinable @inline(__always)
    static func deinterleave(
        _ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>, _ d: SIMD16<UInt8>
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        #if NEONShuffle
        let result = bytes_deinterleave4(a, b, c, d)
        return (result.v0, result.v1, result.v2, result.v3)
        #else
        var result = (SIMD16<UInt8>(), SIMD16<UInt8>(), SIMD16<UInt8>(), SIMD16<UInt8>())
        for index in 0..<64 {
            let source = index < 16 ? a : index < 32 ? b : index < 48 ? c : d
            let byte = source[index % 16]
            switch index % 4 {
            case 0: result.0[index / 4] = byte
            case 1: result.1[index / 4] = byte
            case 2: result.2[index / 4] = byte
            default: result.3[index / 4] = byte
            }
        }
        return result
        #endif
    }

    /// Interleaves the bytes of three vectors, as NEON's `st3` stores them: `a[0]`, `b[0]`, `c[0]`, `a[1]`,
    /// … `c[15]`, in the three result vectors in order. Three 48-byte lookups (one `tbl` each).
    ///
    /// ```swift
    /// let pixels = ByteLanes.interleave(red, green, blue)   // 16 RGB pixels, 48 bytes
    /// ```
    ///
    /// - Parameters:
    ///   - a: The bytes for positions 0, 3, 6, … 45.
    ///   - b: The bytes for positions 1, 4, … 46.
    ///   - c: The bytes for positions 2, 5, … 47.
    /// - Returns: The 48 interleaved bytes, as three vectors.
    @inlinable @inline(__always)
    static func interleave(
        _ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        // Output byte p is byte p / 3 of the p % 3'th vector: index 16 · (p % 3) + p / 3 in the table. The
        // indices as `Byte16` literals (in memory order), which fold to constants: as `SIMD16` array
        // literals here, they compiled to calls to `SIMD.init(_:)` in the caller's loop.
        let table = (a, b, c)
        let first: Byte16 = 0x00_10_20_01_11_21_02_12_22_03_13_23_04_14_24_05
        let second: Byte16 = 0x15_25_06_16_26_07_17_27_08_18_28_09_19_29_0A_1A
        let third: Byte16 = 0x2A_0B_1B_2B_0C_1C_2C_0D_1D_2D_0E_1E_2E_0F_1F_2F
        return (ByteLanes(first.vector).lookup(in: table),
                ByteLanes(second.vector).lookup(in: table),
                ByteLanes(third.vector).lookup(in: table))
    }

    /// Interleaves the bytes of four vectors, as NEON's `st4` stores them: `a[0]`, `b[0]`, `c[0]`, `d[0]`,
    /// `a[1]`, … `d[15]`, in the four result vectors in order. Eight `zip`s.
    ///
    /// Written in Swift, the two rounds of zips get merged into four-vector shuffles, which ARM64 builds a
    /// lane at a time, so this goes through the CBytesNEON C module (see `lookup(in:)`).
    ///
    /// - Parameters:
    ///   - a: The bytes for positions 0, 4, 8, … 60.
    ///   - b: The bytes for positions 1, 5, … 61.
    ///   - c: The bytes for positions 2, 6, … 62.
    ///   - d: The bytes for positions 3, 7, … 63.
    /// - Returns: The 64 interleaved bytes, as four vectors.
    @inlinable @inline(__always)
    static func interleave(
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

    /// The lane-at-a-time fallback for a lookup in a table of `count` bytes.
    ///
    /// - Parameters:
    ///   - indices: The index for each lane.
    ///   - count: The table's size: indices at or above it give 0.
    ///   - byte: The table byte at an index below `count`.
    /// - Returns: `byte(indices[i])` for each lane `i` whose index is below `count`, else 0.
    @inlinable @inline(__always)
    internal static func _lookup(_ indices: SIMD16<UInt8>, count: Int, _ byte: (Int) -> UInt8) -> SIMD16<UInt8> {
        var result = SIMD16<UInt8>()
        for lane in 0..<16 where Int(indices[lane]) < count {
            result[lane] = byte(Int(indices[lane]))
        }
        return result
    }
}
