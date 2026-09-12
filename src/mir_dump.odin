package main

import "core:strings"

mir_type_label :: proc(t: MIR_Type) -> string {
	switch t {
	case .Invalid: return "invalid"
	case .Void:    return "void"
	case .Bool:    return "bool"
	case .U8:      return "u8"
	case .U32:     return "u32"
	case .UIntptr: return "uintptr"
	case .U8_Ptr:  return "[^]u8"
	}
	return "?"
}

value_kind_label :: proc(k: Value_Kind) -> string {
	switch k {
	case .Invalid: return "invalid"
	case .Param:   return "param"
	case .Local:   return "local"
	case .Temp:    return "temp"
	case .Literal: return "literal"
	case .Null:    return "null"
	case .Global:  return "global"
	}
	return "?"
}

op_kind_label :: proc(k: Op_Kind) -> string {
	switch k {
	case .Invalid:       return "invalid"
	case .Label:         return "label"
	case .Assign:        return "assign"
	case .Unary:         return "unary"
	case .Binary:        return "binary"
	case .Cast:          return "cast"
	case .Load_Index:    return "load_index"
	case .Store_Index:   return "store_index"
	case .Call:          return "call"
	case .Jump:          return "jump"
	case .Jump_If_False: return "jump_if_false"
	case .Return:        return "return"
	}
	return "?"
}

binary_op_label :: proc(op: Binary_Op) -> string {
	switch op {
	case .Invalid:       return "invalid"
	case .Add:           return "+"
	case .Sub:           return "-"
	case .Mul:           return "*"
	case .Div:           return "/"
	case .Mod:           return "%"
	case .Bit_And:       return "&"
	case .Bit_Or:        return "|"
	case .Bit_Xor:       return "~"
	case .Shift_Left:    return "<<"
	case .Shift_Right:   return ">>"
	case .And_Not:       return "&~"
	case .Equal:         return "=="
	case .Not_Equal:     return "!="
	case .Less:          return "<"
	case .Greater:       return ">"
	case .Less_Equal:    return "<="
	case .Greater_Equal: return ">="
	case .Logical_And:   return "&&"
	case .Logical_Or:    return "||"
	}
	return "?"
}

unary_op_label :: proc(op: Unary_Op) -> string {
	switch op {
	case .Invalid:     return "invalid"
	case .Positive:    return "+"
	case .Negative:    return "-"
	case .Logical_Not: return "!"
	case .Bit_Not:     return "~"
	}
	return "?"
}

dump_value_id :: proc(b: ^strings.Builder, id: Value_ID) {
	if id == INVALID_VALUE {
		strings.write_string(b, "-")
		return
	}
	strings.write_string(b, "v")
	strings.write_int(b, int(id))
}

dump_block_id :: proc(b: ^strings.Builder, id: Block_ID) {
	if id == INVALID_BLOCK {
		strings.write_string(b, "-")
		return
	}
	strings.write_string(b, "b")
	strings.write_int(b, int(id))
}

dump_proc_id :: proc(b: ^strings.Builder, id: Proc_ID) {
	if id == INVALID_PROC {
		strings.write_string(b, "-")
		return
	}
	strings.write_string(b, "p")
	strings.write_int(b, int(id))
}

mir_dump :: proc(m: ^MIR_Module) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, "mir {\n")
	strings.write_string(&b, "  globals ")
	strings.write_int(&b, len(m.globals))
	strings.write_string(&b, "\n")
	for g in m.globals {
		strings.write_string(&b, "    ")
		dump_value_id(&b, g.value_id)
		strings.write_string(&b, " ")
		strings.write_string(&b, g.name)
		strings.write_string(&b, ":")
		strings.write_string(&b, mir_type_label(g.type))
		strings.write_string(&b, " = ")
		strings.write_string(&b, g.init)
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "  values ")
	strings.write_int(&b, len(m.values))
	strings.write_string(&b, "\n")
	for v, i in m.values {
		strings.write_string(&b, "    v")
		strings.write_int(&b, i)
		strings.write_string(&b, " ")
		strings.write_string(&b, value_kind_label(v.kind))
		strings.write_string(&b, " ")
		strings.write_string(&b, mir_type_label(v.type))
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

	strings.write_string(&b, "  procedures ")
	strings.write_int(&b, len(m.procedures))
	strings.write_string(&b, "\n")
	for p, proc_index in m.procedures {
		strings.write_string(&b, "    p")
		strings.write_int(&b, proc_index)
		strings.write_string(&b, " ")
		strings.write_string(&b, p.name)
		strings.write_string(&b, " result=")
		strings.write_string(&b, mir_type_label(p.result))
		strings.write_string(&b, p.external ? " export" : " internal")
		if p.calling_convention != "" {
			strings.write_string(&b, " cc=")
			strings.write_string(&b, p.calling_convention)
		}
		strings.write_string(&b, " entry=")
		dump_block_id(&b, p.entry)
		strings.write_string(&b, " blocks=")
		strings.write_int(&b, int(p.first_block))
		strings.write_string(&b, "+")
		strings.write_int(&b, int(p.block_count))
		strings.write_string(&b, " ops=")
		strings.write_int(&b, int(p.first_op))
		strings.write_string(&b, "+")
		strings.write_int(&b, int(p.op_count))
		strings.write_string(&b, " values=")
		strings.write_int(&b, int(p.first_value))
		strings.write_string(&b, "+")
		strings.write_int(&b, int(p.value_count))
		strings.write_string(&b, " params=")
		strings.write_int(&b, int(p.param_first))
		strings.write_string(&b, "+")
		strings.write_int(&b, int(p.param_count))
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "  blocks ")
	strings.write_int(&b, len(m.blocks))
	strings.write_string(&b, "\n")
	for block, i in m.blocks {
		strings.write_string(&b, "    b")
		strings.write_int(&b, i)
		strings.write_string(&b, " ops=")
		strings.write_int(&b, int(block.first_op))
		strings.write_string(&b, "+")
		strings.write_int(&b, int(block.op_count))
		strings.write_string(&b, " incoming=")
		strings.write_int(&b, int(block.incoming))
		if block.terminated do strings.write_string(&b, " terminated")
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "  ops ")
	strings.write_int(&b, len(m.ops))
	strings.write_string(&b, "\n")
	for inst, i in m.ops {
		strings.write_string(&b, "    ")
		strings.write_int(&b, i)
		strings.write_string(&b, " ")
		strings.write_string(&b, op_kind_label(inst.kind))
		#partial switch inst.kind {
		case .Label, .Jump:
			strings.write_string(&b, " ")
			dump_block_id(&b, inst.target)
		case .Jump_If_False:
			strings.write_string(&b, " cond=")
			dump_value_id(&b, inst.a)
			strings.write_string(&b, " target=")
			dump_block_id(&b, inst.target)
		case .Assign:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, " <- ")
			dump_value_id(&b, inst.a)
		case .Unary:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, " <- ")
			strings.write_string(&b, unary_op_label(inst.unary_op))
			dump_value_id(&b, inst.a)
		case .Binary:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, " <- ")
			dump_value_id(&b, inst.a)
			strings.write_string(&b, " ")
			strings.write_string(&b, binary_op_label(inst.bin_op))
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.b)
		case .Cast:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, " <- ")
			strings.write_string(&b, mir_type_label(inst.type))
			strings.write_string(&b, "(")
			dump_value_id(&b, inst.a)
			strings.write_string(&b, ")")
		case .Load_Index:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, " <- ")
			dump_value_id(&b, inst.a)
			strings.write_string(&b, "[")
			dump_value_id(&b, inst.b)
			strings.write_string(&b, "]")
		case .Store_Index:
			strings.write_string(&b, " ")
			dump_value_id(&b, inst.dst)
			strings.write_string(&b, "[")
			dump_value_id(&b, inst.a)
			strings.write_string(&b, "] <- ")
			dump_value_id(&b, inst.b)
		case .Call:
			if inst.dst != INVALID_VALUE {
				strings.write_string(&b, " ")
				dump_value_id(&b, inst.dst)
				strings.write_string(&b, " <-")
			}
			strings.write_string(&b, " call ")
			dump_proc_id(&b, inst.callee)
			strings.write_string(&b, " args=")
			strings.write_int(&b, int(inst.args_first))
			strings.write_string(&b, "+")
			strings.write_int(&b, int(inst.args_count))
		case .Return:
			if inst.a != INVALID_VALUE {
				strings.write_string(&b, " ")
				dump_value_id(&b, inst.a)
			}
		}
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}
