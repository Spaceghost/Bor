#include <stdint.h>
#include <stddef.h>

/* Algorithm-matched C control: same two passes and branches as the Odin fixture. */
static int unreserved(uint8_t c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
}
static uint8_t hex_digit(uint8_t n) { return (uint8_t)(n < 10 ? '0' + n : 'A' + n - 10); }
uint32_t melodica_abi_version(void) { return 1; }
uintptr_t melodica_url_encode_size(uint8_t *src, uintptr_t len) {
    uintptr_t required = 0;
    if (!src) return 0;
    for (uintptr_t i = 0; i < len; ++i) required += unreserved(src[i]) ? 1u : 3u;
    return required;
}
uintptr_t melodica_url_encode(uint8_t *dst, uintptr_t cap, uint8_t *src, uintptr_t len) {
    uintptr_t required = melodica_url_encode_size(src, len), out = 0;
    if (!dst || !src || cap < required) return required;
    for (uintptr_t i = 0; i < len; ++i) {
        uint8_t c = src[i];
        if (unreserved(c)) dst[out++] = c;
        else {
            dst[out++] = '%';
            dst[out++] = hex_digit((uint8_t)(c >> 4));
            dst[out++] = hex_digit((uint8_t)(c & 15));
        }
    }
    return required;
}
