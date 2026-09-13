# Native and C toolchain matrix

Run `make matrix` (alias: `make benchmark-matrix`). The existing `make benchmark`
remains available; the expanded semantic audit is a separate correctness gate. The new report is
`build/matrix/index.html`: a self-contained offline, side-by-side source and
machine-code browser. It requires no web server and performs no network requests.
It is an evidence viewer, not a live Compiler Explorer deployment.

## Entrants

| Implementation | Kernel code generation |
|---|---|
| Borr direct | AST to C control, then selected C compiler |
| Borr raw MIR | Verified unoptimized MIR to C, then selected C compiler |
| Borr optimized MIR | Verified optimized MIR to C, then selected C compiler |
| Borr expression | Verified MIR with bounded pure-expression reconstruction, then selected C compiler |
| Codin (optional locally, required in CI) | Pinned reference to C, then selected C compiler |
| C scalar | Handwritten, algorithm-matched two-pass branch implementation |
| C LUT | Optimized scalar implementation using immutable classification/hex tables |
| Native Odin | Original Odin fixture, `-o:speed` |
| Native Zig fast | LUT algorithm, LLVM, `-O ReleaseFast` |
| Native Zig safe | The same LUT algorithm, LLVM, `-O ReleaseSafe` |

Columns are **GCC, Clang, zig-cc, and TinyCC**. The first seven rows genuinely
recompile C with each column's compiler. The native rows use one unchanged
Odin/Zig-produced object or archive across the four link drivers. A C compiler
cannot compile Odin or Zig source. Native kernel-build timings repeat across
columns intentionally; they are not four independent native compiler runs.

The scalar C row distinguishes language/compiler differences from algorithm
changes. The optimized C and Zig rows implement the same lookup-table algorithm.
Neither is claimed to be the globally optimal implementation or SIMD ceiling.

Thor remains the parser reference in the existing shootout. Its AST output is
not a native executable and is not ranked as one here.

## Fairness and measurement

All kernels target baseline x86-64 Linux, use no LTO, and receive no `restrict`
promise or relaxed buffer contract. GCC/Clang use `-O3 -march=x86-64`. Zig's C
driver uses its `-mcpu=baseline` spelling; its CPU flag parser is not interchangeable
with every Clang/GCC spelling. Native Zig explicitly uses LLVM and baseline CPU. ReleaseSafe also uses
`-fcompiler-rt` to retain the runtime helpers its standalone object needs;
ReleaseFast does not force unused compiler-runtime code into the object.
TinyCC uses its normal code generator: it is not mislabeled as an `-O3` build.

A single GCC `-O2` runtime harness object is reused byte-for-byte in every cell.
Initialization and complete-output hashing are outside its CLOCK_MONOTONIC timed
region. Process startup is excluded. Kernel calls cross object boundaries, and
the checksum remains observable. The runtime child is pinned to one available
CPU, but the runner is shared and frequency/load are not controlled.

The workloads cover 32-byte mixed data, 4 KiB unreserved ASCII, 4 KiB mixed data,
4 KiB binary data, and 64 KiB mixed data. Data comes from two fixed runtime seeds.
Round counts are calibrated once per workload against native Odin, then held
constant for every cell. Nine runtime samples per cell/workload are interleaved
with deterministic randomized order. Reports retain raw values, median, p95,
and median absolute deviation; small differences are not declared universal wins.

C emission, native/kernel compilation, link-driver invocation, and runtime are
separate metrics. Kernel compilation uses a fresh source pathname for each sample
to defeat source-object cache hits, while infrastructure/global caches stay warm.
The first invocation is recorded, but is **not** described as a cold-machine
build. Linking is explicitly a repeated driver invocation with caches retained.
Build samples are grouped by cell, not interleaved across all toolchains.

Assembly is disassembled from the exact native object/archive, including for
TinyCC. The compact code-size metric sums only the three exported `melodica_*`
function bodies. It excludes helpers, tables, runtime and file headers; the full
object size output is also retained. Missing symbol sizes are unknown, not zero.

## Correctness gate and TinyCC policy

Every timed cell must pass 4,128 independent capacity/buffer cases: every length
0..257, four byte distributions, four capacities, all output bytes and guard
bytes, source immutability, size queries, empty input, and null pointers. This
preserves the original ABI's required-size return and no-write-on-short-capacity
behavior. Runtime output length, checksum, and full-output hash must then match
native Odin on every timed sample.

This gate is scoped to this workload. It does not erase the direct emitter's
known wider-language miscompilations, prove pointer aliasing semantics, or replace
the expanded 2,097,152-result semantic audit.

TinyCC build/link/correctness failures are retained with diagnostics as excluded
cells, never silently assigned a timing. GCC/Clang/zig-cc failures fail the job.
A runtime mismatch fails the job regardless of compiler. TinyCC is not removed
merely because its runtime is slower: compile latency is a separate useful axis.
Its less strict warning/standard support is not equated with the GCC/Clang/zig-cc
pedantic C99 checks.

## Reproduction and evidence

```sh
make test unit
make matrix MATRIX_ARGS="--codin /path/to/codin"
# Commands can contain arguments, e.g. TCC="tcc -B/path/to/tcc/runtime".
ZIG=/path/to/zig make matrix
```

The tested Zig release is 0.16.0, with archive SHA-256 pinned in the workflow.
Odin remains pinned to dev-2026-09, Codin to the existing reference commit.
TinyCC comes from the Ubuntu 24.04 package repository; the exact distro package
version is recorded. GCC/Clang versions are recorded, not advertised as fixed by
`ubuntu-24.04`. Native toolchain versions, exact flags, CPU, revision, source/object/
executable hashes, logs, objects, binaries, and disassembly accompany JSON and HTML
in `borr-toolchain-matrix-<run-id>`.

The report contains generated code and executable files. It is not a sandbox.
An Odin row under zig-cc is an interoperability/link-driver test, not a claim
that Odin uses Zig for its native code generator.

The setup workflow `Matrix toolchain kit` can retain the verified Zig archive and
TinyCC package for offline development. It is separate from benchmark timing.
