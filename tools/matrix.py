#!/usr/bin/env python3
"""Correctness-gated source/codegen/link-driver matrix; no timing thresholds."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
STRICT = ["-std=c99", "-pedantic-errors", "-Wall", "-Wextra", "-Werror"]
OPT = ["-O3", "-march=x86-64", "-fPIC", "-fno-lto"]
WORKLOADS = [("mixed", 32), ("ascii", 4096), ("mixed", 4096), ("binary", 4096), ("mixed", 65536)]
SEEDS = [20260912, 3735928559]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values: list[float]) -> dict:
    median = statistics.median(values)
    return {"samples": values, "p50": median,
            "p95": sorted(values)[math.ceil(len(values)*0.95)-1],
            "mad": statistics.median(abs(v-median) for v in values), "n": len(values)}


def signature(result: dict) -> tuple:
    return tuple(result[k] for k in ("rounds", "input_bytes", "output_bytes", "checksum", "output_hash"))


class Matrix:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.out = (ROOT / args.output).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="borr-matrix-"))
        self.events = (self.out / "commands.jsonl").open("w")
        self.odin = shlex.split(os.environ.get("ODIN", "odin"))
        self.zig = shlex.split(os.environ.get("ZIG", "zig"))
        self.cc = {"gcc": shlex.split(os.environ.get("CC", "gcc")),
                   "clang": shlex.split(os.environ.get("CLANG", "clang")),
                   "zig-cc": self.zig + ["cc", "-target", "x86_64-linux-gnu"],
                   "tinycc": shlex.split(os.environ.get("TCC", "tcc"))}
        self.cpu = min(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None
        revision = os.environ.get("GITHUB_SHA") or subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        self.report = {"schema": 1, "status": "running", "revision": revision,
            "platform": platform.platform(), "machine": platform.machine(), "runtime_cpu": self.cpu,
            "cpu_model": next((s.split(":",1)[1].strip() for s in Path("/proc/cpuinfo").read_text().splitlines()
                               if s.startswith("model name")), "unknown"),
            "method": {"isa": "x86-64 baseline", "lto": False, "runtime_samples": args.samples,
                "build_samples": args.build_samples, "seeds": SEEDS, "order_seed": 20260913,
                "runtime_timer": "CLOCK_MONOTONIC inside harness; process startup excluded",
                "harness": "one GCC -O2 object, reused unchanged for every runtime cell",
                "build_cache": "fresh source path per kernel-build sample; infrastructure/global caches warm",
                "link_cache": "repeated link-driver invocation; driver caches retained",
                "native_rows": "Odin/Zig produce fixed native objects; C columns vary link driver only",
                "scope": "Melodica percent-encoding ABI, valid buffers; not full language conformance"},
            "versions": {}, "emitters": {}, "native_builds": {}, "cells": [], "workloads": [],
            "source_hashes": {str(p.relative_to(ROOT)): digest(p) for d in ("src", "bench", "tools") for p in sorted((ROOT/d).rglob("*")) if p.is_file() and "__pycache__" not in p.parts}}
        self.save()

    def run(self, label: str, command: list[str], *, runtime: bool = False) -> tuple[bytes, float]:
        prefix = self.out / "logs" / f"{self.counter:05d}-{label}"
        self.counter += 1
        prefix.parent.mkdir(exist_ok=True)
        start = time.perf_counter_ns()
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=120 if not runtime else 30,
                preexec_fn=(lambda: os.sched_setaffinity(0, {self.cpu})) if runtime and self.cpu is not None else None)
        except subprocess.TimeoutExpired as error:
            prefix.with_suffix(".stderr").write_bytes(error.stderr or b"")
            self.events.write(json.dumps({"label":label,"argv":command,"timeout":True})+"\n")
            self.events.flush()
            raise RuntimeError(f"{label}: timeout") from error
        elapsed = (time.perf_counter_ns()-start)/1e6
        prefix.with_suffix(".stdout").write_bytes(result.stdout)
        prefix.with_suffix(".stderr").write_bytes(result.stderr)
        self.events.write(json.dumps({"label":label,"argv":command,"exit":result.returncode,"wall_ms":elapsed})+"\n")
        self.events.flush()
        if result.returncode:
            raise RuntimeError(f"{label}: exit {result.returncode}: {result.stderr.decode(errors='replace')[-2000:]}")
        return (result.stdout + result.stderr if label.endswith("-version") else result.stdout), elapsed

    counter = 0

    def flags(self, cc: str) -> list[str]:
        # TinyCC is a non-optimizing exploratory backend, not a pretend -O3 compiler.
        if cc == "tinycc": return ["-std=c99", "-Wall", "-Werror"]
        if cc == "zig-cc": return STRICT + [f for f in OPT if f != "-march=x86-64"] + ["-mcpu=baseline"]
        return STRICT + OPT

    def kernel(self, name: str, source: Path, cc: str | None = None) -> tuple[Path, dict]:
        times, commands = [], []
        first = 0.0
        obj = self.out / (name + ".a" if name == "odin-native" else name + ".o")
        for i in range(self.args.build_samples+1):
            # New pathname invalidates source-object caches without timing deletion/downloads.
            package = self.scratch / f"{name}-{i}"
            package.mkdir()
            copied = package / ("main" + source.suffix)
            shutil.copyfile(source, copied)
            if cc:
                command = self.cc[cc]+self.flags(cc)+["-c", str(copied), "-o", str(obj)]
            elif name == "odin-native":
                command = self.odin+["build", str(package), "-build-mode:static", "-o:speed", "-reloc-mode:pic",
                    "-target:linux_amd64", "-microarch:x86-64", "-no-entry-point", f"-out:{obj}"]
            else:
                command = self.zig+["build-obj", str(copied), "-O", "ReleaseSafe" if name.endswith("safe") else "ReleaseFast",
                    "-fllvm", "-fPIC", "-target", "x86_64-linux-gnu", "-mcpu", "baseline", f"-femit-bin={obj}"]
                if name.endswith("safe"): command.append("-fcompiler-rt")
            _, elapsed = self.run(name+"-kernel", command)
            commands.append(command)
            if i: times.append(elapsed)
            else: first = elapsed
        return obj, {"unit":"ms", **stats(times), "first_invocation_ms":first, "argv":commands[-1]}

    def prepare(self) -> tuple[dict, dict]:
        if platform.machine() not in ("x86_64", "AMD64"):
            raise RuntimeError("this matrix deliberately targets x86-64 Linux; no cross-target runtime claims")
        self.report["versions"]["odin"] = self.run("odin-version", self.odin+["version"])[0].decode()
        self.report["versions"]["zig"] = self.run("zig-version", self.zig+["version"])[0].decode()
        for name, command in self.cc.items():
            try:
                self.report["versions"][name] = self.run(name+"-version", command+(["-v", "-c", str(ROOT/"bench/baselines/scalar.c"), "-o", str(self.scratch/"tcc-version.o")] if name=="tinycc" else ["--version"]))[0].decode()
            except (OSError, RuntimeError) as error:
                if name != "tinycc": raise
                self.report["versions"][name] = "unavailable: "+str(error)
        sources = {"c-scalar": ROOT/"bench/baselines/scalar.c", "c-lut": ROOT/"bench/baselines/lut.c"}
        emitters = {}
        for name, mode in (("bor-direct","emit-c-direct"),("bor-raw","emit-c-mir-raw"),("bor-optimized","emit-c")):
            sources[name] = self.out / (name+".c")
            emitters[name] = [str(ROOT/"build/bor"), mode, str(ROOT/"test/melodica"), "-o",str(sources[name])]
        if self.args.codin:
            sources["codin"] = self.out/"codin.c"
            emitters["codin"] = [str(self.args.codin.resolve()),"emit-c",str(ROOT/"test/melodica"),"-o",str(sources["codin"])]
            self.report["versions"]["codin_binary_sha256"] = digest(self.args.codin.resolve())
        for command in emitters.values(): self.run("emit-warmup", command)
        samples = {name:[] for name in emitters}
        rng = random.Random(20260913)
        for _ in range(self.args.emit_samples):
            order = list(emitters); rng.shuffle(order)
            for name in order: samples[name].append(self.run("emit-"+name, emitters[name])[1])
        self.report["emitters"] = {k:{"unit":"ms", **stats(v), "argv":emitters[k]} for k,v in samples.items()}
        natives = {}
        for name, source in (("odin-native",ROOT/"test/melodica/main.odin"),
                              ("zig-fast",ROOT/"bench/baselines/lut.zig"),
                              ("zig-safe",ROOT/"bench/baselines/lut.zig")):
            natives[name], self.report["native_builds"][name] = self.kernel(name,source)
        for filename in ("runtime", "verify"):
            self.run("common-"+filename, self.cc["gcc"]+STRICT+["-O2","-march=x86-64","-fPIC","-c",
                str(ROOT/"bench"/(filename+".c")),"-o",str(self.out/(filename+".o"))])
        self.report["harness_sha256"] = digest(self.out/"runtime.o")
        return sources, natives

    def build_cells(self, sources: dict, natives: dict) -> None:
        for name in list(sources)+list(natives):
            source = sources.get(name, ROOT/("test/melodica/main.odin" if name=="odin-native" else "bench/baselines/lut.zig"))
            for cc, command in self.cc.items():
                key = name+"--"+cc
                cell = {"id":key,"implementation":name,"toolchain":cc,"status":"building", "runtime":{},
                        "lane":"C codegen and link" if name in sources else "fixed native object; link only",
                        "source":source.read_text(), "optimization":"TinyCC defaults; no -O3" if cc=="tinycc" and name in sources else
                            "ReleaseFast" if name=="zig-fast" else "ReleaseSafe" if name=="zig-safe" else "Odin speed" if name=="odin-native" else "O3"}
                self.report["cells"].append(cell)
                try:
                    if name in sources: obj, cell["kernel_build"] = self.kernel(key, source, cc)
                    else: obj, cell["kernel_build"] = natives[name], self.report["native_builds"][name]
                    cell["object_sha256"] = digest(obj)
                    executable, verifier = self.out/key, self.out/(key+"-verify")
                    libs = ["-lm","-ldl","-lpthread"] if name=="odin-native" else []
                    link = command+[str(self.out/"runtime.o"),str(obj)]+libs+["-o",str(executable)]
                    self.run(key+"-link-warmup",link)
                    link_times=[self.run(key+"-link",link)[1] for _ in range(self.args.build_samples)]
                    cell["link_driver"] = {"unit":"ms",**stats(link_times),"argv":link}
                    self.run(key+"-verify-link",command+[str(self.out/"verify.o"),str(obj)]+libs+["-o",str(verifier)])
                    checked = self.run(key+"-verify",[str(verifier)])[0]
                    if checked != b"verified 4128 capacity/buffer cases\n": raise RuntimeError("unexpected verification output")
                    cell["correctness_cases"] = 4128
                    cell["executable_sha256"] = digest(executable)
                    symbols = self.run(key+"-symbols",["nm","-S","--defined-only",str(obj)])[0].decode()
                    cell["kernel_text_bytes"] = sum(int(m.group(1),16) for line in symbols.splitlines()
                        if (m := re.match(r"[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+[Tt]\s+melodica_\w+$",line)))
                    if cell["kernel_text_bytes"] == 0: cell["kernel_text_bytes"] = None
                    cell["object_sections"] = self.run(key+"-sections",["size",str(obj)])[0].decode()
                    assembly = self.run(key+"-disassemble",["objdump","-d","-Mintel","--no-show-raw-insn",
                        "--disassemble=melodica_url_encode",str(obj)])[0].decode()
                    (self.out/(key+".asm")).write_text(assembly)
                    cell["assembly"] = assembly
                    cell["status"] = "passed"
                except (OSError,RuntimeError) as error:
                    cell["status"] = "excluded"
                    cell["error"] = str(error)
                    if cc != "tinycc": raise
                print(f"{key}: {cell['status']}",flush=True)
                self.save()

    def runtime_result(self, cell: dict, shape: str, size: int, rounds: int, seed: int) -> dict:
        result = json.loads(self.run(cell["id"]+"-runtime",[str(self.out/cell["id"]),shape,str(size),str(rounds),str(seed)], runtime=True)[0])
        if result["elapsed_ns"] <= 0 or result["rounds"] != rounds or result["input_bytes"] != size:
            raise RuntimeError("invalid runtime measurement")
        return result

    def measure(self) -> None:
        cells = [c for c in self.report["cells"] if c["status"]=="passed"]
        oracle = next(c for c in cells if c["id"]=="odin-native--gcc")
        rng = random.Random(20260913)
        for shape,size in WORKLOADS:
            key = f"{shape}-{size}"
            probe = self.runtime_result(oracle,shape,size,64,SEEDS[0])
            rounds = max(16,min(5_000_000,int(64*self.args.target_ms*1e6/probe["elapsed_ns"])))
            expected={seed:self.runtime_result(oracle,shape,size,rounds,seed) for seed in SEEDS}
            self.report["workloads"].append({"id":key,"shape":shape,"bytes":size,"rounds":rounds,
                "oracle_signatures": {str(s):list(signature(e)) for s,e in expected.items()}})
            # Every entrant gets an untimed warmup on this workload, followed by interleaved samples.
            for cell in cells: self.runtime_result(cell,shape,size,rounds,SEEDS[0])
            raw={c["id"]:[] for c in cells}
            for iteration in range(self.args.samples):
                order=list(cells);rng.shuffle(order)
                seed=SEEDS[iteration%len(SEEDS)]
                for cell in order:
                    result=self.runtime_result(cell,shape,size,rounds,seed)
                    if signature(result)!=signature(expected[seed]):
                        cell["status"]="wrong-result"
                        raise RuntimeError(f"{cell['id']}: runtime checksum disagrees with native Odin")
                    raw[cell["id"]].append({"seed":seed,**result})
            for cell in cells:
                samples=raw[cell["id"]]
                cell["runtime"][key]={"unit":"ns/input-byte",**stats([r["elapsed_ns"]/(rounds*size) for r in samples]),"raw":samples}
            print(f"{key}: {len(cells)} cells agree; {rounds} rounds/sample",flush=True)
            self.save()

    def save(self) -> None:
        (self.out/"report.json").write_text(json.dumps(self.report,indent=2)+"\n")
        data=json.dumps(self.report).replace("<","\\u003c").replace("\u2028","\\u2028").replace("\u2029","\\u2029")
        template=(ROOT/"bench/view.html").read_text()
        (self.out/"index.html").write_text(template.replace("__MATRIX_DATA__",data))

    def execute(self) -> None:
        try:
            sources,natives=self.prepare()
            self.build_cells(sources,natives)
            self.measure()
            self.report["status"]="passed"
            passed=[c for c in self.report["cells"] if c["status"]=="passed"]
            self.report["passed_cells"]=len(passed)
            self.report["capacity_case_executions"]=sum(c["correctness_cases"] for c in passed)
        except Exception as error:
            self.report["status"]="failed"
            self.report["error"]=str(error)
            raise
        finally:
            self.save()
            self.events.close()
            shutil.rmtree(self.scratch)


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codin",type=Path)
    parser.add_argument("--output",default="build/matrix")
    parser.add_argument("--samples",type=int,default=9)
    parser.add_argument("--build-samples",type=int,default=3)
    parser.add_argument("--emit-samples",type=int,default=15)
    parser.add_argument("--target-ms",type=float,default=15)
    args=parser.parse_args()
    if args.samples<5 or args.build_samples<1 or args.emit_samples<5 or not 1<=args.target_ms<=1000:
        parser.error("need >=5 runtime/emitter samples, >=1 build sample, and target-ms in [1,1000]")
    Matrix(args).execute()


if __name__=="__main__": main()
