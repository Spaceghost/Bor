package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"

Symbol :: struct {
    name: string,
    slot: Slot_Id,
    depth: int,
    mutable: bool,
    constant: ^Constant_Value,
}
Deferred :: struct { stmt: ^ast.Stmt, symbols: []Symbol }
Loop :: struct { done, next: Label_Id, defer_base: int }
Checker :: struct {
    program: ^Program,
    p: ^Procedure,
    symbols: [dynamic]Symbol,
    depth: int,
    deferred: [dynamic]Deferred,
    loops: [dynamic]Loop,
    in_defer: bool,
    constant_cache: map[^ast.Expr]Constant_Value,
    constant_depth: int,
    globals: map[string]^Global_Constant,
}

ident_name :: proc(e: ^ast.Expr) -> string {
    if e == nil { return "" }
    if id, ok := e.derived.(^ast.Ident); ok { return id.name }
    return ""
}
parse_type_name :: proc(name: string) -> Type {
    switch name {
    case "int": return .Int
    case "i64": return .I64
    case "i8": return .I8
    case "i16": return .I16
    case "i32": return .I32
    case "uint": return .Uint
    case "u64": return .U64
    case "u8": return .U8
    case "u16": return .U16
    case "u32": return .U32
    case "uintptr": return .Uintptr
    case "bool": return .Bool
    }
    return .Void
}
resolve_type :: proc(program: ^Program, expr: ^ast.Expr) -> Type {
    type := parse_type_name(ident_name(expr))
    if type == .Void {
        pos := tokenizer.Pos{}
        if expr != nil { pos = expr.pos }
        diag(program, pos, "B1001", "unsupported type; the scalar profile supports 8/16/32/64-bit integers, int/uint/uintptr, and bool")
    }
    return type
}
lookup :: proc(c: ^Checker, name: string) -> (symbol: Symbol, ok: bool) {
    for i := len(c.symbols)-1; i >= 0; i -= 1 {
        if c.symbols[i].name == name { return c.symbols[i], true }
    }
    return
}
bind :: proc(c: ^Checker, name: string, slot: Slot_Id, mutable: bool, pos: tokenizer.Pos) {
    if name == "_" { return }
    if reserved_source_name(name) { diag(c.program,pos,"B1022","shadowing predeclared scalar names is not supported"); return }
    if old, ok := lookup(c, name); ok && old.depth == c.depth {
        diag(c.program, pos, "B1002", fmt.aprintf("redeclaration of '%s' in the same scope", name))
        return
    }
    append(&c.symbols, Symbol{name=name, slot=slot, depth=c.depth, mutable=mutable})
}
require_type :: proc(c: ^Checker, value: Value_Id, want: Type, pos: tokenizer.Pos) -> Value_Id {
    got := value_type(c.p, value)
    if want != .Void && got != want {
        diag(c.program, pos, "B1003", fmt.aprintf("expected %v, got %v; use an explicit conversion", want, got))
    }
    return value
}

// Do not use a wrapping string-to-integer parser for source literals.
// The cutoff test rejects overflow before multiplication, even above u64.
parse_integer :: proc(text: string) -> (value: u64, ok: bool) {
    base: u64 = 10
    start := 0
    if len(text) > 2 && text[0] == '0' {
        switch text[1] {
        case 'x', 'X': base = 16; start = 2
        case 'b', 'B': base = 2; start = 2
        case 'o', 'O': base = 8; start = 2
        case 'd', 'D': base = 10; start = 2
        }
    }
    digits := 0
    for ch in text[start:] {
        if ch == '_' { continue }
        digit: u64
        if ch >= '0' && ch <= '9' { digit = u64(ch-'0') }
        else if ch >= 'a' && ch <= 'f' { digit = u64(ch-'a')+10 }
        else if ch >= 'A' && ch <= 'F' { digit = u64(ch-'A')+10 }
        else { return 0, false }
        if digit >= base || value > (max(u64)-digit)/base { return 0, false }
        value = value*base+digit
        digits += 1
    }
    return value, digits > 0
}

// .Void here means untyped, not a runtime value of type void.
guess_type :: proc(c: ^Checker, expr: ^ast.Expr) -> Type {
    if expr == nil { return .Void }
    #partial switch e in expr.derived {
    case ^ast.Ident:
        if e.name == "true" || e.name == "false" { return .Bool }
        if s, ok := lookup(c, e.name); ok {
            if s.constant!=nil { return s.constant.type }
            return c.p.slots[s.slot].type
        }
        if global,ok:=c.globals[e.name];ok { return resolve_global_constant(c,global).type }
    case ^ast.Paren_Expr: return guess_type(c, e.expr)
    case ^ast.Unary_Expr:
        if e.op.kind == .Not { return .Bool }
        return guess_type(c, e.expr)
    case ^ast.Call_Expr:
        name := ident_name(e.expr)
        if t := parse_type_name(name); t != .Void { return t }
        if id, ok := c.program.names[name]; ok { return c.program.procs[id].result }
    case ^ast.Binary_Expr:
        if e.op.kind >= .Cmp_Eq && e.op.kind <= .Gt_Eq || e.op.kind == .Cmp_And || e.op.kind == .Cmp_Or { return .Bool }
        a := guess_type(c, e.left)
        if a != .Void { return a }
        return guess_type(c, e.right)
    case ^ast.Type_Cast: return parse_type_name(ident_name(e.type))
    }
    return .Void
}

binary_op :: proc(kind: tokenizer.Token_Kind) -> Op {
    #partial switch kind {
    case .Add, .Add_Eq: return .Add
    case .Sub, .Sub_Eq: return .Sub
    case .Mul, .Mul_Eq: return .Mul
    case .Quo, .Quo_Eq: return .Div
    case .Mod, .Mod_Eq: return .Rem
    case .And, .And_Eq: return .And
    case .Or, .Or_Eq: return .Or
    case .Xor, .Xor_Eq: return .Xor
    case .And_Not, .And_Not_Eq: return .And_Not
    case .Cmp_Eq: return .Eq
    case .Not_Eq: return .Ne
    case .Lt: return .Lt
    case .Lt_Eq: return .Le
    case .Gt: return .Gt
    case .Gt_Eq: return .Ge
    }
    return .Nop
}

lower_expr :: proc(c: ^Checker, expr: ^ast.Expr, want := Type.Void) -> Value_Id {
    if expr == nil {
        diag(c.program, {}, "B1004", "missing expression")
        return constant(c.p, .Int, 0, {})
    }
    value: Value_Id
    known := constant_expression(c, expr)
    if known.kind != .Unknown { value = materialize_constant(c, known, want, expr.pos) }
    else { value = lower_expr_inner(c, expr, want) }
    return require_type(c, value, want, expr.pos)
}
lower_expr_inner :: proc(c: ^Checker, expr: ^ast.Expr, want: Type) -> Value_Id {
    p := c.p
    pos := expr.pos
    #partial switch e in expr.derived {
    case ^ast.Paren_Expr: return lower_expr(c, e.expr, want)
    case ^ast.Ident:
        if e.name == "true" || e.name == "false" { return constant(p, .Bool, u64(e.name == "true"), pos) }
        if symbol, ok := lookup(c, e.name); ok { return load(p, symbol.slot, pos) }
        diag(c.program, pos, "B1005", fmt.aprintf("unknown value '%s'", e.name))
    case ^ast.Basic_Lit:
        if e.tok.kind != .Integer { diag(c.program, pos, "B1006", "unsupported literal; expected an integer"); break }
        bits, ok := parse_integer(e.tok.text)
        type := Type.Int if want == .Void else want
        if !ok || type == .Bool || (is_signed(type) && bits > u64(max(i64))) {
            diag(c.program, pos, "B1007", fmt.aprintf("integer literal is not representable as %v", type))
        }
        return constant(p, type, bits, pos)
    case ^ast.Unary_Expr:
        // The magnitude of INT64_MIN is not itself a signed integer.
        if e.op.kind == .Sub && (want == .Void || is_signed(want)) {
            if literal, ok := e.expr.derived.(^ast.Basic_Lit); ok && literal.tok.kind == .Integer {
                bits, parsed := parse_integer(literal.tok.text)
                if parsed && bits == u64(1)<<63 { return constant(p, .Int if want == .Void else want, bits, pos) }
            }
        }
        expected := want
        op := Op.Nop
        #partial switch e.op.kind {
        case .Sub: op = .Neg
        case .Not: op = .Not; expected = .Bool
        case .Xor: op = .Bit_Not
        case .Add:
            value:=lower_expr(c,e.expr,want)
            if !is_integer(value_type(p,value)) { diag(c.program,pos,"B1009","unary plus requires an integer") }
            return value
        }
        if op == .Nop { diag(c.program, pos, "B1008", "unsupported unary operation"); break }
        a := lower_expr(c, e.expr, expected)
        type := value_type(p, a)
        if type == .Bool && op != .Not { diag(c.program, pos, "B1009", "integer operation applied to bool") }
        return emit(p, Instruction{op=op, type=type, a=a, pos=pos})
    case ^ast.Binary_Expr:
        if e.op.kind == .Cmp_And || e.op.kind == .Cmp_Or {
            // Preserve short-circuiting without GNU statement expressions.
            a := lower_expr(c, e.left, .Bool)
            slot := new_slot(p, "$short_circuit", .Bool)
            store(p, slot, a, pos)
            rhs, done := new_label(p), new_label(p)
            yes, no := rhs, done
            if e.op.kind == .Cmp_Or { yes, no = done, rhs }
            emit(p, Instruction{op=.Branch, a=a, target=yes, otherwise=no, pos=pos})
            mark(p, rhs, pos)
            b := lower_expr(c, e.right, .Bool)
            store(p, slot, b, pos)
            jump(p, done, pos)
            mark(p, done, pos)
            return load(p, slot, pos)
        }
        op := binary_op(e.op.kind)
        if op == .Nop { diag(c.program, pos, "B1010", "unsupported binary operation"); break }
        operand_type := guess_type(c, e.left)
        if operand_type == .Void { operand_type = guess_type(c, e.right) }
        if operand_type == .Void { operand_type = want if !is_compare(op) && want != .Void else .Int }
        a := lower_expr(c, e.left, operand_type)
        b := lower_expr(c, e.right, operand_type)
        if operand_type == .Bool && op != .Eq && op != .Ne { diag(c.program, pos, "B1011", "bool supports only equality and logical operations") }
        if op == .Div || op == .Rem {
            reject_zero_divisor(c, e.right)
        }
        result := Type.Bool if is_compare(op) else operand_type
        return emit(p, Instruction{op=op, type=result, a=a, b=b, pos=pos})
    case ^ast.Call_Expr:
        name := ident_name(e.expr)
        if _, shadowed := lookup(c, name); shadowed {
            diag(c.program, pos, "B1012", "value is not callable")
            break
        }
        if type := parse_type_name(name); type != .Void {
            if len(e.args) != 1 { diag(c.program, pos, "B1013", "conversion requires one argument"); break }
            hint := guess_type(c, e.args[0])
            if hint == .Void { hint = type }
            a := lower_expr(c, e.args[0], hint)
            if (type == .Bool) != (value_type(p, a) == .Bool) { diag(c.program, pos, "B1014", "integer/bool conversions are not supported") }
            return emit(p, Instruction{op=.Cast, type=type, a=a, pos=pos})
        }
        if name == "assert" {
            if !p.has_context { diag(c.program, pos, "B1020", "assert requires an Odin context; this procedure is contextless") }
            if len(e.args) != 1 { diag(c.program, pos, "B1015", "assert requires one boolean argument"); break }
            a := lower_expr(c, e.args[0], .Bool)
            return emit(p, Instruction{op=.Assert, a=a, pos=pos})
        }
        id, ok := c.program.names[name]
        if !ok { diag(c.program, pos, "B1016", fmt.aprintf("unknown procedure '%s'", name)); break }
        callee := &c.program.procs[id]
        if callee.has_context && !p.has_context { diag(c.program, pos, "B1021", "calling an Odin-context procedure from a contextless procedure is unsupported") }
        if len(e.args) != callee.parameter_count || e.ellipsis.kind != .Invalid {
            diag(c.program, pos, "B1017", "procedure argument count mismatch or unsupported variadic expansion")
            break
        }
        // Evaluate before appending the contiguous argument span: nested calls
        // may append their own argument lists while we lower these expressions.
        values := make([]Value_Id, len(e.args))
        for arg, i in e.args { values[i] = lower_expr(c, arg, callee.slots[i].type) }
        span := Span{u32(len(p.arguments)), u32(len(values))}
        append(&p.arguments, ..values)
        return emit(p, Instruction{op=.Call, type=callee.result, callee=id, args=span, pos=pos})
    case ^ast.Type_Cast:
        type := resolve_type(c.program, e.type)
        a := lower_expr(c, e.expr)
        if e.tok.kind != .Cast && e.tok.kind != .Transmute { diag(c.program, pos, "B1018", "unsupported cast") }
        if (type == .Bool) != (value_type(p, a) == .Bool) { diag(c.program, pos, "B1014", "integer/bool conversions are not supported") }
        if e.tok.kind == .Transmute && bit_width(type) != bit_width(value_type(p,a)) {
            diag(c.program,pos,"B1024","transmute requires equal-width types")
        }
        return emit(p, Instruction{op=.Cast, type=type, a=a, pos=pos})
    case ^ast.Ternary_If_Expr:
        type := guess_type(c, e.x)
        if type == .Void { type = guess_type(c, e.y) }
        if type == .Void { type = want if want != .Void else .Int }
        cond := lower_expr(c, e.cond, .Bool)
        yes, no, done := new_label(p), new_label(p), new_label(p)
        slot := new_slot(p, "$conditional", type)
        emit(p, Instruction{op=.Branch, a=cond, target=yes, otherwise=no, pos=pos})
        mark(p, yes, pos)
        a := lower_expr(c, e.x, type)
        store(p, slot, a, pos)
        jump(p, done, pos)
        mark(p, no, pos)
        b := lower_expr(c, e.y, type)
        store(p, slot, b, pos)
        jump(p, done, pos)
        mark(p, done, pos)
        return load(p, slot, pos)
    case:
        diag(c.program, pos, "B1019", fmt.aprintf("unsupported expression %T", expr.derived))
    }
    return constant(p, .Int if want == .Void else want, 0, pos)
}

collect_and_check :: proc(files: []^ast.File) -> Program {
    program: Program
    bodies: [dynamic]^ast.Proc_Lit
    globals: map[string]^Global_Constant
    global_order: [dynamic]^Global_Constant
    declared: map[string]bool
    for file in files {
        if len(file.tags) != 0 { diag(&program, file.pos, "B1100", "conditional file tags are not supported") }
        for stmt in file.decls {
            if _, empty := stmt.derived.(^ast.Empty_Stmt); empty { continue }
            decl, ok := stmt.derived.(^ast.Value_Decl)
            if !ok { diag(&program, stmt.pos, "B1101", "only procedures and scalar constants are supported at package scope; imports are not silently substituted"); continue }
            if decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 || decl.is_using {
                diag(&program, decl.pos, "B1102", "expected a single immutable procedure or constant declaration"); continue
            }
            name := ident_name(decl.names[0])
            if name=="" || name=="_" || reserved_source_name(name) { diag(&program,decl.pos,"B1103","invalid or reserved declaration name"); continue }
            if declared[name] { diag(&program,decl.pos,"B1104","duplicate package declaration"); continue }
            declared[name]=true
            literal, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
            if !is_proc {
                if len(decl.attributes)!=0 { diag(&program,decl.pos,"B1106","constant attributes are unsupported") }
                global:=new(Global_Constant)
                global.declaration=decl
                globals[name]=global
                append(&global_order,global)
                continue
            }
            if literal.body==nil || decl.type!=nil { diag(&program,decl.pos,"B1103","expected a procedure with an inferred signature and body"); continue }
            if literal.tags!={} || literal.type.tags!={} || literal.inlining!=.None || literal.tailing!=.None {
                diag(&program,decl.pos,"B1116","procedure directives and forced inlining/tailing are not supported")
            }
            signature := literal.type
            if signature.generic || len(literal.where_clauses) > 0 || signature.diverging {
                diag(&program, decl.pos, "B1105", "polymorphic, constrained, and diverging signatures are not yet supported")
            }
            p := Procedure{name=name, has_context=true}
            for attr in decl.attributes {
                for element in attr.elems {
                    if ident_name(element) == "export" { p.exported = true }
                    else { diag(&program, element.pos, "B1106", "unsupported procedure attribute") }
                }
            }
            if raw_cc, has_cc := signature.calling_convention.(string); has_cc {
                cc := raw_cc[1:len(raw_cc)-1]
                p.has_context = cc == "odin" || cc == ""
                if cc != "" && cc != "c" && cc != "contextless" && cc != "odin" { diag(&program, decl.pos, "B1107", "unsupported calling convention") }
                if p.exported && cc != "c" { diag(&program, decl.pos, "B1108", "exported procedures require proc \"c\" for an explicit ABI") }
            } else if p.exported { diag(&program, decl.pos, "B1108", "exported procedures require proc \"c\"") }
            if p.exported && !valid_export_name(name) { diag(&program,decl.pos,"B1117","export name collides with C99 or the generated runtime namespace") }
            if signature.params != nil {
                for field in signature.params.list {
                    if field.default_value != nil || field.flags != {} { diag(&program, field.pos, "B1109", "parameter defaults and modifiers are unsupported") }
                    type := resolve_type(&program, field.type)
                    for param in field.names {
                        param_name := ident_name(param)
                        if param_name == "" { diag(&program, param.pos, "B1110", "parameter requires an ordinary name") }
                        new_slot(&p, param_name, type)
                    }
                }
            }
            p.parameter_count = len(p.slots)
            if signature.results != nil && len(signature.results.list) > 0 {
                if len(signature.results.list) != 1 { diag(&program, decl.pos, "B1111", "multiple return values are not yet supported") }
                else {
                    field := signature.results.list[0]
                    if len(field.names) != 0 || field.default_value != nil { diag(&program, field.pos, "B1112", "named/default results are not yet supported") }
                    p.result = resolve_type(&program, field.type)
                }
            }
            if name == "main" && (p.parameter_count != 0 || p.result != .Void || p.exported) { diag(&program, decl.pos, "B1113", "main must be a non-exported proc()") }
            emit(&p, Instruction{op=.Nop}) // 0 is never a value.
            program.names[name] = Proc_Id(len(program.procs))
            append(&program.procs, p)
            append(&bodies, literal)
        }
    }
    if len(program.procs) == 0 { diag(&program, {}, "B1114", "no procedures found") }
    if len(program.diagnostics) != 0 { return program }
    constants_checker:=Checker{program=&program,globals=globals}
    for global in global_order { resolve_global_constant(&constants_checker,global) }
    if len(program.diagnostics)!=0 { return program }
    // Signatures are frozen before bodies: recursion and forward calls work.
    for &p, i in program.procs {
        c := Checker{program=&program, p=&p, globals=globals}
        for slot, j in p.slots[:p.parameter_count] { bind(&c, slot.name, Slot_Id(j), false, bodies[i].pos) }
        terminated := lower_stmt(&c, bodies[i].body)
        if !terminated {
            if p.result == .Void { emit(&p, Instruction{op=.Return, pos=bodies[i].end}) }
            else { diag(&program, bodies[i].end, "B1115", "not every reachable path returns a value") }
        }
    }
    return program
}
