package main

import "core:fmt"
import "core:strings"

// A third emission strategy, sharing verified semantics rather than AST guesses.
// Only single-use pure temporaries in one effect-free region are reconstructed.
C_Expression_Plan :: struct {
	inline_at: []int, // producer index plus one; zero means materialized
	skip: []bool,
	folded: int,
}
C_EXPRESSION_MAX_DEPTH :: 24

c_expr_pure :: proc(op: ^MIR_Inst) -> bool {
	#partial switch op.kind {
	case .Cast, .Unary: return true
	case .Binary:
		return op.bin_op != .Div && op.bin_op != .Mod && op.bin_op != .Logical_And && op.bin_op != .Logical_Or
	}
	return false
}

c_expr_plan :: proc(m: ^MIR_Module) -> C_Expression_Plan {
	plan := C_Expression_Plan{
		inline_at = make([]int, len(m.values), context.temp_allocator),
		skip = make([]bool, len(m.ops), context.temp_allocator),
	}
	u := mir_usage(m)
	defs := make([]int, len(m.values), context.temp_allocator)
	epochs := make([]int, len(m.values), context.temp_allocator)
	depths := make([]int, len(m.values), context.temp_allocator)
	epoch := 1
	for block in m.blocks {
		epoch += 1
		for i in int(block.first_op)..<int(block.first_op+block.op_count) {
			op := &m.ops[i]
			depth := 0
			small: [3]Value_ID
			reads: []Value_ID
			#partial switch op.kind {
			case .Assign, .Unary, .Cast, .Load_Index:
				small[0] = op.a
				reads = small[:1]
				if op.kind == .Load_Index { small[1] = op.b; reads = small[:2] }
			case .Binary:
				small[0] = op.a
				reads = small[:1]
				// Guarded C shifts use the count twice; do not duplicate its tree.
				if op.bin_op != .Shift_Left && op.bin_op != .Shift_Right { small[1] = op.b; reads = small[:2] }
			case .Store_Index:
				small = {op.dst, op.a, op.b}
				reads = small[:]
			case .Call:
				reads = m.call_args[int(op.args_first):int(op.args_first+op.args_count)]
			case .Branch, .Return:
				if op.a != INVALID_VALUE { small[0] = op.a; reads = small[:1] }
			}
			for id in reads {
				vi := int(id)
				// Preserve warning-clean comparisons against narrow type limits.
				if op.kind == .Binary && op.bin_op >= .Equal && op.bin_op <= .Greater_Equal && m.values[vi].is_constant do continue
				if defs[vi] == 0 || epochs[vi] != epoch do continue
				if u.reads[vi] != 1 || u.writes[vi] != 1 || depths[vi] >= C_EXPRESSION_MAX_DEPTH do continue
				plan.inline_at[vi] = defs[vi]
				plan.skip[defs[vi]-1] = true
				plan.folded += 1
				depth = max(depth, depths[vi])
			}
			if c_expr_pure(op) && op.dst != INVALID_VALUE && m.values[int(op.dst)].kind == .Temp {
				vi := int(op.dst)
				defs[vi] = i+1
				epochs[vi] = epoch
				depths[vi] = depth+1
			} else if op.kind != .Nop {
				// Calls, loads, stores, local writes and control flow are barriers.
				epoch += 1
			}
		}
	}
	return plan
}

// Conversions are required at every interior node, not just at the final
// assignment: C integer promotion must not erase narrow Odin intermediates.
write_c_expression :: proc(b: ^strings.Builder, m: ^MIR_Module, op: ^MIR_Inst, plan: ^C_Expression_Plan) {
	type_name, valid := mir_c_type(op.type)
	assert(valid)
	strings.write_string(b, "((")
	strings.write_string(b, type_name)
	strings.write_string(b, ")(")
	#partial switch op.kind {
	case .Cast:
		write_value_ref(b, m, op.a, plan)
	case .Unary:
		write_unary_op(b, op.unary_op)
		strings.write_string(b, "(")
		write_value_ref(b, m, op.a, plan)
		strings.write_string(b, ")")
	case .Binary:
		shift := op.bin_op == .Shift_Left || op.bin_op == .Shift_Right
		if shift {
			write_value_ref(b, m, op.b, plan)
			width := op.type == .U8 ? "8" : op.type == .U16 ? "16" : op.type == .U32 ? "32" : op.type == .U64 ? "64" : "(sizeof(uintptr_t) * CHAR_BIT)"
			strings.write_string(b, " < ")
			strings.write_string(b, width)
			strings.write_string(b, " ? (")
		}
		if mir_unsigned(op.type) { write_unsigned_operand(b, m, op.a, op.type, plan) } else { write_value_ref(b, m, op.a, plan) }
		strings.write_string(b, " ")
		if op.bin_op == .And_Not { strings.write_string(b, "& ~(") } else { write_binary_op(b, op.bin_op); strings.write_string(b, " ") }
		if mir_unsigned(op.type) && !shift { write_unsigned_operand(b, m, op.b, op.type, plan) } else { write_value_ref(b, m, op.b, plan) }
		if op.bin_op == .And_Not do strings.write_string(b, ")")
		if shift do strings.write_string(b, ") : 0")
	}
	strings.write_string(b, "))")
}

c_expr_dump_plan :: proc(m: ^MIR_Module) -> string {
	plan := c_expr_plan(m)
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintf(&b, "c-expression-plan folded=%d max-depth=%d\n", plan.folded, C_EXPRESSION_MAX_DEPTH)
	for index, vi in plan.inline_at {
		if index != 0 do fmt.sbprintf(&b, "value %%%d inline op #%d\n", vi, index-1)
	}
	return strings.to_string(b)
}
