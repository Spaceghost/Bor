#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

extern uintptr_t melodica_url_encode(uint8_t *, uintptr_t, uint8_t *, uintptr_t);
static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(2); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static uint64_t number(const char *s) {
    char *end; errno = 0;
    unsigned long long n = strtoull(s, &end, 10);
    if (errno || !*s || *end) { fprintf(stderr,"invalid number: %s\n",s); exit(2); }
    return n;
}
int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr,"usage: runtime <ascii|mixed|binary> <bytes> <rounds> <seed>\n"); return 2; }
    uintptr_t len = (uintptr_t)number(argv[2]);
    uint64_t rounds = number(argv[3]);
    uint32_t seed = (uint32_t)number(argv[4]);
    if (!len || len > 1048576 || !rounds || rounds > UINT64_C(1000000000)) return 2;
    uint8_t *src = malloc(len), *dst = malloc(len*3);
    if (!src || !dst) return 2;
    static const char safe[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    for (uintptr_t i = 0; i < len; ++i) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        if (!strcmp(argv[1], "ascii")) src[i] = (uint8_t)safe[seed % (sizeof safe-1)];
        else if (!strcmp(argv[1], "mixed")) src[i] = seed % 4 ? (uint8_t)safe[seed % (sizeof safe-1)] : (uint8_t)(seed >> 8);
        else if (!strcmp(argv[1], "binary")) src[i] = (uint8_t)seed;
        else return 2;
    }
    /* Separate object files and no LTO prevent cross-language constant folding.
     * Initialization and full-output hashing are outside the timed region.
     */
    uint32_t checksum = 0;
    uintptr_t required = melodica_url_encode(dst, len*3, src, len);
    if (!required || required > len*3) return 3;
    uint64_t start = now_ns();
    for (uint64_t r = 0; r < rounds; ++r) {
        uintptr_t n = melodica_url_encode(dst, len*3, src, len);
        if (n != required) return 3;
        checksum = checksum * 33u + (uint32_t)n + dst[r % n];
    }
    uint64_t elapsed = now_ns() - start;
    uint32_t full = UINT32_C(2166136261);
    for (uintptr_t i = 0; i < required; ++i) full = (full ^ dst[i]) * UINT32_C(16777619);
    printf("{\"elapsed_ns\":%" PRIu64 ",\"rounds\":%" PRIu64 ",\"input_bytes\":%" PRIuPTR ",\"output_bytes\":%" PRIuPTR ",\"checksum\":%u,\"output_hash\":%u}\n", elapsed, rounds, len, required, checksum, full);
    free(dst); free(src);
    return 0;
}
