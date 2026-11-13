// Byte shuffles for the Bytes package: NEON table lookups (`tbl`) that Swift can't express. Swift's SIMD
// swizzle compiles to a scalar loop, and its `Builtin` module doesn't expose CPU-specific intrinsics.
//
// `bytes_table4` returns, for every lane i, byte `index[i]` of the four concatenated table vectors, or 0 if
// `index[i]` is past the end: exactly NEON's `vqtbl4q_u8`. Swift imports `bytes_u8x16` as
// `SIMD16<UInt8>`, and the `static inline` function is inlined into Swift code as a single `tbl`
// instruction. Other architectures get a portable fallback with the same results; so does ARM64 with
// `BYTES_PORTABLE` defined (the package's `Portable` trait), to measure that fallback on Apple silicon.

#ifndef C_BYTES_NEON_H
#define C_BYTES_NEON_H

#include <stdint.h>

#if defined(__aarch64__) && !defined(BYTES_PORTABLE)
#define BYTES_NEON 1
#include <arm_neon.h>
#endif

/// 16 bytes, imported into Swift as `SIMD16<UInt8>`.
typedef uint8_t bytes_u8x16 __attribute__((ext_vector_type(16)));

#define BYTES_INLINE static inline __attribute__((always_inline))

#if !defined(BYTES_NEON)
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
#if defined(BYTES_NEON)
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
#if defined(BYTES_NEON)
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

/// A lookup in a 16-byte table: `vqtbl1q_u8`.
BYTES_INLINE bytes_u8x16 bytes_table1(bytes_u8x16 a, bytes_u8x16 index) {
#if defined(BYTES_NEON)
    return (bytes_u8x16)vqtbl1q_u8((uint8x16_t)a, (uint8x16_t)index);
#else
    uint8_t table[16];
    for (int i = 0; i < 16; i++) table[i] = a[i];
    return bytes_table_portable(table, 16, index);
#endif
}

/// A lookup in a 16-byte table that keeps `fallback`'s lane where `index[i]` is 16 or more: `vqtbx1q_u8`.
BYTES_INLINE bytes_u8x16 bytes_table1x(bytes_u8x16 fallback, bytes_u8x16 a, bytes_u8x16 index) {
#if defined(BYTES_NEON)
    return (bytes_u8x16)vqtbx1q_u8((uint8x16_t)fallback, (uint8x16_t)a, (uint8x16_t)index);
#else
    bytes_u8x16 looked = bytes_table1(a, index);
    for (int lane = 0; lane < 16; lane++) {
        if (index[lane] >= 16) looked[lane] = fallback[lane];
    }
    return looked;
#endif
}

/// A lookup in a 48-byte table that keeps `fallback`'s lane where `index[i]` is 48 or more: `vqtbx3q_u8`.
BYTES_INLINE bytes_u8x16 bytes_table3x(bytes_u8x16 fallback, bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 index) {
#if defined(BYTES_NEON)
    uint8x16x3_t table = { { (uint8x16_t)a, (uint8x16_t)b, (uint8x16_t)c } };
    return (bytes_u8x16)vqtbx3q_u8((uint8x16_t)fallback, table, (uint8x16_t)index);
#else
    bytes_u8x16 looked = bytes_table3(a, b, c, index);
    for (int lane = 0; lane < 16; lane++) {
        if (index[lane] >= 48) looked[lane] = fallback[lane];
    }
    return looked;
#endif
}

/// A lookup in a 64-byte table that keeps `fallback`'s lane where `index[i]` is 64 or more: `vqtbx4q_u8`.
BYTES_INLINE bytes_u8x16 bytes_table4x(bytes_u8x16 fallback, bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d, bytes_u8x16 index) {
#if defined(BYTES_NEON)
    uint8x16x4_t table = { { (uint8x16_t)a, (uint8x16_t)b, (uint8x16_t)c, (uint8x16_t)d } };
    return (bytes_u8x16)vqtbx4q_u8((uint8x16_t)fallback, table, (uint8x16_t)index);
#else
    bytes_u8x16 looked = bytes_table4(a, b, c, d, index);
    for (int lane = 0; lane < 16; lane++) {
        if (index[lane] >= 64) looked[lane] = fallback[lane];
    }
    return looked;
#endif
}

/// Four vectors, imported into Swift as a struct of four `SIMD16<UInt8>`s.
typedef struct { bytes_u8x16 v0, v1, v2, v3; } bytes_u8x16x4;

/// Every fourth byte of a, b, c, d (64 bytes in order), as NEON's `ld4` loads them: bytes 0, 4, … 60, then
/// 1, 5, … 61, then 2, … 62, then 3, … 63. Two rounds of `uzp`s, 8 in all: the even and odd bytes of a and
/// b, and of c and d, then the even and odd bytes of those. The empty `asm` between the rounds keeps LLVM
/// from merging them into four-vector shuffles, as in `bytes_interleave4`. The one before them keeps it
/// from narrowing the loads of a, b, c, and d: since each `uzp` takes only half the bytes of its sources,
/// LLVM loaded each vector from memory in 8-, 4-, 2-, and 1-byte lanes (measured: 91 instructions per
/// Base64 block against 45).
BYTES_INLINE bytes_u8x16x4 bytes_deinterleave4(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d) {
    bytes_u8x16x4 result;
#if defined(BYTES_NEON)
    __asm__("" : "+w"(a), "+w"(b), "+w"(c), "+w"(d));
    uint8x16_t abEven = vuzp1q_u8((uint8x16_t)a, (uint8x16_t)b), abOdd = vuzp2q_u8((uint8x16_t)a, (uint8x16_t)b);
    uint8x16_t cdEven = vuzp1q_u8((uint8x16_t)c, (uint8x16_t)d), cdOdd = vuzp2q_u8((uint8x16_t)c, (uint8x16_t)d);
    __asm__("" : "+w"(abEven), "+w"(abOdd), "+w"(cdEven), "+w"(cdOdd));
    result.v0 = (bytes_u8x16)vuzp1q_u8(abEven, cdEven);
    result.v1 = (bytes_u8x16)vuzp1q_u8(abOdd, cdOdd);
    result.v2 = (bytes_u8x16)vuzp2q_u8(abEven, cdEven);
    result.v3 = (bytes_u8x16)vuzp2q_u8(abOdd, cdOdd);
#else
    bytes_u8x16 *out[4] = { &result.v0, &result.v1, &result.v2, &result.v3 };
    for (int i = 0; i < 64; i++) {
        bytes_u8x16 source = (i < 16) ? a : (i < 32) ? b : (i < 48) ? c : d;
        (*out[i % 4])[i / 4] = source[i % 16];
    }
#endif
    return result;
}

/// The bytes of four vectors interleaved, as NEON's `st4` stores them: a[0], b[0], c[0], d[0], a[1], …, in
/// the four result vectors in order. Two rounds of `zip`s: bytes of a and b, and of c and d, then 2-byte
/// pairs of those. An empty `asm` between the rounds stops LLVM from merging each pair of zips into one
/// shuffle of four vectors, which ARM64 can only build a lane at a time (measured: 1 `zip` and 14 inserts
/// instead of 3 `zip`s per vector).
BYTES_INLINE bytes_u8x16x4 bytes_interleave4(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d) {
    bytes_u8x16x4 result;
#if defined(BYTES_NEON)
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
