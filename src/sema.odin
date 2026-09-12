package main

import "core:fmt"
import "core:odin/ast"

// The tooling parser deliberately preserves some source spelling, and the
// bootstrap lowerer deliberately uses a layout-shaped conditional terminator.
// Canonical MIR should contain neither. This phase is the boundary where
// parser/lowerer-shaped metadata becomes compiler semantics.

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

find_layout_successor :: proc(m: ^MIR_Module, p: ^MIR_Procedure, b: ^Basic_Block) -> (Block_ID, bool) {
	wanted_first_op := b.first_op + b.op_count
	for bi in int(p.first_block)..<int(p.first_block + p.block_count) {
		candidate := &m.blocks[bi]
		if candidate.started && candidate.first_op == wanted_first_op {
			return candidate.id, true
		}
	}
	return INVALID_BLOCK, false
}

canonicalize_control_flow :: proc(m: ^MIR_Module) -> bool {
	for &p, pi in m.procedures {
		for bi in int(p.first_block)..<int(p.first_block + p.block_count) {
			b := &m.blocks[bi]
			if !b.started || b.op_count == 0 do continue

			last_index := int(b.first_op + b.op_count - 1)
			terminator := &m.ops[last_index]
			if terminator.kind != .Jump_If_False do continue

			true_target, found := find_layout_successor(m, &p, b)
			if !found {
				fmt.eprintfln("bor: sema: proc %d (%s) block %d conditional has no layout successor", pi, p.name, bi)
				return false
			}

			false_target := terminator.target
			terminator.kind = .Branch
			terminator.target = true_target
			terminator.target_else = false_target

			// Bootstrap lowering already counted the false edge. Canonical MIR
			// owns both edges explicitly, so account for the formerly implicit
			// true/fallthrough edge exactly once while rewriting the terminator.
			m.blocks[int(true_target)].incoming += 1
		}
	}
	return true
}

normalize_mir_semantics :: proc(pkg: ^ast.Package, m: ^MIR_Module) -> bool {
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

	return canonicalize_control_flow(m)
}
