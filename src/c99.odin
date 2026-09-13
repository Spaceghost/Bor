package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
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
	Slice_U8,
	String,
}

Array_Local :: struct {
	elem:  C_Type,
	count: ^ast.Expr,
}

Emitter :: struct {
	out:           strings.Builder,
	depth:         int,
	locals:        map[string]C_Type,
	arrays:        map[string]Array_Local,
	named_locals:  map[string]string,
	struct_types:  map[string]bool,
	enum_backing:  map[string]C_Type,
	proc_results:  map[string]C_Type,
	proc_exports:  map[string]bool,
	failed:        bool,
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
	case .Unknown:  return "", false
	case .Void:     return "void", true
	case .Bool:     return "bool", true
	case .U8:       return "uint8_t", true
	case .U32:      return "uint32_t", true
	case .UIntptr:  return "uintptr_t", true
	case .U8_Ptr:   return "uint8_t *", true
	case .Slice_U8: return "bor_slice_u8", true
	case .String:   return "bor_string", true
	}
	return "", false
}

builtin_type :: proc(name: string) -> C_Type {
	switch name {
	case "bool":    return .Bool
	case "u8":      return .U8
	case "u32":     return .U32
	case "uintptr": return .UIntptr
	case "string":  return .String
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
	case ^ast.Array_Type:
		if n.len == nil && ast_type(n.elem) == .U8 {
			return .Slice_U8
		}
	}
	return .Unknown
}

resolved_type :: proc(e: ^Emitter, expr: ^ast.Expr) -> C_Type {
	if expr == nil {
		return .Unknown
	}
	if n, ok := expr.derived.(^ast.Ident); ok {
		if t, found := e.enum_backing[n.name]; found {
			return t
		}
	}
	return ast_type(expr)
}

named_type_name :: proc(e: ^Emitter, expr: ^ast.Expr) -> (string, bool) {
	name, ok := ident_name(expr)
	if !ok {
		return "", false
	}
	if e.struct_types[name] {
		return name, true
	}
	if _, found := e.enum_backing[name]; found {
		return name, true
	}
	return "", false
}

proc_result_type :: proc(e: ^Emitter, p: ^ast.Proc_Lit) -> C_Type {
	if p == nil || p.type == nil || p.type.results == nil || len(p.type.results.list) == 0 {
		return .Void
	}
	if len(p.type.results.list) != 1 {
		return .Unknown
	}
	return resolved_type(e, p.type.results.list[0].type)
}

enum_selector :: proc(e: ^Emitter, expr: ^ast.Expr) -> (type_name, field_name: string, ok: bool) {
	if expr == nil {
		return
	}
	n, is_selector := expr.derived.(^ast.Selector_Expr)
	if !is_selector || n.expr == nil || n.field == nil {
		return
	}
	base, named := ident_name(n.expr)
	if !named {
		return
	}
	if _, found := e.enum_backing[base]; !found {
		return
	}
	type_name = base
	field_name = n.field.name
	ok = true
	return
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
		if n.tok.kind == tokenizer.Token_Kind.String {
			return .String
		}
		if n.tok.kind == tokenizer.Token_Kind.Rune {
			return .U8
		}
		return .UIntptr
	case ^ast.Paren_Expr:
		return infer_type(e, n.expr)
	case ^ast.Index_Expr:
		if name, named := ident_name(n.expr); named {
			if a, found := e.arrays[name]; found {
				return a.elem
			}
		}
		base := infer_type(e, n.expr)
		if base == .U8_Ptr || base == .Slice_U8 || base == .String {
			return .U8
		}
	case ^ast.Slice_Expr:
		base := infer_type(e, n.expr)
		if name, named := ident_name(n.expr); named {
			if a, found := e.arrays[name]; found && a.elem == .U8 {
				return .Slice_U8
			}
		}
		if base == .Slice_U8 || base == .String {
			return .Slice_U8
		}
	case ^ast.Selector_Expr:
		if enum_name, _, ok := enum_selector(e, expr); ok {
			return e.enum_backing[enum_name]
		}
	case ^ast.Call_Expr:
		if name, named := ident_name(n.expr); named {
			if name == "len" {
				return .UIntptr
			}
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
	case ^ast.Type_Cast:
		return resolved_type(e, n.type)
	}
	return .Unknown
}

emit_type :: proc(e: ^Emitter, expr: ^ast.Expr) -> bool {
	if name, named := named_type_name(e, expr); named {
		write(e, name)
		return true
	}
	t := resolved_type(e, expr)
	if name, known := c_type_name(t); known {
		write(e, name)
		return true
	}
	return fail(e, "type at %s:%d", expr.pos.file, expr.pos.line)
}

emit_string_literal :: proc(e: ^Emitter, n: ^ast.Basic_Lit) -> bool {
	if n == nil || n.tok.kind != tokenizer.Token_Kind.String {
		return fail(e, "string literal")
	}
	text := n.tok.text
	if len(text) < 2 || text[0] != '"' || text[len(text)-1] != '"' {
		return fail(e, "raw string literal")
	}
	write(e, "(bor_string){(const uint8_t *)")
	write(e, text)
	write(e, ", (uintptr_t)(sizeof(")
	write(e, text)
	write(e, ") - 1)}")
	return true
}

emit_array_initializer :: proc(e: ^Emitter, n: ^ast.Comp_Lit) -> bool {
	write(e, "{")
	for elem, i in n.elems {
		if i > 0 do write(e, ", ")
		if _, named := elem.derived.(^ast.Field_Value); named {
			return fail(e, "named fixed-array initializer")
		}
		if !emit_expr(e, elem) do return false
	}
	write(e, "}")
	return true
}

emit_compound_literal :: proc(e: ^Emitter, n: ^ast.Comp_Lit) -> bool {
	if n == nil || n.type == nil {
		return fail(e, "untyped compound literal")
	}

	if type_name, named := ident_name(n.type); named && e.struct_types[type_name] {
		write(e, "(")
		write(e, type_name)
		write(e, "){")
		for elem, i in n.elems {
			if i > 0 do write(e, ", ")
			if fv, is_named := elem.derived.(^ast.Field_Value); is_named {
				field, field_ok := ident_name(fv.field)
				if !field_ok {
					return fail(e, "struct compound field")
				}
				write(e, ".")
				write(e, field)
				write(e, " = ")
				if !emit_expr(e, fv.value) do return false
			} else {
				if !emit_expr(e, elem) do return false
			}
		}
		write(e, "}")
		return true
	}

	if at, is_array := n.type.derived.(^ast.Array_Type); is_array && at.len != nil {
		write(e, "(")
		if !emit_type(e, at.elem) do return false
		write(e, "[")
		if !emit_expr(e, at.len) do return false
		write(e, "])")
		return emit_array_initializer(e, n)
	}

	return fail(e, "compound literal type")
}

emit_len :: proc(e: ^Emitter, arg: ^ast.Expr) -> bool {
	if arg == nil {
		return fail(e, "nil len operand")
	}
	if name, named := ident_name(arg); named {
		if a, found := e.arrays[name]; found {
			write(e, "(uintptr_t)(")
			if !emit_expr(e, a.count) do return false
			write(e, ")")
			return true
		}
	}
	if lit, is_lit := arg.derived.(^ast.Basic_Lit); is_lit && lit.tok.kind == tokenizer.Token_Kind.String {
		write(e, "(uintptr_t)(sizeof(")
		write(e, lit.tok.text)
		write(e, ") - 1)")
		return true
	}
	t := infer_type(e, arg)
	if t == .Slice_U8 || t == .String {
		write(e, "(")
		if !emit_expr(e, arg) do return false
		write(e, ").len")
		return true
	}
	return fail(e, "len operand")
}

emit_slice_bound :: proc(e: ^Emitter, base: ^ast.Expr, bound: ^ast.Expr, default_high: bool) -> bool {
	if bound != nil {
		return emit_expr(e, bound)
	}
	if !default_high {
		write(e, "0")
		return true
	}
	return emit_len(e, base)
}

emit_slice_expr :: proc(e: ^Emitter, n: ^ast.Slice_Expr) -> bool {
	if n == nil || n.expr == nil {
		return fail(e, "slice expression")
	}
	elem_type := C_Type.Unknown
	is_array := false
	if name, named := ident_name(n.expr); named {
		if a, found := e.arrays[name]; found {
			elem_type = a.elem
			is_array = true
		}
	}
	base_type := infer_type(e, n.expr)
	if elem_type == .Unknown && (base_type == .Slice_U8 || base_type == .String) {
		elem_type = .U8
	}
	if elem_type != .U8 {
		return fail(e, "slice element type")
	}

	write(e, "(bor_slice_u8){")
	if is_array {
		write(e, "&(")
		if !emit_expr(e, n.expr) do return false
		write(e, ")[")
		if !emit_slice_bound(e, n.expr, n.low, false) do return false
		write(e, "]")
	} else {
		write(e, "&((")
		if !emit_expr(e, n.expr) do return false
		write(e, ").data[")
		if !emit_slice_bound(e, n.expr, n.low, false) do return false
		write(e, "])")
	}
	write(e, ", (uintptr_t)((")
	if !emit_slice_bound(e, n.expr, n.high, true) do return false
	write(e, ") - (")
	if !emit_slice_bound(e, n.expr, n.low, false) do return false
	write(e, "))}")
	return true
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
		if n.tok.kind == tokenizer.Token_Kind.String {
			return emit_string_literal(e, n)
		}
		write(e, n.tok.text)
		return true

	case ^ast.Paren_Expr:
		write(e, "(")
		if !emit_expr(e, n.expr) do return false
		write(e, ")")
		return true

	case ^ast.Selector_Expr:
		if enum_name, field_name, ok := enum_selector(e, expr); ok {
			write(e, enum_name)
			write(e, "_")
			write(e, field_name)
			return true
		}
		if n.expr == nil || n.field == nil {
			return fail(e, "implicit selector")
		}
		if !emit_expr(e, n.expr) do return false
		write(e, ".")
		write(e, n.field.name)
		return true

	case ^ast.Index_Expr:
		base_type := infer_type(e, n.expr)
		if base_type == .Slice_U8 || base_type == .String {
			write(e, "(")
			if !emit_expr(e, n.expr) do return false
			write(e, ").data[")
			if !emit_expr(e, n.index) do return false
			write(e, "]")
			return true
		}
		if !emit_expr(e, n.expr) do return false
		write(e, "[")
		if !emit_expr(e, n.index) do return false
		write(e, "]")
		return true

	case ^ast.Slice_Expr:
		return emit_slice_expr(e, n)

	case ^ast.Comp_Lit:
		return emit_compound_literal(e, n)

	case ^ast.Call_Expr:
		if name, named := ident_name(n.expr); named {
			if name == "len" {
				if len(n.args) != 1 {
					return fail(e, "len argument count")
				}
				return emit_len(e, n.args[0])
			}
			if t := builtin_type(name); t != .Unknown && t != .String {
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
			if _, enum_cast := e.enum_backing[name]; enum_cast {
				if len(n.args) != 1 {
					return fail(e, "enum cast argument count")
				}
				write(e, "((")
				write(e, name)
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

emit_fixed_array_local :: proc(e: ^Emitter, name: string, lit: ^ast.Comp_Lit, at: ^ast.Array_Type) -> bool {
	if at == nil || at.len == nil {
		return fail(e, "inferred/dynamic fixed array")
	}
	elem := resolved_type(e, at.elem)
	ct, known := c_type_name(elem)
	if !known || elem == .Slice_U8 || elem == .String {
		return fail(e, "fixed array element type")
	}
	e.arrays[name] = Array_Local{elem = elem, count = at.len}

	indent(e)
	write(e, ct)
	write(e, " ")
	write(e, name)
	write(e, "[")
	if !emit_expr(e, at.len) do return false
	write(e, "] = ")
	if !emit_array_initializer(e, lit) do return false
	write(e, ";\n")
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
	value := d.values[0]

	if lit, is_compound := value.derived.(^ast.Comp_Lit); is_compound {
		if lit.type == nil {
			return fail(e, "untyped compound literal local")
		}
		if at, is_array := lit.type.derived.(^ast.Array_Type); is_array {
			return emit_fixed_array_local(e, name, lit, at)
		}
		if type_name, is_named := ident_name(lit.type); is_named && e.struct_types[type_name] {
			e.named_locals[name] = type_name
			indent(e)
			write(e, type_name)
			write(e, " ")
			write(e, name)
			write(e, " = ")
			if !emit_compound_literal(e, lit) do return false
			write(e, ";\n")
			return true
		}
	}

	if enum_name, _, is_enum_value := enum_selector(e, value); is_enum_value {
		e.locals[name] = e.enum_backing[enum_name]
		e.named_locals[name] = enum_name
		indent(e)
		write(e, enum_name)
		write(e, " ")
		write(e, name)
		write(e, " = ")
		if !emit_expr(e, value) do return false
		write(e, ";\n")
		return true
	}

	if d.type != nil {
		if type_name, is_named := named_type_name(e, d.type); is_named && e.struct_types[type_name] {
			e.named_locals[name] = type_name
			indent(e)
			write(e, type_name)
			write(e, " ")
			write(e, name)
			write(e, " = ")
			if !emit_expr(e, value) do return false
			write(e, ";\n")
			return true
		}
	}

	t := d.type != nil ? resolved_type(e, d.type) : infer_type(e, value)
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
	if !emit_expr(e, value) do return false
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
		if len(f.names) == 0 {
			return fail(e, "unnamed procedure parameter")
		}
		for ne in f.names {
			name, named := ident_name(ne)
			if !named {
				return fail(e, "procedure parameter name")
			}
			if !first do write(e, ", ")

			if type_name, is_named := named_type_name(e, f.type); is_named {
				write(e, type_name)
				if record_locals {
					e.named_locals[name] = type_name
					if backing, is_enum := e.enum_backing[type_name]; is_enum {
						e.locals[name] = backing
					}
				}
			} else {
				t := resolved_type(e, f.type)
				ct, known_type := c_type_name(t)
				if !known_type {
					return fail(e, "procedure parameter type")
				}
				write(e, ct)
				if record_locals {
					e.locals[name] = t
				}
			}
			write(e, " ")
			write(e, name)
			first = false
		}
	}
	return true
}

emit_proc_head :: proc(e: ^Emitter, name: string, p: ^ast.Proc_Lit, prototype: bool) -> bool {
	result_type := proc_result_type(e, p)
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

emit_struct_type :: proc(e: ^Emitter, name: string, n: ^ast.Struct_Type) -> bool {
	if n == nil || n.fields == nil {
		return fail(e, "empty struct type %s", name)
	}
	if n.poly_params != nil || n.align != nil || n.min_field_align != nil || n.max_field_align != nil ||
	   n.is_packed || n.is_raw_union || n.is_no_copy || n.is_all_or_none {
		return fail(e, "advanced struct type %s", name)
	}

	write(e, "typedef struct ")
	write(e, name)
	write(e, " {\n")
	e.depth += 1
	for field in n.fields.list {
		if field == nil || field.type == nil || len(field.names) == 0 {
			return fail(e, "struct field in %s", name)
		}
		for field_expr in field.names {
			field_name, ok := ident_name(field_expr)
			if !ok {
				return fail(e, "struct field name in %s", name)
			}
			indent(e)
			if !emit_type(e, field.type) do return false
			write(e, " ")
			write(e, field_name)
			write(e, ";\n")
		}
	}
	e.depth -= 1
	write(e, "} ")
	write(e, name)
	write(e, ";\n")
	return true
}

emit_enum_type :: proc(e: ^Emitter, name: string, n: ^ast.Enum_Type) -> bool {
	if n == nil || n.base_type == nil {
		return fail(e, "enum %s without explicit backing type", name)
	}
	backing := resolved_type(e, n.base_type)
	ct, known := c_type_name(backing)
	if !known || (backing != .U8 && backing != .U32 && backing != .UIntptr) {
		return fail(e, "enum %s backing type", name)
	}
	write(e, "typedef ")
	write(e, ct)
	write(e, " ")
	write(e, name)
	write(e, ";\nenum {\n")
	e.depth += 1
	for field_expr, i in n.fields {
		indent(e)
		if id, plain := field_expr.derived.(^ast.Ident); plain {
			write(e, name)
			write(e, "_")
			write(e, id.name)
		} else if fv, valued := field_expr.derived.(^ast.Field_Value); valued {
			field_name, named := ident_name(fv.field)
			if !named || fv.value == nil {
				return fail(e, "enum field in %s", name)
			}
			write(e, name)
			write(e, "_")
			write(e, field_name)
			write(e, " = ")
			if !emit_expr(e, fv.value) do return false
		} else {
			return fail(e, "enum field AST in %s", name)
		}
		if i+1 < len(n.fields) do write(e, ",")
		write(e, "\n")
	}
	e.depth -= 1
	write(e, "};\n")
	return true
}

collect_types :: proc(e: ^Emitter, pkg: ^ast.Package) {
	for _, file in pkg.files {
		for stmt in file.decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 {
				continue
			}
			name, named := ident_name(d.names[0])
			if !named do continue
			#partial switch n in d.values[0].derived {
			case ^ast.Struct_Type:
				e.struct_types[name] = true
			case ^ast.Enum_Type:
				e.enum_backing[name] = ast_type(n.base_type)
			}
		}
	}
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
				e.proc_results[name] = proc_result_type(e, p)
				e.proc_exports[name] = decl_is_exported(d)
			}
		}
	}
}

reset_locals :: proc(e: ^Emitter) {
	delete(e.locals)
	delete(e.arrays)
	delete(e.named_locals)
	e.locals = make(map[string]C_Type)
	e.arrays = make(map[string]Array_Local)
	e.named_locals = make(map[string]string)
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

			value := d.values[0]
			if p, is_proc := value.derived.(^ast.Proc_Lit); is_proc {
				if phase == 1 {
					if !emit_proc_head(e, name, p, true) do return false
					write(e, ";\n")
				} else if phase == 2 {
					reset_locals(e)
					if !emit_proc_head(e, name, p, false) do return false
					write(e, " ")
					if !emit_block(e, p.body) do return false
					write(e, "\n")
				}
				continue
			}

			if st, is_struct := value.derived.(^ast.Struct_Type); is_struct {
				if phase == 0 {
					if !emit_struct_type(e, name, st) do return false
				}
				continue
			}
			if et, is_enum := value.derived.(^ast.Enum_Type); is_enum {
				if phase == 0 {
					if !emit_enum_type(e, name, et) do return false
				}
				continue
			}

			if phase == 0 {
				value_type := d.type != nil ? resolved_type(e, d.type) : infer_type(e, value)
				ct, known_value := c_type_name(value_type)
				if !known_value {
					return fail(e, "top-level constant %s type", name)
				}
				write(e, "static const ")
				write(e, ct)
				write(e, " ")
				write(e, name)
				write(e, " = ")
				if !emit_expr(e, value) do return false
				write(e, ";\n")
			}
		}
	}
	return true
}

emit_c99 :: proc(pkg: ^ast.Package) -> (string, bool) {
	e := Emitter{
		locals        = make(map[string]C_Type),
		arrays        = make(map[string]Array_Local),
		named_locals  = make(map[string]string),
		struct_types  = make(map[string]bool),
		enum_backing  = make(map[string]C_Type),
		proc_results  = make(map[string]C_Type),
		proc_exports  = make(map[string]bool),
	}
	strings.builder_init(&e.out)
	defer delete(e.locals)
	defer delete(e.arrays)
	defer delete(e.named_locals)
	defer delete(e.struct_types)
	defer delete(e.enum_backing)
	defer delete(e.proc_results)
	defer delete(e.proc_exports)

	collect_types(&e, pkg)
	collect_globals(&e, pkg)

	write(&e, "/* generated by Bor from core:odin/parser AST */\n")
	write(&e, "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n")
	write(&e, "typedef struct { uint8_t *data; uintptr_t len; } bor_slice_u8;\n")
	write(&e, "typedef struct { const uint8_t *data; uintptr_t len; } bor_string;\n\n")
	if !emit_phase(&e, pkg, 0) do return "", false
	write(&e, "\n")
	if !emit_phase(&e, pkg, 1) do return "", false
	write(&e, "\n")
	if !emit_phase(&e, pkg, 2) do return "", false

	return strings.to_string(e.out), !e.failed
}
