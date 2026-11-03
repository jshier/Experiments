#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <zlib.h>

// We'll read the compressed bytes from a file written by Swift
int try_inflate(const unsigned char *src, size_t src_len, int wbits, const char *label) {
    unsigned char out[1024];
    z_stream s = {0};
    s.next_in  = (Bytef *)src;
    s.avail_in = (uInt)src_len;
    s.next_out = out;
    s.avail_out = sizeof(out);

    if (inflateInit2(&s, wbits) != Z_OK) { printf("%s: inflateInit2 failed\n", label); return 0; }
    int ret = inflate(&s, Z_FINISH);
    size_t produced = sizeof(out) - s.avail_out;
    inflateEnd(&s);

    const char *expected = "Hello, Alamofire! This is a test of the zlib compression format.";
    int ok = (ret == Z_STREAM_END) && (produced == strlen(expected)) && (memcmp(out, expected, produced) == 0);
    printf("%s: ret=%d produced=%zu match=%s\n", label, ret, produced, ok ? "YES ✓" : "NO ✗");
    return ok;
}

int main(void) {
    // Read compressed.bin (Apple's output) and alamofire.bin (Alamofire's output)
    FILE *f;
    unsigned char buf[1024];
    size_t n;

    printf("=== Apple compressed(using: .zlib) output ===\n");
    f = fopen("/tmp/apple_compressed.bin", "rb");
    if (!f) { printf("Cannot open apple_compressed.bin\n"); return 1; }
    n = fread(buf, 1, sizeof(buf), f); fclose(f);
    printf("Size: %zu bytes, first bytes: %02X %02X %02X %02X\n", n, buf[0], buf[1], buf[2], buf[3]);
    // CMF+FLG check for RFC 1950
    int valid_rfc1950 = (buf[0] == 0x78) && ((buf[0]*256 + buf[1]) % 31 == 0);
    printf("Valid RFC 1950 header (starts 0x78, CMF*256+FLG div by 31): %s\n", valid_rfc1950 ? "YES" : "NO");
    try_inflate(buf, n, 15,  "  wbits=15  (zlib wrapper, RFC 1950)");
    try_inflate(buf, n, -15, "  wbits=-15 (raw deflate, RFC 1951)");
    try_inflate(buf, n, 47,  "  wbits=47  (auto-detect zlib/gzip)");

    printf("\n=== Alamofire deflate() output ===\n");
    f = fopen("/tmp/alamofire_deflate.bin", "rb");
    if (!f) { printf("Cannot open alamofire_deflate.bin\n"); return 1; }
    n = fread(buf, 1, sizeof(buf), f); fclose(f);
    printf("Size: %zu bytes, first bytes: %02X %02X %02X %02X\n", n, buf[0], buf[1], buf[2], buf[3]);
    try_inflate(buf, n, 15,  "  wbits=15  (zlib wrapper, RFC 1950)");
    try_inflate(buf, n, -15, "  wbits=-15 (raw deflate, RFC 1951)");
    try_inflate(buf, n, 47,  "  wbits=47  (auto-detect zlib/gzip)");

    return 0;
}
