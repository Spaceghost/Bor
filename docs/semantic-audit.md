# Semantic audit, September 12, 2026

Base compiler: `663789787a84fda6b9864e30888e1967c06f3287`.
Odin bootstrap archive: `dev-2026-09`, SHA-256
`167c3e1d7056419dad2e04bb3bd98715b7ff286d4c125f3c5a5ee337c6254283`.
Codin: `5cd28a63023c24079f16e9a51a0140501cebdfa2`.
Thor: `5e7a2fa67063ca71d7efabb90fbde66a8c91d2fe` (debug parser build).

## Findings and repairs

| Failure | Repair | Regression |
|---|---|---|
| Nested calls interleaved inner arguments into the outer span | Reserve the entire outer argument span before recursive lowering | `nested_calls`, `ordered_calls` |
| Inner scope bindings leaked into later statements | Binding trail with scope marks and reverse restoration | `lexical_scope` |
| Uninitialized locals and boolean literals were rejected | Explicit typed zero/null/false initialization | `zero_locals`, `short_circuit` |
| Both arms returned but a phantom join still fell through | Allocate a join only for paths that reach it | `all_paths_return` |
| Inclusive maximum could wrap into an infinite loop | Exit before incrementing the maximum index | Three integer-width range cases |
| A bound containing a call was evaluated only once | Lower the bound into the loop condition path | `dynamic_bound` |
| C promotions changed narrow intermediate arithmetic | Typed MIR results and unsigned C operands | `byte_arithmetic`, generated u8/u32 corpus |
| Oversized C shifts could invoke undefined behavior | Width guard with zero result outside the width | 0..79 shift-count sweep |
| Odin numeric spellings were copied verbatim into C | Checked numeric decoding and decimal C emission | `source_literals` |
| Invalid call/return/type shapes reached C emission | Structural ownership and scalar type checks | Rejection corpus and MIR mutation tests |
| Constant overflow could be silently truncated | Checked constant metadata separate from mutable locals | Constant cast/add/shift/global rejection cases |
| Export attributes could silently change ABI meaning | Reject currently unsupported ABI forms | Context/link-name rejection cases |

Native Odin reevaluates the exercised range upper bound on each condition test.
An initial “evaluate once” expectation was rejected by the native oracle; the
regression retains the observed native result instead.

For `u32((x+x)/2)` with `x:u8=200`, native Odin and the repaired MIR path return
72. The direct control returns 200. This is why the direct control is not a
production default and cannot stand in for a semantic oracle.

## Optimization contract

The first pass rewrites `temp = operation; destination = temp` only when the
instructions are adjacent in one basic block, the temporary has one definition
and one read, and destination types agree. It moves no side effect or branch.
Multiple-read and multiple-definition cases are unit-tested exclusions. The
verifier runs on both sides of the pass. Raw MIR remains independently runnable.

CFG normalization previously scanned all blocks to find a physical successor;
linkage normalization also nested a declaration scan over the procedure table.
The successor is now obtained from the next label and linkage uses a name map.
This removes those quadratic searches without changing generated C.

## Reproduction and boundaries

```sh
make test unit audit
make benchmark BENCH_ARGS="--codin /path/to/codin --thor /path/to/thor"
```

The audit report records 21 invalid and 6 valid-but-unsupported rejection cases,
128 generated procedures, two input seeds, and ten compiler configurations.
All 655,360 generated result comparisons are exact, with successful native
execution and a 131,072-byte output required for every seed/configuration.
The separate hand-written regression harness exercises control flow and effects.

Timing samples are interleaved with a fixed order seed and recorded individually.
The local host is shared and noisy. Measurements of a tiny package are not a
claim about general compiler throughput, complete Odin programs, or universal
runtime superiority. A smaller C file also does not guarantee faster C compilation.

To isolate normalization, build a second copy of the same compiler with the
base revision's `src/sema.odin`, then pass its path as
`--normalizer-before /path/to/that/bor`. The benchmark first requires byte-identical
C for both implementations. It measures packages containing 64, 512, and 2,048
conditionals; that workload tests the block-successor search, not every scaling
property of the compiler.

The generator currently targets bounded pure unsigned expression trees. It is
not coverage-guided fuzzing and has no reducer yet. Signed operations, aggregate
ABI, package semantics, memory safety, complete constant-expression rules,
dominance, and full Odin conformance remain separate milestones. The C output is
not a sandbox. The exercised pointer-width model matches the 64-bit host; other
target widths are not yet validated.
