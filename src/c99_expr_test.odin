package main

import "core:testing"
import "core:strings"

@(test)
expression_plan_folds_single_use :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	testing.expect(t, mir_verify(&m))
	p := c_expr_plan(&m)
	testing.expect_value(t, p.folded, 1)
	testing.expect_value(t, p.inline_at[2], 2)
	testing.expect(t, p.skip[1])
	testing.expect(t, mir_verify(&m))
}
@(test)
expression_plan_preserves_multiple_reads_and_definitions :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	m.ops[3].a = Value_ID(2)
	testing.expect_value(t, c_expr_plan(&m).folded, 0)
	m.ops[2].dst = Value_ID(2)
	testing.expect_value(t, c_expr_plan(&m).folded, 0)
}
@(test)
expression_plan_stops_at_mutable_writes :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	m.ops[2].a = Value_ID(1)
	m.ops[3].a = Value_ID(2)
	testing.expect(t, mir_verify(&m))
	testing.expect_value(t, c_expr_plan(&m).folded, 0)
}
@(test)
expression_plan_does_not_duplicate_shift_counts :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	m.ops[2] = MIR_Inst{kind = .Binary, type = .U32, dst = Value_ID(3), a = Value_ID(0), b = Value_ID(2), bin_op = .Shift_Left}
	testing.expect(t, mir_verify(&m))
	testing.expect_value(t, c_expr_plan(&m).folded, 0)
}
@(test)
expression_plan_retains_narrow_types :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	for &v in m.values do v.type = .U8
	m.ops[1].type = .U8
	m.ops[2].type = .U8
	m.procedures[0].result = .U8
	testing.expect(t, mir_verify(&m))
	code, ok := emit_mir_c99(&m, expressions = true)
	defer delete(code)
	testing.expect(t, ok && strings.contains(code, "((uint8_t)("))
	testing.expect(t, !strings.contains(code, "uint8_t _bor_v2;"))
}
@(test)
expression_plan_bounds_recursion :: proc(t: ^testing.T) {
	m: MIR_Module
	defer mir_destroy(&m)
	append(&m.values, MIR_Value{kind = .Param, type = .U32, name = "x"})
	append(&m.ops, MIR_Inst{kind = .Label, target = Block_ID(0)})
	for i in 1..=100 {
		append(&m.values, MIR_Value{kind = .Temp, type = .U32})
		append(&m.ops, MIR_Inst{kind = .Cast, type = .U32, dst = Value_ID(i), a = Value_ID(i-1)})
	}
	append(&m.ops, MIR_Inst{kind = .Return, a = Value_ID(100)})
	append(&m.blocks, Basic_Block{id = Block_ID(0), op_count = 102, started = true, terminated = true})
	append(&m.procedures, MIR_Procedure{name = "chain", result = .U32, external = true, entry = Block_ID(0), block_count = 1, op_count = 102, value_count = 101, param_count = 1})
	testing.expect(t, mir_verify(&m))
	p := c_expr_plan(&m)
	testing.expect(t, p.folded > 0 && p.folded < 100)
	for vi in 0..<len(m.values) {
		depth := 0
		id := vi
		for p.inline_at[id] != 0 { depth += 1; id = int(m.ops[p.inline_at[id]-1].a) }
		testing.expect(t, depth <= C_EXPRESSION_MAX_DEPTH)
	}
}
