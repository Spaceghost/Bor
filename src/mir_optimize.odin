package main

// Preserve IDs and table ranges: removed instructions become explicit Nops.
// This keeps existing diagnostic/dump coordinates stable across this pass.
MIR_Usage :: struct {
	reads: []u32,
	writes: []u32,
}

mir_usage :: proc(m: ^MIR_Module) -> MIR_Usage {
	u := MIR_Usage{
		reads = make([]u32, len(m.values), context.temp_allocator),
		writes = make([]u32, len(m.values), context.temp_allocator),
	}
	for op in m.ops {
		#partial switch op.kind {
		case .Assign, .Unary, .Cast, .Load_Index:
			u.writes[int(op.dst)] += 1
			u.reads[int(op.a)] += 1
			if op.kind == .Load_Index do u.reads[int(op.b)] += 1
		case .Binary:
			u.writes[int(op.dst)] += 1
			u.reads[int(op.a)] += 1
			u.reads[int(op.b)] += 1
		case .Store_Index:
			u.reads[int(op.dst)] += 1
			u.reads[int(op.a)] += 1
			u.reads[int(op.b)] += 1
		case .Call:
			if op.dst != INVALID_VALUE do u.writes[int(op.dst)] += 1
			for i in int(op.args_first)..<int(op.args_first + op.args_count) {
				u.reads[int(m.call_args[i])] += 1
			}
		case .Branch, .Jump_If_False:
			u.reads[int(op.a)] += 1
		case .Return:
			if op.a != INVALID_VALUE do u.reads[int(op.a)] += 1
		}
	}
	return u
}

MIR_Optimize_Stats :: struct {
	copies_fused: u32,
}

//    t = op(args); x = t   ->   x = op(args); nop
// Requires adjacency, one definition, one read, and identical destination
// types. No instruction, memory effect, or CFG edge moves. In particular this
// must not fuse multi-definition short-circuit/merge temporaries.
mir_optimize :: proc(m: ^MIR_Module) -> MIR_Optimize_Stats {
	stats: MIR_Optimize_Stats
	u := mir_usage(m)
	for b in m.blocks {
		first := int(b.first_op)
		last := first + int(b.op_count)
		for i in first..<last-1 {
			op := &m.ops[i]
			copy := &m.ops[i+1]
			if copy.kind != .Assign do continue
			eligible := false
			#partial switch op.kind {
			case .Unary, .Binary, .Cast, .Load_Index, .Call:
				eligible = true
			}
			if !eligible || op.dst == INVALID_VALUE || copy.a != op.dst do continue
			temp := int(op.dst)
			if m.values[temp].kind != .Temp || u.reads[temp] != 1 || u.writes[temp] != 1 do continue
			if m.values[int(copy.dst)].type != m.values[temp].type do continue
			op.dst = copy.dst
			copy^ = MIR_Inst{kind = .Nop}
			stats.copies_fused += 1
		}
	}
	return stats
}
