package main

import "core:strings"

mir_c_type :: proc(t: MIR_Type) -> (string, bool) {
	#partial switch t {
	case .Void:    return "void", true
	case .Bool:    return "bool", true
	case .U8:      return "uint8_t", true
	case .U32:     return "uint32_t", true
	case .UIntptr: return "uintptr_t", true
	case .U8_Ptr:  return "uint8_t *", true
	}
	return "", false
}

write_id :: proc(b: ^strings.Builder, id: int) {
	strings.write_int(b, id)
}

write_block_label :: proc(b: ^strings.Builder, proc_id: int, block: Block_ID) {
	strings.write_string(b, "bor_p")
	write_id(b, proc_id)
	strings.write_string(b, "_b")
	write_id(b, int(block))
}

write_value_ref :: proc(b: ^strings.Builder, m: ^MIR_Module, id: Value_ID) {
	assert(id != INVALID_VALUE)
	v := &m.values[int(id)]
	#partial switch v.kind {
	case .Literal:
		write_literal_c(b, v.literal)
	case .Null:
		strings.write_string(b, "NULL")
	case .Global, .Param:
		strings.write_string(b, v.name)
	case .Local, .Temp:
		strings.write_string(b, "_bor_v")
		write_id(b, int(id))
	}
}

write_binary_op :: proc(b: ^strings.Builder, op: Binary_Op) {
	#partial switch op {
	case .Add:             strings.write_string(b, "+")
	case .Sub:             strings.write_string(b, "-")
	case .Mul:             strings.write_string(b, "*")
	case .Div:             strings.write_string(b, "/")
	case .Mod:             strings.write_string(b, "%")
	case .Bit_And:         strings.write_string(b, "&")
	case .Bit_Or:          strings.write_string(b, "|")
	case .Bit_Xor:         strings.write_string(b, "^")
	case .Shift_Left:      strings.write_string(b, "<<")
	case .Shift_Right:     strings.write_string(b, ">>")
	case .Equal:           strings.write_string(b, "==")
	case .Not_Equal:       strings.write_string(b, "!=")
	case .Less:            strings.write_string(b, "<")
	case .Greater:         strings.write_string(b, ">")
	case .Less_Equal:      strings.write_string(b, "<=")
	case .Greater_Equal:   strings.write_string(b, ">=")
	case .Logical_And:     strings.write_string(b, "&&")
	case .Logical_Or:      strings.write_string(b, "||")
	}
}

write_unary_op :: proc(b: ^strings.Builder, op: Unary_Op) {
	#partial switch op {
	case .Positive:    strings.write_string(b, "+")
	case .Negative:    strings.write_string(b, "-")
	case .Logical_Not: strings.write_string(b, "!")
	case .Bit_Not:     strings.write_string(b, "~")
	}
}

emit_mir_proc_head :: proc(b: ^strings.Builder, m: ^MIR_Module, proc_id: int, prototype: bool) -> bool {
	p := &m.procedures[proc_id]
	result, ok := mir_c_type(p.result)
	if !ok do return false
	if !p.external do strings.write_string(b, "static ")
	strings.write_string(b, result)
	strings.write_string(b, " ")
	strings.write_string(b, p.name)
	strings.write_string(b, "(")

	if p.param_count == 0 {
		strings.write_string(b, "void")
	} else {
		for i in 0..<int(p.param_count) {
			if i > 0 do strings.write_string(b, ", ")
			id := Value_ID(p.param_first + u32(i))
			v := &m.values[int(id)]
			type_name, known := mir_c_type(v.type)
			if !known do return false
			strings.write_string(b, type_name)
			strings.write_string(b, " ")
			strings.write_string(b, v.name)
		}
	}
	strings.write_string(b, ")")
	if prototype do strings.write_string(b, ";\n")
	return true
}

emit_mir_inst :: proc(
	b: ^strings.Builder,
	m: ^MIR_Module,
	proc_id: int,
	op_index: int,
	needs_label: []bool,
	op: ^MIR_Inst,
) -> bool {
	#partial switch op.kind {
	case .Nop:
		return true
	case .Label:
		if !needs_label[int(op.target)] do return true
		write_block_label(b, proc_id, op.target)
		strings.write_string(b, ": ;\n")

	case .Assign:
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, " = ")
		write_value_ref(b, m, op.a)
		strings.write_string(b, ";\n")

	case .Unary:
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, " = (")
		write_unary_op(b, op.unary_op)
		write_value_ref(b, m, op.a)
		strings.write_string(b, ");\n")

	case .Binary:
		if op.bin_op == .Shift_Left || op.bin_op == .Shift_Right {
			emit_checked_shift(b, m, op)
			return true
		}
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, " = (")
		if mir_unsigned(op.type) {
			write_unsigned_operand(b, m, op.a, op.type)
		} else {
			write_value_ref(b, m, op.a)
		}
		if op.bin_op == .And_Not {
			strings.write_string(b, " & ~(")
			if mir_unsigned(op.type) {
				write_unsigned_operand(b, m, op.b, op.type)
			} else {
				write_value_ref(b, m, op.b)
			}
			strings.write_string(b, ")")
		} else {
			strings.write_string(b, " ")
			write_binary_op(b, op.bin_op)
			strings.write_string(b, " ")
			if mir_unsigned(op.type) {
				write_unsigned_operand(b, m, op.b, op.type)
			} else {
				write_value_ref(b, m, op.b)
			}
		}
		strings.write_string(b, ");\n")

	case .Cast:
		type_name, ok := mir_c_type(op.type)
		if !ok do return false
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, " = (")
		strings.write_string(b, type_name)
		strings.write_string(b, ")(")
		write_value_ref(b, m, op.a)
		strings.write_string(b, ");\n")

	case .Load_Index:
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, " = ")
		write_value_ref(b, m, op.a)
		strings.write_string(b, "[")
		write_value_ref(b, m, op.b)
		strings.write_string(b, "];\n")

	case .Store_Index:
		strings.write_string(b, "    ")
		write_value_ref(b, m, op.dst)
		strings.write_string(b, "[")
		write_value_ref(b, m, op.a)
		strings.write_string(b, "] = ")
		write_value_ref(b, m, op.b)
		strings.write_string(b, ";\n")

	case .Call:
		strings.write_string(b, "    ")
		if op.dst != INVALID_VALUE {
			write_value_ref(b, m, op.dst)
			strings.write_string(b, " = ")
		}
		strings.write_string(b, m.procedures[int(op.callee)].name)
		strings.write_string(b, "(")
		for i in 0..<int(op.args_count) {
			if i > 0 do strings.write_string(b, ", ")
			arg := m.call_args[int(op.args_first) + i]
			write_value_ref(b, m, arg)
		}
		strings.write_string(b, ");\n")

	case .Jump:
		if c99_target_is_fallthrough(m, op.target, op_index) do return true
		strings.write_string(b, "    goto ")
		write_block_label(b, proc_id, op.target)
		strings.write_string(b, ";\n")

	case .Branch:
		if op.target == op.target_else {
			if c99_target_is_fallthrough(m, op.target, op_index) do return true
			strings.write_string(b, "    goto ")
			write_block_label(b, proc_id, op.target)
			strings.write_string(b, ";\n")
			return true
		}

		true_fallthrough := c99_target_is_fallthrough(m, op.target, op_index)
		false_fallthrough := c99_target_is_fallthrough(m, op.target_else, op_index)
		if true_fallthrough {
			strings.write_string(b, "    if (!(")
			write_value_ref(b, m, op.a)
			strings.write_string(b, ")) goto ")
			write_block_label(b, proc_id, op.target_else)
			strings.write_string(b, ";\n")
		} else if false_fallthrough {
			strings.write_string(b, "    if (")
			write_value_ref(b, m, op.a)
			strings.write_string(b, ") goto ")
			write_block_label(b, proc_id, op.target)
			strings.write_string(b, ";\n")
		} else {
			strings.write_string(b, "    if (")
			write_value_ref(b, m, op.a)
			strings.write_string(b, ") goto ")
			write_block_label(b, proc_id, op.target)
			strings.write_string(b, "; else goto ")
			write_block_label(b, proc_id, op.target_else)
			strings.write_string(b, ";\n")
		}

	case .Jump_If_False:
		return false

	case .Return:
		strings.write_string(b, "    return")
		if op.a != INVALID_VALUE {
			strings.write_string(b, " ")
			write_value_ref(b, m, op.a)
		}
		strings.write_string(b, ";\n")
	case:
		return false
	}
	return true
}

emit_mir_c99 :: proc(m: ^MIR_Module) -> (string, bool) {
	b: strings.Builder
	strings.builder_init(&b)
	needs_label := c99_layout_needs_labels(m)
	usage := mir_usage(m)

	strings.write_string(&b, "/* generated by Bor MIR unity backend */\n")
	strings.write_string(&b, "#include <limits.h>\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n")

	for g in m.globals {
		type_name, ok := mir_c_type(g.type)
		if !ok do return "", false
		strings.write_string(&b, "static const ")
		strings.write_string(&b, type_name)
		strings.write_string(&b, " ")
		strings.write_string(&b, g.name)
		strings.write_string(&b, " = ")
		write_literal_c(&b, g.init)
		strings.write_string(&b, ";\n")
	}
	strings.write_string(&b, "\n")

	for _, proc_id in m.procedures {
		if !emit_mir_proc_head(&b, m, proc_id, true) do return "", false
	}
	strings.write_string(&b, "\n")

	for p, proc_id in m.procedures {
		if !emit_mir_proc_head(&b, m, proc_id, false) do return "", false
		strings.write_string(&b, " {\n")

		for vi in int(p.param_first)..<int(p.param_first+p.param_count) {
			if usage.reads[vi] == 0 {
				strings.write_string(&b, "    (void)&")
				strings.write_string(&b, m.values[vi].name)
				strings.write_string(&b, ";\n")
			}
		}
		first := int(p.first_value)
		last := first + int(p.value_count)
		for value_index in first..<last {
			v := &m.values[value_index]
			if v.kind != .Local && v.kind != .Temp do continue
			if usage.reads[value_index] == 0 && usage.writes[value_index] == 0 do continue
			type_name, ok := mir_c_type(v.type)
			if !ok do return "", false
			strings.write_string(&b, "    ")
			strings.write_string(&b, type_name)
			strings.write_string(&b, " _bor_v")
			write_id(&b, value_index)
			strings.write_string(&b, ";\n")
			if usage.reads[value_index] == 0 {
				// Taking an address does not read an uninitialized value. Keep valid
				// write-only Odin locals warning-clean without suppressing C warnings.
				strings.write_string(&b, "    (void)&_bor_v")
				write_id(&b, value_index)
				strings.write_string(&b, ";\n")
			}
		}
		strings.write_string(&b, "\n")

		op_first := int(p.first_op)
		op_last := op_first + int(p.op_count)
		for op_index in op_first..<op_last {
			if !emit_mir_inst(&b, m, proc_id, op_index, needs_label, &m.ops[op_index]) do return "", false
		}
		strings.write_string(&b, "}\n\n")
	}

	return strings.to_string(b), true
}
