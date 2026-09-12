#!/usr/bin/env python3
"""Correctness-gated, seeded/interleaved measurements; never rank unlike phases."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, platform, random, shutil, statistics, subprocess, sys
from test_semantics import ROOT, command, require

MASK32=(1<<32)-1

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def stats(samples):
    med=statistics.median(samples)
    return {'median_ms':med,'mad_ms':statistics.median(abs(x-med) for x in samples),'samples_ms':samples}

def advance(state,n):
    # Independent logarithmic-time affine-composition oracle, not the C loop.
    mul,add,am,aa=1664525,1013904223,1,0
    while n:
        if n&1: am,aa=(am*mul)&MASK32,(aa*mul+add)&MASK32
        mul,add=(mul*mul)&MASK32,((mul+1)*add)&MASK32
        n>>=1
    return (state*am+aa)&MASK32

def measure_group(commands,rounds,cwd):
    samples={name:[] for name in commands}
    for name,cmd in commands.items(): require(cmd,cwd=cwd,timeout=120)  # excluded warmup
    rng=random.Random(0xB077)
    for _ in range(rounds):
        order=list(commands);rng.shuffle(order)
        for name in order:
            _,ms=require(commands[name],cwd=cwd,timeout=120);samples[name].append(ms)
    return {name:{**stats(samples[name]),'command':list(map(str,cmd))} for name,cmd in commands.items()}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--odin',default=os.environ.get('ODIN','odin'));ap.add_argument('--bor',default=str(ROOT/'build/bor'))
    ap.add_argument('--codin',type=pathlib.Path);ap.add_argument('--thor',type=pathlib.Path);ap.add_argument('--zig',default=os.environ.get('ZIG','zig'))
    ap.add_argument('--rounds',type=int,default=7);ap.add_argument('--functions',type=int,default=128)
    ap.add_argument('--out',type=pathlib.Path,default=ROOT/'build/shootout')
    a=ap.parse_args()
    if not 3<=a.rounds<=101 or not 1<=a.functions<=512: ap.error('rounds must be 3..101 and functions 1..512')
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    bor=str(pathlib.Path(a.bor).resolve());odin=shutil.which(a.odin) or a.odin
    codin=str(a.codin.resolve()) if a.codin else None
    report={'schema':1,'host':platform.platform(),'machine':platform.machine(),'cpu_count':os.cpu_count(),
            'clock':'perf_counter_ns wall time; runtime loop uses C clock() CPU time',
            'method':'one excluded warmup; fresh process per sample; warm filesystem cache; seeded interleaving; no LTO',
            'rounds':a.rounds,'versions':{},'source_revision':os.environ.get('GITHUB_SHA','local-worktree'),
            'compiler_sha256':digest(pathlib.Path(bor)),'notes':[]}
    report['versions']['odin']=require([odin,'version'])[0].strip()
    report['versions']['bor']=require([bor,'--version'])[0].strip()
    try: report['cpu_model']=next(l.split(':',1)[1].strip() for l in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name'))
    except (OSError,StopIteration): pass
    compilers={'gcc':['gcc'],'clang':['clang']}
    zig=shutil.which(a.zig)
    if zig: compilers['zig-cc']=[zig,'cc'];report['versions']['zig']=require([zig,'version'])[0].strip()
    else: report['notes'].append('Zig was not present; Zig lanes are unmeasured.')
    for name,cmd in compilers.items(): report['versions'][name]=require([*cmd,'--version'])[0].splitlines()[0]

    # A common source profile: no borrowed performance numbers or language rewrites.
    corpus=out/'scale';corpus.mkdir(exist_ok=True)
    base=(ROOT/'tests/bench/main.odin').read_text()
    function=base[base.index('@(export)'):]
    source='package scale\n'+''.join(function.replace('mix32',f'mix_{i}') for i in range(a.functions))
    (corpus/'main.odin').write_text(source)
    report['compile_corpus']={'functions':a.functions,'bytes':len(source.encode()),'sha256':digest(corpus/'main.odin')}
    emitters={'bor-opt':[bor,'emit',corpus,'-o',out/'bor-opt.c'],
              'bor-no-opt':[bor,'emit',corpus,'--no-opt','-o',out/'bor-no-opt.c']}
    if codin: emitters['codin']=[codin,'emit-c',corpus,'-o',out/'codin.c']
    else: report['notes'].append('Codin was not provided; no Codin performance claim can be made.')
    report['emit']=measure_group(emitters,a.rounds,out)
    for name,row in report['emit'].items():
        c=out/f'{name}.c';row['c_bytes']=c.stat().st_size;row['c_sha256']=digest(c)
        # Determinism is verified separately, not inferred from successful exit.
        require(emitters[name],cwd=out)
        if digest(c)!=row['c_sha256']: raise RuntimeError(f'{name}: nondeterministic C emission')
        if pathlib.Path('/usr/bin/time').exists():
            rss=out/f'{name}.rss'
            require(['/usr/bin/time','-f','%M','-o',rss,*emitters[name]],cwd=out)
            row['max_rss_kib']=int(rss.read_text().strip())
    native=out/'native-scale.o'
    native_cmd=[odin,'build',corpus,'-build-mode:obj','-no-entry-point','-o:speed',f'-out:{native}']
    # Native object production does more work than emission. Keep a separate group.
    report['native_object']=measure_group({'odin':native_cmd},a.rounds,out)
    compile_commands={name:['gcc','-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror','-O2','-c',out/f'{name}.c','-o',out/f'{name}.o'] for name in emitters}
    report['c_object']=measure_group(compile_commands,a.rounds,out)
    scale_driver=out/'scale-driver.c'
    lines=['#include <stdint.h>','#include <inttypes.h>','#include <stdio.h>']
    for i in range(a.functions): lines.append(f'extern uint32_t mix_{i}(uint32_t, uintptr_t);')
    lines += ['int main(void) { uint64_t sum=0;']
    expected=0
    for i in range(a.functions):
        seed=(i*3141592653)&MASK32;n=i%29
        lines.append(f'sum += mix_{i}(UINT32_C({seed}), (uintptr_t){n});');expected+=advance(seed,n)
    lines += ['printf("%" PRIu64 "\\n",sum);return 0;}'];scale_driver.write_text('\n'.join(lines)+'\n')
    report['scale_execution']={}
    for name in [*emitters,'native-scale']:
        obj=out/f'{name}.o';exe=out/f'scale-{name}'
        require(['gcc',obj,scale_driver,'-lm','-o',exe])
        stdout,_=require([exe]);actual=int(stdout.strip())
        report['scale_execution'][name]={'expected':expected,'actual':actual,'pass':actual==expected,'object_bytes':obj.stat().st_size}
        if actual!=expected: raise RuntimeError(f'{name} failed compile-corpus execution gate')

    # Runtime timing uses a long observable dependency chain and an independent checksum.
    runtime_source=ROOT/'tests/bench'
    runtime_c={}
    for name,flags in [('bor-opt',[]),('bor-no-opt',['--no-opt'])]:
        path=out/f'runtime-{name}.c';require([bor,'emit',runtime_source,'-o',path,*flags]);runtime_c[name]=path
    if codin:
        path=out/'runtime-codin.c';require([codin,'emit-c',runtime_source,'-o',path],cwd=out);runtime_c['codin']=path
    handwritten=out/'handwritten.c';handwritten.write_text('#include <stdint.h>\nuint32_t mix32(uint32_t x,uintptr_t n) { for(uintptr_t i=0;i<n;i++) x=x*UINT32_C(1664525)+UINT32_C(1013904223);return x;}\n');runtime_c['handwritten']=handwritten
    driver=out/'runtime-driver.c'
    driver.write_text('''#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
extern uint32_t mix32(uint32_t,uintptr_t);
int main(int argc,char **argv) {
    if(argc!=4) return 2;
    uintptr_t n=(uintptr_t)strtoull(argv[1],0,10);
    uint32_t repeats=(uint32_t)strtoul(argv[2],0,10),state=(uint32_t)strtoul(argv[3],0,10);
    uint64_t checksum=0;
    clock_t start=clock();
    for(uint32_t i=0;i<repeats;i++) { state=mix32(state,n);checksum+=state; }
    double ms=1000.0*(double)(clock()-start)/(double)CLOCKS_PER_SEC;
    printf("%" PRIu64 " %.9f\\n",checksum,ms);
    return 0;
}
''')
    lanes={}
    for name,c in runtime_c.items():
        for compiler,cmd in compilers.items():
            lane=f'{name}-{compiler}';obj=out/f'{lane}.o';exe=out/lane
            require([*cmd,'-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror','-O3','-c',c,'-o',obj])
            require(['gcc',obj,driver,'-lm','-o',exe]);lanes[lane]=exe
    native_obj=out/'native-runtime.o';native_exe=out/'native-odin'
    require([odin,'build',runtime_source,'-build-mode:obj','-no-entry-point','-o:speed',f'-out:{native_obj}'])
    require(['gcc',native_obj,driver,'-lm','-o',native_exe]);lanes['native-odin']=native_exe
    n,repeats,seed=200000,64,123456789
    state=seed;expected=0
    for _ in range(repeats): state=advance(state,n);expected+=state
    runtime={name:{'samples_ms':[],'binary_bytes':exe.stat().st_size} for name,exe in lanes.items()}
    order=list(lanes);rng=random.Random(0xB077)
    for iteration in range(a.rounds+1):
        rng.shuffle(order)
        for name in order:
            stdout,_=require([lanes[name],n,repeats,seed],timeout=30)
            checksum,cpu_ms=stdout.split()
            if int(checksum)!=expected: raise RuntimeError(f'{name}: wrong runtime checksum {checksum} != {expected}')
            if iteration: runtime[name]['samples_ms'].append(float(cpu_ms))
    for row in runtime.values(): row.update(stats(row['samples_ms']));row['checksum']=expected
    report['runtime']={'workload':'32-bit LCG dependency chain (not a general application benchmark)','updates_per_sample':n*repeats,'lanes':runtime}
    report['compiler_files']={}
    for name,path in [('bor',pathlib.Path(bor)),('codin',pathlib.Path(codin) if codin else None),('thor',a.thor)]:
        if path and path.exists(): report['compiler_files'][name]={'bytes':path.stat().st_size,'sha256':digest(path)}
    if a.thor:
        path=a.thor.resolve();p,ms=command([path],cwd=path.parent,timeout=20)
        (out/'thor.stdout').write_text(p.stdout);(out/'thor.stderr').write_text(p.stderr)
        report['thor']={'status':'not-comparable: parser/AST-dump driver with hard-coded input, no C emission command',
                        'exit_code':p.returncode,'probe_wall_ms':ms,'stdout_bytes':len(p.stdout.encode()),'stderr':p.stderr,
                        'warning':'Exit zero is not a compilation pass. Do not rank this timing against emit/object production.'}
    report['semantic_optimizer']={}
    sem_source=ROOT/'tests/semantics'
    for mode,flags in [('opt',[]),('no-opt',['--no-opt'])]:
        c=out/f'semantic-{mode}.c';require([bor,'emit',sem_source,'-o',c,*flags]);report['semantic_optimizer'][mode]={'bytes':c.stat().st_size,'sha256':digest(c)}
    (out/'shootout.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'emit':{k:round(v['median_ms'],3) for k,v in report['emit'].items()},'native_object_ms':report['native_object']['odin']['median_ms'],
          'runtime_ms':{k:round(v['median_ms'],3) for k,v in runtime.items()},'optimizer_c_bytes':report['semantic_optimizer']},indent=2))
    return True

if __name__=='__main__':
    try: sys.exit(0 if main() else 1)
    except (RuntimeError,subprocess.TimeoutExpired,OSError,ValueError) as e: print(e,file=sys.stderr);sys.exit(1)
