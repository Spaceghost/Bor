package structs

Pair :: struct {
	a: u8,
	b: u32,
}

@(export)
bor_test_pair_sum :: proc "c" (a: u8, b: u32) -> u32 {
	p := Pair{a = a, b = b}
	return u32(p.a) + p.b
}
