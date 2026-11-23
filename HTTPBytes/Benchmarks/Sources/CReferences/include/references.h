#ifndef HTTPBYTES_C_REFERENCES_H
#define HTTPBYTES_C_REFERENCES_H

#include <stddef.h>

/// picohttpparser: the head's length (or -1 bad, -2 incomplete); `field_count` set.
long pico_parse_request(const char *bytes, size_t count, int *field_count);
long pico_parse_response(const char *bytes, size_t count, int *field_count);
/// picohttpparser's chunked decoder (in place): the decoded body's length, or negative.
long pico_decode_chunked(char *bytes, size_t count);

/// llhttp: the head's length (or -1); `field_count` set; every field's spans recorded by callbacks.
long llhttp_parse_request(const char *bytes, size_t count, int *field_count);
long llhttp_parse_response(const char *bytes, size_t count, int *field_count);
/// llhttp: a whole request with a chunked body; the body's length (or -1).
long llhttp_parse_chunked_message(const char *bytes, size_t count);

#endif
