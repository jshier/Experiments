// ls-qpack and cursed-http's QPACK, driven as described in qpack_references.h.

#include "lsqpack.h"
#include "lsxpack_header.h"
#include "../../../../TestData/cursed-http/include/qpack.h"
#include "qpack_references.h"

// A Section Acknowledgment (RFC 9204 §4.4.1) for `stream`: 1 + 7-bit prefix integer.
static size_t section_ack(unsigned char *out, uint64_t stream) {
    if (stream < 127) { out[0] = (unsigned char)(0x80 | stream); return 1; }
    out[0] = 0xFF;
    uint64_t rest = stream - 127;
    size_t n = 1;
    while (rest >= 128) { out[n++] = (unsigned char)(rest | 0x80); rest >>= 7; }
    out[n++] = (unsigned char)rest;
    return n;
}

// MARK: - ls-qpack

struct lsqpack_context {
    struct lsxpack_header header;
    char buffer[0x10000];
    long total;
    int fields;
};

static void lsqpack_unblocked(void *context) { (void)context; }

static struct lsxpack_header *lsqpack_prepare(void *context, struct lsxpack_header *header, size_t space) {
    struct lsqpack_context *c = context;
    if (space > sizeof c->buffer) return NULL;
    if (header) { header->val_len = (lsxpack_strlen_t)space; return header; }
    lsxpack_header_prepare_decode(&c->header, c->buffer, 0, space);
    return &c->header;
}

static int lsqpack_process(void *context, struct lsxpack_header *header) {
    struct lsqpack_context *c = context;
    c->total += header->name_len + header->val_len;
    c->fields++;
    return 0;
}

static const struct lsqpack_dec_hset_if lsqpack_callbacks = {
    .dhi_unblocked = lsqpack_unblocked,
    .dhi_prepare_decode = lsqpack_prepare,
    .dhi_process_header = lsqpack_process,
};

long lsqpack_decode_sections(const unsigned char *bytes, const size_t *ins_ends, const size_t *sec_ends, const int *fields,
                             size_t count, unsigned capacity) {
    static struct lsqpack_context context;
    struct lsqpack_dec dec;
    lsqpack_dec_init(&dec, NULL, capacity, 100, &lsqpack_callbacks, 0);
    context.total = 0;
    size_t start = 0;
    for (size_t i = 0; i < count; i++) {
        if (ins_ends[i] > start && lsqpack_dec_enc_in(&dec, bytes + start, ins_ends[i] - start) != 0) goto fail;
        const unsigned char *p = bytes + ins_ends[i];
        size_t size = sec_ends[i] - ins_ends[i];
        unsigned char ack[LSQPACK_LONGEST_HEADER_ACK];
        size_t ack_size = sizeof ack;
        context.fields = 0;
        if (lsqpack_dec_header_in(&dec, &context, 4 * i, size, &p, size, ack, &ack_size) != LQRHS_DONE) goto fail;
        if (context.fields != fields[i]) goto fail;
        start = sec_ends[i];
    }
    lsqpack_dec_cleanup(&dec);
    return context.total;
fail:
    lsqpack_dec_cleanup(&dec);
    return -1;
}

long lsqpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count, unsigned capacity,
                         unsigned char *out, size_t out_capacity, size_t *ins_ends, size_t *sec_ends) {
    static unsigned char lines[0x10000];
    struct lsqpack_enc enc;
    unsigned char sdtc[LSQPACK_LONGEST_SDTC];
    size_t sdtc_size = sizeof sdtc;
    lsqpack_enc_preinit(&enc, NULL);
    if (lsqpack_enc_init(&enc, NULL, capacity, capacity, capacity ? 100 : 0, 0, capacity ? sdtc : NULL,
                         capacity ? &sdtc_size : NULL) != 0) return -1;
    unsigned char *dst = out, *end = out + out_capacity;
    if (capacity) { memcpy(dst, sdtc, sdtc_size); dst += sdtc_size; }
    size_t field = 0;
    for (size_t i = 0; i < count; i++) {
        uint64_t stream = 4 * i;
        if (lsqpack_enc_start_header(&enc, stream, 0) != 0) goto fail;
        size_t line_count = 0;
        for (; field < set_ends[i]; field++) {
            const uint32_t *o = offsets + 3 * field;
            struct lsxpack_header header;
            lsxpack_header_set_offset2(&header, buf + o[0], 0, o[1], o[1], o[2]);
            size_t enc_size = (size_t)(end - dst), header_size = sizeof lines - line_count;
            if (lsqpack_enc_encode(&enc, dst, &enc_size, lines + line_count, &header_size, &header, 0) != LQES_OK) goto fail;
            dst += enc_size;
            line_count += header_size;
        }
        ins_ends[i] = (size_t)(dst - out);
        unsigned char prefix[32];
        ssize_t prefix_size = lsqpack_enc_end_header(&enc, prefix, sizeof prefix, NULL);
        if (prefix_size <= 0 || (size_t)(end - dst) < (size_t)prefix_size + line_count) goto fail;
        memcpy(dst, prefix, (size_t)prefix_size);
        memcpy(dst + prefix_size, lines, line_count);
        dst += (size_t)prefix_size + line_count;
        sec_ends[i] = (size_t)(dst - out);
        if (prefix[0] != 0) {
            unsigned char ack[16];
            if (lsqpack_enc_decoder_in(&enc, ack, section_ack(ack, stream)) != 0) goto fail;
        }
    }
    lsqpack_enc_cleanup(&enc);
    return (long)(dst - out);
fail:
    lsqpack_enc_cleanup(&enc);
    return -1;
}

long lsqpack_encode_sets_fed(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count, unsigned capacity,
                             unsigned blocked, unsigned delay, unsigned char *out, size_t out_capacity, size_t *ins_ends,
                             size_t *sec_ends, unsigned char *feedback, size_t feedback_capacity, size_t *feedback_ends,
                             int record) {
    static unsigned char lines[0x10000];
    static struct lsqpack_context context;
    struct lsqpack_enc enc;
    struct lsqpack_dec dec;
    unsigned char sdtc[LSQPACK_LONGEST_SDTC];
    size_t sdtc_size = sizeof sdtc;
    lsqpack_enc_preinit(&enc, NULL);
    if (lsqpack_enc_init(&enc, NULL, capacity, capacity, blocked, 0, sdtc, &sdtc_size) != 0) return -1;
    if (record) lsqpack_dec_init(&dec, NULL, capacity, blocked ? blocked : 1, &lsqpack_callbacks, 0);
    unsigned char *dst = out, *end = out + out_capacity;
    memcpy(dst, sdtc, sdtc_size);
    dst += sdtc_size;
    size_t field = 0, decoded = 0, start = 0, fed = 0;
    for (size_t i = 0; i < count; i++) {
        uint64_t stream = 4 * i;
        if (lsqpack_enc_start_header(&enc, stream, 0) != 0) goto fail;
        size_t line_count = 0;
        for (; field < set_ends[i]; field++) {
            const uint32_t *o = offsets + 3 * field;
            struct lsxpack_header header;
            lsxpack_header_set_offset2(&header, buf + o[0], 0, o[1], o[1], o[2]);
            size_t enc_size = (size_t)(end - dst), header_size = sizeof lines - line_count;
            if (lsqpack_enc_encode(&enc, dst, &enc_size, lines + line_count, &header_size, &header, 0) != LQES_OK) goto fail;
            dst += enc_size;
            line_count += header_size;
        }
        ins_ends[i] = (size_t)(dst - out);
        unsigned char prefix[32];
        ssize_t prefix_size = lsqpack_enc_end_header(&enc, prefix, sizeof prefix, NULL);
        if (prefix_size <= 0 || (size_t)(end - dst) < (size_t)prefix_size + line_count) goto fail;
        memcpy(dst, prefix, (size_t)prefix_size);
        memcpy(dst + prefix_size, lines, line_count);
        dst += (size_t)prefix_size + line_count;
        sec_ends[i] = (size_t)(dst - out);
        size_t first = fed;
        if (record) {
            for (; i >= delay && decoded <= i - delay; decoded++) {
                if (ins_ends[decoded] > start && lsqpack_dec_enc_in(&dec, out + start, ins_ends[decoded] - start) != 0) goto fail;
                const unsigned char *p = out + ins_ends[decoded];
                size_t size = sec_ends[decoded] - ins_ends[decoded];
                if (feedback_capacity - fed < 64) goto fail;
                size_t ack_size = feedback_capacity - fed;
                if (lsqpack_dec_header_in(&dec, &context, 4 * decoded, size, &p, size, feedback + fed, &ack_size) != LQRHS_DONE) {
                    goto fail;
                }
                fed += ack_size;
                if (lsqpack_dec_ici_pending(&dec)) {
                    ssize_t n = lsqpack_dec_write_ici(&dec, feedback + fed, feedback_capacity - fed);
                    if (n < 0) goto fail;
                    fed += (size_t)n;
                }
                start = sec_ends[decoded];
            }
            feedback_ends[i] = fed;
        } else {
            fed = feedback_ends[i];
        }
        if (fed > first && lsqpack_enc_decoder_in(&enc, feedback + first, fed - first) != 0) goto fail;
    }
    lsqpack_enc_cleanup(&enc);
    if (record) lsqpack_dec_cleanup(&dec);
    return (long)(dst - out);
fail:
    lsqpack_enc_cleanup(&enc);
    if (record) lsqpack_dec_cleanup(&dec);
    return -1;
}

struct lsqpack_digest_context {
    struct lsxpack_header header;
    char buffer[0x10000];
    uint64_t digest;
};

static uint64_t fnv1a(uint64_t digest, const void *bytes, size_t count) {
    const unsigned char *p = bytes;
    for (size_t i = 0; i < count; i++) digest = (digest ^ p[i]) * 0x100000001B3ull;
    return digest;
}

static struct lsxpack_header *lsqpack_digest_prepare(void *context, struct lsxpack_header *header, size_t space) {
    struct lsqpack_digest_context *c = context;
    if (space > sizeof c->buffer) return NULL;
    if (header) { header->val_len = (lsxpack_strlen_t)space; return header; }
    lsxpack_header_prepare_decode(&c->header, c->buffer, 0, space);
    return &c->header;
}

static int lsqpack_digest_process(void *context, struct lsxpack_header *header) {
    struct lsqpack_digest_context *c = context;
    const unsigned char zero = 0, one = 1;
    c->digest = fnv1a(c->digest, lsxpack_header_get_name(header), header->name_len);
    c->digest = fnv1a(c->digest, &zero, 1);
    c->digest = fnv1a(c->digest, lsxpack_header_get_value(header), header->val_len);
    c->digest = fnv1a(c->digest, &one, 1);
    return 0;
}

static const struct lsqpack_dec_hset_if lsqpack_digest_callbacks = {
    .dhi_unblocked = lsqpack_unblocked,
    .dhi_prepare_decode = lsqpack_digest_prepare,
    .dhi_process_header = lsqpack_digest_process,
};

uint64_t lsqpack_decode_digest(const unsigned char *bytes, const size_t *ins_ends, const size_t *sec_ends, size_t count,
                               unsigned capacity, unsigned late) {
    static struct lsqpack_digest_context context;
    struct lsqpack_dec dec;
    lsqpack_dec_init(&dec, NULL, capacity, 100, &lsqpack_digest_callbacks, 0);
    context.digest = 0xCBF29CE484222325ull;
    size_t applied = 0;
    for (size_t i = 0; i < count; i++) {
        size_t through = i + late < count ? i + late : count - 1;
        for (; applied <= through; applied++) {
            size_t from = applied ? sec_ends[applied - 1] : 0;
            if (ins_ends[applied] > from && lsqpack_dec_enc_in(&dec, bytes + from, ins_ends[applied] - from) != 0) goto fail;
        }
        const unsigned char *p = bytes + ins_ends[i];
        size_t size = sec_ends[i] - ins_ends[i];
        unsigned char ack[LSQPACK_LONGEST_HEADER_ACK];
        size_t ack_size = sizeof ack;
        if (lsqpack_dec_header_in(&dec, &context, 4 * i, size, &p, size, ack, &ack_size) != LQRHS_DONE) goto fail;
    }
    lsqpack_dec_cleanup(&dec);
    return context.digest;
fail:
    lsqpack_dec_cleanup(&dec);
    return 0;
}

// MARK: - cursed-http

long cursed_qpack_decode_sections(const unsigned char *bytes, const size_t *ins_ends, const size_t *sec_ends, const int *fields,
                                  size_t count, unsigned capacity) {
    static qp_dec dec;
    static hp_field out[512];
    static uint8_t arena[1 << 16];
    static uint8_t feedback[256];
    qp_dec_init(&dec, capacity);
    long total = 0;
    size_t start = 0;
    for (size_t i = 0; i < count; i++) {
        if (ins_ends[i] > start) {
            int used = qp_dec_encoder(&dec, bytes + start, ins_ends[i] - start);
            if (used < 0 || (size_t)used != ins_ends[i] - start) return -1;
        }
        int flags = 0;
        int n = qp_decode_section(&dec, 4 * i, bytes + ins_ends[i], sec_ends[i] - ins_ends[i], out, 512, arena, sizeof arena,
                                  1u << 20, &flags);
        if (n != fields[i]) return -1;
        for (int j = 0; j < n; j++) total += out[j].nlen + out[j].vlen;
        qp_dec_feedback(&dec, feedback, sizeof feedback);
        start = sec_ends[i];
    }
    return total;
}

long cursed_qpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count, unsigned capacity,
                              unsigned char *out, size_t out_capacity, size_t *ins_ends, size_t *sec_ends) {
    static qp_enc enc;
    static unsigned char lines[0x10000];
    unsigned char *dst = out, *end = out + out_capacity;
    size_t field = 0;
    if (!capacity) {
        for (size_t i = 0; i < count; i++) {
            ins_ends[i] = (size_t)(dst - out);
            if (end - dst < 16) return -1;
            dst += qp_enc_prefix(dst);
            for (; field < set_ends[i]; field++) {
                const uint32_t *o = offsets + 3 * field;
                if ((size_t)(end - dst) < qp_enc_bound(o[1], o[2])) return -1;
                const uint8_t *name = (const uint8_t *)buf + o[0];
                dst += qp_enc_field(dst, name, o[1], name + o[1], o[2], 0);
            }
            sec_ends[i] = (size_t)(dst - out);
        }
        return (long)(dst - out);
    }
    qp_enc_init(&enc);
    qp_enc_settings(&enc, capacity, 100);
    for (size_t i = 0; i < count; i++) {
        uint64_t stream = 4 * i;
        qp_esec section;
        qp_enc_begin(&enc, &section, stream);
        unsigned char *p = lines;
        for (; field < set_ends[i]; field++) {
            const uint32_t *o = offsets + 3 * field;
            if ((size_t)(lines + sizeof lines - p) < qp_enc_bound(o[1], o[2])) return -1;
            const uint8_t *name = (const uint8_t *)buf + o[0];
            p += qp_enc_ifield(&enc, &section, p, name, o[1], name + o[1], o[2], 0);
        }
        dst += qp_enc_take(&enc, dst, (size_t)(end - dst));
        if (qp_enc_pending(&enc)) return -1;
        ins_ends[i] = (size_t)(dst - out);
        if ((size_t)(end - dst) < (size_t)(p - lines) + 16) return -1;
        dst += qp_enc_end(&enc, &section, lines, p, dst);
        sec_ends[i] = (size_t)(dst - out);
        if (out[ins_ends[i]] != 0) {
            unsigned char ack[16];
            size_t n = section_ack(ack, stream);
            if (qp_enc_feedback(&enc, ack, n) != (int)n) return -1;
        }
    }
    return (long)(dst - out);
}
