# Borr

**An Odin-to-C compiler written in Odin.** Repository: `Bor`. Executable: `bor`.

Borr implements a checked scalar subset, not the complete Odin language. Its development loop is executable: compare native Odin, verified raw MIR, optimized MIR, and independent reference implementations before making performance claims.

## Build and use

The tested bootstrap compiler is Odin `dev-2026-09`; CI verifies its release archive checksum. GCC, Clang, Make, and Python 3 are used for the test and measurement tools. The compiler and test-program generator are written in Odin.

```sh
make bor
./build/bor emit-c test/melodica -o build/melodica.c
cc -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 \
  build/melodica.c test/c99/smoke.c -o build/smoke
./build/smoke

make test unit audit
make benchmark
```

`emit-c` now selects the **verified, optimized MIR path**. The controls remain available:

```sh
./build/bor emit-c-mir-raw test/semantics -o build/semantics-raw.c
./build/bor emit-c-mir test/semantics -o build/semantics.c
./build/bor dump-mir-raw test/semantics -o build/semantics-raw.mir
./build/bor dump-mir test/semantics -o build/semantics.mir
./build/bor emit-c-direct test/melodica -o build/direct.c
```

“Raw” means unoptimized, **not unchecked**. The direct AST-to-C emitter is an experimental comparison control: it passes the original fixtures but has known semantic gaps on the wider corpus. It is no longer the default.

## Compiler pipeline

```text
Odin source
  -> core:odin/parser + core:odin/ast
  -> scoped scalar lowering and constant checks
  -> semantic normalization and explicit two-successor CFG
  -> structural and type verification
  -> adjacent single-use copy fusion
  -> verification again
  -> one readable C99 translation unit
  -> GCC / Clang
```

Borr uses Odin's shipped tooling parser rather than maintaining another grammar. Borr owns semantics after parsing; using that parser does not provide Odin's full semantic checker.

The MIR uses distinct value, block, and procedure IDs into flat tables. Procedures own contiguous table ranges. Conditional branches name both successors. Optimization retains instruction coordinates by replacing eliminated copies with explicit `nop` records. `dump-mir` exposes the representation actually consumed by the backend.

Export linkage is independent of calling convention. Unsupported ABI attributes and context-bearing procedures are diagnosed rather than silently treated as C functions.

## What this slice exercises

The fixtures cover `u8`, `u32`, `uintptr`, `bool`, byte multi-pointers, scalar casts, direct calls, `@(export)`, C/contextless procedures, scoped locals, zero initialization, assignments, unsigned arithmetic, bit operations, conditionals, short-circuit expressions, bounded ranges, and returns.

The semantic audit specifically checks nested argument lists, left-to-right call effects, shadow restoration, all-branches-return control flow, byte-width intermediate arithmetic, oversized shifts, source integer spellings, dynamically reevaluated range bounds, and inclusive ranges ending at the maximum integer value.

Typed constant overflow is diagnosed. Runtime unsigned arithmetic retains its width and wrapping behavior. These are separate rules; optimization must not turn one into the other.

This is **not** a full type checker or an implementation of signed arithmetic, aggregates, strings/slices, imports, generic procedures, the implicit Odin context, or the broader runtime. Unsupported and invalid inputs are distinct categories in the audit. Dominance and definite-assignment proofs are not yet part of the MIR verifier.

## Shootout and evidence

`make test` keeps the original 15 native/direct/MIR executable controls. `make unit` exercises MIR verification and the copy-fusion guards. `make audit` adds:

- A deterministic **Odin-written generator**: 128 procedures, 256 input pairs per seed, two runtime input seeds.
- Exact native-Odin output comparison against raw and optimized MIR under GCC and Clang at `-O0` and `-O3`, plus optimized AddressSanitizer/UndefinedBehaviorSanitizer builds.
- **655,360 generated result comparisons** across those ten variants. This is a bounded corpus, not 655,360 independent language features or proof of complete correctness.
- Rejection cases checked against native Odin, including immutable parameters, argument/return types, scope escape, duplicate declarations, malformed syntax, and constant overflow. Failure must preserve an existing output file.

Every process has a timeout. Oracle success and the exact expected output length are required before a comparison can pass. Failed or empty executions cannot qualify as agreement.

The `Semantic audit and measured shootout` workflow retains the executable, its checksum, exact revision, generated Odin/C, raw/optimized MIR, diagnostics, native outputs, commands, and machine-readable reports in `bor-semantic-evidence-<run-id>`.

`make benchmark` records interleaved raw timing samples, warmups, compiler versions, source hashes, generated C sizes, executable sections, compile/link time, and runtime checksums. Timing is informational, not a noisy CI speed threshold.

```sh
make benchmark BENCH_ARGS="--codin /path/to/codin --thor /path/to/thor"
```

Codin is an independent executable reference where its implemented surface overlaps. Thor is a parser and data-oriented architecture reference; its AST output is **not** counted as a runtime result. Native Odin remains the behavior oracle. The pinned revisions are in CI and [the audit notes](docs/semantic-audit.md).

## Next milestones

The next language ladder is a real address/lvalue model, structs and fixed arrays, enums, slices/strings, multiple returns and `defer`, unions, imports/runtime integration, and generics. Each addition needs positive, negative, and differential fixtures before becoming supported.

The Graal/Sulong inspiration is an inspectable semantic representation shared by execution, optimization, and tooling. Borr currently emits C ahead of time. It does not contain a JIT, Truffle integration, speculative optimization, or a self-hosting compiler.

## Native and C toolchain matrix

`make matrix` adds native Odin, native Zig ReleaseFast/ReleaseSafe, algorithm-matched
C, and optimized lookup-table C alongside the three Borr paths and pinned Codin.
GCC, Clang, zig-cc, and TinyCC occupy separate columns. Native rows keep their
language-generated object fixed and vary only the link driver.

Open `build/matrix/index.html` for an offline side-by-side source/assembly browser,
workload selectors, timings, code sizes, flags, and provenance. Raw JSON, commands,
objects, and correctness diagnostics are retained in CI artifacts.
See [matrix methodology and reproduction](docs/toolchain-matrix.md).
