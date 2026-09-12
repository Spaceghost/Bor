package control

mix_core :: proc "contextless" (x: u32, n: uintptr) -> u32 {
	acc := x
	for i in 0..<n {
		v := u32(i)
		if (v & 1) == 0 {
			acc += v * 3
		} else {
			acc = acc ~ (v + 7)
		}
	}
	if acc > 1000 && n != 0 {
		acc -= 1000
	}
	return acc
}

@(export)
control_mix :: proc "c" (x: u32, n: uintptr) -> u32 {
	return mix_core(x, n)
}
