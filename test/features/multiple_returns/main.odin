package multiple_returns

pair :: proc "contextless" (x: u32) -> (u32, u8) {
	return x + 1, u8(2)
}

@(export)
bor_test_multiple_returns :: proc "c" () -> u32 {
	a, b := pair(40)
	return a + u32(b)
}
