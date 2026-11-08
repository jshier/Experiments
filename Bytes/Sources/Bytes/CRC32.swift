#if canImport(CBytesCRC)
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
/// it uses tables, eight bytes per step.
public struct CRC32: Hashable, Sendable {
    /// The checksum of everything added so far.
    public private(set) var value: UInt32

    /// A CRC of no bytes yet, or continuing from the checksum of earlier bytes (`value` of another
    /// `CRC32`, or a checksum stored with the data).
    public init(continuing value: UInt32 = 0) {
        self.value = value
    }

    /// Adds `bytes`.
    public mutating func update(_ bytes: RawSpan) {
        value = ~Self._update(~value, bytes)
    }

    /// Adds `bytes`.
    public mutating func update(_ bytes: Span<UInt8>) {
        update(bytes.bytes)
    }

    /// The checksum of `bytes`.
    public static func checksum(_ bytes: RawSpan) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    /// `state` (the unconditioned register) updated with `bytes`.
    static func _update(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
        #if canImport(CBytesCRC) && arch(arm64)
        _hardwareUpdate(state, bytes)
        #else
        _tableUpdate(state, bytes)
        #endif
    }
}

// MARK: - Apple silicon

#if canImport(CBytesCRC) && arch(arm64)
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
    /// Slicing-by-8 tables: `tables[k][b]` is the CRC of byte `b` followed by `k` zero bytes.
    ///
    /// Eight arrays rather than one `InlineArray<8, InlineArray<256, UInt32>>`: with separate arrays each
    /// table's address is a register, so a lookup is one load (`ldr w, [table, index, lsl #2]`), and the
    /// optimizer checks the bounds once, before the loop. A single global needs an `add` before each load,
    /// and the lookups are a latency chain: 7% slower, despite 23% fewer instructions.
    static let tables: [[UInt32]] = {
        var tables = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = crc[bit: 0] ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1
            }
            tables[0][byte] = crc
        }
        for k in 1..<8 {
            for byte in 0..<256 {
                let previous = tables[k - 1][byte]
                tables[k][byte] = previous >> 8 ^ tables[0][Int(previous[Byte.self, at: 0])]
            }
        }
        return tables
    }()

    /// `state` updated with `bytes` from tables: 8 bytes per step (8 lookups), then single bytes.
    static func _tableUpdate(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
        let tables = tables
        var state = state
        var reader = BytesReader(bytes)
        reader.forEach(Byte8.self) { group in
            // The register joins the first 4 bytes. Each byte is then looked up in the table for the bytes
            // still after it (7 for the first), and the results combine.
            let bytes = group ^ Byte8(UInt64(state), .littleEndian)
            state = 0
            for index in 0..<8 {
                state ^= tables[7 &- index][Int(bytes[index])]
            }
        }
        reader.forEach(Byte.self) { byte in
            state = state >> 8 ^ tables[0][Int(state[Byte.self, at: 0] ^ byte)]
        }
        return state
    }

    /// The table-driven checksum, which other CPUs use, for benchmarking it on this one.
    @_spi(Benchmarking)
    public static func tableChecksum(_ bytes: RawSpan) -> UInt32 {
        ~_tableUpdate(~0, bytes)
    }
}
