package linkage

internal_c :: proc "c" (x: u32) -> u32 {
	return x + 1
}

@(export)
public_c :: proc "c" (x: u32) -> u32 {
	return internal_c(x) + 1
}
