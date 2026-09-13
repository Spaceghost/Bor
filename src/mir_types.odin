package main

import "core:strconv"

mir_unsigned :: proc(t: MIR_Type) -> bool {
	return t == .U8 || t == .U16 || t == .U64 || t == .U32 || t == .UIntptr
}

mir_literal_number :: proc(text: string) -> (u64, bool) {
	if len(text) >= 2 && text[0] == '\'' && text[len(text)-1] == '\'' {
		r, _, tail, ok := strconv.unquote_char(text[1:len(text)-1], '\'')
		return u64(r), ok && len(tail) == 0 && r >= 0
	}
	base: u64 = 10
	offset := 0
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b': base = 2; offset = 2
		case 'o': base = 8; offset = 2
		case 'd': base = 10; offset = 2
		case 'z': base = 12; offset = 2
		case 'x': base = 16; offset = 2
		}
	}
	value: u64
	digits := 0
	for c in text[offset:] {
		if c == '_' do continue
		digit: u64
		switch {
		case c >= '0' && c <= '9': digit = u64(c-'0')
		case c >= 'a' && c <= 'f': digit = u64(c-'a')+10
		case c >= 'A' && c <= 'F': digit = u64(c-'A')+10
		case: return 0, false
		}
		if digit >= base || value > (max(u64)-digit)/base do return 0, false
		value = value*base + digit
		digits += 1
	}
	return value, digits > 0
}

mir_assignable :: proc(m: ^MIR_Module, id: Value_ID, target: MIR_Type) -> bool {
	v := &m.values[int(id)]
	if v.type == target do return true
	if v.kind == .Null do return target == .U8_Ptr
	if v.kind != .Literal || !mir_unsigned(v.type) || !mir_unsigned(target) do return false
	n, ok := mir_literal_number(v.literal)
	if !ok do return false
	#partial switch target {
	case .U8: return n <= 255
	case .U16: return n <= 65535
	case .U64: return true
	case .U32: return n <= 0xffff_ffff
	case .UIntptr: return n <= u64(max(uintptr))
	}
	return false
}

mir_writable :: proc(m: ^MIR_Module, id: Value_ID) -> bool {
	kind := m.values[int(id)].kind
	return kind == .Local || kind == .Temp
}

// Run only after structural verification, so all referenced IDs/ranges are safe.
mir_verify_types :: proc(m: ^MIR_Module) -> bool {
	for p, pi in m.procedures {
		for oi in int(p.first_op)..<int(p.first_op+p.op_count) {
			op := &m.ops[oi]
			#partial switch op.kind {
			case .Assign, .Unary, .Binary, .Cast, .Load_Index:
				if !mir_writable(m, op.dst) do return mir_verify_fail("proc %d op %d writes an immutable value", pi, oi)
				if m.values[int(op.dst)].type != op.type do return mir_verify_fail("proc %d op %d result type disagrees with destination", pi, oi)
			}
			#partial switch op.kind {
			case .Assign:
				if !mir_assignable(m, op.a, op.type) do return mir_verify_fail("proc %d op %d assignment type mismatch", pi, oi)
			case .Unary:
				t := m.values[int(op.a)].type
				if op.unary_op == .Logical_Not {
					if t != .Bool || op.type != .Bool do return mir_verify_fail("proc %d op %d logical not requires bool", pi, oi)
				} else if !mir_unsigned(t) || op.type != t {
					return mir_verify_fail("proc %d op %d unary type mismatch", pi, oi)
				}
			case .Binary:
				a := m.values[int(op.a)].type
				b := m.values[int(op.b)].type
				comparison := (op.bin_op >= .Equal && op.bin_op <= .Greater_Equal)
				if (op.bin_op == .Logical_And || op.bin_op == .Logical_Or) {
					if a != .Bool || b != .Bool || op.type != .Bool do return mir_verify_fail("proc %d op %d logical type mismatch", pi, oi)
				} else if comparison {
					if op.type != .Bool do return mir_verify_fail("proc %d op %d comparison result is not bool", pi, oi)
					if !mir_assignable(m, op.a, b) && !mir_assignable(m, op.b, a) do return mir_verify_fail("proc %d op %d incomparable operands", pi, oi)
					if !((op.bin_op == .Equal || op.bin_op == .Not_Equal)) && (!mir_unsigned(a) || !mir_unsigned(b)) do return mir_verify_fail("proc %d op %d unsupported ordered comparison", pi, oi)
				} else {
					if !mir_unsigned(op.type) || !mir_unsigned(a) || !mir_unsigned(b) do return mir_verify_fail("proc %d op %d arithmetic requires unsigned integers", pi, oi)
					if !mir_assignable(m, op.a, op.type) do return mir_verify_fail("proc %d op %d left operand type mismatch", pi, oi)
					if !((op.bin_op == .Shift_Left || op.bin_op == .Shift_Right)) && !mir_assignable(m, op.b, op.type) do return mir_verify_fail("proc %d op %d right operand type mismatch", pi, oi)
				}
			case .Cast:
				source := m.values[int(op.a)].type
				if (!mir_unsigned(source) && source != .Bool) || (!mir_unsigned(op.type) && op.type != .Bool) do return mir_verify_fail("proc %d op %d unsupported cast", pi, oi)
			case .Load_Index:
				if m.values[int(op.a)].type != .U8_Ptr || !mir_unsigned(m.values[int(op.b)].type) || op.type != .U8 do return mir_verify_fail("proc %d op %d invalid byte load", pi, oi)
			case .Store_Index:
				if m.values[int(op.dst)].type != .U8_Ptr || !mir_unsigned(m.values[int(op.a)].type) || !mir_assignable(m, op.b, .U8) do return mir_verify_fail("proc %d op %d invalid byte store", pi, oi)
			case .Call:
				callee := &m.procedures[int(op.callee)]
				if op.args_count != callee.param_count do return mir_verify_fail("proc %d op %d argument count mismatch: got %d, expected %d", pi, oi, op.args_count, callee.param_count)
				if op.type != callee.result do return mir_verify_fail("proc %d op %d call result type mismatch", pi, oi)
				if callee.result == .Void {
					if op.dst != INVALID_VALUE do return mir_verify_fail("proc %d op %d void call has a result", pi, oi)
				} else if op.dst == INVALID_VALUE || !mir_writable(m, op.dst) || m.values[int(op.dst)].type != callee.result {
					return mir_verify_fail("proc %d op %d call destination type mismatch", pi, oi)
				}
				for i in 0..<int(op.args_count) {
					id := m.call_args[int(op.args_first)+i]
					if !mir_assignable(m, id, m.values[int(callee.param_first)+i].type) do return mir_verify_fail("proc %d op %d argument %d type mismatch", pi, oi, i)
				}
			case .Return:
				if p.result == .Void {
					if op.a != INVALID_VALUE do return mir_verify_fail("proc %d op %d void procedure returns a value", pi, oi)
				} else if op.a == INVALID_VALUE || !mir_assignable(m, op.a, p.result) {
					return mir_verify_fail("proc %d op %d return type mismatch", pi, oi)
				}
			}
		}
	}
	return true
}
