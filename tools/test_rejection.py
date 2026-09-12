#!/usr/bin/env python3
"""Reject invalid/unsupported source, retain diagnostics, and preserve output on error."""
from __future__ import annotations
import argparse, json, os, pathlib, subprocess, sys
from test_semantics import command, ROOT

# True means valid native Odin but intentionally outside Borr's current profile.
CASES = [
('undefined', 'main :: proc() { x = 1 }', False),
('wrong_type', 'main :: proc() { x: bool = 1; _ = x }', False),
('distinct_types', 'f :: proc(x: i64) -> int { return x }', False),
('param_assignment', 'f :: proc(x: int) { x = 1 }', False),
('range_assignment', 'main :: proc() { for i in 0..<3 { i = 1 } }', False),
('constant_assignment', 'main :: proc() { x :: 1; x = 2 }', False),
('duplicate_local', 'main :: proc() { x := 1; x := 2; _ = x }', False),
('duplicate_global', 'x :: 1\nx :: 2\nmain :: proc() {}', False),
('duplicate_param', 'f :: proc(a, a: int) {}', False),
('missing_return', 'f :: proc(x: bool) -> int { if x { return 1 } }', False),
('unreachable_invalid', 'f :: proc() -> int { return 1; x = 2 }', False),
('wrong_args', 'f :: proc(x: int) {}\nmain :: proc() { f() }', False),
('void_value', 'f :: proc() {}\nmain :: proc() { x := f(); _ = x }', False),
('bad_expression_stmt', 'main :: proc() { 1 + 2 }', False),
('bad_return', 'main :: proc() { return 1 }', False),
('break_outside', 'main :: proc() { break }', False),
('continue_outside', 'main :: proc() { continue }', False),
('escape_defer', 'main :: proc() { defer { return } }', False),
('assignment_arity', 'main :: proc() { x, y := 1, 2; x, y = 3 }', False),
('literal_overflow', 'main :: proc() { x: u64 = 18446744073709551616; _ = x }', False),
('signed_literal_overflow', 'main :: proc() { x: int = 9223372036854775808; _ = x }', False),
('negative_unsigned', 'main :: proc() { x: u64 = -1; _ = x }', False),
('typed_constant_overflow', 'main :: proc() { x := u64(18446744073709551615) + 1; _ = x }', False),
('constant_cast_overflow', 'main :: proc() { x := i64(u64(18446744073709551615)); _ = x }', False),
('constant_div_zero', 'main :: proc() { x := 1 / 0; _ = x }', False),
('mixed_div_zero', 'f :: proc(x: int) -> int { return x / 0 }', False),
('compound_div_zero', 'main :: proc() { x := 3; x /= 0 }', False),
('constant_cycle', 'A :: B\nB :: A\nmain :: proc() {}', False),
('bool_arithmetic', 'f :: proc(a: bool) -> bool { return a + true }', False),
('bool_order', 'f :: proc(a: bool) -> bool { return a < true }', False),
('negative_unsigned_operand', 'f :: proc(a: u64) -> u64 { return a + -1 }', False),
('contextless_call', 'f :: proc() {}\ng :: proc "contextless" () { f() }', False),
('shadowed_call', 'f :: proc() {}\nmain :: proc() { f := 1; f() }', False),
('default_arg', 'f :: proc(a: int = 1) -> int { return a }', True),
('named_result', 'f :: proc() -> (x: int) { return 1 }', True),
('multiple_returns', 'f :: proc() -> (int, int) { return 1, 2 }', True),
('generics', 'f :: proc(a: $T) -> T { return a }', True),
('import', 'import "core:fmt"\nmain :: proc() { fmt.println("test") }', True),
('array', 'f :: proc(a: [3]int) -> int { return a[0] }', True),
('struct', 'V :: struct { x: int }\nf :: proc(a: V) -> int { return a.x }', True),
('pointer', 'f :: proc(a: ^int) -> int { return a^ }', True),
('string', 'f :: proc(a: string) -> int { return len(a) }', True),
('float', 'f :: proc(a: f64) -> f64 { return a }', True),
('global_mutable', 'x: int\nmain :: proc() { x = 1 }', True),
('using', 'V :: struct { x: int }\nf :: proc(using a: V) -> int { return x }', False),
('c_export_collision', '@(export) malloc :: proc "c" () -> int { return 1 }', False),
('nested_defer', 'main :: proc() { defer { defer {} } }', True),
('labelled_loop', 'main :: proc() { outer: for { break outer } }', True),
('int128', 'f :: proc(a: u128) -> u128 { return a }', True),
('narrow_overflow', 'main :: proc() { x: u8 = 256; _ = x }', False),
('narrow_signed_overflow', 'main :: proc() { x: i8 = 128; _ = x }', False),
('transmute_width', 'f :: proc(x: u32) -> u64 { return transmute(u64)x }', False),
]

def test(odin: str, bor: str, out: pathlib.Path) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    report = {'schema': 1, 'cases': []}
    for name, code, valid in CASES:
        source = out / f'{name}.odin'
        source.write_text('package test\n'+code+'\n')
        oracle, _ = command([odin,'check',source,'-file','-no-entry-point'],timeout=20)
        for mode in ('opt','no-opt'):
            output = out / 'sentinel.c'
            output.write_text('/* preserve me on failure */\n')
            args=[bor, 'emit', source, '-o', output]
            if mode=='no-opt': args += ['--no-opt']
            p,_=command(args, timeout=10)
            row={'name':name, 'mode':mode, 'native_valid_expected':valid,'native_returncode':oracle.returncode,
                 'bor_returncode':p.returncode,'diagnostic':p.stderr,'native_diagnostic':oracle.stderr,
                 'output_preserved':output.read_text()=='/* preserve me on failure */\n'}
            row['pass']=p.returncode==1 and bool(p.stderr) and row['output_preserved'] and (oracle.returncode==0)==valid
            report['cases'].append(row)
    # Runtime safety is separately enforced by the bounded interpreter.
    for name, code, args, text in [
        ('step_limit','main :: proc() { for {} }', ['--steps','20'], 'Step_Limit'),
        ('recursion_limit','f :: proc() -> int { return f() }', ['--entry','f'], 'Recursion_Limit'),
        ('assertion','main :: proc() { assert(false) }', [], 'Assertion_Failed'),
        ('div_zero','f :: proc(x: int) -> int { return 1/x }',['--entry','f','--arg','0'],'Arithmetic_Trap')]:
        source=out/f'{name}.odin';source.write_text('package test\n'+code+'\n')
        p,_=command([bor,'eval',source,*args],timeout=10)
        report['cases'].append({'name':name,'pass':p.returncode==1 and text in p.stderr, 'diagnostic':p.stderr})
    # Mixed package names must fail, deterministically.
    mixed=out/'mixed';mixed.mkdir(exist_ok=True)
    (mixed/'a.odin').write_text('package a\nmain :: proc() {}\n')
    (mixed/'b.odin').write_text('package b\nf :: proc() {}\n')
    p,_=command([bor,'check',mixed])
    report['cases'].append({'name':'mixed_packages','pass':p.returncode==1 and 'B0004' in p.stderr,'diagnostic':p.stderr})
    # Output aliases must not destroy source bytes through symlinks or hard links.
    original=out/'original.odin';body='package aliases\nmain :: proc() {}\n';original.write_text(body)
    for kind in ('direct','symlink','hardlink'):
        target=original if kind=='direct' else out/f'{kind}.c'
        if kind!='direct':
            target.unlink(missing_ok=True)
            if kind=='symlink': target.symlink_to(original.resolve())
            else: os.link(original,target)
        p,_=command([bor,'emit',original,'-o',target])
        report['cases'].append({'name':f'output_{kind}','pass':p.returncode==2 and 'B0011' in p.stderr and original.read_text()==body,'diagnostic':p.stderr})
    conditional=out/'selection';conditional.mkdir(exist_ok=True)
    (conditional/'main_windows.odin').write_text('package selection\nmain :: proc() {}\n')
    p,_=command([bor,'check',conditional])
    report['cases'].append({'name':'conditional_filename','pass':p.returncode==1 and 'B0016' in p.stderr,'diagnostic':p.stderr})
    report['summary']={'checks':len(report['cases']),'failures':sum(not r['pass'] for r in report['cases'])}
    (out/'rejection.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['summary']))
    for r in report['cases']:
        if not r['pass']: print(json.dumps(r))
    return not report['summary']['failures']

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--odin',default=os.environ.get('ODIN','odin'));ap.add_argument('--bor',default=str(ROOT/'build/bor'));ap.add_argument('--out',type=pathlib.Path,default=ROOT/'build/rejection')
    a=ap.parse_args()
    try: sys.exit(0 if test(a.odin,a.bor,a.out) else 1)
    except (RuntimeError,subprocess.TimeoutExpired) as e: print(e,file=sys.stderr);sys.exit(1)
