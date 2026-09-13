package generate

import "core:fmt"
import "core:os"
import "core:strings"

Generator :: struct {
	state: u32,
	out: strings.Builder,
	type_name: string,
}

next :: proc(g: ^Generator) -> u32 {
	x := g.state
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	g.state = x
	return x
}

expression :: proc(g: ^Generator, depth: int) {
	if depth == 0 {
		switch next(g) % 3 {
		case 0: strings.write_string(&g.out, "a")
		case 1: strings.write_string(&g.out, "b")
		case 2: strings.write_string(&g.out, "c")
		}
		return
	}
	operators := [?]string{"+", "-", "*", "~", "&", "|", "<<", ">>", "/", "%"}
	op := int(next(g) % u32(len(operators)))
	strings.write_string(&g.out, "(")
	expression(g, depth-1)
	fmt.sbprintf(&g.out, " %s ", operators[op])
	if op >= 8 {
		fmt.sbprintf(&g.out, "%s(%d)", g.type_name, next(g) % 15 + 1)
	} else if op >= 6 {
		// Includes oversized byte shifts but stays within the u32 shift domain.
		fmt.sbprintf(&g.out, "u32(%d)", next(g) % 32)
	} else {
		expression(g, depth-1)
	}
	strings.write_string(&g.out, ")")
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: generate <existing-output-directory>")
		os.exit(2)
	}
	g := Generator{state = 0xB077_2026}
	strings.builder_init(&g.out)
	defer strings.builder_destroy(&g.out)
	strings.write_string(&g.out, "package generated\n\n")
	COUNT :: 256
	for i in 0..<COUNT {
		g.type_name = i < 64 ? "u32" : i < 128 ? "u8" : i < 192 ? "u16" : "u64"
		fmt.sbprintf(&g.out, "@(export)\nf_%d :: proc \"c\" (x, y: u32) -> u32 {{\n", i)
		fmt.sbprintf(&g.out, "\ta := %s(x)\n\tb := %s(y)\n\tc := %s(%d)\n\treturn u32(", g.type_name, g.type_name, g.type_name, next(&g) % 128)
		expression(&g, 5)
		strings.write_string(&g.out, ")\n}\n\n")
	}
	source := strings.to_string(g.out)
	if err := os.write_entire_file(fmt.tprintf("%s/main.odin", os.args[1]), transmute([]u8)source); err != nil do os.exit(1)

	h: strings.Builder
	strings.builder_init(&h)
	defer strings.builder_destroy(&h)
	strings.write_string(&h, "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n")
	for i in 0..<COUNT do fmt.sbprintf(&h, "extern uint32_t f_%d(uint32_t, uint32_t);\n", i)
	strings.write_string(&h, "typedef uint32_t (*function)(uint32_t,uint32_t);\nint main(int argc, char **argv) {\nfunction functions[] = {\n")
	for i in 0..<COUNT do fmt.sbprintf(&h, "f_%d,\n", i)
	strings.write_string(&h, "};\nuint32_t seed = argc > 1 ? (uint32_t)strtoul(argv[1],0,0) : UINT32_C(20260912);\n")
	strings.write_string(&h, "for (unsigned j=0; j<256; ++j) {\nseed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;\nuint32_t x = j==0 ? UINT32_MAX : seed;\nseed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;\nuint32_t y = j==0 ? 1u : seed;\n")
	fmt.sbprintf(&h, "for (unsigned i=0; i<%d; ++i) {{\nuint32_t value=functions[i](x,y);\nif(fwrite(&value,sizeof(value),1,stdout)!=1) return 1;\n}}\n}}\nreturn 0;\n}}\n", COUNT)
	host := strings.to_string(h)
	if err := os.write_entire_file(fmt.tprintf("%s/host.c", os.args[1]), transmute([]u8)host); err != nil do os.exit(1)
	fmt.println("generated 256 procedures, 256 input pairs, seed 0xB0772026")
}
