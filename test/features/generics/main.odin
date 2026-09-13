package generics

identity :: proc "contextless" (value: $T) -> T {
	return value
}

@(export)
bor_test_generic :: proc "c" () -> u32 {
	return identity(u32(77))
}
