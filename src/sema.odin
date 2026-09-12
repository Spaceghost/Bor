package main

import "core:odin/ast"

// The tooling parser deliberately preserves some source spelling. Bor's MIR
// should not. This phase is the boundary where parser-shaped metadata becomes
// compiler semantics before verification and backend emission.

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

normalize_calling_convention :: proc(cc: string) -> string {
	if len(cc) < 2 do return cc
	first := cc[0]
	last := cc[len(cc)-1]
	if (first == '"' && last == '"') || (first == '`' && last == '`') {
		return cc[1:len(cc)-1]
	}
	return cc
}

normalize_mir_semantics :: proc(pkg: ^ast.Package, m: ^MIR_Module) {
	// ABI spelling is syntax. Strip the parser's source delimiters once here so
	// every later pass sees semantic names such as `c` and `contextless`.
	for &p in m.procedures {
		p.calling_convention = normalize_calling_convention(p.calling_convention)
	}

	// Visibility belongs to the declaration's @(export) attribute, not to its
	// calling convention. Set it explicitly even if bootstrap lowering guessed.
	for _, file in pkg.files {
		for stmt in file.decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 do continue
			name_expr, named := d.names[0].derived.(^ast.Ident)
			if !named do continue
			if _, is_proc := d.values[0].derived.(^ast.Proc_Lit); !is_proc do continue

			for &p in m.procedures {
				if p.name == name_expr.name {
					p.external = decl_is_exported(d)
					break
				}
			}
		}
	}
}
