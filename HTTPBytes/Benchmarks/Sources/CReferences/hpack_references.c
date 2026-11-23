// ls-hpack driven as a connection would: one decoder or encoder for a sequence of field blocks.

#include "lshpack.h"
#include "hpack_references.h"

long lshpack_decode_blocks(const unsigned char *bytes, const size_t *ends, const int *fields, size_t count) {
    struct lshpack_dec dec;
    lshpack_dec_init(&dec);
    char out[0x10000];
    long total = 0;
    size_t start = 0;
    for (size_t i = 0; i < count; i++) {
        const unsigned char *src = bytes + start, *end = bytes + ends[i];
        int n = 0;
        while (src < end) {
            struct lsxpack_header header;
            lsxpack_header_prepare_decode(&header, out, 0, sizeof out);
            if (lshpack_dec_decode(&dec, &src, end, &header) != 0) { lshpack_dec_cleanup(&dec); return -1; }
            total += header.name_len + header.val_len;
            n++;
        }
        if (n != fields[i]) { lshpack_dec_cleanup(&dec); return -1; }
        start = ends[i];
    }
    lshpack_dec_cleanup(&dec);
    return total;
}

long lshpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count,
                         unsigned char *out, size_t capacity, size_t *block_ends) {
    struct lshpack_enc enc;
    if (lshpack_enc_init(&enc) != 0) return -1;
    unsigned char *dst = out, *dst_end = out + capacity;
    size_t field = 0;
    for (size_t i = 0; i < count; i++) {
        for (; field < set_ends[i]; field++) {
            const uint32_t *o = offsets + 3 * field;
            struct lsxpack_header header;
            lsxpack_header_set_offset2(&header, buf + o[0], 0, o[1], o[1], o[2]);
            unsigned char *next = lshpack_enc_encode(&enc, dst, dst_end, &header);
            if (next == dst) { lshpack_enc_cleanup(&enc); return -1; }
            dst = next;
        }
        block_ends[i] = (size_t)(dst - out);
    }
    lshpack_enc_cleanup(&enc);
    return (long)(dst - out);
}
