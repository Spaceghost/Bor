package main

import "core:fmt"
import "core:odin/ast"

emit_direct_operand :: proc(e: ^Emitter, expr: ^ast.Expr, t: C_Type, numeric: bool) -> bool {
	if numeric {
		ct := t == .UIntptr ? "uintptr_t" : t == .U64 ? "uint64_t" : "uint32_t"
		write(e, fmt.tprintf("((%s)(", ct))
	}
	if !emit_expr(e, expr) do return false
	if numeric do write(e, "))")
	return true
}

// Helpers evaluate a shift count once and guard C's undefined oversized shifts.
// The experimental AST path still has independent call-order/type-checking gaps.
emit_direct_shift_helpers :: proc(e: ^Emitter) {
	for t in ([?]C_Type{.U8,.U16,.U32,.U64,.UIntptr}) {
		ct, _ := c_type_name(t)
		for op in ([?]string{"shl", "shr"}) {
			if !e.shift_helpers[fmt.tprintf("%s_%s",op,ct)] do continue
			write(e, fmt.tprintf("static inline %s bor_c99_%s_%s(%s a, uint64_t n) {{ return (%s)(n < sizeof(%s) * CHAR_BIT ? ((uint64_t)a %s n) : 0); }}\n",ct,op,ct,ct,ct,ct,op == "shl" ? "<<" : ">>"))
		}
	}
	write(e, "\n")
}
