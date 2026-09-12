package main

import "core:fmt"

mir_verify_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintf("bor: invalid MIR: ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\n")
	return false
}

mir_range_fits :: proc(first, count: u32, total: int) -> bool {
	return u64(first) + u64(count) <= u64(total)
}

mir_value_id_valid :: proc(m: ^MIR_Module, id: Value_ID) -> bool {
	return id != INVALID_VALUE && int(id) >= 0 && int(id) < len(m.values)
}

mir_block_id_valid :: proc(m: ^MIR_Module, id: Block_ID) -> bool {
	return id != INVALID_BLOCK && int(id) >= 0 && int(id) < len(m.blocks)
}

mir_proc_id_valid :: proc(m: ^MIR_Module, id: Proc_ID) -> bool {
	return id != INVALID_PROC && int(id) >= 0 && int(id) < len(m.procedures)
}

mir_block_in_proc :: proc(p: ^MIR_Procedure, id: Block_ID) -> bool {
	if id == INVALID_BLOCK do return false
	i := u64(id)
	first := u64(p.first_block)
	return i >= first && i < first + u64(p.block_count)
}

mir_require_value :: proc(m: ^MIR_Module, id: Value_ID, proc_index, op_index: int, role: string) -> bool {
	if mir_value_id_valid(m, id) {
		v := &m.values[int(id)]
		p := &m.procedures[proc_index]
		if v.kind == .Global || (u64(id) >= u64(p.first_value) && u64(id) < u64(p.first_value)+u64(p.value_count)) do return true
		return mir_verify_fail("proc %d op %d references a foreign procedure value %d", proc_index, op_index, u32(id))
	}
	return mir_verify_fail("proc %d op %d has invalid %s value id %d", proc_index, op_index, role, u32(id))
}

mir_verify :: proc(m: ^MIR_Module) -> bool {
	for g, gi in m.globals {
		if g.name == "" do return mir_verify_fail("global %d has no name", gi)
		if g.type == .Invalid || g.type == .Void do return mir_verify_fail("global %d (%s) has invalid type", gi, g.name)
		if !mir_value_id_valid(m, g.value_id) do return mir_verify_fail("global %d (%s) has invalid value id", gi, g.name)
		v := &m.values[int(g.value_id)]
		if v.kind != .Global || v.type != g.type || v.name != g.name {
			return mir_verify_fail("global %d (%s) value record disagrees with global table", gi, g.name)
		}
	}

	incoming := make([]u32, len(m.blocks), context.temp_allocator)

	for &p, pi in m.procedures {
		if p.name == "" do return mir_verify_fail("proc %d has no name", pi)
		if p.result == .Invalid do return mir_verify_fail("proc %d (%s) has invalid result type", pi, p.name)
		if !mir_range_fits(p.first_block, p.block_count, len(m.blocks)) {
			return mir_verify_fail("proc %d (%s) block range escapes module", pi, p.name)
		}
		if !mir_range_fits(p.first_op, p.op_count, len(m.ops)) {
			return mir_verify_fail("proc %d (%s) op range escapes module", pi, p.name)
		}
		if !mir_range_fits(p.first_value, p.value_count, len(m.values)) {
			return mir_verify_fail("proc %d (%s) value range escapes module", pi, p.name)
		}
		if !mir_range_fits(p.param_first, p.param_count, len(m.values)) {
			return mir_verify_fail("proc %d (%s) parameter range escapes value table", pi, p.name)
		}

		value_first := u64(p.first_value)
		value_last := value_first + u64(p.value_count)
		param_first := u64(p.param_first)
		param_last := param_first + u64(p.param_count)
		if p.param_count > 0 && (param_first < value_first || param_last > value_last) {
			return mir_verify_fail("proc %d (%s) parameter range escapes procedure values", pi, p.name)
		}

		if p.block_count == 0 {
			return mir_verify_fail("proc %d (%s) has no basic blocks", pi, p.name)
		}
		if !mir_block_in_proc(&p, p.entry) {
			return mir_verify_fail("proc %d (%s) entry block is outside procedure", pi, p.name)
		}

		for vi in int(p.first_value)..<int(p.first_value + p.value_count) {
			v := &m.values[vi]
			if v.kind == .Invalid do return mir_verify_fail("proc %d (%s) value %d has invalid kind", pi, p.name, vi)
			if v.type == .Invalid || v.type == .Void do return mir_verify_fail("proc %d (%s) value %d has invalid type", pi, p.name, vi)
		}
		for vi in int(p.param_first)..<int(p.param_first + p.param_count) {
			if m.values[vi].kind != .Param {
				return mir_verify_fail("proc %d (%s) parameter value %d is not a Param", pi, p.name, vi)
			}
		}

		proc_op_first := u64(p.first_op)
		proc_op_last := proc_op_first + u64(p.op_count)
		for bi in int(p.first_block)..<int(p.first_block + p.block_count) {
			b := &m.blocks[bi]
			if b.id != Block_ID(bi) do return mir_verify_fail("proc %d (%s) block table id mismatch at %d", pi, p.name, bi)
			if !b.started do return mir_verify_fail("proc %d (%s) block %d was never started", pi, p.name, bi)
			if b.op_count == 0 do return mir_verify_fail("proc %d (%s) block %d is empty", pi, p.name, bi)
			block_op_first := u64(b.first_op)
			block_op_last := block_op_first + u64(b.op_count)
			if block_op_first < proc_op_first || block_op_last > proc_op_last {
				return mir_verify_fail("proc %d (%s) block %d op range escapes procedure", pi, p.name, bi)
			}
			first := &m.ops[int(b.first_op)]
			if first.kind != .Label || first.target != b.id {
				return mir_verify_fail("proc %d (%s) block %d does not begin with its label", pi, p.name, bi)
			}
			if !b.terminated {
				return mir_verify_fail("proc %d (%s) block %d is not terminated", pi, p.name, bi)
			}

			last_index := int(b.first_op + b.op_count - 1)
			last := &m.ops[last_index]
			if last.kind == .Jump_If_False {
				return mir_verify_fail("proc %d (%s) block %d still has raw fallthrough conditional", pi, p.name, bi)
			}
			if last.kind != .Jump && last.kind != .Branch && last.kind != .Return {
				return mir_verify_fail("proc %d (%s) block %d has no canonical terminator", pi, p.name, bi)
			}

			for oi in int(b.first_op)..<last_index {
				kind := m.ops[oi].kind
				if kind == .Jump || kind == .Branch || kind == .Jump_If_False || kind == .Return {
					return mir_verify_fail("proc %d (%s) block %d has early terminator at op %d", pi, p.name, bi, oi)
				}
			}
		}

		for oi in int(p.first_op)..<int(p.first_op + p.op_count) {
			op := &m.ops[oi]
			if op.kind == .Invalid do return mir_verify_fail("proc %d (%s) op %d has invalid kind", pi, p.name, oi)

			#partial switch op.kind {
			case .Label:
				if !mir_block_in_proc(&p, op.target) do return mir_verify_fail("proc %d op %d labels foreign block", pi, oi)
			case .Assign:
				if !mir_require_value(m, op.dst, pi, oi, "dst") || !mir_require_value(m, op.a, pi, oi, "source") do return false
			case .Unary:
				if op.unary_op == .Invalid do return mir_verify_fail("proc %d op %d has invalid unary operator", pi, oi)
				if !mir_require_value(m, op.dst, pi, oi, "dst") || !mir_require_value(m, op.a, pi, oi, "operand") do return false
			case .Binary:
				if op.bin_op == .Invalid do return mir_verify_fail("proc %d op %d has invalid binary operator", pi, oi)
				if !mir_require_value(m, op.dst, pi, oi, "dst") || !mir_require_value(m, op.a, pi, oi, "left") || !mir_require_value(m, op.b, pi, oi, "right") do return false
			case .Cast:
				if op.type == .Invalid || op.type == .Void do return mir_verify_fail("proc %d op %d casts to invalid type", pi, oi)
				if !mir_require_value(m, op.dst, pi, oi, "dst") || !mir_require_value(m, op.a, pi, oi, "source") do return false
			case .Load_Index:
				if !mir_require_value(m, op.dst, pi, oi, "dst") || !mir_require_value(m, op.a, pi, oi, "base") || !mir_require_value(m, op.b, pi, oi, "index") do return false
			case .Store_Index:
				if !mir_require_value(m, op.dst, pi, oi, "base") || !mir_require_value(m, op.a, pi, oi, "index") || !mir_require_value(m, op.b, pi, oi, "value") do return false
			case .Call:
				if !mir_proc_id_valid(m, op.callee) do return mir_verify_fail("proc %d op %d calls invalid procedure id", pi, oi)
				if op.dst != INVALID_VALUE && !mir_require_value(m, op.dst, pi, oi, "call result") do return false
				if !mir_range_fits(op.args_first, op.args_count, len(m.call_args)) do return mir_verify_fail("proc %d op %d argument range escapes call table", pi, oi)
				for ai in int(op.args_first)..<int(op.args_first + op.args_count) {
					if !mir_require_value(m, m.call_args[ai], pi, oi, "call argument") do return false
				}
			case .Jump:
				if !mir_block_in_proc(&p, op.target) do return mir_verify_fail("proc %d op %d jumps to foreign block", pi, oi)
				incoming[int(op.target)] += 1
			case .Branch:
				if !mir_require_value(m, op.a, pi, oi, "condition") do return false
				if m.values[int(op.a)].type != .Bool do return mir_verify_fail("proc %d op %d branch condition is not bool", pi, oi)
				if !mir_block_in_proc(&p, op.target) do return mir_verify_fail("proc %d op %d true edge targets foreign block", pi, oi)
				if !mir_block_in_proc(&p, op.target_else) do return mir_verify_fail("proc %d op %d false edge targets foreign block", pi, oi)
				incoming[int(op.target)] += 1
				incoming[int(op.target_else)] += 1
			case .Jump_If_False:
				return mir_verify_fail("proc %d op %d raw fallthrough conditional survived normalization", pi, oi)
			case .Return:
				if op.a != INVALID_VALUE && !mir_require_value(m, op.a, pi, oi, "return") do return false
			}
		}
	}

	for b, bi in m.blocks {
		if incoming[bi] != b.incoming {
			return mir_verify_fail("block %d incoming count is %d, expected %d from CFG", bi, b.incoming, incoming[bi])
		}
	}

	return mir_verify_types(m)
}
