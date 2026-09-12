package semantics

inc :: proc "contextless" (x: u32) -> u32 { return x + 1 }
pair :: proc "contextless" (a, b: u32) -> u32 { return a * 100 + b }
next_byte :: proc "contextless" (p: [^]u8) -> u32 {
	p[0] = p[0] + 1
	return u32(p[0])
}
touch :: proc "contextless" (p: [^]u8) -> bool {
	p[0] = p[0] + 1
	return true
}
limit :: proc "contextless" (p: [^]u8) -> u32 { return u32(p[0]) }

@(export)
nested_calls :: proc "c" () -> u32 { return pair(inc(1), inc(2)) }

@(export)
ordered_calls :: proc "c" (p: [^]u8) -> u32 {
	return pair(next_byte(p), next_byte(p))
}

@(export)
lexical_scope :: proc "c" () -> u32 {
	x := u32(7)
	total: u32
	{
		x := u32(9)
		total += x
	}
	return x * 100 + total
}

@(export)
zero_locals :: proc "c" () -> u32 {
	n: u32
	flag: bool
	p: [^]u8
	if !flag && p == nil { return n }
	return 17
}

@(export)
short_circuit :: proc "c" (p: [^]u8) -> u32 {
	r := false && touch(p)
	r = true || touch(p)
	if r && touch(p) { return u32(p[0]) }
	return 999
}

@(export)
all_paths_return :: proc "c" (flag: bool) -> u32 {
	if flag { return 11 } else { return 22 }
}

@(export)
byte_arithmetic :: proc "c" (x: u8) -> u32 { return u32((x + x) / 2) }

@(export)
literal_width :: proc "c" (x: u32) -> u32 {
	sum := 1 + x
	sum += 1
	return sum / 2
}

@(export)
max_range_byte :: proc "c" (first, last: u8) -> u32 {
	n: u32
	for i in first..=last { n += u32(i) - u32(first) + 1 }
	return n
}

@(export)
max_range_word :: proc "c" (first, last: u32) -> u32 {
	n: u32
	for i in first..=last { n += i - first + 1 }
	return n
}

@(export)
max_range_pointer :: proc "c" (first, last: uintptr) -> u32 {
	n: u32
	for i in first..=last { n += u32(i - first) + 1 }
	return n
}

@(export)
dynamic_bound :: proc "c" (p: [^]u8) -> u32 {
	n: u32
	for i in 0..<limit(p) {
		n += i
		p[0] = 2
	}
	return n
}

@(export)
shift_byte :: proc "c" (x: u8, n: u32) -> u32 { return u32(x << n) }
@(export)
shift_word :: proc "c" (x: u32, n: u32) -> u32 { return x << n }
@(export)
shift_pointer :: proc "c" (x: uintptr, n: u32) -> uintptr { return x >> n }
@(export)
source_literals :: proc "c" () -> u32 { return u32(0b1010 + 0o12 + 1_000 + 012) }
