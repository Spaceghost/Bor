#define _POSIX_C_SOURCE 200809L

#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

size_t melodica_url_encode(uint8_t *dst, size_t dst_cap, uint8_t *src, size_t src_len);

static double seconds_since(const struct timespec *start, const struct timespec *end) {
    return (double)(end->tv_sec - start->tv_sec) +
           (double)(end->tv_nsec - start->tv_nsec) / 1000000000.0;
}

int main(void) {
    enum { INPUT_SIZE = 1024, OUTPUT_SIZE = INPUT_SIZE * 3, ITERATIONS = 250000 };
    uint8_t input[INPUT_SIZE];
    uint8_t output[OUTPUT_SIZE];
    volatile uint64_t sink = 0;

    for (size_t i = 0; i < sizeof input; ++i) {
        /* A deterministic mix of cheap and escaped bytes, including controls. */
        static const uint8_t pattern[] =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ /+?=&%\n\t";
        input[i] = pattern[i % (sizeof pattern - 1u)];
    }

    const size_t encoded = melodica_url_encode(output, sizeof output, input, sizeof input);
    if (encoded == 0u || encoded > sizeof output) {
        fprintf(stderr, "benchmark preflight failed: encoded=%zu\n", encoded);
        return 2;
    }

    struct timespec start;
    struct timespec end;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) return 3;

    for (size_t i = 0; i < ITERATIONS; ++i) {
        const size_t n = melodica_url_encode(output, sizeof output, input, sizeof input);
        sink += (uint64_t)n + output[i & (sizeof output - 1u)];
    }

    if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) return 4;

    const double elapsed = seconds_since(&start, &end);
    const double mib = ((double)INPUT_SIZE * (double)ITERATIONS) / (1024.0 * 1024.0);
    printf("url_encode: %.2f MiB/s elapsed=%.6f sink=%" PRIu64 "\n",
           mib / elapsed, elapsed, (uint64_t)sink);
    return 0;
}
