package main

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

C_Type :: enum {
	Unknown,
	Void,
	Bool,
	U8,
	U32,
	UIntptr,
	U8_Ptr,
}

Emitter :: struct {
	out:          strings.Builder,
	depth:        int,
	locals:       map[string]C_Type,
	proc_results: map[string]C_Type,
	proc_exports: map[string]bool,
	failed:       bool,
}

write :: proc(e: ^Emitter, s: string) {
	strings.write_string(&e.out, s)
}

indent :: proc(e: ^Emitter) {
	for _ in 0..<e.depth {
		write(e, "    ")
	}
}

fail :: proc(e: ^Emitter, msg: string, args: ..any) -> bool {
	fmt.eprintf("bor: unsupported: ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
	e.failed = true
	return false
}

ident_name :: proc(expr: ^ast.Expr) -> (string, bool) {
	if expr == nil {
		return "", false
	}
	if n, matched := expr.derived.(^ast.Ident); matched {
		return n.name, true
	}
	return "", false
}

c_type_name :: proc(t: C_Type) -> (string, bool) {
	switch t {
	case .Unknown: return "", false
	case .Void:    return "void", true
	case .Bool:    return "bool", true
	case .U8:      return "uint8_t", true
	case .U32:     return "uint32_t", true
	case .UIntptr: return "uintptr_t", true
	case .U8_Ptr:  return "uint8_t *", true
	}
	return "", false
}

builtin_type :: proc(name: string) -> C_Type {
	switch name {
	case "bool":    return .Bool
	case "u8":      return .U8
	case "u32":     return .U32
	case "uintptr": return .UIntptr
	}
	return .Unknown
}

ast_type :: proc(expr: ^ast.Expr) -> C_Type {
	if expr == nil {
		return .Unknown
	}
	#partial switch n in expr.derived {
	case ^ast.Ident:
		return builtin_type(n.name)
	case ^ast.Paren_Expr:
		return ast_type(n.expr)
	case ^ast.Multi_Pointer_Type:
		if ast_type(n.elem) == .U8 {
			return .U8_Ptr
		}
	case ^ast.Pointer_Type:
		if ast_type(n.elem) == .U8 {
			return .U8_Ptr
		}
	}
	return .Unknown
}

proc_result_type :: proc(p: ^ast.Proc_Lit) -> C_Type {
	if p == nil || p.type == nil || p.type.results == nil || len(p.type.results.list) == 0 {
		return .Void
	}
	if len(p.type.results.list) != 1 {
		return .Unknown
	}
	return ast_type(p.type.results.list[0].type)
}

infer_type :: proc(e: ^Emitter, expr: ^ast.Expr) -> C_Type {
	if expr == nil {
		return .Unknown
	}
	#partial switch n in expr.derived {
	case ^ast.Ident:
		if t, found_local := e.locals[n.name]; found_local {
			return t
		}
		if t, found_proc := e.proc_results[n.name]; found_proc {
			return t
		}
		return builtin_type(n.name)
	case ^ast.Basic_Lit:
		return .UIntptr
	case ^ast.Paren_Expr:
		return infer_type(e, n.expr)
	case ^ast.Index_Expr:
		if infer_type(e, n.expr) == .U8_Ptr {
			return .U8
		}
	case ^ast.Call_Expr:
		if name, named := ident_name(n.expr); named {
			if t := builtin_type(name); t != .Unknown {
				return t
			}
			if t, found_proc := e.proc_results[name]; found_proc {
				return t
			}
		}
	case ^ast.Unary_Expr:
		return infer_type(e, n.expr)
	case ^ast.Binary_Expr:
		switch n.op.text {
		case "==", "!=", "<", ">", "<=", ">=", "&&", "||":
			return .Bool
		}
		left_type := infer_type(e, n.left)
		right_type := infer_type(e, n.right)
		if left_type != .Unknown && left_type != .Bool {
			return left_type
		}
		return right_type
	}
	return .Unknown
}

emit_type :: proc(e: ^Emitter, expr: ^ast.Expr) -> bool {
	t := ast_type(expr)
	if name, known := c_type_name(t); known {
		write(e, name)
		return true
	}
	return fail(e, "type at %s:%d", expr.pos.file, expr.pos.line)
}

emit_expr :: proc(e: ^Emitter, expr: ^ast.Expr) -> bool {
	if expr == nil {
		return fail(e, "nil expression")
	}

	#partial switch n in expr.derived {
	case ^ast.Ident:
		if n.name == "nil" {
			write(e, "NULL")
		} else {
			write(e, n.name)
		}
		return true

	case ^ast.Basic_Lit:
		write(e, n.tok.text)
		return true

	case ^ast.Paren_Expr:
		write(e, "(")
		if !emit_expr(e, n.expr) do return false
		write(e, ")")
		return true

	case ^ast.Index_Expr:
		if !emit_expr(e, n.expr) do return false
		write(e, "[")
		if !emit_expr(e, n.index) do return false
		write(e, "]")
		return true

	case ^ast.Call_Expr:
		if name, named := ident_name(n.expr); named {
			if t := builtin_type(name); t != .Unknown {
				if len(n.args) != 1 {
					return fail(e, "scalar cast argument count")
				}
				ct, _ := c_type_name(t)
				write(e, "((")
				write(e, ct)
				write(e, ")(")
				if !emit_expr(e, n.args[0]) do return false
				write(e, "))")
				return true
			}
		}
		if !emit_expr(e, n.expr) do return false
		write(e, "(")
		for arg, i in n.args {
			if i > 0 do write(e, ", ")
			if !emit_expr(e, arg) do return false
		}
		write(e, ")")
		return true

	case ^ast.Unary_Expr:
		write(e, "(")
		write(e, n.op.text)
		if !emit_expr(e, n.expr) do return false
		write(e, ")")
		return true

	case ^ast.Binary_Expr:
		if n.op.text == "..<" || n.op.text == "..=" {
			return fail(e, "range expression outside range statement")
		}
		write(e, "(")
		if !emit_expr(e, n.left) do return false
		if n.op.text == "&~" {
			write(e, " & ~(")
			if !emit_expr(e, n.right) do return false
			write(e, ")")
		} else {
			write(e, " ")
			write(e, n.op.text == "~" ? "^" : n.op.text)
			write(e, " ")
			if !emit_expr(e, n.right) do return false
		}
		write(e, ")")
		return true

	case ^ast.Type_Cast:
		write(e, "((")
		if !emit_type(e, n.type) do return false
		write(e, ")(")
		if !emit_expr(e, n.expr) do return false
		write(e, "))")
		return true
	}

	return fail(e, "expression node at %s:%d", expr.pos.file, expr.pos.line)
}

emit_block :: proc(e: ^Emitter, stmt: ^ast.Stmt) -> bool {
	if stmt == nil {
		return fail(e, "nil block")
	}
	b, is_block := stmt.derived.(^ast.Block_Stmt)
	if !is_block {
		return fail(e, "expected block at %s:%d", stmt.pos.file, stmt.pos.line)
	}

	write(e, "{\n")
	e.depth += 1
	for s in b.stmts {
		if !emit_stmt(e, s) do return false
	}
	e.depth -= 1
	indent(e)
	write(e, "}\n")
	return true
}

emit_local_decl :: proc(e: ^Emitter, d: ^ast.Value_Decl) -> bool {
	if len(d.names) != 1 || len(d.values) != 1 {
		return fail(e, "multi-name local declaration")
	}
	name, named := ident_name(d.names[0])
	if !named {
		return fail(e, "non-identifier local declaration")
	}

	t := d.type != nil ? ast_type(d.type) : infer_type(e, d.values[0])
	ct, known_type := c_type_name(t)
	if !known_type {
		return fail(e, "cannot infer local %s", name)
	}
	e.locals[name] = t

	indent(e)
	write(e, ct)
	write(e, " ")
	write(e, name)
	write(e, " = ")
	if !emit_expr(e, d.values[0]) do return false
	write(e, ";\n")
	return true
}

emit_stmt :: proc(e: ^Emitter, stmt: ^ast.Stmt) -> bool {
	if stmt == nil {
		return true
	}

	#partial switch n in stmt.derived {
	case ^ast.Block_Stmt:
		return emit_block(e, stmt)

	case ^ast.Value_Decl:
		return emit_local_decl(e, n)

	case ^ast.Return_Stmt:
		if len(n.results) > 1 {
			return fail(e, "multiple return values")
		}
		indent(e)
		write(e, "return")
		if len(n.results) == 1 {
			write(e, " ")
			if !emit_expr(e, n.results[0]) do return false
		}
		write(e, ";\n")
		return true

	case ^ast.Expr_Stmt:
		indent(e)
		if !emit_expr(e, n.expr) do return false
		write(e, ";\n")
		return true

	case ^ast.Assign_Stmt:
		if len(n.lhs) != 1 || len(n.rhs) != 1 {
			return fail(e, "tuple assignment")
		}
		indent(e)
		if !emit_expr(e, n.lhs[0]) do return false
		write(e, " ")
		write(e, n.op.text == "~=" ? "^=" : n.op.text)
		write(e, " ")
		if !emit_expr(e, n.rhs[0]) do return false
		write(e, ";\n")
		return true

	case ^ast.If_Stmt:
		if n.init != nil {
			return fail(e, "if initializer")
		}
		indent(e)
		if _, binary_condition := n.cond.derived.(^ast.Binary_Expr); binary_condition {
			write(e, "if ")
			if !emit_expr(e, n.cond) do return false
			write(e, " ")
		} else {
			write(e, "if (")
			if !emit_expr(e, n.cond) do return false
			write(e, ") ")
		}
		if !emit_block(e, n.body) do return false
		if n.else_stmt != nil {
			indent(e)
			write(e, "else ")
			if _, is_if := n.else_stmt.derived.(^ast.If_Stmt); is_if {
				if !emit_stmt(e, n.else_stmt) do return false
			} else {
				if !emit_block(e, n.else_stmt) do return false
			}
		}
		return true

	case ^ast.Range_Stmt:
		if n.reverse || len(n.vals) != 1 {
			return fail(e, "reverse/multi-value range")
		}
		idx, named_idx := ident_name(n.vals[0])
		if !named_idx {
			return fail(e, "range index")
		}
		range_expr, is_range := n.expr.derived.(^ast.Binary_Expr)
		if !is_range || (range_expr.op.text != "..<" && range_expr.op.text != "..=") {
			return fail(e, "non-bounded range")
		}
		idx_type := infer_type(e, range_expr.right)
		if idx_type == .Unknown {
			idx_type = .UIntptr
		}
		ct, known_idx_type := c_type_name(idx_type)
		if !known_idx_type {
			return fail(e, "range index type")
		}
		e.locals[idx] = idx_type

		indent(e)
		write(e, "for (")
		write(e, ct)
		write(e, " ")
		write(e, idx)
		write(e, " = ")
		if !emit_expr(e, range_expr.left) do return false
		write(e, "; ")
		write(e, idx)
		write(e, range_expr.op.text == "..<" ? " < " : " <= ")
		if !emit_expr(e, range_expr.right) do return false
		write(e, "; ++")
		write(e, idx)
		write(e, ") ")
		return emit_block(e, n.body)
	}

	return fail(e, "statement node at %s:%d", stmt.pos.file, stmt.pos.line)
}

emit_params :: proc(e: ^Emitter, p: ^ast.Proc_Lit, record_locals: bool) -> bool {
	if p.type.params == nil || len(p.type.params.list) == 0 {
		write(e, "void")
		return true
	}

	first := true
	for f in p.type.params.list {
		t := ast_type(f.type)
		ct, known_type := c_type_name(t)
		if !known_type {
			return fail(e, "procedure parameter type")
		}
		if len(f.names) == 0 {
			return fail(e, "unnamed procedure parameter")
		}
		for ne in f.names {
			name, named := ident_name(ne)
			if !named {
				return fail(e, "procedure parameter name")
			}
			if !first do write(e, ", ")
			write(e, ct)
			write(e, " ")
			write(e, name)
			if record_locals {
				e.locals[name] = t
			}
			first = false
		}
	}
	return true
}

emit_proc_head :: proc(e: ^Emitter, name: string, p: ^ast.Proc_Lit, prototype: bool) -> bool {
	result_type := proc_result_type(p)
	ct, known_result := c_type_name(result_type)
	if !known_result {
		return fail(e, "procedure result type for %s", name)
	}
	if !e.proc_exports[name] {
		write(e, "static ")
	}
	write(e, ct)
	write(e, " ")
	write(e, name)
	write(e, "(")
	if !emit_params(e, p, !prototype) do return false
	write(e, ")")
	return true
}

collect_globals :: proc(e: ^Emitter, pkg: ^ast.Package) {
	for _, file in pkg.files {
		for stmt in file.decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 {
				continue
			}
			name, named := ident_name(d.names[0])
			if !named do continue
			if p, is_proc := d.values[0].derived.(^ast.Proc_Lit); is_proc {
				e.proc_results[name] = proc_result_type(p)
				e.proc_exports[name] = decl_is_exported(d)
			}
		}
	}
}

emit_phase :: proc(e: ^Emitter, pkg: ^ast.Package, phase: int) -> bool {
	paths := make([dynamic]string, 0, len(pkg.files), context.temp_allocator)
	for path, _ in pkg.files {
		append(&paths, path)
	}
	slice.sort(paths[:])

	for path in paths {
		file := pkg.files[path]
		for stmt in file.decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 {
				continue
			}
			name, named := ident_name(d.names[0])
			if !named {
				return fail(e, "top-level non-identifier declaration")
			}

			if p, is_proc := d.values[0].derived.(^ast.Proc_Lit); is_proc {
				if phase == 1 {
					if !emit_proc_head(e, name, p, true) do return false
					write(e, ";\n")
				} else if phase == 2 {
					delete(e.locals)
					e.locals = make(map[string]C_Type)
					if !emit_proc_head(e, name, p, false) do return false
					write(e, " ")
					if !emit_block(e, p.body) do return false
					write(e, "\n")
				}
				continue
			}

			if phase == 0 {
				value_type := d.type != nil ? ast_type(d.type) : infer_type(e, d.values[0])
				ct, known_value := c_type_name(value_type)
				if !known_value {
					return fail(e, "top-level constant %s type", name)
				}
				write(e, "static const ")
				write(e, ct)
				write(e, " ")
				write(e, name)
				write(e, " = ")
				if !emit_expr(e, d.values[0]) do return false
				write(e, ";\n")
			}
		}
	}
	return true
}

emit_c99 :: proc(pkg: ^ast.Package) -> (string, bool) {
	e := Emitter{
		locals       = make(map[string]C_Type),
		proc_results = make(map[string]C_Type),
		proc_exports = make(map[string]bool),
	}
	strings.builder_init(&e.out)
	defer delete(e.locals)
	defer delete(e.proc_results)
	defer delete(e.proc_exports)

	collect_globals(&e, pkg)

	write(&e, "/* generated by Bor from core:odin/parser AST */\n")
	write(&e, "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n")
	if !emit_phase(&e, pkg, 0) do return "", false
	write(&e, "\n")
	if !emit_phase(&e, pkg, 1) do return "", false
	write(&e, "\n")
	if !emit_phase(&e, pkg, 2) do return "", false

	// This string aliases the builder's storage only until main writes it.
	// The process exits immediately afterwards, so no copy is required.
	return strings.to_string(e.out), !e.failed
}
