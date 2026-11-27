internal import Bytes

/// The CRC-64 that `.xz` files use (CRC-64/XZ: ECMA-182's polynomial 0x42F0E1EBA9EA3693, reflected, initial and
/// final value all ones), computed incrementally.
///
/// ```swift
/// var crc = CRC64()
/// crc.update(chunk)            // as many times as needed
/// guard crc.value == expected else { … }
///
/// let checksum = CRC64.checksum(data.span.bytes)   // "123456789": 0x995DC9BBDF1939FA
/// ```
///
/// On Apple silicon, inputs of 128 bytes or more are folded 64 bytes per step with carry-less multiplies
/// (`pmull`), as Bytes' ``Bytes/CRC32`` is; elsewhere, and for the rest, eight bytes per step with eight
/// 256-entry tables ("slicing by 8"), as liblzma does.
package struct CRC64: Hashable, Sendable {
    /// The checksum of everything added so far.
    package private(set) var value: UInt64

    /// Creates a CRC of no bytes yet, or continuing from the checksum of earlier bytes.
    ///
    /// - Parameter value: The checksum of the earlier bytes; 0 for none.
    package init(continuing value: UInt64 = 0) {
        self.value = value
    }

    /// Adds `bytes` to the checksum.
    package mutating func update(_ bytes: RawSpan) {
        value = Self.checksum(bytes, continuing: value)
    }

    /// Computes the checksum of `bytes`.
    package static func checksum(_ bytes: RawSpan) -> UInt64 {
        checksum(bytes, continuing: 0)
    }

    /// Continues the checksum of earlier bytes with `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes that follow the earlier ones.
    ///   - value: The checksum of the earlier bytes.
    /// - Returns: The CRC-64 of the earlier bytes followed by `bytes`.
    package static func checksum(_ bytes: RawSpan, continuing value: UInt64) -> UInt64 {
        guard bytes.byteCount > 0 else { return value }
        let tables = Self.tables
        let table = tables.span
        precondition(table.count == 2048) // Folds every lookup's check.
        var crc = ~value
        var rest = bytes
        #if HardwareCRC && arch(arm64) && !Portable
        if rest.byteCount >= 128 {
            let folded = rest.withUnsafeBytes { buffer in
                // Unsafe: the base address of a nonempty buffer.
                unsafe fold(crc, buffer.baseAddress!, buffer.count)
            }
            rest = rest.extracting(droppingFirst: folded.count)
            let words = bitCast(folded.state, to: SIMD2<UInt64>.self)
            crc = update(update(0, word: UInt64(littleEndian: words[0]), table), word: UInt64(littleEndian: words[1]), table)
        }
        #endif
        return ~update(crc, rest, table)
    }

    /// Updates the unconditioned register `crc` with `bytes`, eight at a time with the tables.
    private static func update(_ crc: UInt64, _ bytes: RawSpan, _ table: Span<UInt64>) -> UInt64 {
        // Words (`RawSpan.chunks(of:)`: byte arrays, so any address is aligned for them, read with `bitCast`) and bytes
        // as elements, and table lookups: no checks once the table's size is known, as every index is a byte plus a
        // multiple of 256 below 2048.
        precondition(table.count == 2048)
        var crc = crc
        let count = bytes.byteCount
        let words = bytes.chunks(of: InlineArray<8, UInt8>.self)
        for index in words.indices {
            crc = update(crc, word: UInt64(littleEndianBytes: words[index]), table)
        }
        let tail = Span<UInt8>(viewing: bytes.extracting(droppingFirst: count & ~7))
        for index in tail.indices {
            crc = table[Int((crc ^ UInt64(tail[index])) & 0xFF)] ^ crc &>> 8
        }
        return crc
    }

    /// Updates the unconditioned register `crc` with the 8 bytes `word` (little-endian).
    @inline(__always)
    private static func update(_ crc: UInt64, word: UInt64, _ table: Span<UInt64>) -> UInt64 {
        let word = word ^ crc
        return table[7 &* 256 &+ Int(word & 0xFF)] ^ table[6 &* 256 &+ Int(word &>> 8 & 0xFF)]
            ^ table[5 &* 256 &+ Int(word &>> 16 & 0xFF)] ^ table[4 &* 256 &+ Int(word &>> 24 & 0xFF)]
            ^ table[3 &* 256 &+ Int(word &>> 32 & 0xFF)] ^ table[2 &* 256 &+ Int(word &>> 40 & 0xFF)]
            ^ table[256 &+ Int(word &>> 48 & 0xFF)] ^ table[Int(word &>> 56)]
    }

    /// Eight tables of 256: the first, each byte's CRC; table `k`, the CRC of a byte followed by `k` zeros.
    private static let tables: [UInt64] = {
        let polynomial: UInt64 = 0xC96C_5795_D787_0F42 // 0x42F0E1EBA9EA3693, reflected.
        var tables = [UInt64](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var crc = UInt64(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? crc &>> 1 ^ polynomial : crc &>> 1
            }
            tables[byte] = crc
        }
        for table in 1..<8 {
            for byte in 0..<256 {
                let previous = tables[(table - 1) * 256 + byte]
                tables[table * 256 + byte] = previous &>> 8 ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()
}

// MARK: - Apple silicon

#if HardwareCRC && arch(arm64) && !Portable
extension CRC64 {
    // Folding constants: a 16-byte block moved d bits forward is its low (first) 8 bytes times x^(d + 63) mod P
    // plus its high 8 times x^(d - 1) mod P, both bit-reflected. (`pmull` of reflected operands leaves the
    // product a bit short of where the block's frame puts it: the missing factor x is the 63 and -1 rather than
    // 64 and 0.) The tests check the folded CRC against liblzma's at every length to 600 bytes and beyond.
    private static var fold512: SIMD16<UInt8> {
        bitCast(SIMD2<UInt64>(0x6AE3_EFBB_9DD4_41F3, 0x081F_6054_A784_2DF4), to: SIMD16<UInt8>.self)
    }

    private static var fold128: SIMD16<UInt8> {
        bitCast(SIMD2<UInt64>(0xE05D_D497_CA39_3AE4, 0xDABE_95AF_C787_5F40), to: SIMD16<UInt8>.self)
    }

    /// Folds the whole 16-byte blocks of `count` bytes (at least 128) at `input` into one, four accumulators
    /// moving 64 bytes per step, with `crc` (the unconditioned register) XORed into the first 8 bytes.
    ///
    /// - Returns: The folded block, whose CRC from zero continued with the bytes after `count` (rounded down
    ///   to 16) is the CRC of all of them; and that rounded count.
    // Not inlined, as before the body was shared: inlined into `checksum`, it cost short inputs an instruction a call.
    @inline(never)
    private static func fold(_ crc: UInt64, _ input: UnsafeRawPointer, _ count: Int) -> (state: SIMD16<UInt8>, count: Int) {
        // Unsafe and safe as `CRCFold.fold`: `count` bytes at `input`, at least 128 (the caller checks).
        unsafe CRCFold.fold(
            bitCast(SIMD2<UInt64>(crc, 0), to: SIMD16<UInt8>.self), input, count, reversed: false, fold512: fold512,
            fold128: fold128
        )
    }
}
#endif
