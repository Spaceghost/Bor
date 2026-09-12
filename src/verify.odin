package main

import "core:fmt"

uses_a :: proc(inst: Instruction) -> bool {
    return is_binary(inst.op) || inst.op==.Store || inst.op==.Cast || inst.op==.Neg ||
           inst.op==.Not || inst.op==.Bit_Not || inst.op==.Branch || inst.op==.Assert ||
           (inst.op==.Return && inst.a!=0)
}
valid_value :: proc(p: ^Procedure, value: Value_Id, before: int) -> bool {
    return value!=0 && int(value)<before && has_value(p.code[value])
}
valid_label :: proc(labels: []int, label: Label_Id) -> bool {
    return label!=0 && int(label)<len(labels) && labels[label]>0
}

// Reject malformed IR before indexing operands, labels, argument spans, or
// callee signatures. Verification is also safe on deliberately corrupted IR.
verify :: proc(program: ^Program, p: ^Procedure) -> bool {
    if len(p.code)<2 || p.code[0].op!=.Nop || p.label_count>u32(len(p.code)) ||
       p.parameter_count<0 || p.parameter_count>len(p.slots) {
        diag(program,{},"B9001",fmt.aprintf("invalid IR header in '%s'",p.name)); return false
    }
    if p.result > .Bool { diag(program,{},"B9001","invalid IR result type"); return false }
    for slot in p.slots {
        if slot.type <= .Void || slot.type > .Bool { diag(program,{},"B9001","invalid IR slot type"); return false }
    }
    labels:=make([]int,int(p.label_count)+1)
    defer delete(labels)
    for inst,i in p.code {
        if inst.op==.Label {
            if inst.target==0 || int(inst.target)>=len(labels) || labels[inst.target]!=0 {
                diag(program,inst.pos,"B9001","invalid or duplicate IR label"); return false
            }
            labels[inst.target]=i
        }
    }
    for inst,i in p.code {
        valid:=true
        if inst.type > .Bool { diag(program,inst.pos,"B9001","invalid IR value type"); return false }
        if uses_a(inst) && !valid_value(p,inst.a,i) { valid=false }
        if is_binary(inst.op) && !valid_value(p,inst.b,i) { valid=false }
        if !valid { diag(program,inst.pos,"B9001","invalid IR operand or forward value reference"); return false }
        #partial switch inst.op {
        case .Nop: valid=inst.type==.Void
        case .Const: valid=inst.type!=.Void && inst.bits==normalize_bits(inst.type,inst.bits)
        case .Load,.Store:
            valid=int(inst.slot)<len(p.slots)
            if valid {
                if inst.op==.Load { valid=inst.type==p.slots[inst.slot].type && inst.type!=.Void }
                else { valid=inst.type==.Void && value_type(p,inst.a)==p.slots[inst.slot].type }
            }
        case .Cast:
            a:=value_type(p,inst.a)
            valid=(is_integer(a)&&is_integer(inst.type)) || (a==.Bool && inst.type==.Bool)
        case .Neg,.Bit_Not: valid=is_integer(inst.type) && value_type(p,inst.a)==inst.type
        case .Not: valid=inst.type==.Bool && value_type(p,inst.a)==.Bool
        case .Call:
            valid=int(inst.callee)<len(program.procs) && u64(inst.args.start)+u64(inst.args.count)<=u64(len(p.arguments))
            if valid {
                callee:=&program.procs[inst.callee]
                valid=callee.parameter_count>=0 && callee.parameter_count<=len(callee.slots) &&
                      int(inst.args.count)==callee.parameter_count && inst.type==callee.result
                if valid {
                    for j in 0..<int(inst.args.count) {
                        arg:=p.arguments[int(inst.args.start)+j]
                        if !valid_value(p,arg,i) || value_type(p,arg)!=callee.slots[j].type { valid=false; break }
                    }
                }
            }
        case .Label: valid=inst.type==.Void
        case .Jump: valid=inst.type==.Void && valid_label(labels,inst.target)
        case .Branch:
            valid=inst.type==.Void && value_type(p,inst.a)==.Bool &&
                  valid_label(labels,inst.target) && valid_label(labels,inst.otherwise)
        case .Return:
            valid=inst.type==.Void
            if p.result==.Void { valid=valid && inst.a==0 }
            else { valid=valid && valid_value(p,inst.a,i) && value_type(p,inst.a)==p.result }
        case .Assert: valid=inst.type==.Void && value_type(p,inst.a)==.Bool
        case:
            if is_binary(inst.op) {
                a,b:=value_type(p,inst.a),value_type(p,inst.b)
                valid=a==b && a!=.Void
                if is_compare(inst.op) { valid=valid && inst.type==.Bool && (is_integer(a)||inst.op==.Eq||inst.op==.Ne) }
                else { valid=valid && is_integer(a) && inst.type==a }
            } else { valid=false }
        }
        if !valid { diag(program,inst.pos,"B9001",fmt.aprintf("IR type/shape invariant failed at %s:%d (%v)",p.name,i,inst.op)); return false }
    }
    return verify_dominance(program,p,labels)
}

Block :: struct { first,last: int, successors: [2]int, successor_count: int }
intersect_dominators :: proc(a,b: int, idom, rank: []int) -> int {
    x,y:=a,b
    for x!=y {
        for rank[x]>rank[y] { x=idom[x] }
        for rank[y]>rank[x] { y=idom[y] }
    }
    return x
}
// A compact CFG and immediate-dominator tree avoid quadratic dominator sets.
// Slots have defined zero initialization; SSA-like value registers must be
// defined on every path to their use. Unreachable blocks still get type checks.
verify_dominance :: proc(program: ^Program,p: ^Procedure,labels: []int) -> bool {
    starts:=make([]bool,len(p.code))
    starts[1]=true
    for inst,i in p.code {
        if inst.op==.Label { starts[i]=true }
        if (inst.op==.Jump||inst.op==.Branch||inst.op==.Return) && i+1<len(starts) { starts[i+1]=true }
    }
    blocks: [dynamic]Block
    owners:=make([]int,len(p.code))
    for i in 1..<len(p.code) {
        if starts[i] {
            if len(blocks)>0 { blocks[len(blocks)-1].last=i-1 }
            append(&blocks,Block{first=i,last=len(p.code)-1})
        }
        owners[i]=len(blocks)-1
    }
    for &block,i in blocks {
        tail:=p.code[block.last]
        if tail.op==.Return { continue }
        if tail.op==.Jump||tail.op==.Branch {
            block.successors[0]=owners[labels[tail.target]]
            block.successor_count=1
            if tail.op==.Branch && tail.target!=tail.otherwise { block.successors[1]=owners[labels[tail.otherwise]]; block.successor_count=2 }
        } else if i+1<len(blocks) { block.successors[0]=i+1; block.successor_count=1 }
    }
    n:=len(blocks)
    visited:=make([]bool,n)
    stack,post: [dynamic]int
    append(&stack,0)
    for len(stack)>0 {
        index:=pop(&stack)
        if index<0 { append(&post,~index); continue }
        if visited[index] { continue }
        visited[index]=true
        append(&stack,~index)
        block:=blocks[index]
        for j in 0..<block.successor_count { append(&stack,block.successors[j]) }
    }
    for block,i in blocks {
        if visited[i] && block.last==len(p.code)-1 && p.code[block.last].op!=.Return &&
           p.code[block.last].op!=.Jump && p.code[block.last].op!=.Branch {
            diag(program,p.code[block.last].pos,"B9002","reachable IR falls off the end of a procedure"); return false
        }
    }
    // Predecessors in compressed sparse row form, including harmless dead edges.
    offsets:=make([]int,n+1)
    for block in blocks { for j in 0..<block.successor_count { offsets[block.successors[j]+1]+=1 } }
    for i in 1..<len(offsets) { offsets[i]+=offsets[i-1] }
    next:=make([]int,n)
    copy(next,offsets[:n])
    predecessors:=make([]int,offsets[n])
    for block,i in blocks {
        for j in 0..<block.successor_count { target:=block.successors[j]; predecessors[next[target]]=i; next[target]+=1 }
    }
    idom,rank:=make([]int,n),make([]int,n)
    for &d in idom { d = -1 }
    for index,i in post { rank[index]=len(post)-1-i }
    idom[0]=0
    changed:=true
    for changed {
        changed=false
        for k:=len(post)-2;k>=0;k-=1 {
            index:=post[k]
            parent:= -1
            for pred in predecessors[offsets[index]:offsets[index+1]] {
                if idom[pred]<0 { continue }
                if parent<0 { parent=pred } else { parent=intersect_dominators(parent,pred,idom,rank) }
            }
            if parent!=idom[index] { idom[index]=parent; changed=true }
        }
    }
    // Tree intervals turn every subsequent dominance query into O(1).
    child,sibling:=make([]int,n),make([]int,n)
    for &v in child { v = -1 }
    for &v in sibling { v = -1 }
    for parent,i in idom {
        if i==0 || parent<0 { continue }
        sibling[i]=child[parent]; child[parent]=i
    }
    enter,leave:=make([]int,n),make([]int,n)
    tick:=0
    append(&stack,0)
    for len(stack)>0 {
        index:=pop(&stack)
        if index<0 { leave[~index]=tick; tick+=1; continue }
        enter[index]=tick; tick+=1
        append(&stack,~index)
        for node:=child[index];node>=0;node=sibling[node] { append(&stack,node) }
    }
    for inst,i in p.code {
        if i==0 || !visited[owners[i]] { continue }
        use:=owners[i]
        valid:=true
        if inst.type > .Bool { diag(program,inst.pos,"B9001","invalid IR value type"); return false }
        if uses_a(inst) { valid=dominates_value(inst.a,use,owners,visited,enter,leave) }
        if is_binary(inst.op) { valid=valid && dominates_value(inst.b,use,owners,visited,enter,leave) }
        if inst.op==.Call {
            for value in p.arguments[inst.args.start:inst.args.start+inst.args.count] {
                if !dominates_value(value,use,owners,visited,enter,leave) { valid=false; break }
            }
        }
        if !valid { diag(program,inst.pos,"B9003",fmt.aprintf("an IR operand does not dominate instruction %d in '%s'",i,p.name)); return false }
    }
    return true
}
dominates_value :: proc(value: Value_Id,use: int,owners: []int,visited: []bool,enter,leave: []int) -> bool {
    definition:=owners[value]
    return visited[definition] && enter[definition]<=enter[use] && leave[definition]>=leave[use]
}
