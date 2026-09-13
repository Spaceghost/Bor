package main

import "core:odin/ast"

// Resolve each destination once. Aggregate fields and address-of are separate
// extensions; scalar locals and indexed byte pointers are supported here.
Place_Kind :: enum {Invalid, Local, Byte_Index}
Lower_Place :: struct {
	kind: Place_Kind,
	type: MIR_Type,
	local, base, index: Value_ID,
}
snapshot_place_operand :: proc(l: ^Lowerer, value: Value_ID) -> Value_ID {
	if l.m.values[int(value)].kind != .Local do return value
	result := new_temp(l, value_type(l, value))
	emit_op(l, MIR_Inst{kind = .Assign, type = value_type(l, value), dst = result, a = value})
	return result
}
lower_place :: proc(l: ^Lowerer, expr: ^ast.Expr) -> (Lower_Place, bool) {
	if name, named := mir_ident_name(expr); named {
		id, found := lookup_value(l, name)
		if !found { lower_fail(l, &expr.expr_base, "assignment to unknown %s", name); return {}, false }
		if l.m.values[int(id)].kind != .Local {
			lower_fail(l, &expr.expr_base, "assignment to immutable %s", name)
			return {}, false
		}
		return Lower_Place{kind = .Local, type = value_type(l, id), local = id}, true
	}
	if n, indexed := expr.derived.(^ast.Index_Expr); indexed {
		base, base_ok := lower_value(l, n.expr)
		if !base_ok do return {}, false
		base = snapshot_place_operand(l, base)
		index, index_ok := lower_value(l, n.index)
		if !index_ok do return {}, false
		index = snapshot_place_operand(l, index)
		if value_type(l, base) != .U8_Ptr || !mir_unsigned(value_type(l, index)) {
			lower_fail(l, &expr.expr_base, "assignment needs a byte pointer and an unsigned index")
			return {}, false
		}
		return Lower_Place{kind = .Byte_Index, type = .U8, base = base, index = index}, true
	}
	lower_fail(l, &expr.expr_base, "unsupported assignment destination")
	return {}, false
}
load_place :: proc(l: ^Lowerer, place: Lower_Place) -> Value_ID {
	if place.kind == .Local do return place.local
	result := new_temp(l, place.type)
	emit_op(l, MIR_Inst{kind = .Load_Index, type = place.type, dst = result, a = place.base, b = place.index})
	return result
}
store_place :: proc(l: ^Lowerer, place: Lower_Place, value: Value_ID) {
	if place.kind == .Local {
		emit_op(l, MIR_Inst{kind = .Assign, type = place.type, dst = place.local, a = value})
	} else {
		emit_op(l, MIR_Inst{kind = .Store_Index, type = place.type, dst = place.base, a = place.index, b = value})
	}
}
