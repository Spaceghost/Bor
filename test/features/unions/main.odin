package unions

Value :: union {u32, u8}

from_u32 :: proc "contextless" () -> u32 {
	v: Value = u32(41)
	return v.(u32) + 1
}

from_u8 :: proc "contextless" () -> u32 {
	v: Value = u8(7)
	return u32(v.(u8))
}

@(export)
bor_test_unions :: proc "c" () -> u32 {
	return from_u32() + from_u8()
}
