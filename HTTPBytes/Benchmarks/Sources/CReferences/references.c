// The C parsers HTTPBytes is measured against, wrapped so each benchmark does what a server reading a head does:
// every field's name and value found (picohttpparser fills an array of them; llhttp calls back with each, and the
// callbacks record them), and body bytes delivered (llhttp's `on_body`).

#include "picohttpparser.h"
#include "llhttp.h"
#include "references.h"

// MARK: - picohttpparser

long pico_parse_request(const char *bytes, size_t count, int *field_count) {
    const char *method, *path;
    size_t method_length, path_length;
    int minor;
    struct phr_header fields[256];
    size_t fields_count = 256;
    int result = phr_parse_request(bytes, count, &method, &method_length, &path, &path_length, &minor, fields, &fields_count, 0);
    *field_count = (int)fields_count;
    return result;
}

long pico_parse_response(const char *bytes, size_t count, int *field_count) {
    int minor, status;
    const char *message;
    size_t message_length;
    struct phr_header fields[256];
    size_t fields_count = 256;
    int result = phr_parse_response(bytes, count, &minor, &status, &message, &message_length, fields, &fields_count, 0);
    *field_count = (int)fields_count;
    return result;
}

long pico_decode_chunked(char *bytes, size_t count) {
    struct phr_chunked_decoder decoder = { 0 };
    decoder.consume_trailer = 1;
    size_t size = count;
    ssize_t result = phr_decode_chunked(&decoder, bytes, &size);
    return result < 0 ? result : (long)size;
}

// MARK: - llhttp

typedef struct { const char *at; size_t length; } span_t;
typedef struct {
    span_t names[256];
    span_t values[256];
    int count;
    int done;
    size_t body;
} recorded_t;

static int on_field(llhttp_t *parser, const char *at, size_t length) {
    recorded_t *recorded = parser->data;
    recorded->names[recorded->count & 255] = (span_t){ at, length };
    return 0;
}

static int on_value(llhttp_t *parser, const char *at, size_t length) {
    recorded_t *recorded = parser->data;
    recorded->values[recorded->count & 255] = (span_t){ at, length };
    recorded->count++;
    return 0;
}

static int on_head_complete(llhttp_t *parser) {
    ((recorded_t *)parser->data)->done = 1;
    return HPE_PAUSED;
}

static int on_body(llhttp_t *parser, const char *at, size_t length) {
    ((recorded_t *)parser->data)->body += length;
    return 0;
}

static int on_message_complete(llhttp_t *parser) {
    ((recorded_t *)parser->data)->done = 1;
    return HPE_PAUSED;
}

static llhttp_settings_t head_settings, body_settings;
static int settings_made;

static void make_settings(void) {
    if (settings_made) return;
    llhttp_settings_init(&head_settings);
    head_settings.on_header_field = on_field;
    head_settings.on_header_value = on_value;
    head_settings.on_headers_complete = on_head_complete;
    llhttp_settings_init(&body_settings);
    body_settings.on_body = on_body;
    body_settings.on_message_complete = on_message_complete;
    settings_made = 1;
}

static long llhttp_head(llhttp_type_t type, const char *bytes, size_t count, int *field_count) {
    make_settings();
    llhttp_t parser;
    recorded_t recorded;
    recorded.count = 0;
    recorded.done = 0;
    llhttp_init(&parser, type, &head_settings);
    parser.data = &recorded;
    llhttp_errno_t error = llhttp_execute(&parser, bytes, count);
    if (error != HPE_PAUSED || !recorded.done) return -1;
    *field_count = recorded.count;
    return llhttp_get_error_pos(&parser) - bytes;
}

long llhttp_parse_request(const char *bytes, size_t count, int *field_count) {
    return llhttp_head(HTTP_REQUEST, bytes, count, field_count);
}

long llhttp_parse_response(const char *bytes, size_t count, int *field_count) {
    return llhttp_head(HTTP_RESPONSE, bytes, count, field_count);
}

long llhttp_parse_chunked_message(const char *bytes, size_t count) {
    make_settings();
    llhttp_t parser;
    recorded_t recorded;
    recorded.done = 0;
    recorded.body = 0;
    llhttp_init(&parser, HTTP_REQUEST, &body_settings);
    parser.data = &recorded;
    llhttp_errno_t error = llhttp_execute(&parser, bytes, count);
    if (error != HPE_PAUSED || !recorded.done) return -1;
    return (long)recorded.body;
}
