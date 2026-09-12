#!/usr/bin/env python3
"""Deterministic, independent native-Odin / IR / C-backend conformance gate."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, platform, shlex, shutil, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
MASK = (1 << 64)-1
CASES = [
 ('sum_upto', ['int'], 'int', [(10,),(0,),(200,)], [45,0,19900]),
 ('recursive',['int'],'int',[(10,),(0,),(16,)], [55,0,987]),
 ('gcd',['int','int'],'int',[(48,18),(7,3),(0,17)], [6,1,17]),
 ('parallel',['int','int'],'int',[(3,7),(-5,4)], [703,395]),
 ('branch_merge',['int'],'int',[(8,),(-2,),(0,)], [15,9,11]),
 ('nested_calls',['int'],'int',[(2,),(5,)], [234,567]),
 ('short_circuit',[],'bool',[()], [1]),
 ('ternary',['int'],'int',[(1,),(0,)], [7,11]),
 ('ternary_lazy',[],'bool',[()], [1]),
 ('zero_init',[],'int',[()], [0]),
 ('defer_lifo',[],'int',[()], [16]),
 ('defer_return',[],'int',[()], [3]),
 ('defer_binding',[],'int',[()], [10]),
 ('defer_loop',[],'int',[()], [40]),
 ('u64_wrap',['u64'],'u64',[(MASK,),(17,)], [2,20]),
 ('i64_wrap',['i64'],'i64',[((1<<63)-1,),(-7,)], [-(1<<63)+2,-4]),
 ('signed_division',['int','int'],'int',[(-17,5),(17,-5),(-17,-5)], [-302,-298,298]),
 ('inclusive',['int'],'int',[(5,),(0,),(-1,)], [15,0,0]),
 ('inclusive_max',[],'int',[()], [2]),
 ('nested_loops',['int'],'int',[(4,),(0,)], [24,0]),
 ('all_returns',['bool'],'int',[(1,),(0,)], [3,5]),
 ('bit_cast',['u64'],'i64',[(MASK,),(1<<63,)], [-1,-(1<<63)]),
 ('bit_operations',['u64','u64'],'u64',[(5,3),(0,MASK)], [6, MASK]),
 ('for_clause',['int'],'int',[(10,),(0,)], [90,0]),
 ('if_initializer',['int'],'int',[(7,),(1,)], [8,0]),
 ('unsigned_operand',['u64'],'u64',[(5,),(MASK,)], [8,2]),
 ('bool_logic',['bool','bool'],'bool',[(0,0),(0,1),(1,0),(1,1)], [1,0,1,1]),
 ('signed_min',[],'i64',[()], [-(1<<63)]),
 ('late_defer',[],'int',[()], [9]),
 ('empty_range',[],'int',[()], [0]),
 ('divide_edge',['i64','i64'],'i64',[(-(1<<63),-1), (-(1<<63),1)], [-(1<<63),-(1<<63)]),
 ('remainder_edge',['i64','i64'],'i64',[(-(1<<63),-1), (-(1<<63),1)], [0,0]),
 ('exact_constants',[],'u64',[()], [MASK]),
 ('forward_constant',[],'int',[()], [42]),
 ('local_constant',[],'u64',[()], [MASK]),
 ('multiply_u16',['u16','u16'],'u16',[(65535,65535),(65535,2),(200,200)], [1,65534,40000]),
 ('multiply_u32',['u32','u32'],'u32',[(4294967295,4294967295),(65536,65536)], [1,0]),
 ('wrap_i8',['i8'],'i8',[(127,),(-128,),(-1,)], [-125,-124,3]),
 ('wrap_i16',['i16'],'i16',[(32767,),(-32768,),(-1,)], [-32765,-32764,3]),
 ('wrap_i32',['i32'],'i32',[(2147483647,),(-2147483648,),(-1,)], [-2147483645,-2147483644,3]),
 ('roundtrip_narrow',['i64'],'i64',[(128,),(255,),(256,),(257,),(-1,)], [-128,-1,0,1,-1]),
 ('transmute_narrow',['u8'],'i8',[(255,),(128,),(127,)], [-1,-128,127]),
 ('bitnot_u8',[],'u8',[()], [255]),
 ('bitnot_i8',[],'i8',[()], [-1]),
 ('inclusive_i8',[],'int',[()], [2]),

]
TYPES = {**{f'{sign}{bits}':f'{"u" if sign=="u" else ""}int{bits}_t' for sign in 'iu' for bits in (8,16,32)}, 'int':'int64_t','i64':'int64_t','uint':'uint64_t','u64':'uint64_t','uintptr':'uint64_t','bool':'bool'}

def command(argv, *, timeout=60, **kwargs):
    t=time.perf_counter_ns()
    p=subprocess.run([str(x) for x in argv], text=True, capture_output=True, timeout=timeout, **kwargs)
    return p, (time.perf_counter_ns()-t)/1e6

def require(argv, **kwargs):
    p, elapsed=command(argv, **kwargs)
    if p.returncode:
        raise RuntimeError(f'{shlex.join(map(str,argv))}\nexit {p.returncode}\n{p.stdout}{p.stderr}')
    return p.stdout, elapsed

def make_driver(cases):
    lines=['#include <stdint.h>','#include <stdbool.h>','#include <stdio.h>','#include <stdlib.h>','#include <string.h>','#include <inttypes.h>']
    for name,params,result,_,_ in cases:
        lines.append(f'extern {TYPES[result]} {name}({", ".join(TYPES[x] for x in params) or "void"});')
    lines += ['int main(int argc, char **argv) {','    if (argc < 2) return 2;']
    for name,params,result,_,_ in cases:
        args=[f'({TYPES[t]})'+('strtoll' if t.startswith('i') else 'strtoull')+f'(argv[{i+2}], NULL, 10)' for i,t in enumerate(params)]
        lines += [f'    if (strcmp(argv[1], "{name}") == 0) {{',f'        if (argc != {len(params)+2}) return 2;',f'        printf("%" PRIu64 "\\n", (uint64_t){name}({", ".join(args)}));', '        return 0;', '    }']
    return '\n'.join(lines+['    return 2;','}'])+'\n'

def test(odin, bor, out, sanitizers=True, *, cases=None, source=None):
    cases = CASES if cases is None else cases
    source = ROOT/'tests/semantics' if source is None else source
    out.mkdir(parents=True,exist_ok=True)
    driver=out/'driver.c'; driver.write_text(make_driver(cases))
    report={'schema':1, 'suite':'scalar-semantics', 'host':platform.platform(), 'cases':[], 'builds':[], 'versions':{}}
    report['versions']['odin']=require([odin,'version'])[0].strip()
    report['versions']['bor']=require([bor,'--version'])[0].strip()
    report['source_sha256']=hashlib.sha256((source/'main.odin').read_bytes()).hexdigest()
    lanes={}
    for mode in ('opt','no-opt'):
        c=out/f'{mode}.c'
        flags=[] if mode=='opt' else ['--no-opt']
        _, ms=require([bor,'emit',source,'-o',c,*flags])
        same=require([bor,'emit',source,*flags])[0]
        if same != c.read_text(): raise RuntimeError('nondeterministic emitted C')
        report['builds'].append({'lane':f'bor-{mode}-emit','elapsed_ms':ms,'bytes':c.stat().st_size,'sha256':hashlib.sha256(c.read_bytes()).hexdigest()})
        compilers = [('gcc',['gcc']),('clang',['clang'])]
        zig = shutil.which(os.environ.get('ZIG','zig'))
        if zig: compilers.append(('zig-cc',[zig,'cc']))
        else: report['unmeasured_backends']=['zig-cc']
        for compiler, compiler_command in compilers:
            report['versions'][compiler]=require([*compiler_command,'--version'])[0].splitlines()[0]
            for level in ('0','2'):
                name=f'bor-{mode}-{compiler}-O{level}'
                exe=out/name
                cmd=[*compiler_command,'-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror',f'-O{level}',c,driver,'-o',exe]
                _, ms=require(cmd)
                lanes[name]=[str(exe)]
                report['builds'].append({'lane':name,'elapsed_ms':ms,'bytes':exe.stat().st_size,'command':list(map(str,cmd))})
        if sanitizers:
            name=f'bor-{mode}-ubsan'; exe=out/name
            require(['clang','-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror','-O1','-fsanitize=undefined','-fno-sanitize-recover=all',c,driver,'-o',exe])
            lanes[name]=[str(exe)]
    obj=out/'native-odin.o'; native=out/'native-odin'
    _,ms=require([odin,'build',source,'-build-mode:obj','-no-entry-point','-o:speed',f'-out:{obj}'])
    require(['gcc',obj,driver,'-lm','-o',native])
    lanes['native-odin']=[str(native)]
    report['builds'].append({'lane':'native-odin','elapsed_ms':ms,'bytes':native.stat().st_size})
    failures=[]
    for name,params,result,inputs,expected in cases:
        for args,want in zip(inputs,expected,strict=True):
            for lane,exe in lanes.items():
                p,ms=command([*exe,name,*map(str,args)],timeout=5)
                got=None
                if p.returncode==0:
                    try: got=int(p.stdout.strip())&MASK
                    except ValueError: pass
                row={'case':name,'args':args,'lane':lane,'expected_bits':want&MASK,'actual_bits':got,'returncode':p.returncode,'elapsed_ms':ms,'pass':got==(want&MASK)}
                if not row['pass']:
                    row['stderr']=p.stderr
                    # Pinned dev-2026-09 x86-64 Odin reaches hardware idiv overflow.
                    # Keep this visible as a divergence, never relabel it a pass.
                    known = lane=='native-odin' and name=='divide_edge' and args==(-(1<<63),-1) and p.returncode==-8
                    row['known_reference_divergence']=known
                    if not known: failures.append(row)
                report['cases'].append(row)
            for mode in ('opt','no-opt'):
                argv=[bor,'eval',source,'--entry',name]
                if mode=='no-opt': argv += ['--no-opt']
                for a in args: argv += ['--arg',str(a)]
                p,ms=command(argv,timeout=10)
                got=None
                if p.returncode==0:
                    try: got=int(p.stdout.strip())&MASK
                    except ValueError: pass
                row={'case':name,'args':args,'lane':f'ir-{mode}','expected_bits':want&MASK,'actual_bits':got,'returncode':p.returncode,'elapsed_ms':ms,'pass':got==(want&MASK)}
                if not row['pass']: row['stderr']=p.stderr; failures.append(row)
                report['cases'].append(row)
    report['summary']={'checks':len(report['cases']), 'passes':sum(row['pass'] for row in report['cases']), 'failures':len(failures),'reference_divergences':sum(row.get('known_reference_divergence',False) for row in report['cases']),'functions':len(cases)}
    (out/'semantics.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['summary']))
    for f in failures: print(json.dumps(f))
    return not failures

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--odin',default=os.environ.get('ODIN','odin'));ap.add_argument('--bor',default=str(ROOT/'build/bor'));ap.add_argument('--out',type=pathlib.Path,default=ROOT/'build/semantics');ap.add_argument('--no-sanitizers',action='store_true')
    a=ap.parse_args()
    try: sys.exit(0 if test(a.odin,a.bor,a.out,not a.no_sanitizers) else 1)
    except (RuntimeError,subprocess.TimeoutExpired) as e: print(str(e),file=sys.stderr);sys.exit(1)
