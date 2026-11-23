// cursed-http's HPACK decoder and encoder (hpack.h; MIT), from the cursed-http test-data set (Tools/test-data fetch
// cursed-http), driven as ls-hpack is in hpack_references.c: one decoder or encoder for a sequence of field blocks. Its
// decoder checks every field's characters (RFC 9113 §8.2.1) once, keeping the verdict with table entries.

#include "../../../../TestData/cursed-http/include/hpack.h"
#include "hpack_references.h"

long cursed_hpack_decode_blocks(const unsigned char *bytes, const size_t *ends, const int *fields, size_t count) {
    static hp_dec dec;
    static hp_field out[512];
    static uint8_t arena[1 << 16];
    hp_dec_init(&dec, 4096);
    long total = 0;
    size_t start = 0;
    for (size_t i = 0; i < count; i++) {
        int flags = 0;
        int n = hp_decode_block(&dec, bytes + start, ends[i] - start, out, 512, arena, sizeof arena, 1u << 20, &flags);
        if (n != fields[i]) return -1;
        for (int j = 0; j < n; j++) total += out[j].nlen + out[j].vlen;
        start = ends[i];
    }
    return total;
}

long cursed_hpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count,
                              unsigned char *out, size_t capacity, size_t *block_ends) {
    static hp_enc enc;
    hp_enc_init(&enc, 4096);
    unsigned char *dst = out, *dst_end = out + capacity;
    size_t field = 0;
    for (size_t i = 0; i < count; i++) {
        if (dst_end - dst < 16) return -1;
        dst += hp_enc_begin(&enc, dst);
        for (; field < set_ends[i]; field++) {
            const uint32_t *o = offsets + 3 * field;
            if ((size_t)(dst_end - dst) < hp_enc_bound(o[1], o[2])) return -1;
            const uint8_t *name = (const uint8_t *)buf + o[0];
            dst += hp_enc_ifield(&enc, dst, name, o[1], name + o[1], o[2], 0);
        }
        block_ends[i] = (size_t)(dst - out);
    }
    return (long)(dst - out);
}
