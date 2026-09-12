package main

import "core:odin/tokenizer"

// Indices are stable across array growth. AST pointers never enter the IR.
Value_Id :: distinct u32
Slot_Id  :: distinct u32
Label_Id :: distinct u32
Proc_Id  :: distinct u32

Type :: enum u8 { Void, Int, I8, I16, I32, I64, Uint, U8, U16, U32, U64, Uintptr, Bool }
is_signed :: proc(t: Type) -> bool { return t >= .Int && t <= .I64 }
is_integer :: proc(t: Type) -> bool { return t > .Void && t < .Bool }
bit_width :: proc(t: Type) -> int {
    #partial switch t {
    case .I8, .U8: return 8
    case .I16, .U16: return 16
    case .I32, .U32: return 32
    case .Bool: return 1
    }
    return 64
}
type_mask :: proc(t: Type) -> u64 { return max(u64) >> uint(64-bit_width(t)) }
signed_maximum :: proc(t: Type) -> i64 { return i64(type_mask(t)>>1) }
signed_minimum :: proc(t: Type) -> i64 { return -1-signed_maximum(t) }
normalize_bits :: proc(t: Type, bits: u64) -> u64 {
    mask := type_mask(t)
    value := bits & mask
    if is_signed(t) && value > mask>>1 { value |= ~mask }
    return value
}
Op :: enum u8 {
    Nop, Const, Load, Store, Cast, Neg, Not, Bit_Not,
    Add, Sub, Mul, Div, Rem, And, Or, Xor, And_Not,
    Eq, Ne, Lt, Le, Gt, Ge,
    Call, Label, Jump, Branch, Return, Assert,
}
Span :: struct { start, count: u32 }
Instruction :: struct {
    op: Op,
    type: Type,
    a, b: Value_Id,
    slot: Slot_Id,
    target, otherwise: Label_Id,
    callee: Proc_Id,
    args: Span,
    bits: u64,
    pos: tokenizer.Pos,
}
Slot :: struct { name: string, type: Type }
Procedure :: struct {
    name: string,
    exported: bool,
    has_context: bool,
    result: Type,
    parameter_count: int,
    slots: [dynamic]Slot,
    code: #soa[dynamic]Instruction,
    arguments: [dynamic]Value_Id,
    label_count: u32,
}
Diagnostic :: struct { code, message: string, pos: tokenizer.Pos }
Program :: struct {
    procs: [dynamic]Procedure,
    names: map[string]Proc_Id,
    diagnostics: [dynamic]Diagnostic,
}

diag :: proc(p: ^Program, pos: tokenizer.Pos, code, message: string) {
    append(&p.diagnostics, Diagnostic{code, message, pos})
}
emit :: proc(p: ^Procedure, inst: Instruction) -> Value_Id {
    id := Value_Id(len(p.code))
    append(&p.code, inst)
    return id
}
new_label :: proc(p: ^Procedure) -> Label_Id {
    p.label_count += 1
    return Label_Id(p.label_count)
}
mark :: proc(p: ^Procedure, label: Label_Id, pos: tokenizer.Pos) {
    emit(p, Instruction{op=.Label, target=label, pos=pos})
}
jump :: proc(p: ^Procedure, label: Label_Id, pos: tokenizer.Pos) {
    emit(p, Instruction{op=.Jump, target=label, pos=pos})
}
constant :: proc(p: ^Procedure, type: Type, bits: u64, pos: tokenizer.Pos) -> Value_Id {
    return emit(p, Instruction{op=.Const, type=type, bits=bits, pos=pos})
}
new_slot :: proc(p: ^Procedure, name: string, type: Type) -> Slot_Id {
    id := Slot_Id(len(p.slots))
    append(&p.slots, Slot{name, type})
    return id
}
load :: proc(p: ^Procedure, slot: Slot_Id, pos: tokenizer.Pos) -> Value_Id {
    return emit(p, Instruction{op=.Load, type=p.slots[slot].type, slot=slot, pos=pos})
}
store :: proc(p: ^Procedure, slot: Slot_Id, value: Value_Id, pos: tokenizer.Pos) {
    emit(p, Instruction{op=.Store, slot=slot, a=value, pos=pos})
}
value_type :: proc(p: ^Procedure, id: Value_Id) -> Type { return p.code[id].type }
is_compare :: proc(op: Op) -> bool { return op >= .Eq && op <= .Ge }
is_binary :: proc(op: Op) -> bool { return op >= .Add && op <= .Ge }
has_value :: proc(inst: Instruction) -> bool {
    return inst.type != .Void && inst.op != .Nop
}

// Total arithmetic over a deliberately explicit domain. Unsigned operations
// implement two's-complement wrap without inheriting C's signed-overflow UB.
calculate :: proc(op: Op, type: Type, a, b: u64) -> (bits: u64, ok: bool) {
    value, valid := calculate_wide(op, type, a, b)
    if is_compare(op) || op == .Not { return value, valid }
    return normalize_bits(type, value), valid
}
calculate_wide :: proc(op: Op, type: Type, a, b: u64) -> (bits: u64, ok: bool) {
    x, y := transmute(i64)a, transmute(i64)b
    #partial switch op {
    case .Add: return a+b, true
    case .Sub: return a-b, true
    case .Mul: return a*b, true
    case .Neg: return u64(0)-a, true
    case .Not: return u64(a == 0), true
    case .Bit_Not: return ~a, true
    case .And: return a & b, true
    case .Or: return a | b, true
    case .Xor: return a ~ b, true
    case .And_Not: return a &~ b, true
    case .Eq: return u64(a == b), true
    case .Ne: return u64(a != b), true
    case .Lt: return u64(x < y) if is_signed(type) else u64(a < b), true
    case .Le: return u64(x <= y) if is_signed(type) else u64(a <= b), true
    case .Gt: return u64(x > y) if is_signed(type) else u64(a > b), true
    case .Ge: return u64(x >= y) if is_signed(type) else u64(a >= b), true
    case .Div, .Rem:
        if b == 0 { return 0, false }
        if is_signed(type) && x == min(i64) && y == -1 {
            return a if op == .Div else 0, true
        }
        if is_signed(type) {
            if op == .Div { return transmute(u64)(x/y), true }
            return transmute(u64)(x%y), true
        }
        if op == .Div { return a/b, true }
        return a%b, true
    }
    return 0, false
}

// Conservative, local propagation. A label invalidates every mutable-slot
// fact: never propagate a pre-loop value through a back edge.
optimize :: proc(p: ^Procedure) {
    epochs := make([]u64, len(p.slots))
    epoch: u64 = 1
    values := make([]u64, len(p.slots))
    defer delete(epochs)
    defer delete(values)
    for i in 1..<len(p.code) {
        inst := p.code[i]
        #partial switch inst.op {
        case .Label, .Call:
            epoch += 1
        case .Store:
            source := p.code[inst.a]
            epochs[inst.slot] = epoch if source.op == .Const else 0
            values[inst.slot] = source.bits
        case .Load:
            if epochs[inst.slot] == epoch {
                p.code[i] = Instruction{op=.Const, type=inst.type, bits=values[inst.slot], pos=inst.pos}
            }
        case .Cast:
            source := p.code[inst.a]
            if source.op == .Const {
                p.code[i] = Instruction{op=.Const, type=inst.type, bits=normalize_bits(inst.type,source.bits), pos=inst.pos}
            }
        case .Neg, .Not, .Bit_Not:
            source := p.code[inst.a]
            if source.op == .Const {
                bits, ok := calculate(inst.op, source.type, source.bits, 0)
                if ok { p.code[i] = Instruction{op=.Const, type=inst.type, bits=bits, pos=inst.pos} }
            }
        case .Branch:
            source := p.code[inst.a]
            if source.op == .Const {
                p.code[i] = Instruction{op=.Jump, target=inst.target if source.bits != 0 else inst.otherwise, pos=inst.pos}
            }
        case:
            if is_binary(inst.op) {
                a, b := p.code[inst.a], p.code[inst.b]
                if a.op == .Const && b.op == .Const {
                    bits, ok := calculate(inst.op, a.type, a.bits, b.bits)
                    if ok { p.code[i] = Instruction{op=.Const, type=inst.type, bits=bits, pos=inst.pos} }
                }
            }
        }
    }
}
