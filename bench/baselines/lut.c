#include <stdint.h>
#include <stddef.h>

/* Optimized scalar algorithm: immutable byte classification and hex tables.
 * No restrict promise, unaligned word stores, overreads, or speculative writes.
 * Preserve required-size reporting and no writes when capacity is insufficient.
 */
static const uint8_t width[256] = {
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 3,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3,
    3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 1,
    3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 1, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
};
static const uint8_t hex[] = "0123456789ABCDEF";
uint32_t melodica_abi_version(void) { return 1; }
uintptr_t melodica_url_encode_size(uint8_t *src, uintptr_t len) {
    uintptr_t required = 0;
    if (!src) return 0;
    for (uintptr_t i = 0; i < len; ++i) required += width[src[i]];
    return required;
}
uintptr_t melodica_url_encode(uint8_t *dst, uintptr_t cap, uint8_t *src, uintptr_t len) {
    uintptr_t required = melodica_url_encode_size(src, len), out = 0;
    if (!dst || !src || cap < required) return required;
    for (uintptr_t i = 0; i < len; ++i) {
        uint8_t c = src[i];
        if (width[c] == 1) dst[out++] = c;
        else {
            dst[out++] = '%';
            dst[out++] = hex[c >> 4];
            dst[out++] = hex[c & 15];
        }
    }
    return required;
}
