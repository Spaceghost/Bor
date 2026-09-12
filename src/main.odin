package main

import "core:fmt"
import "core:odin/parser"
import "core:os"

usage :: proc() {
	fmt.eprintln("usage: bor <emit-c|emit-c-direct|emit-c-mir|dump-mir> <odin-package-directory> -o <output>")
}

main :: proc() {
	if len(os.args) != 5 || os.args[3] != "-o" {
		usage()
		os.exit(2)
	}

	command := os.args[1]
	if command != "emit-c" && command != "emit-c-direct" && command != "emit-c-mir" && command != "dump-mir" {
		usage()
		os.exit(2)
	}

	pkg, parsed := parser.parse_package_from_path(os.args[2])
	if !parsed || pkg == nil {
		fmt.eprintfln("bor: failed to parse %s with core:odin/parser", os.args[2])
		os.exit(1)
	}

	generated: string
	emitted := false

	if command == "emit-c-mir" || command == "dump-mir" {
		m, lowered := lower_package_to_mir(pkg)
		defer mir_destroy(&m)
		if !lowered do os.exit(1)
		normalize_mir_semantics(pkg, &m)
		if !mir_verify(&m) do os.exit(1)
		if command == "dump-mir" {
			generated = mir_dump(&m)
			emitted = true
		} else {
			generated, emitted = emit_mir_c99(&m)
		}
	} else {
		generated, emitted = emit_c99(pkg)
	}

	if !emitted do os.exit(1)

	if err := os.write_entire_file(os.args[4], transmute([]u8)generated); err != nil {
		fmt.eprintfln("bor: failed writing %s: %v", os.args[4], err)
		os.exit(1)
	}
}
