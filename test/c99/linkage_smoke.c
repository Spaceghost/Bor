#include <stdint.h>

extern uint32_t public_c(uint32_t x);

/*
 * Deliberately collide with the Odin procedure name. A correct backend keeps
 * the non-@(export) proc "c" private, so this host symbol cannot replace it.
 */
uint32_t internal_c(uint32_t x) {
    return x + 1000u;
}

int main(void) {
    return public_c(40u) == 42u ? 0 : 1;
}
