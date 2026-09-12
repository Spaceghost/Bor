#!/usr/bin/env python3
"""Compile-only portability gates. No emulation and no cross-runtime claims."""
from __future__ import annotations
import argparse,json,os,pathlib,shutil,sys
from test_semantics import ROOT,require

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--bor',default=str(ROOT/'build/bor'));ap.add_argument('--out',type=pathlib.Path,default=ROOT/'build/cross');a=ap.parse_args()
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    c=out/'profile.c';require([a.bor,'emit',ROOT/'tests/semantics','-o',c])
    rows=[]
    for target in ('wasm32-unknown-unknown','aarch64-unknown-linux-gnu','x86_64-w64-windows-gnu'):
        obj=out/f'clang-{target}.o'
        cmd=['clang',f'--target={target}','-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror','-ffreestanding','-DBOR_FREESTANDING','-O2','-c',c,'-o',obj]
        require(cmd);rows.append({'compiler':'clang','target':target,'phase':'object-only','bytes':obj.stat().st_size,'command':list(map(str,cmd))})
    zig=shutil.which(os.environ.get('ZIG','zig'))
    if zig:
        for target in ('aarch64-linux-musl','x86_64-windows-gnu','wasm32-freestanding'):
            obj=out/f'zig-{target}.o'
            cmd=[zig,'cc','-target',target,'-std=c99','-pedantic-errors','-Wall','-Wextra','-Werror','-ffreestanding','-DBOR_FREESTANDING','-O2','-c',c,'-o',obj]
            require(cmd,timeout=180);rows.append({'compiler':'zig cc','target':target,'phase':'object-only','bytes':obj.stat().st_size,'command':list(map(str,cmd))})
    report={'schema':1,'profile':'fixed 64-bit int/uint/uintptr; this is NOT a claim of native Odin ABI compatibility on 32-bit targets','cross_execution':False,'objects':rows,'zig_available':bool(zig)}
    (out/'cross.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'cross_objects':len(rows),'execution':False}));return True
if __name__=='__main__': sys.exit(0 if main() else 1)
