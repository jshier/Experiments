// cursed-http's request and response head parsers (fbparse.h, fbresp.h; MIT), from the cursed-http test-data set
// (Tools/test-data fetch cursed-http), wrapped as picohttpparser is in references.c: every field's name and value found
// into an array of them.

#include "../../../../TestData/cursed-http/include/fbresp.h"
#include "cursed_http.h"

long cursed_parse_request(const char *bytes, size_t count, int *field_count) {
    const char *method, *path;
    size_t method_length, path_length;
    int minor;
    struct fb_header fields[256];
    size_t fields_count = 256;
    int result = fb_parse_request(bytes, count, &method, &method_length, &path, &path_length, &minor, fields, &fields_count, 0);
    *field_count = (int)fields_count;
    return result;
}

long cursed_parse_response(const char *bytes, size_t count, int *field_count) {
    int minor, status;
    const char *message;
    size_t message_length;
    struct fb_header fields[256];
    size_t fields_count = 256;
    int result = fb_parse_response(bytes, count, &minor, &status, &message, &message_length, fields, &fields_count, 0);
    *field_count = (int)fields_count;
    return result;
}
