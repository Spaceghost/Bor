#include <stdint.h>
#include <stddef.h>

extern uint32_t control_mix(uint32_t x, uintptr_t n);

int main(void) {
    if (control_mix(1u, 0u) != 1u) return 1;
    if (control_mix(10u, 5u) != 14u) return 2;
    if (control_mix(1000u, 8u) != 32u) return 3;
    if (control_mix(UINT32_MAX, 3u) != UINT32_C(4294966293)) return 4;
    if (control_mix(42u, 32u) != 746u) return 5;
    return 0;
}
