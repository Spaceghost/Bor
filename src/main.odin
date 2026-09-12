package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"

usage :: proc() {
	fmt.eprintln("usage: bor <emit-c|emit-c-direct|emit-c-mir> <odin-package-directory> -o <output.c>")
}

decl_is_exported :: proc(d: ^ast.Value_Decl) -> bool {
	if d == nil do return false
	for attribute in d.attributes {
		if attribute == nil do continue
		for elem in attribute.elems {
			if ident, ok := elem.derived.(^ast.Ident); ok && ident.name == "export" {
				return true
			}
		}
	}
	return false
}

// Temporary MIR-only compatibility bridge. The direct backend owns linkage
// directly now; the MIR path will follow in the next shootout step.
normalize_mir_export_linkage :: proc(pkg: ^ast.Package) {
	for _, file in pkg.files {
		for stmt in file.decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || !decl_is_exported(d) || len(d.values) != 1 do continue
			p, is_proc := d.values[0].derived.(^ast.Proc_Lit)
			if !is_proc || p.type == nil do continue
			p.type.calling_convention = "c"
		}
	}
}

main :: proc() {
	if len(os.args) != 5 || os.args[3] != "-o" {
		usage()
		os.exit(2)
	}

	command := os.args[1]
	if command != "emit-c" && command != "emit-c-direct" && command != "emit-c-mir" {
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

	if command == "emit-c-mir" {
		normalize_mir_export_linkage(pkg)
		m, lowered := lower_package_to_mir(pkg)
		defer mir_destroy(&m)
		if !lowered do os.exit(1)
		generated, emitted = emit_mir_c99(&m)
	} else {
		generated, emitted = emit_c99(pkg)
	}

	if !emitted do os.exit(1)

	if err := os.write_entire_file(os.args[4], transmute([]u8)generated); err != nil {
		fmt.eprintfln("bor: failed writing %s: %v", os.args[4], err)
		os.exit(1)
	}
}
