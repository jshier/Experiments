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

/// A lookup in a 48-byte table.
BYTES_INLINE bytes_u8x16 bytes_table3(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 index) {
#if defined(__aarch64__)
    uint8x16x3_t table = { { (uint8x16_t)a, (uint8x16_t)b, (uint8x16_t)c } };
    return (bytes_u8x16)vqtbl3q_u8(table, (uint8x16_t)index);
#else
    uint8_t table[48];
    for (int i = 0; i < 16; i++) {
        table[i] = a[i]; table[16 + i] = b[i]; table[32 + i] = c[i];
    }
    return bytes_table_portable(table, 48, index);
#endif
}

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

/// Four vectors, imported into Swift as a struct of four `SIMD16<UInt8>`s.
typedef struct { bytes_u8x16 v0, v1, v2, v3; } bytes_u8x16x4;

/// The bytes of four vectors interleaved, as NEON's `st4` stores them: a[0], b[0], c[0], d[0], a[1], …, in
/// the four result vectors in order. Two rounds of `zip`s: bytes of a and b, and of c and d, then 2-byte
/// pairs of those. An empty `asm` between the rounds stops LLVM from merging each pair of zips into one
/// shuffle of four vectors, which ARM64 can only build a lane at a time (measured: 1 `zip` and 14 inserts
/// instead of 3 `zip`s per vector).
BYTES_INLINE bytes_u8x16x4 bytes_interleave4(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d) {
    bytes_u8x16x4 result;
#if defined(__aarch64__)
    uint8x16_t ab0 = vzip1q_u8((uint8x16_t)a, (uint8x16_t)b), ab1 = vzip2q_u8((uint8x16_t)a, (uint8x16_t)b);
    uint8x16_t cd0 = vzip1q_u8((uint8x16_t)c, (uint8x16_t)d), cd1 = vzip2q_u8((uint8x16_t)c, (uint8x16_t)d);
    __asm__("" : "+w"(ab0), "+w"(ab1), "+w"(cd0), "+w"(cd1));
    result.v0 = (bytes_u8x16)vreinterpretq_u8_u16(vzip1q_u16(vreinterpretq_u16_u8(ab0), vreinterpretq_u16_u8(cd0)));
    result.v1 = (bytes_u8x16)vreinterpretq_u8_u16(vzip2q_u16(vreinterpretq_u16_u8(ab0), vreinterpretq_u16_u8(cd0)));
    result.v2 = (bytes_u8x16)vreinterpretq_u8_u16(vzip1q_u16(vreinterpretq_u16_u8(ab1), vreinterpretq_u16_u8(cd1)));
    result.v3 = (bytes_u8x16)vreinterpretq_u8_u16(vzip2q_u16(vreinterpretq_u16_u8(ab1), vreinterpretq_u16_u8(cd1)));
#else
    bytes_u8x16 *out[4] = { &result.v0, &result.v1, &result.v2, &result.v3 };
    for (int i = 0; i < 64; i++) {
        bytes_u8x16 source = (i % 4 == 0) ? a : (i % 4 == 1) ? b : (i % 4 == 2) ? c : d;
        (*out[i / 16])[i % 16] = source[i / 4];
    }
#endif
    return result;
}

#endif
