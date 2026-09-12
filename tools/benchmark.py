#!/usr/bin/env python3
"""Interleaved, correctness-gated local measurements. Never a noisy CI speed gate."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shlex
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "benchmark"
STRICT = ["-std=c99", "-pedantic-errors", "-Wall", "-Wextra", "-Werror"]


def run(command: list[str], timeout: int = 90) -> bytes:
    p = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f"{shlex.join(command)}\n{p.stderr.decode(errors='replace')}")
    return p.stdout


def timed(cases: dict[str, list[str]], samples: int) -> dict:
    results = {name: [] for name in cases}
    for command in cases.values():
        run(command)
        run(command)
    order = list(cases)
    rng = random.Random(20260912)
    for _ in range(samples):
        rng.shuffle(order)
        for name in order:
            start = time.perf_counter_ns()
            run(cases[name])
            results[name].append((time.perf_counter_ns()-start)/1e6)
    return {name: {"argv": cases[name], "samples_ms": values,
            "p50_ms": statistics.median(values),
            "p95_ms": sorted(values)[math.ceil(len(values)*0.95)-1]}
            for name, values in results.items()}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codin", type=Path)
    parser.add_argument("--thor", type=Path)
    parser.add_argument("--normalizer-before", type=Path)
    parser.add_argument("--samples", type=int, default=21)
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("at least five samples are required")
    OUT.mkdir(parents=True, exist_ok=True)
    bor = str(ROOT / "build/bor")
    odin = shlex.split(os.environ.get("ODIN", "odin"))
    compilers = {"gcc": shlex.split(os.environ.get("CC", "gcc")),
                 "clang": shlex.split(os.environ.get("CLANG", "clang"))}
    report = {"schema": 1, "status": "running", "platform": platform.platform(),
              "machine": platform.machine(), "samples": args.samples,
              "warmups": 2, "interleave_seed": 20260912,
              "source_hashes": {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted((ROOT / "src").glob("*.odin"))},
              "odin": run(odin+["version"]).decode(),
              "c_compilers": {k: run(v+["--version"]).decode() for k,v in compilers.items()},
              "cpu": next((l.split(':',1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name')), 'unknown')}
    try:
        sources = {}
        emitters = {}
        for name, mode in (("bor-direct", "emit-c-direct"), ("bor-raw", "emit-c-mir-raw"), ("bor-optimized", "emit-c")):
            path = OUT / (name+".c")
            sources[name] = path
            emitters[name] = [bor, mode, str(ROOT / "test/melodica"), "-o", str(path)]
        if args.codin:
            sources["codin"] = OUT / "codin.c"
            emitters["codin"] = [str(args.codin.resolve()), "emit-c", str(ROOT / "test/melodica"), "-o", str(sources["codin"])]
        for command in emitters.values():
            run(command)
        # Use the existing acceptance harness before allowing any compiler into timing.
        for name, source in sources.items():
            exe = OUT / (name+"-correctness")
            run(compilers["gcc"]+STRICT+["-O3", str(source), str(ROOT/"test/c99/smoke.c"), "-o", str(exe)])
            run([str(exe)])
        report["emission"] = timed(emitters, args.samples)
        report["generated_c_bytes"] = {name:p.stat().st_size for name,p in sources.items()}
        report["generated_c_sha256"] = {name:digest(p.read_bytes()) for name,p in sources.items()}
        runtime = {}
        compile_cases = {}
        for name, source in sources.items():
            for cc, command in compilers.items():
                label = name+"-"+cc
                exe = OUT / label
                compile_cases[label] = command+STRICT+["-O3", str(source), str(ROOT/"test/c99/benchmark.c"), "-o", str(exe)]
                run(compile_cases[label])
                runtime[label] = [str(exe), "20260912", "2000"]
        archive = OUT / "native.a"
        run(odin+["build", "test/melodica", "-build-mode:static", "-no-entry-point", "-o:speed", "-reloc-mode:pic", f"-out:{archive}"])
        native = OUT / "native"
        run(compilers["gcc"]+STRICT+["-O3", str(ROOT/"test/c99/benchmark.c"), str(archive), "-lm", "-ldl", "-lpthread", "-o", str(native)])
        runtime["native-odin"] = [str(native), "20260912", "2000"]
        outputs = {name:run(command) for name,command in runtime.items()}
        if len(set(outputs.values())) != 1 or not next(iter(outputs.values())).strip():
            raise RuntimeError("runtime benchmark correctness mismatch")
        report["runtime_checksum"] = next(iter(outputs.values())).decode().strip()
        report["runtime"] = timed(runtime, 7)
        report["c_compile_and_link"] = timed(compile_cases, 5)
        report["executable_sections"] = run(["size"]+[cmd[0] for cmd in runtime.values()]).decode()
        if args.thor:
            ast = run([str(args.thor.resolve()), "test/melodica/main.odin"])
            (OUT/"thor.ast").write_bytes(ast)
            report["thor"] = {"role": "parser reference only; not a runtime comparison", "ast_bytes":len(ast), "ast_sha256":digest(ast)}
        if args.normalizer_before:
            report["normalizer_scaling"] = {}
            for count in (64, 512, 2048):
                package = OUT / ("blocks-"+str(count))
                package.mkdir(exist_ok=True)
                text = 'package scale\n@(export) f :: proc "c" (x:u32)->u32 {\na:=x\n'
                for i in range(count):
                    text += f'if a > {i} {{ a ~= {i+1} }}\n'
                text += 'return a\n}\n'
                (package/"main.odin").write_text(text)
                cases = {"linear": [bor, "emit-c-mir-raw", str(package), "-o", str(OUT/"linear.c")],
                         "quadratic": [str(args.normalizer_before.resolve()), "emit-c-mir-raw", str(package), "-o", str(OUT/"quadratic.c")]}
                for command in cases.values():
                    run(command)
                if (OUT/"linear.c").read_bytes() != (OUT/"quadratic.c").read_bytes():
                    raise RuntimeError("normalizer comparison changed C output")
                report["normalizer_scaling"][count] = timed(cases, args.samples)
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        (OUT/"report.json").write_text(json.dumps(report, indent=2)+"\n")
    for section in ("emission", "runtime", "c_compile_and_link"):
        print(section)
        for name, result in report[section].items():
            print(f"  {name:24s} {result['p50_ms']:.3f} ms (p95 {result['p95_ms']:.3f})")
    for count, values in report.get("normalizer_scaling", {}).items():
        print(f"{count} conditionals: old/new = {values['quadratic']['p50_ms']:.3f}/{values['linear']['p50_ms']:.3f} ms")


if __name__ == "__main__":
    main()
