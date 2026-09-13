package main

import "core:strings"

// Normalize source literals without relying on C's prefixes, octal spelling,
// execution character set, or support for digit separators.
write_literal_c :: proc(b: ^strings.Builder, text: string) {
	if n, ok := mir_literal_number(text); ok {
		strings.write_uint(b, uint(n))
		if n > 0x7fff_ffff do strings.write_string(b, "ULL")
	} else {
		// Generated true/false and UINT*_MAX literals have semantic spellings.
		strings.write_string(b, text)
	}
}

write_unsigned_operand :: proc(b: ^strings.Builder, m: ^MIR_Module, id: Value_ID, t: MIR_Type, plan: ^C_Expression_Plan = nil) {
	// U8 operations run in unsigned 32-bit C arithmetic, then truncate at the
	// typed MIR destination. This also works on C targets with 16-bit int.
	ct := t == .UIntptr ? "uintptr_t" : t == .U64 ? "uint64_t" : "uint32_t"
	strings.write_string(b, "((")
	strings.write_string(b, ct)
	strings.write_string(b, ")(")
	write_value_ref(b, m, id, plan)
	strings.write_string(b, "))")
}

emit_checked_shift :: proc(b: ^strings.Builder, m: ^MIR_Module, op: ^MIR_Inst, plan: ^C_Expression_Plan = nil) {
	width := "(sizeof(uintptr_t) * CHAR_BIT)"
	if op.type == .U8 do width = "8"
	if op.type == .U16 do width = "16"
	if op.type == .U64 do width = "64"
	if op.type == .U32 do width = "32"
	strings.write_string(b, "    ")
	write_value_ref(b, m, op.dst, plan)
	strings.write_string(b, " = ")
	write_value_ref(b, m, op.b, plan)
	strings.write_string(b, " < ")
	strings.write_string(b, width)
	strings.write_string(b, " ? (")
	write_unsigned_operand(b, m, op.a, op.type, plan)
	strings.write_string(b, op.bin_op == .Shift_Left ? " << " : " >> ")
	write_value_ref(b, m, op.b, plan)
	strings.write_string(b, ") : 0;\n")
}
