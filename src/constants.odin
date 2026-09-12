package main

import "core:fmt"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// Source constants are mathematical integers. They must not inherit the
// wrapping semantics of runtime IR values. .Void is an untyped integer here.
Constant_Kind :: enum { Unknown, Integer, Boolean, Invalid }
Constant_Value :: struct {
    kind: Constant_Kind,
    type: Type,
    integer: big.Int,
    boolean: bool,
}
constant_error :: proc(c: ^Checker, pos: tokenizer.Pos, message: string) -> Constant_Value {
    diag(c.program, pos, "B1300", message)
    return Constant_Value{kind=.Invalid}
}
constant_fits :: proc(value: Constant_Value, type: Type) -> bool {
    n := value.integer
    if value.kind == .Boolean { return type == .Bool }
    if value.kind != .Integer || !is_integer(type) { return false }
    if is_signed(type) {
        value, err := big.get_i64(&n)
        return err == nil && value >= signed_minimum(type) && value <= signed_maximum(type)
    }
    value, err := big.get_u64(&n)
    return err == nil && value <= type_mask(type)
}
constant_bits :: proc(value: Constant_Value, type: Type) -> u64 {
    if value.kind == .Boolean { return u64(value.boolean) }
    n := value.integer
    if is_signed(type) { x, _ := big.get_i64(&n); return transmute(u64)x }
    x, _ := big.get_u64(&n)
    return x
}
materialize_constant :: proc(c: ^Checker, value: Constant_Value, want: Type, pos: tokenizer.Pos) -> Value_Id {
    type := value.type
    if type == .Void { type = want if want != .Void else .Int }
    if value.kind == .Invalid { return constant(c.p, type if type != .Void else .Int, 0, pos) }
    if want != .Void && type != want {
        diag(c.program, pos, "B1301", fmt.aprintf("constant has type %v, expected %v", type, want))
    }
    if !constant_fits(value, type) {
        diag(c.program, pos, "B1302", fmt.aprintf("constant is not representable as %v", type))
        return constant(c.p, type, 0, pos)
    }
    return constant(c.p, type, constant_bits(value, type), pos)
}
constant_expression :: proc(c: ^Checker, expr: ^ast.Expr) -> Constant_Value {
    if expr == nil { return {} }
    if cached, ok := c.constant_cache[expr]; ok { return cached }
    if c.constant_depth >= 512 { return constant_error(c, expr.pos, "constant expression exceeds the 512-level nesting budget") }
    c.constant_depth += 1
    result := constant_expression_inner(c, expr)
    c.constant_depth -= 1
    if result.kind == .Integer {
        bits, err := big.count_bits(&result.integer)
        if err != nil || bits > 16384 { result = constant_error(c, expr.pos, "constant exceeds the 16384-bit resource budget") }
    }
    c.constant_cache[expr] = result
    return result
}
constant_expression_inner :: proc(c: ^Checker, expr: ^ast.Expr) -> Constant_Value {
    pos := expr.pos
    #partial switch e in expr.derived {
    case ^ast.Paren_Expr: return constant_expression(c, e.expr)
    case ^ast.Ident:
        if e.name == "true" || e.name == "false" { return Constant_Value{kind=.Boolean, type=.Bool, boolean=e.name=="true"} }
        if symbol, ok := lookup(c, e.name); ok {
            if symbol.constant!=nil { return symbol.constant^ }
            return {}
        }
        if global,ok:=c.globals[e.name];ok { return resolve_global_constant(c,global) }
    case ^ast.Basic_Lit:
        if e.tok.kind != .Integer { return {} }
        text, _ := strings.replace_all(e.tok.text, "_", "")
        base: i8 = 10
        if len(text)>2 && text[0]=='0' {
            switch text[1] {
            case 'x','X': base=16
            case 'b','B': base=2
            case 'o','O': base=8
            case 'd','D': base=10
            }
            if text[1]<'0' || text[1]>'9' { text=text[2:] }
        }
        result := Constant_Value{kind=.Integer}
        if len(text)>5000 { return constant_error(c, pos, "integer literal exceeds the resource budget") }
        if err := big.atoi(&result.integer, text, base); err != nil { return constant_error(c, pos, "invalid integer literal") }
        return result
    case ^ast.Unary_Expr:
        a := constant_expression(c, e.expr)
        if a.kind == .Unknown || a.kind == .Invalid { return a }
        result := Constant_Value{kind=a.kind, type=a.type}
        err: big.Error
        #partial switch e.op.kind {
        case .Not:
            if a.kind != .Boolean { return constant_error(c,pos,"logical not requires bool") }
            result.boolean = !a.boolean
        case .Add, .Sub, .Xor:
            if a.kind != .Integer { return constant_error(c,pos,"integer unary operation requires an integer") }
            if e.op.kind == .Add { return a }
            if e.op.kind == .Sub {
                if a.type != .Void && !is_signed(a.type) { return constant_error(c,pos,"an unsigned constant cannot be negated") }
                err = big.neg(&result.integer, &a.integer)
            } else {
                if a.type == .Void { return constant_error(c,pos,"bitwise not requires a typed constant") }
                bits := normalize_bits(a.type,~constant_bits(a,a.type))
                if is_signed(a.type) { err = big.set(&result.integer, transmute(i64)bits) }
                else { err = big.set(&result.integer, bits) }
            }
        case: return {}
        }
        if err != nil { return constant_error(c,pos,"constant arithmetic failed") }
        if result.type != .Void && !constant_fits(result,result.type) { return constant_error(c,pos,"typed constant overflow") }
        return result
    case ^ast.Binary_Expr:
        // Check both sides even for logical short-circuit: type/constant errors
        // are compile-time errors, whereas runtime effects remain conditional.
        a,b := constant_expression(c,e.left), constant_expression(c,e.right)
        if a.kind == .Invalid { return a }
        if b.kind == .Invalid { return b }
        if a.kind == .Unknown || b.kind == .Unknown { return {} }
        if a.kind != b.kind { return constant_error(c,pos,"incompatible constant operand kinds") }
        type := a.type if a.type != .Void else b.type
        if a.type != .Void && b.type != .Void && a.type != b.type { return constant_error(c,pos,"distinct typed constants require an explicit conversion") }
        if type != .Void && (!constant_fits(a,type) || !constant_fits(b,type)) { return constant_error(c,pos,"constant operand is not representable in the operation's type") }
        if a.kind == .Boolean {
            result := Constant_Value{kind=.Boolean,type=.Bool}
            #partial switch e.op.kind {
            case .Cmp_And: result.boolean = a.boolean && b.boolean
            case .Cmp_Or: result.boolean = a.boolean || b.boolean
            case .Cmp_Eq: result.boolean = a.boolean == b.boolean
            case .Not_Eq: result.boolean = a.boolean != b.boolean
            case: return constant_error(c,pos,"unsupported boolean constant operation")
            }
            return result
        }
        op := binary_op(e.op.kind)
        if op == .Nop { return {} }
        result := Constant_Value{kind=.Integer,type=type}
        err: big.Error
        #partial switch op {
        case .Add: err=big.add(&result.integer,&a.integer,&b.integer)
        case .Sub: err=big.sub(&result.integer,&a.integer,&b.integer)
        case .Mul: err=big.mul(&result.integer,&a.integer,&b.integer)
        case .Div: err=big.divmod(&result.integer,nil,&a.integer,&b.integer)
        case .Rem: err=big.divmod(nil,&result.integer,&a.integer,&b.integer)
        case .And: err=big.bit_and(&result.integer,&a.integer,&b.integer)
        case .Or: err=big.bit_or(&result.integer,&a.integer,&b.integer)
        case .Xor: err=big.bit_xor(&result.integer,&a.integer,&b.integer)
        case .And_Not:
            inverted: big.Int
            err=big.bit_complement(&inverted,&b.integer)
            if err==nil { err=big.bit_and(&result.integer,&a.integer,&inverted) }
        case .Eq,.Ne,.Lt,.Le,.Gt,.Ge:
            order: int
            order,err=big.compare(&a.integer,&b.integer)
            result.kind=.Boolean
            result.type=.Bool
            #partial switch op {
            case .Eq: result.boolean=order==0
            case .Ne: result.boolean=order!=0
            case .Lt: result.boolean=order<0
            case .Le: result.boolean=order<=0
            case .Gt: result.boolean=order>0
            case .Ge: result.boolean=order>=0
            }
        }
        if err != nil { return constant_error(c,pos,fmt.aprintf("constant arithmetic: %v",err)) }
        if result.type != .Void && !constant_fits(result,result.type) { return constant_error(c,pos,"typed constant overflow") }
        return result
    case ^ast.Call_Expr:
        type := parse_type_name(ident_name(e.expr))
        if type==.Void || len(e.args)!=1 { return {} }
        if _,shadowed:=lookup(c,ident_name(e.expr)); shadowed { return {} }
        value := constant_expression(c,e.args[0])
        if value.kind==.Unknown || value.kind==.Invalid { return value }
        if !constant_fits(value,type) { return constant_error(c,pos,"constant conversion is not representable in the destination type") }
        value.type=type
        return value
    case ^ast.Type_Cast:
        type := parse_type_name(ident_name(e.type))
        if type==.Void { return {} }
        value := constant_expression(c,e.expr)
        if value.kind==.Unknown || value.kind==.Invalid { return value }
        if e.tok.kind==.Transmute {
            if !is_integer(type) || !is_integer(value.type) || bit_width(type)!=bit_width(value.type) { return constant_error(c,pos,"constant transmute requires typed equal-width integers") }
            bits:=normalize_bits(type,constant_bits(value,value.type))
            result:=Constant_Value{kind=.Integer,type=type}
            err: big.Error
            if is_signed(type) { err=big.set(&result.integer,transmute(i64)bits) }
            else { err=big.set(&result.integer,bits) }
            if err!=nil { return constant_error(c,pos,"constant transmute failed") }
            return result
        }
        if !constant_fits(value,type) { return constant_error(c,pos,"constant conversion is not representable in the destination type") }
        value.type=type
        return value
    case ^ast.Ternary_If_Expr:
        condition:=constant_expression(c,e.cond)
        a,b:=constant_expression(c,e.x),constant_expression(c,e.y)
        if condition.kind==.Invalid { return condition }
        if a.kind==.Invalid { return a }
        if b.kind==.Invalid { return b }
        if condition.kind==.Unknown || a.kind==.Unknown || b.kind==.Unknown { return {} }
        if condition.kind!=.Boolean || a.kind!=b.kind { return constant_error(c,pos,"invalid conditional constant types") }
        type:=a.type if a.type!=.Void else b.type
        if a.type!=.Void && b.type!=.Void && a.type!=b.type { return constant_error(c,pos,"conditional branches have distinct types") }
        if type!=.Void && (!constant_fits(a,type)||!constant_fits(b,type)) { return constant_error(c,pos,"conditional branch constant is not representable") }
        result:=a if condition.boolean else b
        result.type=type
        return result
    }
    return {}
}

Global_Constant :: struct {
    declaration: ^ast.Value_Decl,
    state: enum { Pending, Resolving, Done },
    value: Constant_Value,
}
resolve_global_constant :: proc(c: ^Checker, global: ^Global_Constant) -> Constant_Value {
    if global.state==.Done { return global.value }
    if global.state==.Resolving { return constant_error(c,global.declaration.pos,"cyclic constant dependency") }
    global.state=.Resolving
    value:=constant_expression(c,global.declaration.values[0])
    if value.kind==.Unknown { value=constant_error(c,global.declaration.pos,"initializer is not a supported constant expression") }
    if global.declaration.type!=nil && value.kind!=.Invalid {
        type:=resolve_type(c.program,global.declaration.type)
        if (value.type!=.Void && value.type!=type)||!constant_fits(value,type) {
            value=constant_error(c,global.declaration.pos,"typed constant declaration is not representable or has a distinct initializer type")
        } else { value.type=type }
    }
    global.state=.Done
    global.value=value
    return value
}

reject_zero_divisor :: proc(c: ^Checker, expr: ^ast.Expr) {
    value := constant_expression(c, expr)
    if value.kind == .Integer {
        zero, err := big.is_zero(&value.integer)
        if err == nil && zero { diag(c.program, expr.pos, "B1023", "constant divisor must not be zero") }
    }
}
