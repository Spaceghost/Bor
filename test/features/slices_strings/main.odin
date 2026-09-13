package slices_strings

@(export)
bor_test_slice_string :: proc "c" () -> u32 {
	a := [4]u8{1, 2, 3, 4}
	s := a[1:4]
	text := "abc"
	return u32(s[0]) + u32(s[2]) + u32(text[1]) + u32(len(s)) + u32(len(text))
}
