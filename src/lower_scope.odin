package main

import "core:odin/ast"

// Restore bindings in reverse declaration order without cloning symbol maps.
Local_Binding :: struct {
	name: string,
	previous: Value_ID,
	existed: bool,
}

enter_scope :: proc(l: ^Lowerer) {
	append(&l.scope_marks, len(l.bindings))
}

leave_scope :: proc(l: ^Lowerer) {
	mark := pop(&l.scope_marks)
	for len(l.bindings) > mark {
		b := pop(&l.bindings)
		if b.existed {
			l.locals[b.name] = b.previous
		} else {
			delete_key(&l.locals, b.name)
		}
	}
}

bind_local :: proc(l: ^Lowerer, name: string, id: Value_ID, node: ^ast.Node) -> bool {
	old, existed := l.locals[name]
	// Scope-local duplicate declarations are rejected before code emission.
	mark := l.scope_marks[len(l.scope_marks)-1]
	if existed {
		for b in l.bindings[mark:] {
			if b.name == name do return lower_fail(l, node, "duplicate local %s", name)
		}
	}
	append(&l.bindings, Local_Binding{name = name, previous = old, existed = existed})
	l.locals[name] = id
	return true
}

range_index_type :: proc(l: ^Lowerer, expr: ^ast.Expr) -> MIR_Type {
	if expr == nil do return .Invalid
	#partial switch n in expr.derived {
	case ^ast.Ident:
		if id, found := lookup_value(l, n.name); found do return value_type(l, id)
	case ^ast.Basic_Lit:
		return .UIntptr
	case ^ast.Paren_Expr:
		return range_index_type(l, n.expr)
	case ^ast.Type_Cast:
		return mir_type_from_ast(n.type)
	case ^ast.Call_Expr:
		if t := mir_type_from_ast(n.expr); t != .Invalid do return t
		if name, named := mir_ident_name(n.expr); named {
			if id, found := l.proc_ids[name]; found do return l.m.procedures[int(id)].result
		}
	case ^ast.Binary_Expr:
		return binary_result_type(.Add, range_index_type(l, n.left), range_index_type(l, n.right))
	}
	return .Invalid
}

unsigned_max_text :: proc(t: MIR_Type) -> string {
	#partial switch t {
	case .U8: return "UINT8_MAX"
	case .U32: return "UINT32_MAX"
	case .UIntptr: return "UINTPTR_MAX"
	}
	return "0"
}

// Reject ABI-affecting constructs until they have executable lowering tests.
validate_proc_contract :: proc(l: ^Lowerer, d: ^ast.Value_Decl, p: ^ast.Proc_Lit) -> bool {
	cc := normalize_calling_convention(mir_calling_convention(p))
	if cc != "c" && cc != "cdecl" && cc != "contextless" do return lower_fail(l, &p.node, "only c/cdecl/contextless procedures are implemented")
	if p.body == nil do return lower_fail(l, &p.node, "foreign procedures are not implemented")
	if len(p.where_clauses) != 0 do return lower_fail(l, &p.node, "where clauses are not implemented")
	if p.type.results != nil {
		for field in p.type.results.list {
			if len(field.names) > 1 do return lower_fail(l, &p.node, "multiple named returns are not implemented")
		}
	}
	for attribute in d.attributes {
		for elem in attribute.elems {
			name, named := mir_ident_name(elem)
			if !named || name != "export" do return lower_fail(l, &p.node, "only bare @(export) procedure attributes are implemented")
		}
	}
	return true
}
