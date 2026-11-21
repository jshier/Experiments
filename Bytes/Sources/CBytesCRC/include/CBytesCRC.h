// CPU instructions for CRC-32 that Swift can't express: ARM's carry-less multiply (`pmull`), three-way XOR
// (`eor3`), and CRC32 instructions. Swift's SIMD types have no carry-less multiply, and its `Builtin`
// module doesn't expose CPU-specific intrinsics. Each wrapper is `static inline`, so Swift inlines it as
// the instruction itself. Only defined where the CPU has them (every Apple silicon Mac and device);
// `Bytes` uses a portable table-driven CRC elsewhere, and on ARM64 with `BYTES_PORTABLE` defined (the
// package's `Portable` trait).

#ifndef C_BYTES_CRC_H
#define C_BYTES_CRC_H

#include <stdint.h>

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32) && defined(__ARM_FEATURE_AES) && defined(__ARM_FEATURE_DOTPROD) && !defined(BYTES_PORTABLE)
#define BYTES_HAS_HARDWARE_CRC 1
#include <arm_acle.h>
#include <arm_neon.h>

/// 16 bytes, imported into Swift as `SIMD16<UInt8>`.
typedef uint8_t bytes_crc_u8x16 __attribute__((ext_vector_type(16)));

#define BYTES_CRC_INLINE static inline __attribute__((always_inline))

/// Folds `x` forward over the bits that `constants` were made for, and adds (XORs) `data`:
/// `x.low × constants.low ⊕ x.high × constants.high ⊕ data`, carry-less.
BYTES_CRC_INLINE bytes_crc_u8x16 bytes_crc_fold(bytes_crc_u8x16 x, bytes_crc_u8x16 data, bytes_crc_u8x16 constants) {
    poly64x2_t value = vreinterpretq_p64_u8((uint8x16_t)x);
    poly64x2_t k = vreinterpretq_p64_u8((uint8x16_t)constants);
    uint8x16_t low = vreinterpretq_u8_p128(vmull_p64(vgetq_lane_p64(value, 0), vgetq_lane_p64(k, 0)));
    uint8x16_t high = vreinterpretq_u8_p128(vmull_high_p64(value, k));
#if defined(__ARM_FEATURE_SHA3)
    return (bytes_crc_u8x16)veor3q_u8(low, high, (uint8x16_t)data);
#else
    return (bytes_crc_u8x16)veorq_u8(veorq_u8(low, high), (uint8x16_t)data);
#endif
}

/// Four 32-bit lanes, imported into Swift as `SIMD4<UInt32>`.
typedef uint32_t bytes_crc_u32x4 __attribute__((ext_vector_type(4)));

/// `acc` plus, in each 32-bit lane, the dot product of that lane's four bytes of `a` and of `b` (UDOT, `FEAT_DotProd`:
/// every Apple silicon CPU from the M1 on). Swift's SIMD types have no widening dot product: Adler-32 uses it for
/// the byte sums (against ones) and the position-weighted sums (against weights), 16 bytes in one instruction.
BYTES_CRC_INLINE bytes_crc_u32x4 bytes_crc_udot(bytes_crc_u32x4 acc, bytes_crc_u8x16 a, bytes_crc_u8x16 b) {
    return (bytes_crc_u32x4)vdotq_u32((uint32x4_t)acc, (uint8x16_t)a, (uint8x16_t)b);
}

/// The weights 128, 127, …, 1 for a 128-byte Adler-32 step, as eight vectors (`k` 0 through 7, constant after
/// inlining): the weight of the byte at position `j` in the step is `128 - j`. The last four (`k` 4 through 7) are
/// 64, …, 1, the weights of a single 64-byte block.
BYTES_CRC_INLINE bytes_crc_u8x16 bytes_adler_weights(int k) {
    static const uint8_t weights[128] = {
        128, 127, 126, 125, 124, 123, 122, 121, 120, 119, 118, 117, 116, 115, 114, 113, 112, 111, 110, 109, 108, 107,
        106, 105, 104, 103, 102, 101, 100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 86, 85, 84, 83, 82, 81,
        80, 79, 78, 77, 76, 75, 74, 73, 72, 71, 70, 69, 68, 67, 66, 65, 64, 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53,
        52, 51, 50, 49, 48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 25,
        24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1,
    };
    return (bytes_crc_u8x16)vld1q_u8(weights + 16 * k);
}

/// The CRC32 instructions: `crc` updated with 8 bytes (little-endian) or one byte, unconditioned.
BYTES_CRC_INLINE uint32_t bytes_crc32_u64(uint32_t crc, uint64_t value) { return __crc32d(crc, value); }
BYTES_CRC_INLINE uint32_t bytes_crc32_u8(uint32_t crc, uint8_t value) { return __crc32b(crc, value); }

#endif

#endif
