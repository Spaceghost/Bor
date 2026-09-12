package main

import "core:os"
import "core:odin/tokenizer"

Runtime_Error :: enum { None, Arithmetic_Trap, Assertion_Failed, Step_Limit, Recursion_Limit, Invalid_IR }
VM :: struct {
    program: ^Program,
    remaining: u64,
    depth: int,
    fault: tokenizer.Pos,
}

interpret :: proc(vm: ^VM, id: Proc_Id, args: []u64) -> (value: u64, error: Runtime_Error) {
    if vm.depth >= 256 { return 0, .Recursion_Limit }
    if int(id) >= len(vm.program.procs) { return 0, .Invalid_IR }
    p := &vm.program.procs[id]
    if len(args) != p.parameter_count { return 0, .Invalid_IR }
    vm.depth += 1
    defer vm.depth -= 1
    allocator := os.heap_allocator()
    registers := make([]u64, len(p.code), allocator)
    slots := make([]u64, len(p.slots), allocator)
    labels := make([]int, int(p.label_count)+1, allocator)
    defer delete(registers, allocator)
    defer delete(slots, allocator)
    defer delete(labels, allocator)
    for arg,i in args { slots[i] = normalize_bits(p.slots[i].type,arg) }
    for inst, i in p.code { if inst.op == .Label { labels[inst.target] = i } }
    pc := 1
    for pc < len(p.code) {
        inst := p.code[pc]
        vm.fault = inst.pos
        if vm.remaining == 0 { return 0, .Step_Limit }
        vm.remaining -= 1
        a, b := registers[inst.a], registers[inst.b]
        #partial switch inst.op {
        case .Nop, .Label:
        case .Const: registers[pc] = inst.bits
        case .Load: registers[pc] = slots[inst.slot]
        case .Store: slots[inst.slot] = a
        case .Cast: registers[pc] = normalize_bits(inst.type,a)
        case .Jump: pc = labels[inst.target]; continue
        case .Branch:
            pc = labels[inst.target] if a != 0 else labels[inst.otherwise]
            continue
        case .Return: return a, .None
        case .Assert:
            if a == 0 { return 0, .Assertion_Failed }
        case .Call:
            call_args := make([]u64, int(inst.args.count), allocator)
            for &arg, i in call_args { arg = registers[p.arguments[int(inst.args.start)+i]] }
            result, err := interpret(vm, inst.callee, call_args)
            delete(call_args, allocator)
            if err != .None { return 0, err }
            registers[pc] = result
        case:
            result, ok := calculate(inst.op, value_type(p, inst.a), a, b)
            if !ok { return 0, .Arithmetic_Trap }
            registers[pc] = result
        }
        pc += 1
    }
    return 0, .Invalid_IR
}
