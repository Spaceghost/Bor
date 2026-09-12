#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern uintptr_t melodica_url_encode(uint8_t *, uintptr_t, uint8_t *, uintptr_t);

int main(int argc, char **argv) {
    uint8_t source[4096], target[12288];
    uint32_t seed = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : 20260912u;
    const unsigned rounds = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 2000u;
    for (unsigned i=0; i<sizeof source; ++i) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        source[i] = (uint8_t)seed;
    }
    uint32_t checksum = 0;
    for (unsigned r=0; r<rounds; ++r) {
        source[r % sizeof source] ^= (uint8_t)r;
        uintptr_t length = melodica_url_encode(target, sizeof target, source, sizeof source);
        if (!length || length > sizeof target) return 2;
        checksum = checksum * 33u + (uint32_t)length + target[(r * 17u) % length];
    }
    printf("%u\n", checksum);
    return 0;
}
