#include <assert.h>
#include <stdint.h>

uint32_t bor_test_pair_sum(uint8_t a, uint32_t b);
uint32_t bor_test_array_sum(void);
uint32_t bor_test_enum_value(void);
uint32_t bor_test_slice_string(void);
uint32_t bor_test_multiple_returns(void);
uint32_t bor_test_defer(void);

int main(void) {
    assert(bor_test_pair_sum(3, 4) == 7);
    assert(bor_test_array_sum() == 10);
    assert(bor_test_enum_value() == 9);
    assert(bor_test_slice_string() == 110);
    assert(bor_test_multiple_returns() == 43);
    assert(bor_test_defer() == 19);
    return 0;
}
