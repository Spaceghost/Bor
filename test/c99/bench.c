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

static void sort_samples(double *samples, size_t count) {
    for (size_t i = 1; i < count; ++i) {
        const double value = samples[i];
        size_t j = i;
        while (j > 0u && samples[j - 1u] > value) {
            samples[j] = samples[j - 1u];
            --j;
        }
        samples[j] = value;
    }
}

int main(void) {
    enum {
        INPUT_SIZE = 1024,
        OUTPUT_SIZE = INPUT_SIZE * 3,
        ITERATIONS = 100000,
        RUNS = 5
    };
    uint8_t input[INPUT_SIZE];
    uint8_t output[OUTPUT_SIZE];
    double samples[RUNS];
    volatile uint64_t sink = 0;

    for (size_t i = 0; i < sizeof input; ++i) {
        /* A deterministic mix of cheap and escaped bytes, including controls. */
        static const uint8_t pattern[] =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ /+?=&%\n\t";
        input[i] = pattern[i % (sizeof pattern - 1u)];
    }
    memset(output, 0, sizeof output);

    const size_t encoded = melodica_url_encode(output, sizeof output, input, sizeof input);
    if (encoded == 0u || encoded > sizeof output) {
        fprintf(stderr, "benchmark preflight failed: encoded=%zu\n", encoded);
        return 2;
    }

    const double mib_per_run =
        ((double)INPUT_SIZE * (double)ITERATIONS) / (1024.0 * 1024.0);

    for (size_t run = 0; run < RUNS; ++run) {
        struct timespec start;
        struct timespec end;
        if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) return 3;

        for (size_t i = 0; i < ITERATIONS; ++i) {
            const size_t n = melodica_url_encode(output, sizeof output, input, sizeof input);
            /* Read only bytes that the implementation is required to write. */
            sink += (uint64_t)n + output[(i + run) % n];
        }

        if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) return 4;
        samples[run] = mib_per_run / seconds_since(&start, &end);
    }

    sort_samples(samples, RUNS);
    printf("url_encode: median=%.2f MiB/s min=%.2f max=%.2f sink=%" PRIu64 "\n",
           samples[RUNS / 2], samples[0], samples[RUNS - 1u], (uint64_t)sink);
    return 0;
}
