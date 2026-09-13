#!/usr/bin/env python3
"""Native-Odin coverage and rejection parity. Corpus counts are not language percentages.
Known gaps stay visible; required features and a frozen pass baseline gate regressions.
"""
from __future__ import annotations
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import html
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import time
from completeness_cases import CASES

ROOT = Path(__file__).resolve().parents[1]
MODES = {"direct":"emit-c-direct", "mir":"emit-c-mir", "expression":"emit-c-expr", "raw-control":"emit-c-mir-raw"}
STRICT = ["-std=c99", "-pedantic-errors", "-Wall", "-Wextra", "-Werror"]
SEEDS = [20260913, 3735928559]
HOST = '''#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern uint32_t probe(uint32_t x, uint8_t *p);
int main(int argc,char **argv) {
 uint32_t seed=argc>1?(uint32_t)strtoul(argv[1],0,0):20260913u;
 const uint32_t edges[]={0,1,2,7,127,128,200,254,255,256,65535,0x7fffffffu,0x80000000u,0xffffffffu};
 for(unsigned i=0;i<128;i++) {
  seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;
  uint32_t x=i<sizeof(edges)/sizeof(edges[0])?edges[i]:seed;
  uint8_t p[32]; for(unsigned j=0;j<32;j++) p[j]=(uint8_t)(seed+j);
  uint32_t value=probe(x,p);
  if(fwrite(&value,4,1,stdout)!=1 || fwrite(p,32,1,stdout)!=1) return 1;
 }
 return 0;
}
'''
BYTES_PER_SEED = 128*36


def fingerprint(case: dict) -> str:
    return hashlib.sha256(json.dumps({k:case[k] for k in ("source","files","validity","category") if k in case},sort_keys=True).encode()).hexdigest()


def process(directory: Path, label: str, command: list[str], timeout: int=30) -> dict:
    """Bound every child and kill its process group on timeout; retain diagnostics."""
    start=time.perf_counter_ns()
    try:
        child=subprocess.Popen(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            stdout,stderr=child.communicate(timeout=timeout)
            state="ok" if child.returncode==0 else "crash" if child.returncode<0 else "failed"
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL)
            stdout,stderr=child.communicate()
            state="timeout"
        code=child.returncode
    except OSError as error:
        stdout,stderr,code,state=b"",str(error).encode(),None,"unavailable"
    (directory/(label+".stdout")).write_bytes(stdout)
    (directory/(label+".stderr")).write_bytes(stderr)
    result={"state":state,"exit":code,"argv":command,"wall_ms":(time.perf_counter_ns()-start)/1e6,
            "stdout_bytes":len(stdout),"stdout_sha256":hashlib.sha256(stdout).hexdigest(),
            "diagnostic":stderr.decode(errors="replace")[-1600:]}
    (directory/(label+".command.json")).write_text(json.dumps(result,indent=2)+"\n")
    return result


def classifications(result: dict) -> dict:
    return {mode:{"emit":data["emit"],**{name:cell["state"] for name,cell in data.get("cells",{}).items()}}
            for mode,data in result.get("paths",{}).items()}


class Shootout:
    def __init__(self,args):
        self.args=args
        self.out=(ROOT/args.output).resolve(); self.out.mkdir(parents=True,exist_ok=True)
        self.odin=shlex.split(os.environ.get("ODIN","odin"))
        original=Path(args.bor).resolve() if args.bor else ROOT/"build/bor"
        self.bor=str(self.out/"bor-under-test")
        if not args.native_only: shutil.copy2(original,self.bor)
        self.cc={"gcc":shlex.split(os.environ.get("CC","gcc")),"clang":shlex.split(os.environ.get("CLANG","clang")),
                 "zig-cc":shlex.split(os.environ.get("ZIG","zig"))+["cc","-target","x86_64-linux-gnu"],
                 "tinycc":shlex.split(os.environ.get("TCC","tcc"))}
        self.compilers=args.compilers.split(","); self.levels=args.levels.split(",")
        if any(c not in self.cc for c in self.compilers):raise ValueError("unknown compiler")
        if any(c not in ("O0","O3") for c in self.levels):raise ValueError("unknown level")
        (self.out/"host.c").write_text(HOST)
        self.versions={"odin":process(self.out,"odin-version",self.odin+["version"])}
        for name in self.compilers:
            self.versions[name]=process(self.out,name+"-version",self.cc[name]+(["-v"] if name=="tinycc" else ["--version"]))

    def one(self,case: dict) -> dict:
        d=self.out/case["name"]; d.mkdir(exist_ok=True)
        package=d/"source"; package.mkdir(exist_ok=True)
        (package/"main.odin").write_text(case["source"])
        for name,text in case.get("files",{}).items():
            target=package/name; target.parent.mkdir(parents=True,exist_ok=True); target.write_text(text)
        result={k:v for k,v in case.items() if k not in ("source","files")}
        result.update(fingerprint=fingerprint(case),paths={},native={})
        native=process(d,"native-check",self.odin+["check",str(package),"-no-entry-point","-thread-count:1"])
        result["native"]["check"]=native
        native_valid=native["state"]=="ok"
        classified=native_valid if case["validity"]=="valid" else native["state"]=="failed" and bool(native["diagnostic"])
        if not classified:
            result["oracle_error"]="declared validity disagrees with native Odin, or native failed abnormally";return result
        expected={}
        if native_valid:
            for opt in ("none","speed"):
                archive=d/("native-"+opt+".a")
                built=process(d,"native-build-"+opt,self.odin+["build",str(package),"-build-mode:static","-no-entry-point","-reloc-mode:pic","-thread-count:1","-o:"+opt,"-out:"+str(archive)])
                result["native"][opt]=built
                if built["state"]!="ok":result["oracle_error"]="native build failed";return result
                exe=d/("native-"+opt)
                linked=process(d,"native-link-"+opt,self.cc["gcc"]+STRICT+["-O2",str(self.out/"host.c"),str(archive),"-lm","-ldl","-lpthread","-o",str(exe)])
                if linked["state"]!="ok":result["oracle_error"]="native link failed";return result
                for seed in SEEDS:
                    label=f"native-{opt}-{seed}"
                    ran=process(d,label,[str(exe),str(seed)],timeout=6)
                    data=(d/(label+".stdout")).read_bytes()
                    if ran["state"]!="ok" or len(data)!=BYTES_PER_SEED:
                        result["oracle_error"]="native runtime failed or wrong output length";return result
                    if opt=="none":expected[seed]=data
                    elif expected[seed]!=data:
                        result["oracle_error"]="native optimization levels disagree";return result
            result["native"]["verdict"]="run-agreement"
        else:result["native"]["verdict"]="diagnosed-invalid"
        if self.args.native_only:return result
        for name,mode in MODES.items():
            path={"emit":"not-run","cells":{}}; result["paths"][name]=path
            target=d/(name+".c"); sentinel=b"/* previous successful output */\n"; target.write_bytes(sentinel)
            emit=process(d,name+"-emit",[self.bor,mode,str(package),"-o",str(target)],timeout=10)
            path["command"]=emit
            if emit["state"]!="ok":
                unchanged=target.read_bytes()==sentinel
                path["emit"]=("unsupported" if native_valid else "correct-rejection") if emit["state"]=="failed" and unchanged and emit["diagnostic"] else ("output-damaged" if not unchanged else emit["state"])
                continue
            if not native_valid:path["emit"]="invalid-accepted";continue
            emitted=target.read_bytes()
            if emitted==sentinel or not emitted:path["emit"]="empty-output";continue
            repeat=d/(name+"-repeat.c")
            again=process(d,name+"-repeat",[self.bor,mode,str(package),"-o",str(repeat)],timeout=10)
            if again["state"]!="ok" or emitted!=repeat.read_bytes():path["emit"]="nondeterministic";continue
            path.update(emit="emitted",c_bytes=len(emitted),c_sha256=hashlib.sha256(emitted).hexdigest())
            for cc in self.compilers:
                for level in (["default"] if cc=="tinycc" else self.levels):
                    label=f"{name}-{cc}-{level}";exe=d/label
                    flags=["-std=c99","-Wall","-Werror"] if cc=="tinycc" else STRICT+["-"+level]
                    built=process(d,label+"-build",self.cc[cc]+flags+[str(target),str(self.out/"host.c"),"-o",str(exe)],timeout=90)
                    cell={"state":"c-compile-error" if built["state"]=="failed" else built["state"],"build":built}
                    path["cells"][cc+"/"+level]=cell
                    if built["state"]!="ok":continue
                    cell["state"]="pass"
                    for seed in SEEDS:
                        run_label=f"{label}-{seed}";ran=process(d,run_label,[str(exe),str(seed)],timeout=3)
                        data=(d/(run_label+".stdout")).read_bytes()
                        if ran["state"]!="ok":cell["state"]="runtime-"+ran["state"];break
                        if data!=expected[seed]:
                            cell["state"]="wrong-output"
                            cell["mismatch"]={"seed":seed,"bytes":len(data),"expected_bytes":len(expected[seed]),
                                "first_byte":next((i for i,(a,b) in enumerate(zip(data,expected[seed])) if a!=b),min(len(data),len(expected[seed])))}
                            break
                    if cell["state"]=="pass":cell["observations"]=128*len(SEEDS)
            path["all_configurations_pass"]=bool(path["cells"]) and all(c["state"]=="pass" for c in path["cells"].values())
        return result

    def execute(self) -> dict:
        cases=[c for c in CASES if not self.args.filter or self.args.filter in c["name"]]
        revision=os.environ.get("GITHUB_SHA") or subprocess.run(["git","rev-parse","HEAD"],cwd=ROOT,capture_output=True,text=True).stdout.strip()
        report={"schema":1,"revision":revision,"status":"running","method":{
            "scope":"versioned language probes, not a full Odin conformance percentage",
            "strategies":{k:v for k,v in MODES.items() if k!="raw-control"},"control":"raw-control",
            "shared_semantics":"MIR and expression share the lowerer; only native Odin is independent",
            "native":"check, build and run at -o:none/-o:speed; exact output agreement required",
            "observations_per_case":256,"bytes_per_seed":BYTES_PER_SEED,"seeds":SEEDS,
            "compilers":self.compilers,"levels":self.levels,"tinycc":"non-optimizing, no pretend O3",
            "timing":"command times are diagnostic, not a performance benchmark"},
            "versions":self.versions,
            "compiler_sha256":hashlib.sha256(Path(self.bor).read_bytes()).hexdigest() if not self.args.native_only else None,
            "source_hashes":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/"src").glob("*.odin"))},
            "results":[],"regressions":[],"required_failures":[]}
        with ThreadPoolExecutor(max_workers=self.args.jobs) as pool:
            for result in pool.map(self.one,cases):
                report["results"].append(result)
                print(result["name"],result.get("oracle_error") or {m:("pass" if p.get("all_configurations_pass") else p["emit"]) for m,p in result["paths"].items()},flush=True)
                self.save(report)
        for r in report["results"]:
            if r.get("oracle_error"):report["required_failures"].append(r["name"]+":oracle");continue
            if self.args.native_only:continue
            for m in ("mir","expression","raw-control"):
                p=r["paths"][m]
                if r["validity"]=="invalid" and p["emit"]!="correct-rejection":report["required_failures"].append(r["name"]+":"+m+":"+p["emit"])
                if r["validity"]=="valid" and r.get("required_mir") and not p.get("all_configurations_pass"):
                    report["required_failures"].append(r["name"]+":"+m+":required-feature")
                if any(c["state"] in ("wrong-output","runtime-crash","runtime-timeout") for c in p["cells"].values()):
                    report["required_failures"].append(r["name"]+":"+m+":unsound")
        if self.args.baseline and not self.args.native_only:
            baseline=json.loads(Path(self.args.baseline).read_text());now={r["name"]:r for r in report["results"]}
            for name,old in baseline["cases"].items():
                if name not in now:report["regressions"].append(name+":removed");continue
                r=now[name]
                if r["fingerprint"]!=old["fingerprint"]:report["regressions"].append(name+":fixture-changed");continue
                new=classifications(r)
                dangerous={"wrong-output","runtime-crash","runtime-timeout","invalid-accepted","crash","output-damaged"}
                for mode,cells in new.items():
                    for key,state in cells.items():
                        if state in dangerous and old.get("outcomes",{}).get(mode,{}).get(key)!=state:
                            report["regressions"].append(f"{name}:{mode}:{key}:new-unsafe-outcome")
                for mode,cells in old["outcomes"].items():
                    for key,state in cells.items():
                        if state in ("pass","correct-rejection") and new.get(mode,{}).get(key)!=state:report["regressions"].append(f"{name}:{mode}:{key}")
        report["status"]="failed" if report["required_failures"] or report["regressions"] else "passed"
        report["summary"]={m:{"valid_all_pass":sum(r["validity"]=="valid" and r.get("paths",{}).get(m,{}).get("all_configurations_pass",False) for r in report["results"]),
            "valid_total":sum(r["validity"]=="valid" for r in report["results"]),
            "invalid_rejected":sum(r["validity"]=="invalid" and r.get("paths",{}).get(m,{}).get("emit")=="correct-rejection" for r in report["results"]),
            "invalid_total":sum(r["validity"]=="invalid" for r in report["results"]),
            "cells":dict(Counter(c["state"] for r in report["results"] for c in r.get("paths",{}).get(m,{}).get("cells",{}).values()))} for m in MODES}
        self.save(report)
        if self.args.write_baseline:
            if report["status"]!="passed" or self.args.filter or self.args.native_only:raise RuntimeError("cannot baseline a failed/partial run")
            baseline={"schema":1,"cases":{r["name"]:{"fingerprint":r["fingerprint"],"outcomes":classifications(r)} for r in report["results"]}}
            Path(self.args.write_baseline).write_text(json.dumps(baseline,separators=(",",":"))+"\n")
        return report

    def save(self,report: dict):
        (self.out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
        rows=[]
        for r in report["results"]:
            cells=[]
            for m in MODES:
                p=r.get("paths",{}).get(m,{})
                state="pass" if p.get("all_configurations_pass") else p.get("emit","not-run")
                detail="\n".join(k+": "+v["state"] for k,v in p.get("cells",{}).items())
                cells.append('<td class="'+('pass' if state in ("pass","correct-rejection") else 'gap')+'">'+html.escape(state)+'<pre>'+html.escape(detail)+'</pre></td>')
            rows.append('<tr><td>'+html.escape(r["name"])+'<small>'+html.escape(r["category"])+', '+r["validity"]+'</small></td><td>'+html.escape(r.get("oracle_error") or r.get("native",{}).get("verdict","pending"))+'</td>'+''.join(cells)+'</tr>')
        page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Borr: Odin completeness shootout</title><style>body{background:#101818;color:#e7eeee;font:15px system-ui;margin:2rem}h1{font-weight:500}p{max-width:80ch;line-height:1.5}table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:12px;border:1px solid #324343;vertical-align:top}th{position:sticky;top:0;background:#233333}small{display:block;color:#97aeae}.pass{color:#9bdbbd}.gap{color:#edc88a}pre{font:11px monospace;white-space:pre-wrap;color:#bbc7c7}input{padding:10px;margin:1rem 0;background:#233333;color:white;border:1px solid #748080;width:30em;max-width:90%}</style><h1>Borr / Odin completeness shootout</h1><p>Three strategies, one independent native-Odin oracle. Raw MIR is a fourth control. Unsupported features and miscompilations remain visible. Counts describe this versioned corpus, not the percentage of Odin implemented.</p>'''
        page+='<p>Revision <code>'+html.escape(report['revision'])+'</code> · '+html.escape(report['status'])+'</p><input id="filter" aria-label="Filter cases" placeholder="Filter by feature, category, or outcome"><table><thead><tr><th>Probe</th><th>Native Odin (none/speed)</th>'+''.join('<th>'+html.escape(m)+'</th>' for m in MODES)+'</tr></thead><tbody>'+''.join(rows)+'</tbody></table><script>document.getElementById("filter").oninput=e=>{for(const row of document.querySelectorAll("tbody tr"))row.hidden=!row.textContent.toLowerCase().includes(e.target.value.toLowerCase())};</script></html>'
        (self.out/"index.html").write_text(page)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output",default="build/completeness");p.add_argument("--compilers",default="gcc,clang,zig-cc,tinycc")
    p.add_argument("--levels",default="O0,O3");p.add_argument("--jobs",type=int,default=2)
    p.add_argument("--filter");p.add_argument("--bor");p.add_argument("--native-only",action="store_true")
    p.add_argument("--baseline");p.add_argument("--write-baseline")
    args=p.parse_args()
    if args.jobs<1 or args.jobs>8:p.error("jobs must be in 1..8")
    if args.baseline and args.filter:p.error("a partial run cannot check the full baseline")
    report=Shootout(args).execute()
    print(json.dumps(report["summary"],indent=2))
    print("required failures:",report["required_failures"],"regressions:",report["regressions"])
    raise SystemExit(0 if report["status"]=="passed" else 1)


if __name__=="__main__":main()
