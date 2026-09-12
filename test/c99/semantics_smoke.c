#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>

extern uint32_t nested_calls(void);
extern uint32_t ordered_calls(uint8_t *p);
extern uint32_t lexical_scope(void);
extern uint32_t zero_locals(void);
extern uint32_t short_circuit(uint8_t *p);
extern uint32_t all_paths_return(bool flag);
extern uint32_t byte_arithmetic(uint8_t x);
extern uint32_t literal_width(uint32_t x);
extern uint32_t max_range_byte(uint8_t first, uint8_t last);
extern uint32_t max_range_word(uint32_t first, uint32_t last);
extern uint32_t max_range_pointer(uintptr_t first, uintptr_t last);
extern uint32_t dynamic_bound(uint8_t *p);
extern uint32_t shift_byte(uint8_t x, uint32_t n);
extern uint32_t shift_word(uint32_t x, uint32_t n);
extern uintptr_t shift_pointer(uintptr_t x, uint32_t n);
extern uint32_t source_literals(void);

#define REQUIRE(expr) do { if (!(expr)) { fprintf(stderr, "line %d: %s\n", __LINE__, #expr); return 1; } } while (0)

int main(void) {
    uint8_t p[1] = {0};
    REQUIRE(nested_calls() == 203u);
    REQUIRE(ordered_calls(p) == 102u && p[0] == 2u);
    REQUIRE(lexical_scope() == 709u);
    REQUIRE(zero_locals() == 0u);
    p[0] = 0;
    REQUIRE(short_circuit(p) == 1u && p[0] == 1u);
    REQUIRE(all_paths_return(true) == 11u && all_paths_return(false) == 22u);
    REQUIRE(literal_width(UINT32_MAX) == 0u);
    REQUIRE(max_range_byte(254, 255) == 3u);
    REQUIRE(max_range_byte(255, 254) == 0u);
    REQUIRE(max_range_word(UINT32_MAX-1u, UINT32_MAX) == 3u);
    REQUIRE(max_range_pointer(UINTPTR_MAX-1u, UINTPTR_MAX) == 3u);
    p[0] = 5;
    REQUIRE(dynamic_bound(p) == 1u && p[0] == 2u);
    REQUIRE(source_literals() == 1032u);
    for (uint32_t x = 0; x < 256; ++x) {
        REQUIRE(byte_arithmetic((uint8_t)x) == ((x+x) & 255u) / 2u);
        for (uint32_t n = 0; n < 80; ++n) {
            REQUIRE(shift_byte((uint8_t)x, n) == (n < 8 ? (x << n) & 255u : 0u));
            REQUIRE(shift_word(x, n) == (n < 32 ? x << n : 0u));
            REQUIRE(shift_pointer((uintptr_t)x, n) == (n < sizeof(uintptr_t)*CHAR_BIT ? (uintptr_t)x >> n : 0u));
        }
    }
    puts("semantic regression suite passed");
    return 0;
}
