#!/usr/bin/env python3
"""Seeded, bounded differential programs with a separate Python bit-vector oracle."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, random, sys
from test_semantics import ROOT, MASK, test

def generate(rng, depth, signed):
    if not depth:
        leaf = rng.choice(['x','y',str(rng.randint(-1,1))] if signed else ['x','y'])
        return leaf, lambda x,y: {'x':x,'y':y}.get(leaf,int(leaf) if leaf not in ('x','y') else 0)&MASK
    a,fa=generate(rng,depth-1,signed);b,fb=generate(rng,depth-1,signed)
    op=rng.choice(['+','-','*','&','|','~','&~'])
    def evaluate(x,y):
        p,q=fa(x,y),fb(x,y)
        if op=='+': return (p+q)&MASK
        if op=='-': return (p-q)&MASK
        if op=='*': return (p*q)&MASK
        if op=='&': return p&q
        if op=='|': return p|q
        if op=='~': return p^q
        return p&(~q&MASK)
    return f'({a} {op} {b})', evaluate

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--odin',default=os.environ.get('ODIN','odin'));ap.add_argument('--bor',default=str(ROOT/'build/bor'));ap.add_argument('--out',type=pathlib.Path,default=ROOT/'build/generated');ap.add_argument('--seed',type=int,default=0xB077);ap.add_argument('--functions',type=int,default=24)
    args=ap.parse_args()
    if not 1<=args.functions<=256: ap.error('--functions must be between 1 and 256')
    rng=random.Random(args.seed)
    out=args.out;source=out/'source';source.mkdir(parents=True,exist_ok=True)
    lines=['package generated'];cases=[]
    for i in range(args.functions):
        signed=i%2==0;bits=(8,16,32,64)[(i//2)%4];t=f'{"i" if signed else "u"}{bits}';name=f'generated_{i}';mask=(1<<bits)-1
        expr,fn=generate(rng,3,signed)
        # The explicit conversion gives constant-only trees an exact target type.
        lines.append(f'''@(export) {name} :: proc "c" (x, y: {t}) -> {t} {{
    t := {t}({expr})
    if (t & 1) == 0 {{ t = t*3 + x }} else {{ t = t-y }}
    for j in 0..<3 {{ t += {t}(j) }}
    return t
}}''')
        samples=[(0,0),(1,2),(mask,mask),(1<<(bits-1),(1<<(bits-1))-1)]
        samples += [(rng.getrandbits(bits),rng.getrandbits(bits)) for _ in range(2)]
        inputs=[];expected=[]
        for x,y in samples:
            value=fn(x,y);value=((value*3+x) if value&1==0 else value-y)&MASK;value=(value+3)&mask
            convert=lambda n:n-(1<<bits) if signed and n&(1<<(bits-1)) else n
            inputs.append((convert(x),convert(y)));expected.append(convert(value))
        cases.append((name,[t,t],t,inputs,expected))
    (source/'main.odin').write_text('\n'.join(lines)+'\n')
    (out/'manifest.json').write_text(json.dumps({'schema':1,'seed':args.seed,'generator_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'cases':cases},indent=2)+'\n')
    return test(args.odin,args.bor,out/'run',cases=cases,source=source)

if __name__=='__main__': sys.exit(0 if main() else 1)
