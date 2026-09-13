#!/usr/bin/env python3
"""Differential correctness gate. All generated programs come from the Odin generator.

Every command has a timeout, every oracle must run successfully, and binary
output must have the expected size before it can qualify as a comparison.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "audit"
ODIN = shlex.split(os.environ.get("ODIN", "odin"))
COMPILERS = {"gcc": shlex.split(os.environ.get("CC", "gcc")),
             "clang": shlex.split(os.environ.get("CLANG", "clang"))}
BOR = os.environ.get("BOR", str(ROOT / "build" / "bor"))
STRICT = ["-std=c99", "-pedantic-errors", "-Wall", "-Wextra", "-Werror"]
REPORT: dict = {"schema": 1, "status": "running", "commands": [], "comparisons": [],
                "negative_tests": [], "source_seed": "0xB0772026",
                "input_seeds": [20260912, 3735928559],
                "functions": 256, "inputs_per_seed": 256}


def run(label: str, command: list[str], *, timeout: int = 90,
        expect_success: bool = True) -> subprocess.CompletedProcess:
    start = time.perf_counter_ns()
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        (OUT / f"{label}.stderr").write_bytes(error.stderr or b"")
        raise RuntimeError(f"{label}: timed out after {timeout}s") from error
    duration = (time.perf_counter_ns() - start) / 1e6
    (OUT / f"{label}.stdout").write_bytes(result.stdout)
    (OUT / f"{label}.stderr").write_bytes(result.stderr)
    REPORT["commands"].append({"label": label, "argv": command, "returncode": result.returncode,
                               "elapsed_ms": duration})
    if expect_success and result.returncode:
        raise RuntimeError(f"{label}: exit {result.returncode}\n{result.stderr.decode(errors='replace')[-4000:]}")
    return result


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compare(label: str, got: bytes, expected: bytes, required_length: int) -> None:
    if required_length <= 0 or len(expected) != required_length or len(got) != required_length:
        raise RuntimeError(f"{label}: wrong output lengths {len(got)}, {len(expected)}; expected {required_length}")
    if got != expected:
        offset = next(i for i, (x, y) in enumerate(zip(got, expected)) if x != y)
        raise RuntimeError(f"{label}: observable mismatch at byte {offset}")
    REPORT["comparisons"].append({"label": label, "bytes": len(got), "sha256": sha(got)})


def workload(name: str, source: Path, host: Path, seeds: list[int | None], length: int) -> None:
    archive = OUT / f"{name}-native.a"
    run(f"{name}-native-build", ODIN + ["build", str(source), "-build-mode:static",
        "-no-entry-point", "-o:speed", "-reloc-mode:pic", f"-out:{archive}"])
    native = OUT / f"{name}-native"
    run(f"{name}-native-link", COMPILERS["gcc"] + STRICT + ["-O2", str(host), str(archive),
        "-lm", "-ldl", "-lpthread", "-o", str(native)])
    expected = {}
    for seed in seeds:
        args = [] if seed is None else [str(seed)]
        data = run(f"{name}-native-{seed}", [str(native)] + args, timeout=20).stdout
        if len(data) != length:
            raise RuntimeError(f"native oracle {name}: expected {length} bytes, got {len(data)}")
        expected[seed] = data

    for mode in ("emit-c-mir-raw", "emit-c", "emit-c-expr"):
        tag = "raw" if mode.endswith("raw") else "expression" if mode == "emit-c-expr" else "optimized"
        generated = OUT / f"{name}-{tag}.c"
        run(f"{name}-{tag}-emit", [BOR, mode, str(source), "-o", str(generated)])
        repeat = OUT / f"{name}-{tag}-repeat.c"
        run(f"{name}-{tag}-repeat", [BOR, mode, str(source), "-o", str(repeat)])
        compare(f"{name}-{tag}-deterministic", generated.read_bytes(), repeat.read_bytes(), generated.stat().st_size)
        dump = OUT / f"{name}-{tag}.mir"
        run(f"{name}-{tag}-dump", [BOR, "dump-mir-raw" if tag == "raw" else "dump-mir", str(source), "-o", str(dump)])
        for compiler, command in COMPILERS.items():
            for level in ("O0", "O3"):
                label = f"{name}-{tag}-{compiler}-{level}"
                exe = OUT / label
                run(label + "-build", command + STRICT + [f"-{level}", str(generated), str(host), "-o", str(exe)])
                for seed in seeds:
                    result = run(f"{label}-{seed}", [str(exe)] + ([] if seed is None else [str(seed)]), timeout=20)
                    compare(f"{label}-{seed}", result.stdout, expected[seed], length)
            if tag != "raw":
                label = f"{name}-{tag}-{compiler}-sanitized"
                exe = OUT / label
                run(label + "-build", command + STRICT + ["-O1", "-g", "-fsanitize=address,undefined",
                    "-fno-sanitize-recover=all", "-fno-omit-frame-pointer", str(generated), str(host), "-o", str(exe)])
                for seed in seeds:
                    result = run(f"{label}-{seed}", [str(exe)] + ([] if seed is None else [str(seed)]), timeout=20)
                    compare(f"{label}-{seed}", result.stdout, expected[seed], length)
    print(f"{name}: native agrees with raw/optimized GCC/Clang O0/O3 and sanitized optimized output", flush=True)


INVALID = {
    "parameter-write": '@(export) f :: proc "c" (x:u32)->u32 { x=1; return x }',
    "arity": 'helper :: proc "c" (x:u32)->u32 { return x }\n@(export) f :: proc "c" ()->u32 { return helper() }',
    "argument-type": 'helper :: proc "c" (x:u32)->u32 { return x }\n@(export) f :: proc "c" ()->u32 { return helper(true) }',
    "return-type": '@(export) f :: proc "c" ()->u32 { return true }',
    "missing-return": '@(export) f :: proc "c" (b:bool)->u32 { if b { return 1 } }',
    "empty-return": '@(export) f :: proc "c" ()->u32 { return }',
    "void-return": '@(export) f :: proc "c" () { return 1 }',
    "bool-arithmetic": '@(export) f :: proc "c" (b:bool)->bool { return b + b }',
    "assignment-type": '@(export) f :: proc "c" ()->u32 { x:=u32(1); x=true; return x }',
    "scope-escape": '@(export) f :: proc "c" ()->u32 { { x:=u32(1) }; return x }',
    "duplicate-local": '@(export) f :: proc "c" ()->u32 { x:=u32(1); x:=u32(2); return x }',
    "duplicate-proc": 'f :: proc "c" (){}\nf :: proc "c" (){}',
    "write-constant": 'K :: u32(1)\n@(export) f :: proc "c" ()->u32 { K=2; return K }',
    "constant-cast": '@(export) f :: proc "c" ()->u8 { return u8(256) }',
    "constant-add": '@(export) f :: proc "c" ()->u8 { return u8(200)+u8(100) }',
    "constant-shift": '@(export) f :: proc "c" ()->u8 { return u8(1)<<8 }',
    "constant-zero-div": '@(export) f :: proc "c" ()->u32 { return u32(1)/u32(0) }',
    "global-cast": 'K :: u8(300)\n@(export) f :: proc "c" ()->u8 { return K }',
    "global-overflow": 'K :: u8(255)\n@(export) f :: proc "c" ()->u8 { return K+1 }',
    "wide-literal": '@(export) f :: proc "c" ()->uintptr { return 18446744073709551616 }',
    "syntax": '@(export) f :: proc "c" ()->u32 { return (1 + ) }',
}
UNSUPPORTED = {
    "default-context": 'f :: proc ()->u32 { return 1 }',
    "link-name": '@(export, link_name="renamed") f :: proc "c" ()->u32 { return 1 }',
    "import": 'import "core:fmt"\nf :: proc () { fmt.println("test") }',
    "mutable-global": 'g:u32\n@(export) f :: proc "c" ()->u32 { return g }',
    "aggregate": 'Pair :: struct { x,y:u32 }\n@(export) f :: proc "c" ()->u32 { p:=Pair{1,2}; return p.x }',
    "local-constant": '@(export) f :: proc "c" ()->u32 { K :: u32(1); return K }',
}


def negatives() -> None:
    sentinel = b"previous successful output\n"
    for valid, cases in ((False, INVALID), (True, UNSUPPORTED)):
        for name, body in cases.items():
            source = OUT / ("reject-" + name)
            source.mkdir(exist_ok=True)
            (source / "main.odin").write_text("package rejection\n" + body + "\n")
            oracle = run(name + "-native-check", ODIN + ["check", str(source), "-no-entry-point"], expect_success=valid)
            if not valid and oracle.returncode <= 0:
                raise RuntimeError(f"negative fixture {name} was not cleanly rejected by native Odin")
            for mode in ("emit-c", "emit-c-mir-raw"):
                target = OUT / "rejected.c"
                target.write_bytes(sentinel)
                result = run(name + "-" + mode, [BOR, mode, str(source), "-o", str(target)], expect_success=False)
                if result.returncode <= 0 or target.read_bytes() != sentinel:
                    raise RuntimeError(f"{name}: must diagnose failure without altering output or crashing")
            REPORT["negative_tests"].append({"name": name, "native_valid": valid, "bor": "diagnosed"})
    print(f"negative diagnostics: {len(INVALID)} invalid and {len(UNSUPPORTED)} valid-but-unsupported fixtures", flush=True)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    REPORT["platform"] = platform.platform()
    REPORT["machine"] = platform.machine()
    REPORT["revision"] = os.environ.get("GITHUB_SHA", subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip())
    REPORT["source_hashes"] = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for pattern in ("src/*.odin", "tools/generate/*.odin", "test/semantics/*.odin", "test/c99/semantics_smoke.c") for p in sorted(ROOT.glob(pattern))}
    try:
        for label, command in [("odin-version", ODIN + ["version"])] + [(name+"-version", cmd+["--version"]) for name, cmd in COMPILERS.items()]:
            run(label, command)
        generated = OUT / "generated"
        generated.mkdir(exist_ok=True)
        generator = OUT / "generate"
        run("generator-build", ODIN + ["build", "tools/generate", "-o:speed", f"-out:{generator}"])
        run("generator", [str(generator), str(generated)])
        workload("semantics", ROOT / "test/semantics", ROOT / "test/c99/semantics_smoke.c", [None], len(b"semantic regression suite passed\n"))
        workload("generated", generated, generated / "host.c", REPORT["input_seeds"], 256*256*4)
        negatives()
        REPORT["status"] = "passed"
        REPORT["generated_comparisons"] = sum(c["bytes"]//4 for c in REPORT["comparisons"]
            if c["label"].startswith("generated-") and "deterministic" not in c["label"])
        print(f"PASS: {REPORT['generated_comparisons']} generated result comparisons across 16 variants", flush=True)
    except Exception as error:
        REPORT["status"] = "failed"
        REPORT["error"] = str(error)
        raise
    finally:
        (OUT / "report.json").write_text(json.dumps(REPORT, indent=2) + "\n")


if __name__ == "__main__":
    main()
