package main

import "core:testing"

copy_test_module :: proc() -> MIR_Module {
	m: MIR_Module
	append(&m.values,
		MIR_Value{kind = .Param, type = .U32, name = "x"},
		MIR_Value{kind = .Literal, type = .U32, literal = "1"},
		MIR_Value{kind = .Temp, type = .U32},
		MIR_Value{kind = .Local, type = .U32, name = "result"})
	append(&m.ops,
		MIR_Inst{kind = .Label, target = Block_ID(0)},
		MIR_Inst{kind = .Binary, type = .U32, dst = Value_ID(2), a = Value_ID(0), b = Value_ID(1), bin_op = .Add},
		MIR_Inst{kind = .Assign, type = .U32, dst = Value_ID(3), a = Value_ID(2)},
		MIR_Inst{kind = .Return, a = Value_ID(3)})
	append(&m.blocks, Basic_Block{id = Block_ID(0), first_op = 0, op_count = 4, started = true, terminated = true})
	append(&m.procedures, MIR_Procedure{name = "fixture", result = .U32, external = true, entry = Block_ID(0),
		block_count = 1, op_count = 4, value_count = 4, param_count = 1})
	return m
}

@(test)
copy_fusion_is_verified_and_idempotent :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	testing.expect(t, mir_verify(&m))
	before_ops := len(m.ops)
	stats := mir_optimize(&m)
	testing.expect_value(t, stats.copies_fused, u32(1))
	testing.expect(t, mir_verify(&m))
	testing.expect_value(t, m.ops[1].dst, Value_ID(3))
	testing.expect_value(t, m.ops[2].kind, Op_Kind.Nop)
	testing.expect_value(t, len(m.ops), before_ops)
	testing.expect_value(t, mir_optimize(&m).copies_fused, u32(0))
}

@(test)
copy_fusion_preserves_multiple_reads :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	// Read the producer again: it cannot be retired by the copy pass.
	m.ops[3].a = Value_ID(2)
	testing.expect(t, mir_verify(&m))
	testing.expect_value(t, mir_optimize(&m).copies_fused, u32(0))
	testing.expect_value(t, m.ops[2].kind, Op_Kind.Assign)
}

@(test)
copy_fusion_preserves_multiple_definitions :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	// A self assignment makes the temp multi-defined. The pass must not
	// mistake mutable merge storage for a single-definition producer.
	m.ops[2].dst = Value_ID(2)
	m.ops[3].a = Value_ID(2)
	testing.expect(t, mir_verify(&m))
	testing.expect_value(t, mir_optimize(&m).copies_fused, u32(0))
}

@(test)
verifier_rejects_corrupt_operands_and_returns :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	m.ops[1].a = INVALID_VALUE
	testing.expect(t, !mir_verify(&m))
	m.ops[1].a = Value_ID(0)
	m.ops[3].a = INVALID_VALUE
	testing.expect(t, !mir_verify(&m))
	m.ops[3].a = Value_ID(3)
	m.values[3].type = .Bool
	testing.expect(t, !mir_verify(&m))
	m.values[3].type = .U32
	m.ops[2].dst = Value_ID(1)
	testing.expect(t, !mir_verify(&m))
}

@(test)
verifier_rejects_foreign_values_and_bad_calls :: proc(t: ^testing.T) {
	m := copy_test_module()
	defer mir_destroy(&m)
	append(&m.values, MIR_Value{kind = .Local, type = .U32})
	m.ops[1].a = Value_ID(4)
	testing.expect(t, !mir_verify(&m))
	m.ops[1] = MIR_Inst{kind = .Call, type = .U32, dst = Value_ID(2), callee = Proc_ID(0), args_count = 0}
	testing.expect(t, !mir_verify(&m))
	append(&m.call_args, Value_ID(0))
	m.ops[1].args_count = 1
	testing.expect(t, mir_verify(&m))
}

@(test)
literal_parser_detects_overflow_and_source_bases :: proc(t: ^testing.T) {
	n, ok := mir_literal_number("18_446_744_073_709_551_615")
	testing.expect(t, ok && n == max(u64))
	_, over := mir_literal_number("18446744073709551616")
	testing.expect(t, !over)
	cases := [?]struct {text:string, expected:u64}{{"012",12}, {"0b1010",10}, {"0o12",10}, {"0xff",255}, {"'A'",65}}
	for item in cases {
		value, valid := mir_literal_number(item.text)
		testing.expect(t, valid && value == item.expected)
	}
}
