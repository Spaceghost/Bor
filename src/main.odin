package main

import "core:fmt"
import "core:odin/parser"
import "core:os"

usage :: proc() {
	fmt.eprintln("usage: bor <emit-c|emit-c-expr|dump-expr-plan|emit-c-direct|emit-c-mir|emit-c-mir-raw|dump-mir|dump-mir-raw> <odin-package-directory> -o <output>")
}

main :: proc() {
	if len(os.args) != 5 || os.args[3] != "-o" {
		usage()
		os.exit(2)
	}

	command := os.args[1]
	if command != "emit-c-expr" && command != "dump-expr-plan" && command != "emit-c" && command != "emit-c-direct" && command != "emit-c-mir" && command != "dump-mir" && command != "emit-c-mir-raw" && command != "dump-mir-raw" {
		usage()
		os.exit(2)
	}

	pkg, parsed := parser.parse_package_from_path(os.args[2])
	if !parsed || pkg == nil {
		fmt.eprintfln("bor: failed to parse %s with core:odin/parser", os.args[2])
		os.exit(1)
	}

	for _, file in pkg.files {
		if file.syntax_error_count != 0 {
			fmt.eprintfln("bor: refusing to lower a package with syntax errors")
			os.exit(1)
		}
	}

	generated: string
	emitted := false

	if command != "emit-c-direct" {
		m, lowered := lower_package_to_mir(pkg)
		defer mir_destroy(&m)
		if !lowered do os.exit(1)
		if !normalize_mir_semantics(pkg, &m) do os.exit(1)
		if !mir_verify(&m) do os.exit(1)
		if command != "emit-c-mir-raw" && command != "dump-mir-raw" {
			_ = mir_optimize(&m)
			if !mir_verify(&m) do os.exit(1)
		}
		if command == "dump-expr-plan" {
			generated = c_expr_dump_plan(&m)
			emitted = true
		} else if command == "dump-mir" || command == "dump-mir-raw" {
			generated = mir_dump(&m)
			emitted = true
		} else {
			generated, emitted = emit_mir_c99(&m, expressions = command == "emit-c-expr")
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
