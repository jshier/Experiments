// Byte shuffles for the Bytes package: NEON table lookups (`tbl`) that Swift can't express. Swift's SIMD
// swizzle compiles to a scalar loop, and its `Builtin` module doesn't expose CPU-specific intrinsics.
//
// `bytes_table4` returns, for every lane i, byte `index[i]` of the four concatenated table vectors, or 0 if
// `index[i]` is past the end: exactly NEON's `vqtbl4q_u8`. Swift imports `bytes_u8x16` as
// `SIMD16<UInt8>`, and the `static inline` function is inlined into Swift code as a single `tbl`
// instruction. Other architectures get a portable fallback with the same results.

#ifndef C_BYTES_NEON_H
#define C_BYTES_NEON_H

#include <stdint.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

/// 16 bytes, imported into Swift as `SIMD16<UInt8>`.
typedef uint8_t bytes_u8x16 __attribute__((ext_vector_type(16)));

#define BYTES_INLINE static inline __attribute__((always_inline))

#if !defined(__aarch64__)
BYTES_INLINE bytes_u8x16 bytes_table_portable(const uint8_t *table, int count, bytes_u8x16 index) {
    bytes_u8x16 result;
    for (int lane = 0; lane < 16; lane++) {
        result[lane] = index[lane] < count ? table[index[lane]] : 0;
    }
    return result;
}
#endif

/// A lookup in a 64-byte table.
BYTES_INLINE bytes_u8x16 bytes_table4(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d, bytes_u8x16 index) {
#if defined(__aarch64__)
    uint8x16x4_t table = { { (uint8x16_t)a, (uint8x16_t)b, (uint8x16_t)c, (uint8x16_t)d } };
    return (bytes_u8x16)vqtbl4q_u8(table, (uint8x16_t)index);
#else
    uint8_t table[64];
    for (int i = 0; i < 16; i++) {
        table[i] = a[i]; table[16 + i] = b[i]; table[32 + i] = c[i]; table[48 + i] = d[i];
    }
    return bytes_table_portable(table, 64, index);
#endif
}

#endif
