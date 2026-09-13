package main

import "core:odin/ast"

Lower_Loop :: struct {
	label: string,
	break_target, continue_target: Block_ID,
	defer_first: int,
}
Deferred_Stmt :: struct {
	statement: ^ast.Stmt,
	bindings: map[string]Value_ID,
}
copy_local_bindings :: proc(source: map[string]Value_ID) -> map[string]Value_ID {
	result := make(map[string]Value_ID, len(source))
	for name, id in source do result[name] = id
	return result
}

// Capture names, not runtime values. Each exit lowers against its own map.
register_defer :: proc(l: ^Lowerer, n: ^ast.Defer_Stmt) -> bool {
	if l.in_defer do return lower_fail(l, &n.node, "nested defer bodies are not implemented")
	append(&l.defers, Deferred_Stmt{statement = n.stmt, bindings = copy_local_bindings(l.locals)})
	return true
}
emit_defers_from :: proc(l: ^Lowerer, first: int) -> bool {
	for i := len(l.defers); i > first; i -= 1 {
		d := l.defers[i-1]
		locals := l.locals
		in_defer := l.in_defer
		l.locals = copy_local_bindings(d.bindings)
		l.in_defer = true
		ok := lower_stmt(l, d.statement)
		delete(l.locals)
		l.locals = locals
		l.in_defer = in_defer
		if !ok do return false
	}
	return true
}
lower_value :: proc(l: ^Lowerer, expr: ^ast.Expr) -> (Value_ID, bool) {
	value, ok := lower_expr(l, expr)
	if !ok do return INVALID_VALUE, false
	if value == INVALID_VALUE {
		lower_fail(l, nil, "void expression used where a value is required")
		return INVALID_VALUE, false
	}
	return value, true
}
loop_label :: proc(l: ^Lowerer, expr: ^ast.Expr) -> (string, bool) {
	if expr == nil do return "", true
	name, ok := mir_ident_name(expr)
	if !ok { lower_fail(l, nil, "loop label must be an identifier"); return "", false }
	for loop in l.loops {
		if loop.label == name { lower_fail(l, nil, "duplicate active loop label %s", name); return "", false }
	}
	return name, true
}
lower_branch :: proc(l: ^Lowerer, n: ^ast.Branch_Stmt) -> bool {
	if l.in_defer do return lower_fail(l, &n.node, "branches in deferred bodies are not implemented")
	if n.tok.text != "break" && n.tok.text != "continue" do return lower_fail(l, &n.node, "branch %s is not implemented", n.tok.text)
	for i := len(l.loops); i > 0; i -= 1 {
		loop := l.loops[i-1]
		if n.label != nil && loop.label != n.label.name do continue
		if !emit_defers_from(l, loop.defer_first) do return false
		jump(l, n.tok.text == "break" ? loop.break_target : loop.continue_target)
		return true
	}
	return lower_fail(l, &n.node, "no matching loop for %s", n.tok.text)
}
lower_for :: proc(l: ^Lowerer, n: ^ast.For_Stmt) -> bool {
	enter_scope(l)
	defer leave_scope(l)
	label, label_ok := loop_label(l, n.label)
	if !label_ok do return false
	if n.init != nil && !lower_stmt(l, n.init) do return false
	cond_block := new_block(l)
	body_block := new_block(l)
	step_block := new_block(l)
	end_block := new_block(l)
	jump(l, cond_block)
	begin_block(l, cond_block)
	if n.cond != nil {
		cond, ok := lower_value(l, n.cond)
		if !ok do return false
		jump_if_false(l, cond, end_block)
	} else {
		jump(l, body_block)
	}
	begin_block(l, body_block)
	append(&l.loops, Lower_Loop{label = label, break_target = end_block, continue_target = step_block, defer_first = len(l.defers)})
	ok := lower_stmt(l, n.body)
	pop(&l.loops)
	if !ok do return false
	if !block_terminated(l) do jump(l, step_block)
	begin_block(l, step_block)
	if n.post != nil && !lower_stmt(l, n.post) do return false
	jump(l, cond_block)
	begin_block(l, end_block)
	if n.cond == nil && l.m.blocks[int(end_block)].incoming == 0 {
		// Unreachable bookkeeping exit for an infinite loop, not an invented return.
		jump(l, cond_block)
	}
	return true
}

lower_ternary :: proc(l: ^Lowerer, n: ^ast.Ternary_If_Expr) -> (Value_ID, bool) {
	condition, ok := lower_value(l, n.cond)
	if !ok do return INVALID_VALUE, false
	yes := new_block(l)
	no := new_block(l)
	join := new_block(l)
	jump_if_false(l, condition, no)
	begin_block(l, yes)
	a, a_ok := lower_value(l, n.x)
	if !a_ok do return INVALID_VALUE, false
	// Type inference without evaluating the unchosen arm.
	t := value_type(l, a)
	if l.m.values[int(a)].kind == .Literal {
		other := range_index_type(l, n.y)
		if other != .Invalid do t = other
	}
	dst := new_temp(l, t)
	emit_op(l, MIR_Inst{kind = .Assign, type = t, dst = dst, a = a})
	jump(l, join)
	begin_block(l, no)
	b, b_ok := lower_value(l, n.y)
	if !b_ok do return INVALID_VALUE, false
	emit_op(l, MIR_Inst{kind = .Assign, type = t, dst = dst, a = b})
	jump(l, join)
	begin_block(l, join)
	return dst, true
}
