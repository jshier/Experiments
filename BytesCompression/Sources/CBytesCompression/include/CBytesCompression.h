// CPU instructions for BytesCompression's CRCs that Swift can't express: ARM's carry-less multiply (`pmull`) and
// three-way XOR (`eor3`), for CRC-64's and bzip2's folding (`CRCFold`). Swift's SIMD types have no carry-less multiply,
// and its `Builtin` module doesn't expose CPU-specific intrinsics. Each wrapper is `static inline`, so Swift inlines it
// as the instruction itself. A copy of what BytesCompression used from Bytes' CBytesCRC (which keeps its own for CRC-32
// and Adler-32), with the same names, since the package moved out of Bytes. Only defined where the CPU has them (every
// Apple silicon Mac and device); BytesCompression uses its tables elsewhere, and on ARM64 with `BYTES_PORTABLE`
// defined (the package's `Portable` trait).

#ifndef C_BYTES_COMPRESSION_H
#define C_BYTES_COMPRESSION_H

#include <stdint.h>

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32) && defined(__ARM_FEATURE_AES) && defined(__ARM_FEATURE_DOTPROD) && !defined(BYTES_PORTABLE)
#include <arm_neon.h>

/// 16 bytes, imported into Swift as `SIMD16<UInt8>`.
typedef uint8_t bytes_crc_u8x16 __attribute__((ext_vector_type(16)));

/// Folds `x` forward over the bits that `constants` were made for, and adds (XORs) `data`:
/// `x.low × constants.low ⊕ x.high × constants.high ⊕ data`, carry-less.
static inline __attribute__((always_inline)) bytes_crc_u8x16 bytes_crc_fold(bytes_crc_u8x16 x, bytes_crc_u8x16 data, bytes_crc_u8x16 constants) {
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

#endif

#endif
