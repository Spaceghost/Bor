package defers

touch :: proc "contextless" (s: []u8) -> u32 {
	defer s[0] = 9
	return u32(s[0])
}

@(export)
bor_test_defer :: proc "c" () -> u32 {
	a := [1]u8{1}
	s := a[0:1]
	before := touch(s)
	return before*10 + u32(a[0])
}
