package semantics

@(export)
sum_upto :: proc "c" (n: int) -> int {
    total := 0
    for i in 0..<n { total += i }
    return total
}
fib :: proc "contextless" (n: int) -> int {
    if n < 2 { return n }
    return fib(n-1)+fib(n-2)
}
@(export)
recursive :: proc "c" (n: int) -> int { return fib(n) }
@(export)
gcd :: proc "c" (a,b: int) -> int {
    x,y := a,b
    for y != 0 { x,y = y,x%y }
    return x
}
@(export)
parallel :: proc "c" (a,b: int) -> int {
    x,y := a,b
    x,y = y,x
    return x*100+y
}
@(export)
branch_merge :: proc "c" (n: int) -> int {
    x := 13
    if n > 0 { x=7 } else { x=11 }
    return x+n
}
combine :: proc "contextless" (a,b,c: int) -> int { return a*100+b*10+c }
identity :: proc "contextless" (n: int) -> int { return n }
@(export)
nested_calls :: proc "c" (n: int) -> int { return combine(identity(n), identity(n+1), identity(n+2)) }
explode :: proc "contextless" () -> bool { for {}; return true }
@(export)
short_circuit :: proc "c" () -> bool {
    a := false && explode()
    b := true || explode()
    return !a && b
}
@(export)
ternary :: proc "c" (n: int) -> int {
    x := 7 if n>0 else 11
    return x
}
@(export)
ternary_lazy :: proc "c" () -> bool { return true if true else explode() }
@(export)
zero_init :: proc "c" () -> int {
    x: int
    b: bool
    if b { return 99 }
    return x
}
@(export)
defer_lifo :: proc "c" () -> int {
    x := 1
    {
        defer x *= 2
        defer x += 3
        x=5
    }
    return x
}
@(export)
defer_return :: proc "c" () -> int { x:=3; defer x=90; return x }
@(export)
defer_binding :: proc "c" () -> int {
    x:=2
    {
        defer x += 3
        { x:=100; if x!=100 { return -99 } }
        x=7
    }
    return x
}
@(export)
defer_loop :: proc "c" () -> int {
    total:=0
    for i in 0..<6 {
        defer total += i
        if i==2 { continue }
        if i==4 { break }
        total += 10
    }
    return total
}
@(export)
u64_wrap :: proc "c" (n:u64) -> u64 { return n+3 }
@(export)
i64_wrap :: proc "c" (n:i64) -> i64 { return n+3 }
@(export)
signed_division :: proc "c" (a,b:int) -> int { return (a/b)*100+a%b }
@(export)
inclusive :: proc "c" (n:int) -> int { total:=0; for i in 0..=n { total+=i }; return total }
@(export)
inclusive_max :: proc "c" () -> int {
    n:=u64(18446744073709551615)
    count:=0
    for i in n-1..=n {
        count+=1
        if count>3 { break }
        if i<n-1 { return -99 }
    }
    return count
}
@(export)
nested_loops :: proc "c" (n:int) -> int {
    total:=0
    for i in 0..<n {
        for j in 0..<n {
            if i==j { continue }
            if j==3 { break }
            total+=i+j
        }
    }
    return total
}
@(export)
all_returns :: proc "c" (b:bool) -> int { if b { return 3 } else { return 5 } }
@(export)
bit_cast :: proc "c" (n:u64) -> i64 { return transmute(i64)n }
@(export)
bit_operations :: proc "c" (a,b:u64) -> u64 { return (~a & b) | (a ~ b) | (a &~ b) }
@(export)
for_clause :: proc "c" (n:int) -> int { total:=0; for i:=0; i<n; i+=1 { total+=i*2 }; return total }
@(export)
if_initializer :: proc "c" (n:int) -> int { if x:=n+1; x>4 { return x } else { return 0 } }
@(export)
unsigned_operand :: proc "c" (n:u64) -> u64 { return 3+n }
@(export)
bool_logic :: proc "c" (a,b:bool) -> bool { return (a==b) || (a && !b) }
@(export)
signed_min :: proc "c" () -> i64 { return -9223372036854775808 }
@(export)
late_defer :: proc "c" () -> int {
    x:=1
    { defer if x!=9 { for {} }; x=9 }
    return x
}
@(export)
empty_range :: proc "c" () -> int { total:=0; lo,hi:=4,2; for i in lo..<hi { total+=i }; return total }

// Odin specifies wrap, rather than a trap, for the signed MIN / -1 case.
@(export) divide_edge :: proc "c" (a: i64, b: i64) -> i64 { return a/b }
@(export) remainder_edge :: proc "c" (a: i64, b: i64) -> i64 { return a%b }
@(export) exact_constants :: proc "c" () -> u64 {
    // Intermediates exceed u64: only the final materialization is bounded.
    value :: (18446744073709551615 * 1000) / 1000
    return value
}
NEXT :: FIRST + 1
FIRST :: 41
@(export) forward_constant :: proc "c" () -> int { return NEXT }
@(export) local_constant :: proc "c" () -> u64 {
    x : u64 : 18446744073709551615
    return x
}

@(export) multiply_u16 :: proc "c" (x, y: u16) -> u16 { return x*y }
@(export) multiply_u32 :: proc "c" (x, y: u32) -> u32 { return x*y }
@(export) wrap_i8 :: proc "c" (x: i8) -> i8 { return x+4 }
@(export) wrap_i16 :: proc "c" (x: i16) -> i16 { return x+4 }
@(export) wrap_i32 :: proc "c" (x: i32) -> i32 { return x+4 }
@(export) roundtrip_narrow :: proc "c" (x: i64) -> i64 { return i64(i8(x)) }
@(export) transmute_narrow :: proc "c" (x: u8) -> i8 { return transmute(i8)x }
@(export) bitnot_u8 :: proc "c" () -> u8 { return ~u8(0) }
@(export) bitnot_i8 :: proc "c" () -> i8 { return ~i8(0) }
@(export) inclusive_i8 :: proc "c" () -> int {
    n := 0
    for i in i8(126)..=i8(127) { n += 1 }
    return n
}
