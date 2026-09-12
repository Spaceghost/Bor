package main

// Canonical MIR has explicit control-flow. C does not need to spell every edge
// as a goto, though. This tiny layout analysis chooses physical fallthroughs
// without mutating MIR, then marks only blocks that are actual C goto targets.
// Semantic CFG and presentation layout therefore remain separate concerns.

c99_target_is_fallthrough :: proc(m: ^MIR_Module, target: Block_ID, op_index: int) -> bool {
	if target == INVALID_BLOCK do return false
	block := &m.blocks[int(target)]
	// Preserve explicit edges into loop headers and joins. Besides making the C
	// CFG easier for optimizers to recognize, a multiply-reached block is not a
	// particularly meaningful lexical fallthrough. Single-predecessor blocks are
	// the safe/cheap places to cash explicit MIR edges back into compact C.
	if block.incoming != 1 do return false
	return int(block.first_op) == op_index + 1
}

c99_layout_needs_labels :: proc(m: ^MIR_Module) -> []bool {
	needs_label := make([]bool, len(m.blocks), context.temp_allocator)

	for p in m.procedures {
		op_first := int(p.first_op)
		op_last := op_first + int(p.op_count)
		for op_index in op_first..<op_last {
			op := &m.ops[op_index]
			#partial switch op.kind {
			case .Jump:
				if !c99_target_is_fallthrough(m, op.target, op_index) {
					needs_label[int(op.target)] = true
				}
			case .Branch:
				if op.target == op.target_else {
					if !c99_target_is_fallthrough(m, op.target, op_index) {
						needs_label[int(op.target)] = true
					}
					continue
				}

				true_fallthrough := c99_target_is_fallthrough(m, op.target, op_index)
				false_fallthrough := c99_target_is_fallthrough(m, op.target_else, op_index)
				if !true_fallthrough {
					needs_label[int(op.target)] = true
				}
				if !false_fallthrough {
					needs_label[int(op.target_else)] = true
				}
			}
		}
	}

	return needs_label
}
