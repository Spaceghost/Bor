package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"

emit_deferred :: proc(c: ^Checker, base: int) {
    // Bind names where defer is declared, read their values where it executes.
    // Later shadowing must never retarget an earlier defer.
    for i := len(c.deferred)-1; i >= base; i -= 1 {
        action := c.deferred[i]
        symbols, actions, loops := c.symbols, c.deferred, c.loops
        was_in_defer := c.in_defer
        c.symbols = {}
        append(&c.symbols, ..action.symbols)
        c.deferred = {}
        c.loops = {}
        c.in_defer = true
        lower_stmt(c, action.stmt)
        c.symbols, c.deferred, c.loops = symbols, actions, loops
        c.in_defer = was_in_defer
    }
}

lower_stmt :: proc(c: ^Checker, stmt: ^ast.Stmt) -> (terminates: bool) {
    if stmt == nil { return false }
    p, pos := c.p, stmt.pos
    #partial switch s in stmt.derived {
    case ^ast.Empty_Stmt:
    case ^ast.Block_Stmt:
        if s.label != nil { diag(c.program, pos, "B1200", "labelled blocks are not yet supported") }
        symbols, actions := len(c.symbols), len(c.deferred)
        c.depth += 1
        for child in s.stmts {
            ended := lower_stmt(c, child) // Still check unreachable source.
            terminates = terminates || ended
        }
        if !terminates { emit_deferred(c, actions) }
        resize(&c.symbols, symbols)
        resize(&c.deferred, actions)
        c.depth -= 1
    case ^ast.Value_Decl:
        if !s.is_mutable && !s.is_using && len(s.attributes)==0 {
            if len(s.names)!=1 || len(s.values)!=1 { diag(c.program,pos,"B1201","local constants require one name and one initializer"); break }
            global:=Global_Constant{declaration=s}
            value:=resolve_global_constant(c,&global)
            name:=ident_name(s.names[0])
            if name=="" || reserved_source_name(name) { diag(c.program,pos,"B1201","invalid local constant name"); break }
            if old,ok:=lookup(c,name);ok && old.depth==c.depth { diag(c.program,pos,"B1002","redeclaration in the same scope"); break }
            stored:=new(Constant_Value); stored^=value
            append(&c.symbols,Symbol{name=name,depth=c.depth,constant=stored})
            break
        }
        if s.is_using || len(s.attributes) != 0 {
            diag(c.program, pos, "B1201", "using declarations and local attributes are not supported")
            break
        }
        if len(s.values) != 0 && len(s.values) != len(s.names) {
            diag(c.program, pos, "B1202", "declaration arity mismatch")
            break
        }
        type := Type.Void
        if s.type != nil { type = resolve_type(c.program, s.type) }
        values := make([]Value_Id, len(s.names))
        for name, i in s.names {
            if len(s.values) == 0 {
                if type == .Void { diag(c.program, pos, "B1203", "declaration needs a type or initializer"); type = .Int }
                values[i] = constant(p, type, 0, name.pos)
            } else { values[i] = lower_expr(c, s.values[i], type) }
            if value_type(p, values[i]) == .Void { diag(c.program, pos, "B1204", "cannot store a void value") }
        }
        // New names are not visible in their own or sibling initializers.
        for expr, i in s.names {
            name := ident_name(expr)
            if name == "" { diag(c.program, expr.pos, "B1205", "expected identifier"); continue }
            slot := new_slot(p, name, value_type(p, values[i]))
            store(p, slot, values[i], expr.pos)
            bind(c, name, slot, true, expr.pos)
        }
    case ^ast.Assign_Stmt:
        if len(s.lhs) != len(s.rhs) { diag(c.program, pos, "B1206", "assignment arity mismatch"); break }
        slots := make([]Symbol, len(s.lhs))
        values := make([]Value_Id, len(s.rhs))
        for lhs, i in s.lhs {
            name := ident_name(lhs)
            if name == "_" { values[i] = lower_expr(c, s.rhs[i]); continue }
            symbol, ok := lookup(c, name)
            if !ok { diag(c.program, lhs.pos, "B1207", "assignment target must be a declared local"); continue }
            if !symbol.mutable { diag(c.program, lhs.pos, "B1208", "cannot assign to an immutable binding"); continue }
            slots[i] = symbol
            type := p.slots[symbol.slot].type
            if s.op.kind == .Eq { values[i] = lower_expr(c, s.rhs[i], type) }
            else {
                op := binary_op(s.op.kind)
                if op == .Nop || len(s.lhs) != 1 || type == .Bool {
                    diag(c.program, pos, "B1209", "unsupported compound assignment"); continue
                }
                a := load(p, symbol.slot, lhs.pos)
                b := lower_expr(c, s.rhs[i], type)
                if op == .Div || op == .Rem { reject_zero_divisor(c, s.rhs[i]) }
                values[i] = emit(p, Instruction{op=op, type=type, a=a, b=b, pos=pos})
            }
        }
        for lhs, i in s.lhs {
            if ident_name(lhs) != "_" && values[i] != 0 { store(p, slots[i].slot, values[i], lhs.pos) }
        }
    case ^ast.Expr_Stmt:
        value := lower_expr(c, s.expr)
        if p.code[value].op != .Call && p.code[value].op != .Assert {
            diag(c.program, pos, "B1210", "only procedure calls may be used as expression statements")
        }
    case ^ast.Return_Stmt:
        if c.in_defer { diag(c.program, pos, "B1211", "return cannot leave a deferred statement"); break }
        value: Value_Id
        if p.result == .Void {
            if len(s.results) != 0 { diag(c.program, pos, "B1212", "void procedure cannot return a value") }
        } else {
            if len(s.results) != 1 { diag(c.program, pos, "B1213", "expected one return value") }
            else { value = lower_expr(c, s.results[0], p.result) }
        }
        // The return expression is evaluated before deferred side effects.
        emit_deferred(c, 0)
        emit(p, Instruction{op=.Return, a=value, pos=pos})
        terminates = true
    case ^ast.Defer_Stmt:
        if c.in_defer { diag(c.program, pos, "B1214", "nested defer is outside the supported milestone"); break }
        snapshot := make([]Symbol, len(c.symbols))
        copy(snapshot, c.symbols[:])
        append(&c.deferred, Deferred{s.stmt, snapshot})
    case ^ast.If_Stmt:
        if s.label != nil { diag(c.program, pos, "B1215", "labelled if is not yet supported") }
        symbols, actions := len(c.symbols), len(c.deferred)
        c.depth += 1
        lower_stmt(c, s.init)
        cond := lower_expr(c, s.cond, .Bool)
        yes, no, done := new_label(p), new_label(p), new_label(p)
        emit(p, Instruction{op=.Branch, a=cond, target=yes, otherwise=no, pos=pos})
        mark(p, yes, pos)
        yes_ends := lower_stmt(c, s.body)
        if !yes_ends { jump(p, done, pos) }
        mark(p, no, pos)
        no_ends := lower_stmt(c, s.else_stmt)
        if !no_ends { jump(p, done, pos) }
        mark(p, done, pos)
        terminates = yes_ends && no_ends
        if !terminates { emit_deferred(c, actions) }
        resize(&c.symbols, symbols)
        resize(&c.deferred, actions)
        c.depth -= 1
    case ^ast.For_Stmt:
        if s.label != nil { diag(c.program, pos, "B1216", "labelled for is not yet supported") }
        symbols, actions := len(c.symbols), len(c.deferred)
        c.depth += 1
        lower_stmt(c, s.init)
        test, body, post, done := new_label(p), new_label(p), new_label(p), new_label(p)
        jump(p, test, pos)
        mark(p, test, pos)
        cond := constant(p, .Bool, 1, pos)
        if s.cond != nil { cond = lower_expr(c, s.cond, .Bool) }
        emit(p, Instruction{op=.Branch, a=cond, target=body, otherwise=done, pos=pos})
        mark(p, body, pos)
        append(&c.loops, Loop{done, post, len(c.deferred)})
        body_ends := lower_stmt(c, s.body)
        pop(&c.loops)
        if !body_ends { jump(p, post, pos) }
        mark(p, post, pos)
        lower_stmt(c, s.post)
        jump(p, test, pos)
        mark(p, done, pos)
        emit_deferred(c, actions)
        resize(&c.symbols, symbols)
        resize(&c.deferred, actions)
        c.depth -= 1
    case ^ast.Range_Stmt:
        if s.label != nil || s.reverse || s.init != nil || len(s.vals) != 1 {
            diag(c.program, pos, "B1217", "expected a simple one-variable numeric range"); break
        }
        range, ok := s.expr.derived.(^ast.Binary_Expr)
        if !ok || (range.op.kind != .Range_Half && range.op.kind != .Range_Full) {
            diag(c.program, pos, "B1218", "only numeric half-open and inclusive ranges are supported"); break
        }
        symbols, actions := len(c.symbols), len(c.deferred)
        c.depth += 1
        type := guess_type(c, range.left)
        if type == .Void { type = guess_type(c, range.right) }
        if type == .Void { type = .Int }
        lo := lower_expr(c, range.left, type)
        hi := lower_expr(c, range.right, type)
        if type == .Bool { diag(c.program, pos, "B1219", "numeric range cannot use bool") }
        iterator := new_slot(p, ident_name(s.vals[0]), type)
        store(p, iterator, lo, pos)
        bind(c, ident_name(s.vals[0]), iterator, false, s.vals[0].pos)
        test, body, post, step, done := new_label(p), new_label(p), new_label(p), new_label(p), new_label(p)
        inclusive := range.op.kind == .Range_Full
        jump(p, test, pos)
        mark(p, test, pos)
        current := load(p, iterator, pos)
        condition := emit(p, Instruction{op=.Le if inclusive else .Lt, type=.Bool, a=current, b=hi, pos=pos})
        emit(p, Instruction{op=.Branch, a=condition, target=body, otherwise=done, pos=pos})
        mark(p, body, pos)
        append(&c.loops, Loop{done, post, len(c.deferred)})
        body_ends := lower_stmt(c, s.body)
        pop(&c.loops)
        if !body_ends { jump(p, post, pos) }
        mark(p, post, pos)
        if inclusive {
            // Test before increment: an inclusive MAX endpoint must terminate.
            last := load(p, iterator, pos)
            at_end := emit(p, Instruction{op=.Eq, type=.Bool, a=last, b=hi, pos=pos})
            emit(p, Instruction{op=.Branch, a=at_end, target=done, otherwise=step, pos=pos})
        } else { jump(p, step, pos) }
        mark(p, step, pos)
        old := load(p, iterator, pos)
        one := constant(p, type, 1, pos)
        next := emit(p, Instruction{op=.Add, type=type, a=old, b=one, pos=pos})
        store(p, iterator, next, pos)
        jump(p, test, pos)
        mark(p, done, pos)
        emit_deferred(c, actions)
        resize(&c.symbols, symbols)
        resize(&c.deferred, actions)
        c.depth -= 1
    case ^ast.Branch_Stmt:
        if c.in_defer || len(c.loops) == 0 || s.label != nil || (s.tok.kind != .Break && s.tok.kind != .Continue) {
            diag(c.program, pos, "B1220", "break/continue requires an enclosing loop and no label"); break
        }
        loop := c.loops[len(c.loops)-1]
        emit_deferred(c, loop.defer_base)
        jump(p, loop.done if s.tok.kind == .Break else loop.next, pos)
        terminates = true
    case:
        diag(c.program, pos, "B1221", fmt.aprintf("unsupported statement %T", stmt.derived))
    }
    return
}
