#ifndef HTTPBYTES_CURSED_HTTP_H
#define HTTPBYTES_CURSED_HTTP_H

#include <stddef.h>

/// cursed-http's fbparse.h (requests) and fbresp.h (responses): SIMD heads with picohttpparser's results. The head's
/// length (or -1 bad, -2 incomplete); `field_count` set. They read up to 64 bytes past `bytes + count` (their padding
/// contract): callers give them buffers with 64 more readable bytes.
long cursed_parse_request(const char *bytes, size_t count, int *field_count);
long cursed_parse_response(const char *bytes, size_t count, int *field_count);

#endif
