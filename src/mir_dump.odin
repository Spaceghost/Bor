package main

import "core:strings"

mir_dump_type_name :: proc(t: MIR_Type) -> string {
	switch t {
	case .Invalid: return "invalid"
	case .Void:    return "void"
	case .Bool:    return "bool"
	case .U8:      return "u8"
	case .U16:     return "u16"
	case .U64:     return "u64"
	case .U32:     return "u32"
	case .UIntptr: return "uintptr"
	case .U8_Ptr:  return "^u8"
	}
	return "invalid"
}

mir_dump_value_kind_name :: proc(k: Value_Kind) -> string {
	switch k {
	case .Invalid: return "invalid"
	case .Param:   return "param"
	case .Local:   return "local"
	case .Temp:    return "temp"
	case .Literal: return "literal"
	case .Null:    return "null"
	case .Global:  return "global"
	}
	return "invalid"
}

mir_dump_binary_name :: proc(op: Binary_Op) -> string {
	switch op {
	case .Invalid:       return "invalid"
	case .Add:           return "add"
	case .Sub:           return "sub"
	case .Mul:           return "mul"
	case .Div:           return "div"
	case .Mod:           return "mod"
	case .Bit_And:       return "and"
	case .Bit_Or:        return "or"
	case .Bit_Xor:       return "xor"
	case .Shift_Left:    return "shl"
	case .Shift_Right:   return "shr"
	case .And_Not:       return "and_not"
	case .Equal:         return "eq"
	case .Not_Equal:     return "ne"
	case .Less:          return "lt"
	case .Greater:       return "gt"
	case .Less_Equal:    return "le"
	case .Greater_Equal: return "ge"
	case .Logical_And:   return "logical_and"
	case .Logical_Or:    return "logical_or"
	}
	return "invalid"
}

mir_dump_unary_name :: proc(op: Unary_Op) -> string {
	switch op {
	case .Invalid:     return "invalid"
	case .Positive:    return "positive"
	case .Negative:    return "negative"
	case .Logical_Not: return "logical_not"
	case .Bit_Not:     return "bit_not"
	}
	return "invalid"
}

mir_dump_int :: proc(b: ^strings.Builder, value: int) {
	strings.write_int(b, value)
}

mir_dump_value_ref :: proc(b: ^strings.Builder, m: ^MIR_Module, id: Value_ID) {
	if id == INVALID_VALUE {
		strings.write_string(b, "void")
		return
	}
	v := &m.values[int(id)]
	#partial switch v.kind {
	case .Literal:
		strings.write_string(b, v.literal)
	case .Null:
		strings.write_string(b, "nil")
	case .Global:
		strings.write_string(b, "@")
		strings.write_string(b, v.name)
	case .Param, .Local, .Temp:
		strings.write_string(b, "%")
		mir_dump_int(b, int(id))
	case:
		strings.write_string(b, "%invalid")
	}
}

mir_dump_inst :: proc(b: ^strings.Builder, m: ^MIR_Module, op: ^MIR_Inst) {
	#partial switch op.kind {
	case .Nop:
		strings.write_string(b, "nop")
	case .Label:
		strings.write_string(b, "label b")
		mir_dump_int(b, int(op.target))
	case .Assign:
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, " = copy ")
		mir_dump_value_ref(b, m, op.a)
	case .Unary:
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, " = ")
		strings.write_string(b, mir_dump_unary_name(op.unary_op))
		strings.write_string(b, " ")
		mir_dump_value_ref(b, m, op.a)
	case .Binary:
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, " = ")
		strings.write_string(b, mir_dump_binary_name(op.bin_op))
		strings.write_string(b, " ")
		mir_dump_value_ref(b, m, op.a)
		strings.write_string(b, ", ")
		mir_dump_value_ref(b, m, op.b)
	case .Cast:
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, " = cast.")
		strings.write_string(b, mir_dump_type_name(op.type))
		strings.write_string(b, " ")
		mir_dump_value_ref(b, m, op.a)
	case .Load_Index:
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, " = load_index ")
		mir_dump_value_ref(b, m, op.a)
		strings.write_string(b, ", ")
		mir_dump_value_ref(b, m, op.b)
	case .Store_Index:
		strings.write_string(b, "store_index ")
		mir_dump_value_ref(b, m, op.dst)
		strings.write_string(b, ", ")
		mir_dump_value_ref(b, m, op.a)
		strings.write_string(b, ", ")
		mir_dump_value_ref(b, m, op.b)
	case .Call:
		if op.dst != INVALID_VALUE {
			mir_dump_value_ref(b, m, op.dst)
			strings.write_string(b, " = ")
		}
		strings.write_string(b, "call @")
		strings.write_string(b, m.procedures[int(op.callee)].name)
		strings.write_string(b, "(")
		for i in 0..<int(op.args_count) {
			if i > 0 do strings.write_string(b, ", ")
			mir_dump_value_ref(b, m, m.call_args[int(op.args_first) + i])
		}
		strings.write_string(b, ")")
	case .Jump:
		strings.write_string(b, "jump b")
		mir_dump_int(b, int(op.target))
	case .Branch:
		strings.write_string(b, "branch ")
		mir_dump_value_ref(b, m, op.a)
		strings.write_string(b, ", b")
		mir_dump_int(b, int(op.target))
		strings.write_string(b, ", b")
		mir_dump_int(b, int(op.target_else))
	case .Jump_If_False:
		strings.write_string(b, "raw_jump_false ")
		mir_dump_value_ref(b, m, op.a)
		strings.write_string(b, ", b")
		mir_dump_int(b, int(op.target))
	case .Return:
		strings.write_string(b, "return")
		if op.a != INVALID_VALUE {
			strings.write_string(b, " ")
			mir_dump_value_ref(b, m, op.a)
		}
	case:
		strings.write_string(b, "invalid")
	}
}

mir_dump :: proc(m: ^MIR_Module) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, "mir module globals=")
	mir_dump_int(&b, len(m.globals))
	strings.write_string(&b, " procs=")
	mir_dump_int(&b, len(m.procedures))
	strings.write_string(&b, " blocks=")
	mir_dump_int(&b, len(m.blocks))
	strings.write_string(&b, " ops=")
	mir_dump_int(&b, len(m.ops))
	strings.write_string(&b, " values=")
	mir_dump_int(&b, len(m.values))
	strings.write_string(&b, " call_args=")
	mir_dump_int(&b, len(m.call_args))
	strings.write_string(&b, "\n\n")

	for g, gi in m.globals {
		strings.write_string(&b, "global #")
		mir_dump_int(&b, gi)
		strings.write_string(&b, " @")
		strings.write_string(&b, g.name)
		strings.write_string(&b, " : ")
		strings.write_string(&b, mir_dump_type_name(g.type))
		strings.write_string(&b, " = ")
		strings.write_string(&b, g.init)
		strings.write_string(&b, "\n")
	}
	if len(m.globals) > 0 do strings.write_string(&b, "\n")

	for p, pi in m.procedures {
		strings.write_string(&b, "proc #")
		mir_dump_int(&b, pi)
		strings.write_string(&b, " @")
		strings.write_string(&b, p.name)
		strings.write_string(&b, " : ")
		strings.write_string(&b, mir_dump_type_name(p.result))
		strings.write_string(&b, p.external ? " external" : " internal")
		if p.calling_convention != "" {
			strings.write_string(&b, " cc=")
			strings.write_string(&b, p.calling_convention)
		}
		strings.write_string(&b, " entry=b")
		mir_dump_int(&b, int(p.entry))
		strings.write_string(&b, " {\n")

		for vi in int(p.first_value)..<int(p.first_value + p.value_count) {
			v := &m.values[vi]
			strings.write_string(&b, "  value %")
			mir_dump_int(&b, vi)
			strings.write_string(&b, " ")
			strings.write_string(&b, mir_dump_value_kind_name(v.kind))
			strings.write_string(&b, " : ")
			strings.write_string(&b, mir_dump_type_name(v.type))
			if v.name != "" {
				strings.write_string(&b, " name=")
				strings.write_string(&b, v.name)
			}
			if v.literal != "" {
				strings.write_string(&b, " literal=")
				strings.write_string(&b, v.literal)
			}
			strings.write_string(&b, "\n")
		}

		for bi in int(p.first_block)..<int(p.first_block + p.block_count) {
			block := &m.blocks[bi]
			strings.write_string(&b, "\n  block b")
			mir_dump_int(&b, bi)
			strings.write_string(&b, " incoming=")
			mir_dump_int(&b, int(block.incoming))
			strings.write_string(&b, " {\n")
			for oi in int(block.first_op)..<int(block.first_op + block.op_count) {
				strings.write_string(&b, "    #")
				mir_dump_int(&b, oi)
				strings.write_string(&b, " ")
				mir_dump_inst(&b, m, &m.ops[oi])
				strings.write_string(&b, "\n")
			}
			strings.write_string(&b, "  }\n")
		}
		strings.write_string(&b, "}\n\n")
	}

	return strings.to_string(b)
}
