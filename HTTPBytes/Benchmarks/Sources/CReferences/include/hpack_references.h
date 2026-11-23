#ifndef HTTPBYTES_HPACK_REFERENCES_H
#define HTTPBYTES_HPACK_REFERENCES_H

#include <stddef.h>
#include <stdint.h>

/// ls-hpack decoding `count` field blocks with one decoder (a connection's): block i is `bytes[ends[i - 1] ..< ends[i]]`,
/// each field decoded into one reused buffer, as ls-hpack's API does (names and values copied out). Checks block i has
/// `fields[i]` fields. Returns the fields' bytes (names and values), or -1.
long lshpack_decode_blocks(const unsigned char *bytes, const size_t *ends, const int *fields, size_t count);

/// ls-hpack encoding field sets with one encoder: field j's name is `buf[offsets[3j] ..< offsets[3j] + offsets[3j + 1]]`
/// and its value the `offsets[3j + 2]` bytes after it; set i ends before field `set_ends[i]`. Blocks are written one after
/// another into `out`, block i ending at `block_ends[i]`. Returns the bytes written, or -1.
long lshpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count,
                         unsigned char *out, size_t capacity, size_t *block_ends);

/// cursed-http's decoder, as `lshpack_decode_blocks` (fields as views of the block, its arena, or the table; every
/// field's characters checked).
long cursed_hpack_decode_blocks(const unsigned char *bytes, const size_t *ends, const int *fields, size_t count);

/// cursed-http's encoder (a dynamic table of 4,096), as `lshpack_encode_sets`.
long cursed_hpack_encode_sets(const char *buf, const uint32_t *offsets, const size_t *set_ends, size_t count,
                              unsigned char *out, size_t capacity, size_t *block_ends);

#endif
