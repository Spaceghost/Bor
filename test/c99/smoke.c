#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

uint32_t melodica_abi_version(void);
size_t melodica_url_encode_size(uint8_t *src, size_t src_len);
size_t melodica_url_encode(uint8_t *dst, size_t dst_cap, uint8_t *src, size_t src_len);

int main(void) {
    uint8_t input[] = "A b/+~";
    uint8_t output[32] = {0};
    const char expected[] = "A%20b%2F%2B~";

    assert(melodica_abi_version() == 1u);
    assert(melodica_url_encode_size(input, sizeof input - 1u) == sizeof expected - 1u);
    assert(melodica_url_encode(output, sizeof output, input, sizeof input - 1u) == sizeof expected - 1u);
    assert(memcmp(output, expected, sizeof expected - 1u) == 0);
    return 0;
}
