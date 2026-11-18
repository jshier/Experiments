// ARMv8's cryptography instructions, one wrapper per instruction: AES rounds (`aese`, `aesmc`), SHA-1 and SHA-256
// steps (`sha1c`/`sha1p`/`sha1m`/`sha1h`/`sha1su0`/`sha1su1`, `sha256h`/`sha256h2`/`sha256su0`/`sha256su1`),
// carry-less multiplication (`pmull`, for GHASH), and the byte reversals the hashes' big-endian words need. Swift
// has no intrinsics and its `Builtin` module doesn't expose CPU-specific ones; everything else (key schedules,
// rounds, modes, padding) is Swift, in `BytesCrypto`. Each wrapper is `static inline`, so Swift inlines it as the
// instruction itself.
//
// Only defined where the CPU has them (every Apple silicon Mac and device); `BytesCrypto` uses portable,
// constant-time Swift elsewhere, and on ARM64 with `BYTES_PORTABLE` defined (the package's `Portable` trait).

#ifndef C_BYTES_CRYPTO_H
#define C_BYTES_CRYPTO_H

#include <stdint.h>

#if defined(__aarch64__) && defined(__ARM_FEATURE_AES) && defined(__ARM_FEATURE_SHA2) && !defined(BYTES_PORTABLE)
#define BYTES_HAS_HARDWARE_CRYPTO 1
#include <arm_neon.h>

/// 16 bytes, imported into Swift as `SIMD16<UInt8>`.
typedef uint8_t bytes_crypto_u8x16 __attribute__((ext_vector_type(16)));
/// Four 32-bit words, imported into Swift as `SIMD4<UInt32>`.
typedef uint32_t bytes_crypto_u32x4 __attribute__((ext_vector_type(4)));
/// Two 64-bit words, imported into Swift as `SIMD2<UInt64>`.
typedef uint64_t bytes_crypto_u64x2 __attribute__((ext_vector_type(2)));

#define BYTES_CRYPTO_INLINE static inline __attribute__((always_inline))

// MARK: AES

/// `aese`: AddRoundKey with `key`, then SubBytes and ShiftRows.
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_aese(bytes_crypto_u8x16 state, bytes_crypto_u8x16 key) {
    return (bytes_crypto_u8x16)vaeseq_u8((uint8x16_t)state, (uint8x16_t)key);
}

/// `aesmc`: MixColumns.
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_aesmc(bytes_crypto_u8x16 state) {
    return (bytes_crypto_u8x16)vaesmcq_u8((uint8x16_t)state);
}

/// `aese` then `aesmc`: one full middle round but its key addition (which the next `aese` does). Apple's cores
/// fuse the pair.
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_aes_round(bytes_crypto_u8x16 state, bytes_crypto_u8x16 key) {
    return (bytes_crypto_u8x16)vaesmcq_u8(vaeseq_u8((uint8x16_t)state, (uint8x16_t)key));
}

// MARK: SHA-1

/// `sha1c`: four rounds with the "choose" function.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha1c(bytes_crypto_u32x4 abcd, uint32_t e, bytes_crypto_u32x4 wk) {
    return (bytes_crypto_u32x4)vsha1cq_u32((uint32x4_t)abcd, e, (uint32x4_t)wk);
}

/// `sha1p`: four rounds with the parity function.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha1p(bytes_crypto_u32x4 abcd, uint32_t e, bytes_crypto_u32x4 wk) {
    return (bytes_crypto_u32x4)vsha1pq_u32((uint32x4_t)abcd, e, (uint32x4_t)wk);
}

/// `sha1m`: four rounds with the majority function.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha1m(bytes_crypto_u32x4 abcd, uint32_t e, bytes_crypto_u32x4 wk) {
    return (bytes_crypto_u32x4)vsha1mq_u32((uint32x4_t)abcd, e, (uint32x4_t)wk);
}

/// `sha1h`: `e` rotated left by 30.
BYTES_CRYPTO_INLINE uint32_t bytes_sha1h(uint32_t e) { return vsha1h_u32(e); }

/// `sha1su0`: the first half of the message schedule update.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha1su0(bytes_crypto_u32x4 w0, bytes_crypto_u32x4 w1, bytes_crypto_u32x4 w2) {
    return (bytes_crypto_u32x4)vsha1su0q_u32((uint32x4_t)w0, (uint32x4_t)w1, (uint32x4_t)w2);
}

/// `sha1su1`: the second half of the message schedule update.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha1su1(bytes_crypto_u32x4 tw, bytes_crypto_u32x4 w3) {
    return (bytes_crypto_u32x4)vsha1su1q_u32((uint32x4_t)tw, (uint32x4_t)w3);
}

// MARK: SHA-256

/// `sha256h`: four rounds, updating ABCD.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha256h(bytes_crypto_u32x4 abcd, bytes_crypto_u32x4 efgh, bytes_crypto_u32x4 wk) {
    return (bytes_crypto_u32x4)vsha256hq_u32((uint32x4_t)abcd, (uint32x4_t)efgh, (uint32x4_t)wk);
}

/// `sha256h2`: four rounds, updating EFGH.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha256h2(bytes_crypto_u32x4 efgh, bytes_crypto_u32x4 abcd, bytes_crypto_u32x4 wk) {
    return (bytes_crypto_u32x4)vsha256h2q_u32((uint32x4_t)efgh, (uint32x4_t)abcd, (uint32x4_t)wk);
}

/// `sha256su0`: the first half of the message schedule update.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha256su0(bytes_crypto_u32x4 w0, bytes_crypto_u32x4 w1) {
    return (bytes_crypto_u32x4)vsha256su0q_u32((uint32x4_t)w0, (uint32x4_t)w1);
}

/// `sha256su1`: the second half of the message schedule update.
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_sha256su1(bytes_crypto_u32x4 tw, bytes_crypto_u32x4 w2, bytes_crypto_u32x4 w3) {
    return (bytes_crypto_u32x4)vsha256su1q_u32((uint32x4_t)tw, (uint32x4_t)w2, (uint32x4_t)w3);
}

// MARK: Byte order and carry-less multiplication

/// `rev32`: each 32-bit word's bytes reversed (big-endian words to native and back).
BYTES_CRYPTO_INLINE bytes_crypto_u32x4 bytes_rev32(bytes_crypto_u8x16 bytes) {
    return (bytes_crypto_u32x4)vrev32q_u8((uint8x16_t)bytes);
}

/// `rev32` the other way: four native words to bytes, each word's bytes reversed (native words to big-endian).
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_rev32_words(bytes_crypto_u32x4 words) {
    return (bytes_crypto_u8x16)vrev32q_u8(vreinterpretq_u8_u32((uint32x4_t)words));
}

/// All sixteen bytes reversed (`rev64` then `ext`): a GCM block as one big-endian 128-bit integer, in two
/// native 64-bit lanes (low, high).
BYTES_CRYPTO_INLINE bytes_crypto_u64x2 bytes_reverse16(bytes_crypto_u8x16 bytes) {
    uint8x16_t swapped = vrev64q_u8((uint8x16_t)bytes);
    return (bytes_crypto_u64x2)vreinterpretq_u64_u8(vextq_u8(swapped, swapped, 8));
}

/// The inverse of `bytes_reverse16`: two native lanes back to sixteen bytes in GCM's order.
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_unreverse16(bytes_crypto_u64x2 words) {
    uint8x16_t bytes = vreinterpretq_u8_u64((uint64x2_t)words);
    uint8x16_t swapped = vrev64q_u8(bytes);
    return (bytes_crypto_u8x16)vextq_u8(swapped, swapped, 8);
}

/// `rev64`: each 64-bit word's bytes reversed.
BYTES_CRYPTO_INLINE bytes_crypto_u8x16 bytes_rev64(bytes_crypto_u8x16 bytes) {
    return (bytes_crypto_u8x16)vrev64q_u8((uint8x16_t)bytes);
}

/// `pmull`: the low 64-bit lanes of `a` and `b` multiplied carry-less, a 128-bit product.
BYTES_CRYPTO_INLINE bytes_crypto_u64x2 bytes_pmull_low(bytes_crypto_u64x2 a, bytes_crypto_u64x2 b) {
    return (bytes_crypto_u64x2)vreinterpretq_u64_p128(vmull_p64(vgetq_lane_p64(vreinterpretq_p64_u64((uint64x2_t)a), 0),
                                                                 vgetq_lane_p64(vreinterpretq_p64_u64((uint64x2_t)b), 0)));
}

/// `pmull2`: the high 64-bit lanes of `a` and `b` multiplied carry-less, a 128-bit product.
BYTES_CRYPTO_INLINE bytes_crypto_u64x2 bytes_pmull_high(bytes_crypto_u64x2 a, bytes_crypto_u64x2 b) {
    return (bytes_crypto_u64x2)vreinterpretq_u64_p128(vmull_high_p64(vreinterpretq_p64_u64((uint64x2_t)a),
                                                                      vreinterpretq_p64_u64((uint64x2_t)b)));
}

/// `eor3`: three-way XOR (SHA-3 extension), or two `eor`s without it.
BYTES_CRYPTO_INLINE bytes_crypto_u64x2 bytes_xor3(bytes_crypto_u64x2 a, bytes_crypto_u64x2 b, bytes_crypto_u64x2 c) {
#if defined(__ARM_FEATURE_SHA3)
    return (bytes_crypto_u64x2)veor3q_u64((uint64x2_t)a, (uint64x2_t)b, (uint64x2_t)c);
#else
    return (bytes_crypto_u64x2)veorq_u64(veorq_u64((uint64x2_t)a, (uint64x2_t)b), (uint64x2_t)c);
#endif
}

#endif

#endif
