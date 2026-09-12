package main

import "core:fmt"
import "core:odin/parser"
import "core:os"

usage :: proc() {
	fmt.eprintln("usage: bor emit-c <odin-package-directory> -o <output.c>")
}

main :: proc() {
	if len(os.args) != 5 || os.args[1] != "emit-c" || os.args[3] != "-o" {
		usage()
		os.exit(2)
	}

	pkg, parsed := parser.parse_package_from_path(os.args[2])
	if !parsed || pkg == nil {
		fmt.eprintfln("bor: failed to parse %s with core:odin/parser", os.args[2])
		os.exit(1)
	}

	generated, emitted := emit_c99(pkg)
	if !emitted {
		os.exit(1)
	}

	if err := os.write_entire_file(os.args[4], transmute([]u8)generated); err != nil {
		fmt.eprintfln("bor: failed writing %s: %v", os.args[4], err)
		os.exit(1)
	}
}
