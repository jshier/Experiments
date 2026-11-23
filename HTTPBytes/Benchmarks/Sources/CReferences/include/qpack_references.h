#ifndef HTTPBYTES_QPACK_REFERENCES_H
#define HTTPBYTES_QPACK_REFERENCES_H

#include <stddef.h>
#include <stdint.h>

// QPACK references driven as a connection would: one decoder or encoder for a sequence of field sections, the encoder
// stream's instructions delivered before each section, and each section that used the dynamic table acknowledged at
// once (the peer's Section Acknowledgment fed to the encoder).
//
// Sections to decode: section i's encoder stream bytes are `bytes[sec_ends[i - 1] ..< ins_ends[i]]` (0 for i = 0), its
// field section `bytes[ins_ends[i] ..< sec_ends[i]]`, on stream 4i. Decoders check section i has `fields[i]` fields and
// return the fields' bytes (names and values), or -1.
//
// Sets to encode: field j's name is `buf[offsets[3j] ..< offsets[3j] + offsets[3j + 1]]` and its value the
// `offsets[3j + 2]` bytes after it; set i ends before field `set_ends[i]`. Output in the layout above (`ins_ends` and
// `sec_ends` filled). Returns the bytes written, or -1. `capacity` 0 is static only.

/// ls-qpack's decoder (each field copied into a buffer, as its API does); `capacity` is the advertised table capacity.
long lsqpack_decode_sections(const unsigned char *bytes, const size_t *ins_ends, const size_t *sec_ends, const int *fields,
                             size_t count, unsigned capacity);

/// ls-qpack's encoder (default options; up to 100 sections at risk of blocking).
long lsqpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count, unsigned capacity,
                         unsigned char *out, size_t out_capacity, size_t *ins_ends, size_t *sec_ends);

/// cursed-http's decoder (qpack.h: views of the section, its arena, or the table; every field's characters checked; no
/// blocked streams).
long cursed_qpack_decode_sections(const unsigned char *bytes, const size_t *ins_ends, const size_t *sec_ends, const int *fields,
                                  size_t count, unsigned capacity);

/// cursed-http's encoder: `qp_enc_field` (static only) with `capacity` 0, else its dynamic-table encoder.
long cursed_qpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count, unsigned capacity,
                              unsigned char *out, size_t out_capacity, size_t *ins_ends, size_t *sec_ends);

#endif
