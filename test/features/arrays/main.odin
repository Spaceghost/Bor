package arrays

@(export)
bor_test_array_sum :: proc "c" () -> u32 {
	a := [4]u8{1, 2, 3, 4}
	return u32(a[0]) + u32(a[1]) + u32(a[2]) + u32(a[3])
}
