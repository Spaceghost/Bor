# Bor

**Bor is an Odin-to-C compiler written in Odin.**

It uses Odin's own tooling parser as the syntax authority, then takes ownership of semantics in a compact typed MIR before emitting strict C99. The point is not to maintain a second Odin grammar forever. The point is to build a small, inspectable compiler pipeline whose behavior can be proved against Odin itself and competing implementations.

Bor is early. It is also already executable, differential-tested, deterministic, and faster than the pinned Codin reference on the current tiny-package shootout. Those are more useful properties than an enormous README claiming the language is finished.

## Pipeline

```text
Odin source
    |
    v
core:odin/parser + core:odin/ast
    |  Odin owns syntax
    v
semantic normalization
    |  export visibility != calling convention
    |  parser spellings become semantic metadata
    v
flat typed MIR
    |  Value_ID / Block_ID / Proc_ID
    |  contiguous value, op, block and call-argument tables
    v
MIR verifier
    |  ranges, operands, block termination, targets, calls, CFG counts
    +------------------------------+
    |                              |
    v                              v
human-readable `dump-mir`       strict C99 backend
                                   |
                         +---------+---------+
                         |                   |
                         v                   v
                       GCC                 Clang
```

There is also a deliberately retained direct AST-to-C backend. It is useful as an independent implementation for differential testing while MIR becomes the canonical compiler path.

The design rule is simple: **front-end syntax may be complicated; the middle of the compiler should not be mysterious.**

## Try it

```sh
make test

# Build Bor
odin build src -out:build/bor -o:speed

# Canonical MIR path
./build/bor emit-c-mir test/control -o build/control.c

# Independent direct backend
./build/bor emit-c-direct test/control -o build/control-direct.c

# Inspect exactly the verified MIR consumed by the backend
./build/bor dump-mir test/control -o build/control.mir
```

`emit-c` currently aliases the direct backend while the MIR path is brought through the feature ladder. Both are kept under the same behavior tests.

## What is proved today

The current executable subset covers the language used by the repository's melodica, linkage, and control-flow workloads:

- `u8`, `u32`, `uintptr`, `bool`
- `[^]u8` and byte indexing
- `proc "c"` and `proc "contextless"`
- `@(export)` as linkage metadata independent of ABI
- scalar casts
- direct procedure calls
- locals and exercised local type inference
- unary and binary expressions
- Odin XOR spelling (`~`, `~=`) lowered correctly to C/MIR semantics
- assignments and compound assignments
- `if` / `else`
- short-circuit `&&` / `||`
- bounded `for i in a..<b` and `..=` ranges
- returns

Unsupported AST shapes fail loudly instead of being translated by optimism.

## The shootout

Bor is developed in loops against three oracles:

1. **Native Odin** is the semantic authority for observable behavior.
2. **Codin** (`Spaceghost/codin`, pinned in CI) is the executable Odin-to-C reference.
3. **Thor** (`Spaceghost/Thor`, pinned in CI) is a useful modern front-end/data-oriented design reference.

Every supported slice is expected to survive:

- deterministic Bor emission, byte-for-byte across repeated runs;
- strict `-std=c99 -pedantic-errors -Wall -Wextra -Werror` compilation;
- GCC and Clang;
- native-Odin differential behavior;
- adversarial semantic fixtures, not only happy paths;
- Codin/Thor comparison where their implemented surface overlaps;
- generated-source, binary-size, and CLI-latency reporting.

The linkage fixture is intentionally hostile: it gives an internal Odin `proc "c"` the same C symbol name as a function supplied by the host harness. If Bor confuses calling convention with `@(export)`, it fails at link time or runtime.

### Current pinned tiny-package result

GitHub Actions run 61, `dev-2026-09` Odin, 30 warm CLI samples after one discarded cold invocation:

| compiler path | p50 emit latency | p95 |
|---|---:|---:|
| Bor direct | **1.175 ms** | 1.245 ms |
| Bor MIR + verify | **1.311 ms** | 1.397 ms |
| Codin | 8.762 ms | 13.289 ms |

This is a deliberately tiny workload, not a universal compiler benchmark. On this workload Bor MIR is about **6.7x faster** than the pinned Codin executable while also running the verifier.

The same run produced these GCC text sizes:

| workload | Bor direct | Bor MIR | Codin |
|---|---:|---:|---:|
| melodica smoke | 2712 B | **2664 B** | 2712 B |
| control smoke | 1483 B | **1472 B** | n/a in the linked size report |

Clang produced identical text sizes for Bor direct vs MIR on both measured workloads. Generated MIR C is currently much more verbose than direct C; optimized machine code is the metric that matters for this stage, and readability/compaction remains an obvious backend improvement.

## MIR

Bor's MIR is intentionally flat and boring in the complimentary compiler-engineering sense.

- values, blocks, procedures, instructions, and call arguments use indexed tables;
- IDs are distinct types rather than interchangeable integers at interfaces;
- procedures own contiguous ranges into module tables;
- instructions have fixed-shape records instead of object graphs;
- calling convention and export visibility are separate facts;
- semantic normalization happens before verification;
- the C backend only receives verified MIR;
- `dump-mir` exposes that exact representation deterministically.

The verifier currently checks table ranges, value and procedure IDs, parameter ownership, basic-block initialization and termination, label identity, instruction operands, call ranges, branch targets, and stored incoming-edge counts.

A compiler IR that cannot explain itself is merely a future debugging incident with branding.

## Why Codin and Thor are references, not foundations

Bor borrows evidence and ideas, not implementation debt.

Codin is valuable because it already exercised a useful Odin-to-C surface and gives the shootout an independent implementation. Thor is valuable because its modern parser work and data-oriented direction are closer to where a clean compiler should go. Odin's own `core:odin/parser` remains the source of truth for syntax, so Bor can spend its complexity budget on semantic lowering, IR, diagnostics, optimization, and portable C.

## Next compiler loops

The immediate architectural target is to remove physical block order from control-flow meaning. Conditional MIR branches should name **both successors explicitly** so blocks can be reordered by later passes without silently changing semantics.

After that, feature work proceeds through the same evidence loop rather than as a giant syntax land-grab:

1. explicit CFG edges + verifier strengthening;
2. a real lvalue/address model;
3. structs, fixed arrays, enums, and richer pointer operations;
4. slices and strings;
5. tuples / multiple returns and `defer`;
6. unions and broader aggregate ABI lowering;
7. imports/packages and runtime surface;
8. generics and the remaining Odin type-system surface;
9. optimization passes, each verified before and after transformation;
10. differential fuzzing over the supported subset.

The long-term standard is not merely "Odin that happens to compile to C." Bor should emit portable, small, readable C; cross-compile without ceremony; make wrong IR difficult to represent and easy to diagnose; and stay simple enough that a compiler engineer can inspect a lowering decision without excavating a framework.
