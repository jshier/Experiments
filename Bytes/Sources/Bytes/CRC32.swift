#if HardwareCRC
internal import CBytesCRC
#endif

/// The CRC-32 used by zip, gzip, PNG, and Ethernet (ISO-HDLC: polynomial 0x04C11DB7, reflected, initial
/// and final value all ones), computed incrementally.
///
/// ```swift
/// var crc = CRC32()
/// crc.update(chunk)            // as many times as needed
/// guard crc.value == expected else { … }
///
/// let checksum = CRC32.checksum(data.span.bytes)
/// ```
///
/// On Apple silicon it folds 128 bytes per step with carry-less multiplies (`pmull`), eight 16-byte
/// lanes at a time, and finishes with the CPU's CRC32 instructions: faster than zlib's `crc32`. Elsewhere
/// it uses tables, five interleaved CRCs over 40 bytes per step, as zlib does.
public struct CRC32: Hashable, Sendable {
    /// The checksum of everything added so far.
    public private(set) var value: UInt32

    /// Creates a CRC of no bytes yet, or continuing from the checksum of earlier bytes.
    ///
    /// - Parameter value: The checksum of the earlier bytes (`value` of another `CRC32`, or a checksum
    ///   stored with the data); 0 for none.
    public init(continuing value: UInt32 = 0) {
        self.value = value
    }

    /// Adds `bytes` to the checksum.
    ///
    /// - Parameter bytes: The bytes to add.
    public mutating func update(_ bytes: RawSpan) {
        value = ~Self._update(~value, bytes)
    }

    /// Adds `bytes` to the checksum.
    ///
    /// - Parameter bytes: The bytes to add.
    public mutating func update(_ bytes: Span<UInt8>) {
        update(bytes.bytes)
    }

    /// Computes the checksum of `bytes`.
    ///
    /// - Parameter bytes: The bytes to checksum.
    /// - Returns: The CRC-32 of `bytes`.
    public static func checksum(_ bytes: RawSpan) -> UInt32 {
        checksum(bytes, continuing: 0)
    }

    /// Continues the checksum of earlier bytes with `bytes`: for a running CRC kept as an integer, as
    /// zlib's `crc32(crc, buf, len)` does.
    ///
    /// ```swift
    /// crc = CRC32.checksum(chunk, continuing: crc)
    /// ```
    ///
    /// - Parameters:
    ///   - bytes: The bytes that follow the earlier ones.
    ///   - value: The checksum of the earlier bytes.
    /// - Returns: The CRC-32 of the earlier bytes followed by `bytes`.
    public static func checksum(_ bytes: RawSpan, continuing value: UInt32) -> UInt32 {
        ~_update(~value, bytes)
    }

    /// Continues the checksum of earlier bytes with `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes that follow the earlier ones.
    ///   - value: The checksum of the earlier bytes.
    /// - Returns: The CRC-32 of the earlier bytes followed by `bytes`.
    public static func checksum(_ bytes: Span<UInt8>, continuing value: UInt32) -> UInt32 {
        checksum(bytes.bytes, continuing: value)
    }

    /// Updates the unconditioned register with `bytes`.
    ///
    /// - Parameters:
    ///   - state: The register, the complement of a checksum.
    ///   - bytes: The bytes to add.
    /// - Returns: The updated register.
    static func _update(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
        #if HardwareCRC && arch(arm64) && !Portable
        _hardwareUpdate(state, bytes)
        #else
        _tableUpdate(state, bytes)
        #endif
    }
}

// MARK: - Apple silicon

#if HardwareCRC && arch(arm64) && !Portable
extension CRC32 {
    // Folding constants for the reflected polynomial: x^(n + 32) and x^(n − 32) mod P, bit-reflected and
    // shifted left one, for folding 16 bytes forward by n bits (the low half has 64 bits further to go).
    // The 128- and 512-bit ones match Linux's (`crc32-pclmul_asm.S`); see the tests for their derivation.
    static var fold1024: SIMD16<UInt8> { bitCast(SIMD2<UInt64>(0x1_E88E_F372, 0x1_4A7F_E880), to: SIMD16<UInt8>.self) }
    static var fold128: SIMD16<UInt8> { bitCast(SIMD2<UInt64>(0x1_7519_97D0, 0x0_CCAA_009E), to: SIMD16<UInt8>.self) }

    /// Inputs this long or longer are folded; shorter ones take the CRC32 instructions 8 bytes at a time
    /// (one per 3 cycles, a dependency chain) rather than pay for combining the eight lanes.
    static var foldThreshold: Int { 256 }

    static func _hardwareUpdate(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
        var state = state
        var reader = BytesReader(bytes)
        if reader.remainingByteCount >= foldThreshold {
            state = _fold(state, &reader)
        }
        reader.forEach(Byte8.self, .littleEndian) { state = bytes_crc32_u64(state, $0) }
        reader.forEach(Byte.self) { state = bytes_crc32_u8(state, $0.rawValue) }
        return state
    }

    /// Folds whole 16-byte blocks of `reader` (at least 128 bytes) into 16 bytes, then reduces them with
    /// the CRC32 instructions. Leaves the last 0–15 bytes.
    ///
    /// The register's state is XORed into the first 4 bytes, so everything after is a CRC from zero. Eight
    /// accumulators each fold forward 128 bytes per step (two carry-less multiplies and a three-way XOR):
    /// independent chains, so the multiplies' latency overlaps. Each 128-byte step is read as a fixed-size
    /// sub-cursor, so its eight loads need no bounds checks of their own.
    ///
    /// - Parameters:
    ///   - state: The unconditioned register.
    ///   - reader: The bytes to fold; advanced past the folded blocks.
    /// - Returns: The register after the folded bytes.
    static func _fold(_ state: UInt32, _ reader: inout BytesReader) -> UInt32 {
        var block = BytesReader(try! reader.read(byteCount: 128))
        // Always inlined: as a call, each load spilled the eight accumulators (3.5x slower).
        @inline(always) func next(_ block: inout BytesReader) -> SIMD16<UInt8> { try! block.load(SIMD16<UInt8>.self) }
        var x0 = next(&block) ^ bitCast(SIMD4<UInt32>(state, 0, 0, 0), to: SIMD16<UInt8>.self)
        var x1 = next(&block), x2 = next(&block), x3 = next(&block)
        var x4 = next(&block), x5 = next(&block), x6 = next(&block), x7 = next(&block)

        let fold1024 = Self.fold1024
        while reader.remainingByteCount >= 128 {
            block = BytesReader(try! reader.read(byteCount: 128))
            x0 = bytes_crc_fold(x0, next(&block), fold1024)
            x1 = bytes_crc_fold(x1, next(&block), fold1024)
            x2 = bytes_crc_fold(x2, next(&block), fold1024)
            x3 = bytes_crc_fold(x3, next(&block), fold1024)
            x4 = bytes_crc_fold(x4, next(&block), fold1024)
            x5 = bytes_crc_fold(x5, next(&block), fold1024)
            x6 = bytes_crc_fold(x6, next(&block), fold1024)
            x7 = bytes_crc_fold(x7, next(&block), fold1024)
        }

        // Combine the lanes, each folded 16 bytes into the next, then the remaining whole blocks.
        let fold128 = Self.fold128
        var x = bytes_crc_fold(x0, x1, fold128)
        x = bytes_crc_fold(x, x2, fold128)
        x = bytes_crc_fold(x, x3, fold128)
        x = bytes_crc_fold(x, x4, fold128)
        x = bytes_crc_fold(x, x5, fold128)
        x = bytes_crc_fold(x, x6, fold128)
        x = bytes_crc_fold(x, x7, fold128)
        while reader.remainingByteCount >= 16 {
            x = bytes_crc_fold(x, try! reader.load(SIMD16<UInt8>.self), fold128)
        }

        // The CRC (from zero) of the 16 folded bytes is the register's state after everything folded.
        let halves = bitCast(x, to: SIMD2<UInt64>.self)
        return bytes_crc32_u64(bytes_crc32_u64(0, halves[0]), halves[1])
    }
}
#endif

// MARK: - Tables (other CPUs)

extension CRC32 {
    /// The number of interleaved CRCs ("braids") in ``_tableUpdate(_:_:)``, as in zlib's `crc32` for 64-bit
    /// words: enough independent lookup chains to keep the loads busy.
    static var braids: Int { 5 }

    /// Two sets of eight 256-entry tables, in one array. In each set, table `k` gives the register
    /// contribution of byte `b` at position `k` of an 8-byte word, advanced to a later position: the CRC of
    /// `b` followed by `7 - k` zero bytes (slicing-by-8, to the next word), then for the braid set by the
    /// other braids' words too, `8 * (braids - 1)` more (to the same braid's next word).
    static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 16 * 256)
        var single = [UInt32](repeating: 0, count: 256)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = crc[bit: 0] ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1
            }
            single[byte] = crc
        }
        for k in 0..<8 {
            for byte in 0..<256 {
                var crc = single[byte]
                for zeros in 1...(7 - k + 8 * (braids - 1)) {
                    crc = crc >> 8 ^ single[Int(crc[Byte.self, at: 0])]
                    if zeros == 7 - k { tables[k * 256 + byte] = crc }
                }
                if k == 7 { tables[k * 256 + byte] = single[byte] }
                tables[(8 + k) * 256 + byte] = crc
            }
        }
        return tables
    }()

    /// One set of eight tables (see ``tables``): a pointer to each, so each table's address is a register
    /// and a lookup is one load (`ldr w, [table, index, lsl #2]`).
    ///
    /// Unsafe: unchecked loads from `tables`' storage, valid while the caller has it borrowed. Safe: every
    /// index is a byte, below each table's 256 entries. The safe form, a 256-entry span per table, needs the
    /// optimizer to know each count is 256: it did in one loop and not in the other, and stating it made
    /// the first spill registers and check every lookup again (126 to 293 instructions per 40 bytes).
    @unsafe struct _Tables {
        let t0, t1, t2, t3, t4, t5, t6, t7: UnsafePointer<UInt32>

        /// The set starting at table `first` of `tables`.
        ///
        /// - Parameters:
        ///   - tables: The start of `tables`' storage.
        ///   - first: The set's first table: 0 or 8.
        @inline(__always)
        init(_ tables: UnsafePointer<UInt32>, first: Int) {
            let base = unsafe tables + first &* 256
            unsafe (t0, t1, t2, t3) = (base, base + 256, base + 512, base + 768)
            unsafe (t4, t5, t6, t7) = (base + 1024, base + 1280, base + 1536, base + 1792)
        }

        /// The combined contribution of a word's 8 bytes, the first in the low bits.
        ///
        /// - Parameter word: The bytes, with the register (or a braid's) added to the first four.
        /// - Returns: The register at the position the set advances to.
        @inline(__always)
        func callAsFunction(_ word: UInt64) -> UInt32 {
            // Eight independent loads, combined in a tree rather than a chain.
            let low = unsafe (t0[Int(word & 0xFF)] ^ t1[Int(word &>> 8 & 0xFF)]) ^ (t2[Int(word &>> 16 & 0xFF)] ^ t3[Int(word &>> 24 & 0xFF)])
            let high = unsafe (t4[Int(word &>> 32 & 0xFF)] ^ t5[Int(word &>> 40 & 0xFF)]) ^ (t6[Int(word &>> 48 & 0xFF)] ^ t7[Int(word &>> 56)])
            return low ^ high
        }
    }

    /// Updates the unconditioned register from tables: five interleaved CRCs ("braids", as in zlib) over
    /// consecutive 8-byte words, combined in the last 40-byte block, then 8 bytes per step (slicing-by-8),
    /// then single bytes.
    ///
    /// Slicing-by-8 alone is a chain: each word's eight lookups wait for the previous word's. Each braid
    /// covers every fifth word and jumps 40 bytes per step (its tables advance over the other braids'
    /// words as zeros), so five chains run at once, and the result is their sum, by linearity.
    ///
    /// - Parameters:
    ///   - state: The register, the complement of a checksum.
    ///   - bytes: The bytes to add.
    /// - Returns: The updated register.
    static func _tableUpdate(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
        // Unsafe: lookups through pointers. Safe: the storage is borrowed for the whole update (see `_Tables`).
        tables.withUnsafeBufferPointer { storage in unsafe _tableUpdate(state, bytes, storage.baseAddress!) }
    }

    /// ``_tableUpdate(_:_:)`` with the tables' storage borrowed.
    ///
    /// - Parameters:
    ///   - state: The register, the complement of a checksum.
    ///   - bytes: The bytes to add.
    ///   - storage: The start of ``tables``' storage.
    /// - Returns: The updated register.
    @unsafe @inline(__always)
    static func _tableUpdate(_ state: UInt32, _ bytes: RawSpan, _ storage: UnsafePointer<UInt32>) -> UInt32 {
        let slicing = unsafe _Tables(storage, first: 0)
        var state = state
        let words = bytes.byteCount / 8
        // Unsafe: unchecked loads. Safe: callers only ask for words below `words`, which are whole.
        func word(_ index: Int) -> UInt64 { unsafe Load.little(UInt64.self, from: bytes, at: index &* 8) }
        var done = 0 // Words.
        // At least one braided block and the block that combines them.
        if words >= 2 &* braids {
            let braid = unsafe _Tables(storage, first: 8)
            let blocks = words / braids
            var crc0 = UInt64(state), crc1: UInt64 = 0, crc2: UInt64 = 0, crc3: UInt64 = 0, crc4: UInt64 = 0
            for block in 0..<(blocks &- 1) {
                let first = block &* 5
                crc0 = UInt64(unsafe braid(crc0 ^ word(first)))
                crc1 = UInt64(unsafe braid(crc1 ^ word(first &+ 1)))
                crc2 = UInt64(unsafe braid(crc2 ^ word(first &+ 2)))
                crc3 = UInt64(unsafe braid(crc3 ^ word(first &+ 3)))
                crc4 = UInt64(unsafe braid(crc4 ^ word(first &+ 4)))
            }
            // The last block: each braid's register joins the combined one where its next word starts.
            let first = (blocks &- 1) &* 5
            var crc = unsafe slicing(crc0 ^ word(first))
            crc = unsafe slicing(UInt64(crc) ^ crc1 ^ word(first &+ 1))
            crc = unsafe slicing(UInt64(crc) ^ crc2 ^ word(first &+ 2))
            crc = unsafe slicing(UInt64(crc) ^ crc3 ^ word(first &+ 3))
            state = unsafe slicing(UInt64(crc) ^ crc4 ^ word(first &+ 4))
            done = blocks &* braids
        }
        for index in done..<words {
            state = unsafe slicing(UInt64(state) ^ word(index))
        }
        for offset in (words &* 8)..<bytes.byteCount {
            // Unsafe: an unchecked load. Safe: `offset` is below the byte count.
            let byte = unsafe Load.native(UInt8.self, from: bytes, at: offset)
            state = unsafe state >> 8 ^ slicing.t7[Int(UInt8(truncatingIfNeeded: state) ^ byte)]
        }
        return state
    }

    /// Computes the checksum with the tables that other CPUs use, for benchmarking it on this one.
    ///
    /// - Parameter bytes: The bytes to checksum.
    /// - Returns: The CRC-32 of `bytes`.
    @_spi(Benchmarking)
    public static func tableChecksum(_ bytes: RawSpan) -> UInt32 {
        ~_tableUpdate(~0, bytes)
    }
}
