// CPU instructions for CRC-32 that Swift can't express: ARM's carry-less multiply (`pmull`), three-way XOR
// (`eor3`), and CRC32 instructions. Swift's SIMD types have no carry-less multiply, and its `Builtin`
// module doesn't expose CPU-specific intrinsics. Each wrapper is `static inline`, so Swift inlines it as
// the instruction itself. Only defined where the CPU has them (every Apple silicon Mac and device);
// `Bytes` uses a portable table-driven CRC elsewhere.

#ifndef C_BYTES_CRC_H
#define C_BYTES_CRC_H

#include <stdint.h>

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32) && defined(__ARM_FEATURE_AES)
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

/// The CRC32 instructions: `crc` updated with 8 bytes (little-endian) or one byte, unconditioned.
BYTES_CRC_INLINE uint32_t bytes_crc32_u64(uint32_t crc, uint64_t value) { return __crc32d(crc, value); }
BYTES_CRC_INLINE uint32_t bytes_crc32_u8(uint32_t crc, uint8_t value) { return __crc32b(crc, value); }

#endif

#endif
