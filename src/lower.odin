package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"

Lowerer :: struct {
	m:             ^MIR_Module,
	proc_ids:      map[string]Proc_ID,
	global_ids:    map[string]Value_ID,
	locals:        map[string]Value_ID,
	current_proc:  Proc_ID,
	current_block: Block_ID,
	failed:        bool,
	bindings:      [dynamic]Local_Binding,
	scope_marks:   [dynamic]int,
	loops: [dynamic]Lower_Loop,
	defers: [dynamic]Deferred_Stmt,
	in_defer: bool,
}

lower_fail :: proc(l: ^Lowerer, node: ^ast.Node, msg: string, args: ..any) -> bool {
	if node != nil {
		fmt.eprintf("bor: mir: %s:%d:%d: ", node.pos.file, node.pos.line, node.pos.column)
	} else {
		fmt.eprintf("bor: mir: ")
	}
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
	l.failed = true
	return false
}

mir_ident_name :: proc(expr: ^ast.Expr) -> (string, bool) {
	if expr == nil do return "", false
	if n, matched := expr.derived.(^ast.Ident); matched do return n.name, true
	return "", false
}

mir_type_from_ast :: proc(expr: ^ast.Expr) -> MIR_Type {
	if expr == nil do return .Invalid
	#partial switch n in expr.derived {
	case ^ast.Ident:
		switch n.name {
		case "bool":    return .Bool
		case "u8":      return .U8
		case "u16":     return .U16
		case "u64":     return .U64
		case "u32":     return .U32
		case "uintptr": return .UIntptr
		}
	case ^ast.Paren_Expr:
		return mir_type_from_ast(n.expr)
	case ^ast.Multi_Pointer_Type:
		if mir_type_from_ast(n.elem) == .U8 do return .U8_Ptr
	case ^ast.Pointer_Type:
		if mir_type_from_ast(n.elem) == .U8 do return .U8_Ptr
	}
	return .Invalid
}

mir_proc_result :: proc(p: ^ast.Proc_Lit) -> MIR_Type {
	if p == nil || p.type == nil || p.type.results == nil || len(p.type.results.list) == 0 do return .Void
	if len(p.type.results.list) != 1 do return .Invalid
	return mir_type_from_ast(p.type.results.list[0].type)
}

mir_calling_convention :: proc(p: ^ast.Proc_Lit) -> string {
	if p == nil || p.type == nil do return ""
	if cc, matched := p.type.calling_convention.(string); matched do return cc
	return ""
}

mir_proc_external :: proc(p: ^ast.Proc_Lit) -> bool {
	cc := mir_calling_convention(p)
	return cc == "c" || cc == "cdecl"
}

new_value :: proc(l: ^Lowerer, kind: Value_Kind, t: MIR_Type, name := "", literal := "") -> Value_ID {
	id := Value_ID(len(l.m.values))
	v := MIR_Value{kind = kind, type = t, name = name, literal = literal}
	if kind == .Literal {
		v.constant_value, v.is_constant = mir_literal_number(literal)
		if t == .Bool {
			v.is_constant = true
			v.constant_value = literal == "true" ? 1 : 0
		}
	}
	append(&l.m.values, v)
	return id
}

new_temp :: proc(l: ^Lowerer, t: MIR_Type) -> Value_ID {
	return new_value(l, .Temp, t)
}

new_literal :: proc(l: ^Lowerer, text: string, t := MIR_Type.UIntptr) -> Value_ID {
	return new_value(l, .Literal, t, literal = text)
}

lookup_value :: proc(l: ^Lowerer, name: string) -> (Value_ID, bool) {
	if id, found_local := l.locals[name]; found_local do return id, true
	if id, found_global := l.global_ids[name]; found_global do return id, true
	return INVALID_VALUE, false
}

value_type :: proc(l: ^Lowerer, id: Value_ID) -> MIR_Type {
	if id == INVALID_VALUE do return .Invalid
	return l.m.values[int(id)].type
}

new_block :: proc(l: ^Lowerer) -> Block_ID {
	id := Block_ID(len(l.m.blocks))
	append(&l.m.blocks, Basic_Block{id = id, first_op = INVALID_INDEX})
	return id
}

emit_op :: proc(l: ^Lowerer, inst: MIR_Inst) {
	assert(l.current_block != INVALID_BLOCK)
	if !record_constant(l, inst) do l.failed = true
	append(&l.m.ops, inst)
	l.m.blocks[int(l.current_block)].op_count += 1
}

begin_block :: proc(l: ^Lowerer, id: Block_ID) {
	assert(id != INVALID_BLOCK)
	l.current_block = id
	b := &l.m.blocks[int(id)]
	assert(!b.started)
	b.started = true
	b.first_op = u32(len(l.m.ops))
	emit_op(l, MIR_Inst{kind = .Label, target = id})
}

block_terminated :: proc(l: ^Lowerer) -> bool {
	return l.current_block == INVALID_BLOCK || l.m.blocks[int(l.current_block)].terminated
}

jump :: proc(l: ^Lowerer, target: Block_ID) {
	emit_op(l, MIR_Inst{kind = .Jump, target = target})
	l.m.blocks[int(l.current_block)].terminated = true
	l.m.blocks[int(target)].incoming += 1
}

jump_if_false :: proc(l: ^Lowerer, cond: Value_ID, target: Block_ID) {
	emit_op(l, MIR_Inst{kind = .Jump_If_False, a = cond, target = target})
	l.m.blocks[int(l.current_block)].terminated = true
	l.m.blocks[int(target)].incoming += 1
}

binary_op :: proc(text: string) -> (Binary_Op, bool) {
	switch text {
	case "+":  return .Add, true
	case "-":  return .Sub, true
	case "*":  return .Mul, true
	case "/":  return .Div, true
	case "%":  return .Mod, true
	case "&":  return .Bit_And, true
	case "|":  return .Bit_Or, true
	case "~":  return .Bit_Xor, true
	case "<<": return .Shift_Left, true
	case ">>": return .Shift_Right, true
	case "&~": return .And_Not, true
	case "==": return .Equal, true
	case "!=": return .Not_Equal, true
	case "<":  return .Less, true
	case ">":  return .Greater, true
	case "<=": return .Less_Equal, true
	case ">=": return .Greater_Equal, true
	case "&&": return .Logical_And, true
	case "||": return .Logical_Or, true
	}
	return .Invalid, false
}

assignment_op :: proc(text: string) -> (Binary_Op, bool) {
	switch text {
	case "+=":  return .Add, true
	case "-=":  return .Sub, true
	case "*=":  return .Mul, true
	case "/=":  return .Div, true
	case "%=":  return .Mod, true
	case "&=":  return .Bit_And, true
	case "|=":  return .Bit_Or, true
	case "~=":  return .Bit_Xor, true
	case "<<=": return .Shift_Left, true
	case ">>=": return .Shift_Right, true
	case "&~=": return .And_Not, true
	}
	return .Invalid, false
}

unary_op :: proc(text: string) -> (Unary_Op, bool) {
	switch text {
	case "+": return .Positive, true
	case "-": return .Negative, true
	case "!": return .Logical_Not, true
	case "~": return .Bit_Not, true
	}
	return .Invalid, false
}

binary_result_type :: proc(op: Binary_Op, a, b: MIR_Type) -> MIR_Type {
	#partial switch op {
	case .Equal, .Not_Equal, .Less, .Greater, .Less_Equal, .Greater_Equal, .Logical_And, .Logical_Or:
		return .Bool
	}
	if a != .Invalid && a != .Bool do return a
	return b
}

lower_logical_and :: proc(l: ^Lowerer, n: ^ast.Binary_Expr) -> (Value_ID, bool) {
	result := new_temp(l, .Bool)
	false_value := new_literal(l, "false", .Bool)
	emit_op(l, MIR_Inst{kind = .Assign, type = .Bool, dst = result, a = false_value})

	left, left_ok := lower_value(l, n.left)
	if !left_ok do return INVALID_VALUE, false
	rhs_block := new_block(l)
	end_block := new_block(l)
	jump_if_false(l, left, end_block)

	begin_block(l, rhs_block)
	right, right_ok := lower_value(l, n.right)
	if !right_ok do return INVALID_VALUE, false
	emit_op(l, MIR_Inst{kind = .Assign, type = .Bool, dst = result, a = right})
	jump(l, end_block)

	begin_block(l, end_block)
	return result, true
}

lower_logical_or :: proc(l: ^Lowerer, n: ^ast.Binary_Expr) -> (Value_ID, bool) {
	result := new_temp(l, .Bool)
	left, left_ok := lower_value(l, n.left)
	if !left_ok do return INVALID_VALUE, false
	true_block := new_block(l)
	rhs_block := new_block(l)
	end_block := new_block(l)
	jump_if_false(l, left, rhs_block)

	begin_block(l, true_block)
	true_value := new_literal(l, "true", .Bool)
	emit_op(l, MIR_Inst{kind = .Assign, type = .Bool, dst = result, a = true_value})
	jump(l, end_block)

	begin_block(l, rhs_block)
	right, right_ok := lower_value(l, n.right)
	if !right_ok do return INVALID_VALUE, false
	emit_op(l, MIR_Inst{kind = .Assign, type = .Bool, dst = result, a = right})
	jump(l, end_block)

	begin_block(l, end_block)
	return result, true
}

lower_expr :: proc(l: ^Lowerer, expr: ^ast.Expr) -> (Value_ID, bool) {
	if expr == nil {
		lower_fail(l, nil, "nil expression")
		return INVALID_VALUE, false
	}

	#partial switch n in expr.derived {
	case ^ast.Ident:
		if n.name == "true" || n.name == "false" do return new_literal(l, n.name, .Bool), true
		if n.name == "nil" do return new_value(l, .Null, .U8_Ptr, literal = "NULL"), true
		if id, found := lookup_value(l, n.name); found do return id, true
		lower_fail(l, &expr.expr_base, "unknown identifier %s", n.name)
		return INVALID_VALUE, false

	case ^ast.Basic_Lit:
		if n.tok.kind != .Integer && n.tok.kind != .Rune {
			lower_fail(l, &expr.expr_base, "only integer and rune literals are supported")
			return INVALID_VALUE, false
		}
		t := MIR_Type.UIntptr
		if _, ok := mir_literal_number(n.tok.text); !ok {
			lower_fail(l, &expr.expr_base, "literal does not fit the supported unsigned 64-bit domain")
			return INVALID_VALUE, false
		}
		return new_literal(l, n.tok.text, t), true

	case ^ast.Paren_Expr:
		return lower_expr(l, n.expr)

	case ^ast.Index_Expr:
		base, base_ok := lower_value(l, n.expr)
		if !base_ok do return INVALID_VALUE, false
		index, index_ok := lower_value(l, n.index)
		if !index_ok do return INVALID_VALUE, false
		if value_type(l, base) != .U8_Ptr {
			lower_fail(l, &expr.expr_base, "unsupported index base type")
			return INVALID_VALUE, false
		}
		dst := new_temp(l, .U8)
		emit_op(l, MIR_Inst{kind = .Load_Index, type = .U8, dst = dst, a = base, b = index})
		return dst, true

	case ^ast.Call_Expr:
		name, named := mir_ident_name(n.expr)
		if !named {
			lower_fail(l, &expr.expr_base, "indirect call")
			return INVALID_VALUE, false
		}
		if cast_type := mir_type_from_ast(n.expr); cast_type != .Invalid {
			if len(n.args) != 1 {
				lower_fail(l, &expr.expr_base, "scalar cast argument count")
				return INVALID_VALUE, false
			}
			source, source_ok := lower_value(l, n.args[0])
			if !source_ok do return INVALID_VALUE, false
			dst := new_temp(l, cast_type)
			emit_op(l, MIR_Inst{kind = .Cast, type = cast_type, dst = dst, a = source})
			return dst, true
		}
		callee, found := l.proc_ids[name]
		if !found {
			lower_fail(l, &expr.expr_base, "unknown procedure %s", name)
			return INVALID_VALUE, false
		}
		// Reserve the whole outer span before recursively lowering arguments.
		// Inner calls append their own spans and may reallocate the table.
		first_arg := u32(len(l.m.call_args))
		for _ in n.args do append(&l.m.call_args, INVALID_VALUE)
		for arg, i in n.args {
			id, arg_ok := lower_value(l, arg)
			if !arg_ok do return INVALID_VALUE, false
			if id == INVALID_VALUE {
				lower_fail(l, &expr.expr_base, "void expression used as a call argument")
				return INVALID_VALUE, false
			}
			l.m.call_args[int(first_arg) + i] = id
		}
		result_type := l.m.procedures[int(callee)].result
		dst := INVALID_VALUE
		if result_type != .Void do dst = new_temp(l, result_type)
		emit_op(l, MIR_Inst{kind = .Call, type = result_type, dst = dst, callee = callee, args_first = first_arg, args_count = u32(len(n.args))})
		return dst, true

	case ^ast.Unary_Expr:
		op, supported := unary_op(n.op.text)
		if !supported {
			lower_fail(l, &expr.expr_base, "unary operator %s", n.op.text)
			return INVALID_VALUE, false
		}
		a, operand_ok := lower_value(l, n.expr)
		if !operand_ok do return INVALID_VALUE, false
		t := value_type(l, a)
		if op == .Logical_Not do t = .Bool
		dst := new_temp(l, t)
		emit_op(l, MIR_Inst{kind = .Unary, type = t, dst = dst, a = a, unary_op = op})
		return dst, true

	case ^ast.Binary_Expr:
		if n.op.text == "&&" do return lower_logical_and(l, n)
		if n.op.text == "||" do return lower_logical_or(l, n)
		if n.op.text == "..<" || n.op.text == "..=" {
			lower_fail(l, &expr.expr_base, "range expression outside range statement")
			return INVALID_VALUE, false
		}
		op, supported := binary_op(n.op.text)
		if !supported {
			lower_fail(l, &expr.expr_base, "binary operator %s", n.op.text)
			return INVALID_VALUE, false
		}
		a, left_ok := lower_value(l, n.left)
		if !left_ok do return INVALID_VALUE, false
		b, right_ok := lower_value(l, n.right)
		if !right_ok do return INVALID_VALUE, false
		left_type := value_type(l, a)
		right_type := value_type(l, b)
		if l.m.values[int(a)].kind == .Literal && l.m.values[int(b)].kind != .Literal do left_type = right_type
		t := binary_result_type(op, left_type, right_type)
		dst := new_temp(l, t)
		emit_op(l, MIR_Inst{kind = .Binary, type = t, dst = dst, a = a, b = b, bin_op = op})
		return dst, true

	case ^ast.Ternary_If_Expr:
		return lower_ternary(l, n)

	case ^ast.Type_Cast:
		t := mir_type_from_ast(n.type)
		if t == .Invalid {
			lower_fail(l, &expr.expr_base, "cast type")
			return INVALID_VALUE, false
		}
		a, operand_ok := lower_value(l, n.expr)
		if !operand_ok do return INVALID_VALUE, false
		dst := new_temp(l, t)
		emit_op(l, MIR_Inst{kind = .Cast, type = t, dst = dst, a = a})
		return dst, true
	}

	lower_fail(l, &expr.expr_base, "expression AST kind")
	return INVALID_VALUE, false
}

lower_local :: proc(l: ^Lowerer, n: ^ast.Value_Decl) -> bool {
	if len(n.names) != 1 || len(n.values) > 1 do return lower_fail(l, &n.node, "multi-name local declaration")
	if !n.is_mutable do return lower_fail(l, &n.node, "local compile-time constants are not implemented")
	name, named := mir_ident_name(n.names[0])
	if !named do return lower_fail(l, &n.node, "local name")
	t := mir_type_from_ast(n.type)
	if n.type != nil && t == .Invalid do return lower_fail(l, &n.node, "unsupported local type")
	init := INVALID_VALUE
	if len(n.values) == 1 {
		if n.type == nil && defaults_to_signed_integer(n.values[0]) do return lower_fail(l, &n.node, "inferred signed integer/rune locals are not implemented; use an explicit supported type")
		init_ok: bool
		init, init_ok = lower_value(l, n.values[0])
		if !init_ok do return false
		if t == .Invalid do t = value_type(l, init)
	} else {
		if t == .Invalid do return lower_fail(l, &n.node, "zero-initialized local needs a supported type")
		init = new_literal(l, t == .Bool ? "false" : "0", t)
		if t == .U8_Ptr do init = new_value(l, .Null, t)
	}
	if t == .Invalid do return lower_fail(l, &n.node, "cannot infer local %s", name)
	dst := new_value(l, .Local, t, name = name)
	if !bind_local(l, name, dst, &n.node) do return false
	emit_op(l, MIR_Inst{kind = .Assign, type = t, dst = dst, a = init})
	return true
}

lower_assign :: proc(l: ^Lowerer, n: ^ast.Assign_Stmt) -> bool {
	if len(n.lhs) != 1 || len(n.rhs) != 1 do return lower_fail(l, &n.node, "tuple assignment")
	place, place_ok := lower_place(l, n.lhs[0])
	if !place_ok do return false
	rhs, rhs_ok := lower_value(l, n.rhs[0])
	if !rhs_ok do return false
	if n.op.text == "=" { store_place(l, place, rhs); return true }
	// Odin resolves the place first, evaluates RHS effects, then reads the
	// old stored value for compound assignment. Do not snapshot it too early.
	old := load_place(l, place)
	op, supported := assignment_op(n.op.text)
	if !supported do return lower_fail(l, &n.node, "assignment operator %s", n.op.text)
	tmp := new_temp(l, place.type)
	emit_op(l, MIR_Inst{kind = .Binary, type = place.type, dst = tmp, a = old, b = rhs, bin_op = op})
	store_place(l, place, tmp)
	return true
}

lower_if :: proc(l: ^Lowerer, n: ^ast.If_Stmt) -> bool {
	enter_scope(l)
	defer leave_scope(l)
	if n.init != nil && !lower_stmt(l, n.init) do return false
	cond, cond_ok := lower_value(l, n.cond)
	if !cond_ok do return false
	then_block := new_block(l)
	else_block := new_block(l)
	end_block := INVALID_BLOCK
	jump_if_false(l, cond, else_block)

	begin_block(l, then_block)
	if !lower_stmt(l, n.body) do return false
	if !block_terminated(l) {
		end_block = new_block(l)
		jump(l, end_block)
	}

	begin_block(l, else_block)
	if n.else_stmt != nil && !lower_stmt(l, n.else_stmt) do return false
	if !block_terminated(l) {
		if end_block == INVALID_BLOCK do end_block = new_block(l)
		jump(l, end_block)
	}
	// No phantom join when both arms return. The current block stays terminated.
	if end_block != INVALID_BLOCK do begin_block(l, end_block)
	return true
}

lower_range :: proc(l: ^Lowerer, n: ^ast.Range_Stmt) -> bool {
	enter_scope(l)
	defer leave_scope(l)
	label, label_ok := loop_label(l, n.label)
	if !label_ok do return false
	if n.init != nil && !lower_stmt(l, n.init) do return false
	if n.reverse || len(n.vals) != 1 do return lower_fail(l, &n.node, "reverse/multi-value range")
	name, named := mir_ident_name(n.vals[0])
	if !named do return lower_fail(l, &n.node, "range index")
	r, is_range := n.expr.derived.(^ast.Binary_Expr)
	if !is_range || (r.op.text != "..<" && r.op.text != "..=") do return lower_fail(l, &n.node, "non-bounded range")

	first, first_ok := lower_value(l, r.left)
	if !first_ok do return false
	idx_type := range_index_type(l, r.right)
	if !mir_unsigned(idx_type) do return lower_fail(l, &n.node, "unsupported range index type")
	index := new_value(l, .Local, idx_type, name = name)
	if !bind_local(l, name, index, &n.node) do return false
	emit_op(l, MIR_Inst{kind = .Assign, type = idx_type, dst = index, a = first})

	cond_block := new_block(l)
	body_block := new_block(l)
	step_block := new_block(l)
	end_block := new_block(l)
	jump(l, cond_block)

	begin_block(l, cond_block)
	limit, limit_ok := lower_value(l, r.right)
	if !limit_ok do return false
	cmp := Binary_Op.Less
	if r.op.text == "..=" do cmp = .Less_Equal
	cond := new_temp(l, .Bool)
	emit_op(l, MIR_Inst{kind = .Binary, type = .Bool, dst = cond, a = index, b = limit, bin_op = cmp})
	jump_if_false(l, cond, end_block)

	begin_block(l, body_block)
	append(&l.loops, Lower_Loop{label = label, break_target = end_block, continue_target = step_block, defer_first = len(l.defers)})
	body_ok := lower_stmt(l, n.body)
	pop(&l.loops)
	if !body_ok do return false
	if !block_terminated(l) do jump(l, step_block)
	begin_block(l, step_block)
	{
		if r.op.text == "..=" {
			// An inclusive maximum must exit before increment wraps the index.
			increment_block := new_block(l)
			maximum := new_literal(l, unsigned_max_text(idx_type), idx_type)
			can_step := new_temp(l, .Bool)
			emit_op(l, MIR_Inst{kind = .Binary, type = .Bool, dst = can_step, a = index, b = maximum, bin_op = .Not_Equal})
			jump_if_false(l, can_step, end_block)
			begin_block(l, increment_block)
		}
		one := new_literal(l, "1", idx_type)
		next := new_temp(l, idx_type)
		emit_op(l, MIR_Inst{kind = .Binary, type = idx_type, dst = next, a = index, b = one, bin_op = .Add})
		emit_op(l, MIR_Inst{kind = .Assign, type = idx_type, dst = index, a = next})
		jump(l, cond_block)
	}

	begin_block(l, end_block)
	return true
}

lower_stmt :: proc(l: ^Lowerer, stmt: ^ast.Stmt) -> bool {
	if stmt == nil do return true
	if block_terminated(l) do return true

	#partial switch n in stmt.derived {
	case ^ast.Block_Stmt:
		enter_scope(l)
		defer leave_scope(l)
		defer_first := len(l.defers)
		defer {
			for len(l.defers) > defer_first { d := pop(&l.defers); delete(d.bindings) }
		}
		dead := false
		for child in n.stmts {
			if block_terminated(l) {
				// Odin still type-checks unreachable source. Give it an isolated
				// block rather than silently dropping invalid statements.
				begin_block(l, new_block(l))
				dead = true
			}
			if !lower_stmt(l, child) do return false
		}
		if !block_terminated(l) {
			if !emit_defers_from(l, defer_first) do return false
			if dead do jump(l, l.current_block)
		}
		return true
	case ^ast.Value_Decl:
		return lower_local(l, n)
	case ^ast.Assign_Stmt:
		return lower_assign(l, n)
	case ^ast.Expr_Stmt:
		_, expr_ok := lower_expr(l, n.expr)
		return expr_ok
	case ^ast.Return_Stmt:
		if l.in_defer do return lower_fail(l, &n.node, "return in defer is not implemented")
		if len(n.results) > 1 do return lower_fail(l, &n.node, "multiple return values")
		value := INVALID_VALUE
		if len(n.results) == 1 {
			result_ok: bool
			value, result_ok = lower_value(l, n.results[0])
			if !result_ok do return false
		}
		// A return value is evaluated before deferred statements execute.
		if value != INVALID_VALUE && len(l.defers) > 0 do value = snapshot_place_operand(l, value)
		if !emit_defers_from(l, 0) do return false
		emit_op(l, MIR_Inst{kind = .Return, a = value})
		l.m.blocks[int(l.current_block)].terminated = true
		return true
	case ^ast.If_Stmt:
		return lower_if(l, n)
	case ^ast.Range_Stmt:
		return lower_range(l, n)
	case ^ast.For_Stmt:
		return lower_for(l, n)
	case ^ast.Branch_Stmt:
		return lower_branch(l, n)
	case ^ast.Defer_Stmt:
		return register_defer(l, n)
	}

	return lower_fail(l, nil, "statement AST kind")
}

const_init_text :: proc(expr: ^ast.Expr) -> (string, MIR_Type, bool) {
	if expr == nil do return "", .Invalid, false
	#partial switch n in expr.derived {
	case ^ast.Basic_Lit:
		if n.tok.kind != .Integer && n.tok.kind != .Rune do return "", .Invalid, false
		_, valid := mir_literal_number(n.tok.text)
		return n.tok.text, .UIntptr, valid
	case ^ast.Paren_Expr:
		return const_init_text(n.expr)
	case ^ast.Call_Expr:
		if len(n.args) == 1 {
			t := mir_type_from_ast(n.expr)
			if t != .Invalid {
				text, _, init_ok := const_init_text(n.args[0])
				number, number_ok := mir_literal_number(text)
				return text, t, init_ok && number_ok && mir_unsigned(t) && number <= unsigned_limit(t)
			}
		}
	}
	return "", .Invalid, false
}

sorted_files :: proc(pkg: ^ast.Package) -> [dynamic]string {
	paths := make([dynamic]string, 0, len(pkg.files), context.temp_allocator)
	for path, _ in pkg.files do append(&paths, path)
	slice.sort(paths[:])
	return paths
}

collect_symbols :: proc(l: ^Lowerer, pkg: ^ast.Package) -> bool {
	for path in sorted_files(pkg) {
		if len(pkg.files[path].imports) != 0 do return lower_fail(l, nil, "imports are not implemented")
		for stmt in pkg.files[path].decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 do return lower_fail(l, &stmt.stmt_base, "unsupported top-level declaration")
			if d.is_mutable do return lower_fail(l, &stmt.stmt_base, "mutable globals are not implemented")
			name, named := mir_ident_name(d.names[0])
			if !named do return lower_fail(l, nil, "top-level declaration name")
			if _, found := l.proc_ids[name]; found do return lower_fail(l, nil, "duplicate declaration %s", name)
			if _, found := l.global_ids[name]; found do return lower_fail(l, nil, "duplicate declaration %s", name)

			if p, is_proc := d.values[0].derived.(^ast.Proc_Lit); is_proc {
				if !validate_proc_contract(l, d, p) do return false
				result := mir_proc_result(p)
				if result == .Invalid do return lower_fail(l, &p.node, "procedure result type for %s", name)
				id := Proc_ID(len(l.m.procedures))
				append(&l.m.procedures, MIR_Procedure{name = name, result = result, calling_convention = mir_calling_convention(p), external = mir_proc_external(p), entry = INVALID_BLOCK})
				l.proc_ids[name] = id
				continue
			}

			init, init_type, init_ok := const_init_text(d.values[0])
			if !init_ok do return lower_fail(l, nil, "top-level constant initializer for %s", name)
			t := mir_type_from_ast(d.type)
			if t == .Invalid do t = init_type
			if t == .Invalid do return lower_fail(l, nil, "top-level constant type for %s", name)
			number, number_ok := mir_literal_number(init)
			if !number_ok || !mir_unsigned(t) || number > unsigned_limit(t) do return lower_fail(l, nil, "top-level constant %s is out of range", name)
			value_id := new_value(l, .Global, t, name = name)
			l.m.values[int(value_id)].is_constant = true
			l.m.values[int(value_id)].constant_value = number
			append(&l.m.globals, MIR_Global{name = name, type = t, init = init, value_id = value_id})
			l.global_ids[name] = value_id
		}
	}
	return true
}

lower_procedure :: proc(l: ^Lowerer, id: Proc_ID, p: ^ast.Proc_Lit) -> bool {
	meta := &l.m.procedures[int(id)]
	l.current_proc = id
	l.current_block = INVALID_BLOCK
	delete(l.locals)
	l.locals = make(map[string]Value_ID)
	clear(&l.bindings)
	clear(&l.scope_marks)
	enter_scope(l)
	defer leave_scope(l)

	meta.first_value = u32(len(l.m.values))
	meta.param_first = meta.first_value
	if p.type.params != nil {
		for f in p.type.params.list {
			if len(f.names) == 0 do return lower_fail(l, &p.node, "unnamed parameters are not implemented")
			t := mir_type_from_ast(f.type)
			if t == .Invalid do return lower_fail(l, &p.node, "procedure parameter type in %s", meta.name)
			for name_expr in f.names {
				name, named := mir_ident_name(name_expr)
				if !named do return lower_fail(l, &p.node, "procedure parameter name in %s", meta.name)
				value_id := new_value(l, .Param, t, name = name)
				if !bind_local(l, name, value_id, &p.node) do return false
				meta.param_count += 1
			}
		}
	}

	meta.first_block = u32(len(l.m.blocks))
	meta.first_op = u32(len(l.m.ops))
	entry := new_block(l)
	meta.entry = entry
	begin_block(l, entry)
	if !lower_stmt(l, p.body) do return false
	if !block_terminated(l) {
		if meta.result != .Void do return lower_fail(l, &p.node, "non-void procedure %s can fall through", meta.name)
		emit_op(l, MIR_Inst{kind = .Return, a = INVALID_VALUE})
		l.m.blocks[int(l.current_block)].terminated = true
	}

	meta.block_count = u32(len(l.m.blocks)) - meta.first_block
	meta.op_count = u32(len(l.m.ops)) - meta.first_op
	meta.value_count = u32(len(l.m.values)) - meta.first_value
	return true
}

lower_package_to_mir :: proc(pkg: ^ast.Package) -> (m: MIR_Module, ok: bool) {
	l := Lowerer{
		m = &m,
		proc_ids = make(map[string]Proc_ID),
		global_ids = make(map[string]Value_ID),
		locals = make(map[string]Value_ID),
		current_proc = INVALID_PROC,
		current_block = INVALID_BLOCK,
	}
	defer delete(l.proc_ids)
	defer delete(l.global_ids)
	defer delete(l.locals)
	defer delete(l.bindings)
	defer delete(l.scope_marks)
	defer delete(l.loops)
	defer delete(l.defers)

	if !collect_symbols(&l, pkg) do return m, false

	for path in sorted_files(pkg) {
		for stmt in pkg.files[path].decls {
			d, is_decl := stmt.derived.(^ast.Value_Decl)
			if !is_decl || len(d.names) != 1 || len(d.values) != 1 do continue
			p, is_proc := d.values[0].derived.(^ast.Proc_Lit)
			if !is_proc do continue
			name, named := mir_ident_name(d.names[0])
			if !named do return m, false
			id := l.proc_ids[name]
			if !lower_procedure(&l, id, p) do return m, false
		}
	}

	return m, !l.failed
}
