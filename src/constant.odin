package main

unsigned_limit :: proc(t: MIR_Type) -> u64 {
	#partial switch t {
	case .U8: return 255
	case .U16: return 65535
	case .U64: return max(u64)
	case .U32: return 0xffff_ffff
	case .UIntptr: return u64(max(uintptr))
	}
	return 0
}

// Odin diagnoses typed constant overflow; it only wraps runtime unsigned
// arithmetic. Keep this metadata separate from mutable locals, even when an
// optimizer could prove a local's runtime value constant.
record_constant :: proc(l: ^Lowerer, op: MIR_Inst) -> bool {
	if op.kind != .Cast && op.kind != .Unary && op.kind != .Binary do return true
	if op.a == INVALID_VALUE || op.dst == INVALID_VALUE do return true
	a := l.m.values[int(op.a)]
	if !a.is_constant do return true
	value := a.constant_value
	limit := unsigned_limit(op.type)

	#partial switch op.kind {
	case .Cast:
		if op.type == .Bool {
			value = value != 0 ? 1 : 0
		} else if !mir_unsigned(op.type) || value > limit {
			return lower_fail(l, nil, "constant cast is out of range")
		}
	case .Unary:
		switch op.unary_op {
		case .Logical_Not: value = value == 0 ? 1 : 0
		case .Positive:
		case .Negative:
			if value != 0 do return lower_fail(l, nil, "negative unsigned constant")
		case .Bit_Not: value = (~value) & limit
		case .Invalid: return false
		}
	case .Binary:
		if op.b == INVALID_VALUE do return true
		b := l.m.values[int(op.b)]
		if !b.is_constant do return true
		x := a.constant_value
		y := b.constant_value
		switch op.bin_op {
		case .Add:
			if x > limit || y > limit-x do return lower_fail(l, nil, "constant addition overflows its type")
			value = x+y
		case .Sub:
			if x < y do return lower_fail(l, nil, "negative unsigned constant subtraction")
			value = x-y
		case .Mul:
			if y != 0 && x > limit/y do return lower_fail(l, nil, "constant multiplication overflows its type")
			value = x*y
		case .Div, .Mod:
			if y == 0 do return lower_fail(l, nil, "constant division by zero")
			value = op.bin_op == .Div ? x/y : x%y
		case .Shift_Left:
			if x != 0 && (y >= 64 || x > (limit >> y)) do return lower_fail(l, nil, "constant left shift overflows its type")
			value = y >= 64 ? 0 : x << y
		case .Shift_Right: value = y >= 64 ? 0 : x >> y
		case .Bit_And: value = x & y
		case .Bit_Or: value = x | y
		case .Bit_Xor: value = x ~ y
		case .And_Not: value = x & ~y
		case .Equal: value = x == y ? 1 : 0
		case .Not_Equal: value = x != y ? 1 : 0
		case .Less: value = x < y ? 1 : 0
		case .Greater: value = x > y ? 1 : 0
		case .Less_Equal: value = x <= y ? 1 : 0
		case .Greater_Equal: value = x >= y ? 1 : 0
		case .Logical_And: value = x != 0 && y != 0 ? 1 : 0
		case .Logical_Or: value = x != 0 || y != 0 ? 1 : 0
		case .Invalid: return false
		}
	case: return true
	}
	if mir_unsigned(op.type) && value > limit do return lower_fail(l, nil, "constant result is out of range")
	l.m.values[int(op.dst)].is_constant = true
	l.m.values[int(op.dst)].constant_value = value
	return true
}
