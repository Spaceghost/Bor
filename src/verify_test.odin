package main

import "core:testing"
import "core:mem/virtual"

// These are hostile-IR tests, not source fixtures. A verifier which crashes on
// a damaged operand cannot serve as a useful pass boundary.
@(test)
verify_rejects_malformed_ir :: proc(t: ^testing.T) {
    arena: virtual.Arena
    err := virtual.arena_init_growing(&arena)
    testing.expect(t, err == nil)
    if err != nil { return }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    for variant in 0..<9 {
        program: Program
        p := Procedure{name="hostile", result=.Int}
        emit(&p, Instruction{op=.Nop})
        value := constant(&p, .Int, 42, {})
        emit(&p, Instruction{op=.Return, a=value})
        switch variant {
        case 0: p.code[2].a = 500 // out-of-range operand
        case 1: p.code[1].op = .Load; p.code[1].slot = 400
        case 2: p.code[2] = Instruction{op=.Jump, target=200}
        case 3: p.code[1] = Instruction{op=.Const, type=.Bool, bits=2}
        case 4: p.code[1] = Instruction{op=.Call, type=.Int, callee=100}
        case 5: p.code[2] = Instruction{op=.Nop} // falls off the end
        case 6: p.code[1] = Instruction{op=.Cast, type=.Int, a=Value_Id(1)}
        case 7: p.parameter_count = -1
        case 8:
            append(&program.procs, Procedure{result=.Int})
            p.code[1] = Instruction{op=.Call, type=.Int, args={max(u32),max(u32)}}
        }
        testing.expect(t, !verify(&program, &p))
        testing.expect(t, len(program.diagnostics) > 0)
    }
}

@(test)
verify_checks_dominance :: proc(t: ^testing.T) {
    arena: virtual.Arena
    err := virtual.arena_init_growing(&arena)
    testing.expect(t, err == nil)
    if err != nil { return }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    program: Program
    p := Procedure{name="diamond",result=.Int}
    emit(&p, Instruction{op=.Nop})
    condition := constant(&p, .Bool, 1, {})
    yes, no, done := new_label(&p), new_label(&p), new_label(&p)
    emit(&p, Instruction{op=.Branch,a=condition,target=yes,otherwise=no})
    mark(&p, yes, {})
    partial_value := constant(&p, .Int, 42, {})
    jump(&p, done, {})
    mark(&p, no, {})
    jump(&p, done, {})
    mark(&p, done, {})
    emit(&p, Instruction{op=.Return,a=partial_value})
    testing.expect(t, !verify(&program, &p))
    testing.expect(t, program.diagnostics[len(program.diagnostics)-1].code == "B9003")
}

@(test)
verify_accepts_loop_carried_slots :: proc(t: ^testing.T) {
    arena: virtual.Arena
    err := virtual.arena_init_growing(&arena)
    testing.expect(t, err == nil)
    if err != nil { return }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    program: Program
    p := Procedure{name="loop",result=.Int}
    emit(&p, Instruction{op=.Nop})
    slot := new_slot(&p,"counter",.Int)
    zero := constant(&p,.Int,0,{})
    one := constant(&p,.Int,1,{})
    limit := constant(&p,.Int,5,{})
    store(&p,slot,zero,{})
    test,body,done := new_label(&p),new_label(&p),new_label(&p)
    jump(&p,test,{})
    mark(&p,test,{})
    current := load(&p,slot,{})
    cond := emit(&p,Instruction{op=.Lt,type=.Bool,a=current,b=limit})
    emit(&p,Instruction{op=.Branch,a=cond,target=body,otherwise=done})
    mark(&p,body,{})
    incremented := emit(&p,Instruction{op=.Add,type=.Int,a=current,b=one})
    store(&p,slot,incremented,{})
    jump(&p,test,{})
    mark(&p,done,{})
    result := load(&p,slot,{})
    emit(&p,Instruction{op=.Return,a=result})
    testing.expect(t, verify(&program,&p))
    optimize(&p)
    testing.expect(t, verify(&program,&p))
    append(&program.procs,p)
    vm := VM{program=&program,remaining=500}
    value,failure := interpret(&vm,0,nil)
    testing.expect(t, failure==.None && value==5)
}
