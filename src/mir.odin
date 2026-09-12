package main

// MIR is intentionally flat. IDs index global arrays owned by MIR_Module.
// Procedures and blocks describe contiguous ranges into those arrays.

MIR_Type :: enum u8 {
	Invalid,
	Void,
	Bool,
	U8,
	U32,
	UIntptr,
	U8_Ptr,
}

Value_ID :: distinct u32
Block_ID :: distinct u32
Proc_ID  :: distinct u32

INVALID_VALUE :: Value_ID(0xffff_ffff)
INVALID_BLOCK :: Block_ID(0xffff_ffff)
INVALID_PROC  :: Proc_ID(0xffff_ffff)
INVALID_INDEX :: u32(0xffff_ffff)

Value_Kind :: enum u8 {
	Invalid,
	Param,
	Local,
	Temp,
	Literal,
	Null,
	Global,
}

MIR_Value :: struct {
	kind:    Value_Kind,
	type:    MIR_Type,
	name:    string,
	literal: string,
}

Binary_Op :: enum u8 {
	Invalid,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Bit_And,
	Bit_Or,
	Bit_Xor,
	Shift_Left,
	Shift_Right,
	And_Not,
	Equal,
	Not_Equal,
	Less,
	Greater,
	Less_Equal,
	Greater_Equal,
	Logical_And,
	Logical_Or,
}

Unary_Op :: enum u8 {
	Invalid,
	Positive,
	Negative,
	Logical_Not,
	Bit_Not,
}

Op_Kind :: enum u8 {
	Invalid,
	Label,
	Assign,
	Unary,
	Binary,
	Cast,
	Load_Index,
	Store_Index,
	Call,
	Jump,
	Jump_If_False,
	Return,
}

// One fixed-size instruction shape is deliberate. It trades a handful of cold
// bytes for simple allocation, iteration, serialization, instrumentation, and
// backend code. Fields are interpreted by `kind`.
MIR_Inst :: struct {
	kind:       Op_Kind,
	type:       MIR_Type,
	dst:        Value_ID,
	a:          Value_ID,
	b:          Value_ID,
	bin_op:     Binary_Op,
	unary_op:   Unary_Op,
	target:     Block_ID,
	callee:     Proc_ID,
	args_first: u32,
	args_count: u32,
}

Basic_Block :: struct {
	id:         Block_ID,
	first_op:   u32,
	op_count:   u32,
	incoming:   u32,
	started:    bool,
	terminated: bool,
}

MIR_Procedure :: struct {
	name:               string,
	result:             MIR_Type,
	calling_convention: string,
	external:           bool,
	entry:              Block_ID,
	first_block:        u32,
	block_count:        u32,
	first_value:        u32,
	value_count:        u32,
	param_first:        u32,
	param_count:        u32,
}

MIR_Global :: struct {
	name: string,
	type: MIR_Type,
	init: string,
}

MIR_Module :: struct {
	globals:   [dynamic]MIR_Global,
	procedures:[dynamic]MIR_Procedure,
	blocks:    [dynamic]Basic_Block,
	ops:       [dynamic]MIR_Inst,
	values:    [dynamic]MIR_Value,
	call_args: [dynamic]Value_ID,
}

mir_destroy :: proc(m: ^MIR_Module) {
	delete(m.globals)
	delete(m.procedures)
	delete(m.blocks)
	delete(m.ops)
	delete(m.values)
	delete(m.call_args)
	m^ = {}
}

value_at :: proc(m: ^MIR_Module, id: Value_ID) -> ^MIR_Value {
	assert(id != INVALID_VALUE)
	return &m.values[int(id)]
}

block_at :: proc(m: ^MIR_Module, id: Block_ID) -> ^Basic_Block {
	assert(id != INVALID_BLOCK)
	return &m.blocks[int(id)]
}

proc_at :: proc(m: ^MIR_Module, id: Proc_ID) -> ^MIR_Procedure {
	assert(id != INVALID_PROC)
	return &m.procedures[int(id)]
}
