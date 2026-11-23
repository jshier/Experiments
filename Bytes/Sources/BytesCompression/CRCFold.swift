#if HardwareCRC && arch(arm64) && !Portable
internal import CBytesCRC

/// Carry-less-multiply folding (`pmull`) for the CRCs here that fold 64 bytes per step: CRC-64 (`.xz`), reflected,
/// and bzip2's CRC, most significant bit first. They differ only in the load (bzip2's blocks are byte-reversed, so
/// memory order becomes a polynomial's), where the register goes in the first block, and the constants. (CRC-32,
/// in Bytes, folds 128 bytes per step and finishes with the CRC32 instructions: its own fold.)
enum CRCFold {
    /// Folds the whole 16-byte blocks of `count` bytes (at least 64) at `input` into one: four accumulators moving
    /// 64 bytes per step, then the rest 16 at a time.
    ///
    /// Always inlined into each CRC's own (not inlined) `fold`, with `reversed` a literal, so each has its loads
    /// and nothing tests `reversed` at run time.
    ///
    /// - Parameters:
    ///   - initial: XORed into the first block: the unconditioned register, where the CRC's frame puts it.
    ///   - input: The bytes.
    ///   - count: How many there are, at least 64.
    ///   - reversed: Whether each block is byte-reversed when loaded.
    ///   - fold512: The constants that move a block 512 bits forward.
    ///   - fold128: The constants that move a block 128 bits forward.
    /// - Returns: The folded block (byte-reversed if `reversed`), whose CRC from zero continued with the bytes after
    ///   `count` rounded down to 16 is the CRC of all of them; and that rounded count.
    @inline(__always)
    static func fold(
        _ initial: SIMD16<UInt8>, _ input: UnsafeRawPointer, _ count: Int, reversed: Bool, fold512: SIMD16<UInt8>,
        fold128: SIMD16<UInt8>
    ) -> (state: SIMD16<UInt8>, count: Int) {
        // Unsafe: 16-byte loads. Safe: each is below `count` (checked by the loops), which the caller's buffer
        // holds.
        @inline(always) func load(_ offset: Int) -> SIMD16<UInt8> {
            let block = unsafe input.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            return reversed ? reverse(block) : block
        }
        var x0 = load(0) ^ initial
        var x1 = load(16), x2 = load(32), x3 = load(48)
        var index = 64
        while count &- index >= 64 {
            x0 = bytes_crc_fold(x0, load(index), fold512)
            x1 = bytes_crc_fold(x1, load(index &+ 16), fold512)
            x2 = bytes_crc_fold(x2, load(index &+ 32), fold512)
            x3 = bytes_crc_fold(x3, load(index &+ 48), fold512)
            index &+= 64
        }
        var x = bytes_crc_fold(x0, x1, fold128)
        x = bytes_crc_fold(x, x2, fold128)
        x = bytes_crc_fold(x, x3, fold128)
        while count &- index >= 16 {
            x = bytes_crc_fold(x, load(index), fold128)
            index &+= 16
        }
        return (x, index)
    }

    /// A vector's bytes in reverse order: memory order to a 128-bit polynomial's, first byte highest.
    @inline(__always)
    static func reverse(_ v: SIMD16<UInt8>) -> SIMD16<UInt8> {
        SIMD16(v[15], v[14], v[13], v[12], v[11], v[10], v[9], v[8], v[7], v[6], v[5], v[4], v[3], v[2], v[1], v[0])
    }
}
#endif
