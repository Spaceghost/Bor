#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

extern uint32_t melodica_abi_version(void);
extern uintptr_t melodica_url_encode_size(uint8_t *, uintptr_t);
extern uintptr_t melodica_url_encode(uint8_t *, uintptr_t, uint8_t *, uintptr_t);

/* Deliberately independent byte specification, not the optimized LUT. */
static int allowed(uint8_t c) {
    const char *p = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    for (; *p; ++p) if ((uint8_t)*p == c) return 1;
    return 0;
}
static uintptr_t reference(uint8_t *out, const uint8_t *src, uintptr_t len) {
    const char *hex = "0123456789ABCDEF";
    uintptr_t n = 0;
    for (uintptr_t i = 0; i < len; ++i) {
        uint8_t c = src[i];
        if (allowed(c)) out[n++] = c;
        else { out[n++] = '%'; out[n++] = (uint8_t)hex[c / 16]; out[n++] = (uint8_t)hex[c % 16]; }
    }
    return n;
}
#define CHECK(expr) do { if (!(expr)) { fprintf(stderr,"line %d: %s\n",__LINE__,#expr); return 1; } } while (0)
int main(void) {
    uint8_t src[257], saved[257], expected[771], buffer[803];
    uint32_t rng = UINT32_C(0xB0772026);
    unsigned cases = 0;
    CHECK(melodica_abi_version() == 1);
    CHECK(melodica_url_encode_size(NULL, 123) == 0);
    CHECK(melodica_url_encode(NULL, 0, NULL, 123) == 0);
    for (unsigned shape = 0; shape < 4; ++shape) {
        for (unsigned i = 0; i < sizeof src; ++i) {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            src[i] = shape == 0 ? (uint8_t)i : shape == 1 ? (uint8_t)'A' :
                     shape == 2 ? (uint8_t)' ' : (uint8_t)rng;
        }
        memcpy(saved, src, sizeof src);
        for (uintptr_t len = 0; len <= sizeof src; ++len) {
            uintptr_t required = reference(expected, src, len);
            CHECK(melodica_url_encode_size(src, len) == required);
            CHECK(melodica_url_encode(NULL, 0, src, len) == required);
            uintptr_t caps[4] = {0, required ? required - 1 : 0, required, required + 1};
            for (unsigned ci = 0; ci < 4; ++ci) {
                memset(buffer, 0xa5, sizeof buffer);
                CHECK(melodica_url_encode(buffer + 16, caps[ci], src, len) == required);
                for (uintptr_t i = 0; i < sizeof buffer; ++i) {
                    uint8_t want = (caps[ci] >= required && i >= 16 && i < 16 + required) ? expected[i-16] : 0xa5;
                    CHECK(buffer[i] == want);
                }
                CHECK(memcmp(src, saved, sizeof src) == 0);
                ++cases;
            }
        }
    }
    memset(buffer, 0xa5, sizeof buffer);
    CHECK(melodica_url_encode(buffer, sizeof buffer, NULL, 42) == 0);
    for (unsigned i = 0; i < sizeof buffer; ++i) CHECK(buffer[i] == 0xa5);
    printf("verified %u capacity/buffer cases\n", cases);
    return 0;
}
