# Three compiler strategies against native Odin

## Reproduce

```sh
make test unit audit
make completeness
make matrix
```

`make completeness` uses GCC and Clang at O0/O3, zig-cc at O0/O3, and TinyCC
at its ordinary non-optimizing settings. Install the same pinned Odin and Zig
versions as `.github/workflows/completeness.yml`. Override `ODIN`, `CC`, `CLANG`,
`ZIG`, or `TCC` to select installed tools. Artifacts live in `build/completeness`.
The HTML report works offline and can filter by feature, category or outcome.

A focused development run does not validate or update the complete baseline:

```sh
python3 tools/completeness.py --filter defer --compilers gcc,clang
```

## Three strategies, plus one control

| Entrant | Semantics and code generation |
|---|---|
| `emit-c-direct` | Experimental independent AST emitter; known coverage and diagnostic gaps remain visible |
| `emit-c-mir` | Scoped lowering, verified typed MIR, copy fusion, flat C statements |
| `emit-c-expr` | The same checked MIR, followed by bounded pure-expression reconstruction |
| `emit-c-mir-raw` | Unoptimized, verified flat-MIR control; not a fourth independent semantic implementation |

MIR and expression reconstruction share a lowerer. Agreement between them is not
proof of correctness. Native Odin is the independent oracle, and its own
`-o:none` and `-o:speed` executions must agree before a fixture is scored.

The expression backend reconstructs only single-definition, single-read pure
temporaries within an effect-free basic-block region. Calls, loads, stores,
mutable writes and control flow are barriers. Division/remainder remain
materialized. Shift counts are not duplicated, and every reconstructed interior
node converts back to its MIR type. Recursion is bounded at depth 24. The
schedule does not mutate the checked MIR. `dump-expr-plan` exposes its choices.

## What the completeness score means

The initial version contains 133 hand-written probes: 95 valid programs and 38
invalid programs across 15 categories. `tools/completeness_cases.py` is the
versioned inventory. It spans scalar types, expressions, scope, procedures,
control flow, cleanup, memory, aggregate/container types, metaprogramming,
packages, runtime/ABI features, constants and diagnostics. The public reference
is Odin's overview: https://odin-lang.org/docs/overview/ .

This is a corpus score, not a percentage of the Odin language implemented. A
single passing struct example would not prove every struct/ABI rule. Standard
library conformance, self-hosting, all targets, all compiler flags, generics and
complete type-system coverage are not claimed by a green run.

For each valid fixture, native Odin must check it, build it at both optimization
levels, link it to a fixed C harness, and produce the same nonempty output for
two input seeds. Each seed contains 128 calls including integer edge values.
Every call records the exact return value and all 32 bytes of caller-owned
memory. The test compares those bytes, not only a checksum. Every Borr emitter
must also produce byte-identical C on repeat invocations.

For each invalid fixture, native Odin must diagnose it. Borr only gets rejection
credit for a nonzero compiler exit with a diagnostic that preserves an existing
output file. Producing invalid C and leaving rejection to the C compiler does
not count. Crashes, unavailable tools, timeouts and damaged outputs are separate
outcomes. Valid-but-rejected programs stay in the coverage denominator.

## Regression policy

`test/completeness-baseline.json` stores every fixture fingerprint and observed
outcome. A baseline run rejects removed fixtures, changed fingerprints, lost
passing cells, lost correct rejections, and newly unsafe outcomes for an existing
case. Mandatory checked-path features must pass all requested configurations.
Every invalid case must be rejected by the checked paths. A wrong answer or
runtime crash/timeout in either checked path fails the run, even for a discovery
probe that was not declared supported.

The experimental direct backend's known failures are displayed, not relabeled
as successes. Original direct-backend controls remain independently required by
`make test`; an empty baseline cannot replace that check.

A full, passing investigation can write a reviewed new baseline with
`--write-baseline`. Partial or failed runs cannot do so. Changing both a corpus
and its baseline still requires ordinary code review; the gate is not a claim
of tamper-proof policy enforcement.

All processes have timeouts and separate process groups. On timeout the harness
kills the group. A private copy of the tested Borr executable is kept per run,
so rebuilding another candidate cannot silently change an in-flight experiment.
Exact commands, versions, source fingerprints, compiler checksum, diagnostics,
C output, native output and the scorecard are retained in the CI artifact.
Command wall times in this report are diagnostic, not a performance ranking.
The separate matrix performs the performance measurements.

## Repairs driven by this expansion

The checked lowerer now covers unsigned C-style/condition-only loops, labeled
`break`/`continue`, lazy conditional expressions, if initializers, scoped deferred
cleanup, and indexed compound assignment. Deferred statements execute in reverse
order on scope exit, return, break and continue. Deferred names bind lexically;
return values are captured before cleanup effects. Nested defer bodies and
control transfers from a deferred body are explicitly outside this slice.

The indexed compound-assignment probe found a shared lowerer bug: the first
version resolved the place and loaded its value before evaluating RHS effects.
Native Odin resolves the destination, evaluates RHS effects, then reads the
stored value for the compound operation. All three MIR variants initially
agreed on the wrong answer. The retained regression requires the native order.

Fixed-width `u16` and `u64` extend the unsigned type ladder. Direct C emission
also preserves narrow binary intermediates, decodes source literal spellings,
and guards oversized shifts without duplicating the count. Inferred untyped
integer/rune locals are not silently mapped to unsigned `uintptr`: they are
diagnosed until signed default types have a real lowering implementation.
Unreachable statements are checked instead of discarded, and unsupported
parameter defaults/attributes are no longer silently ignored.

The generated arithmetic audit is separate from feature coverage. It preserves
the original first 128 generated procedures and adds 128 u16/u64 procedures.
Across two input seeds and 16 raw/flat/expression configurations it compares
2,097,152 results. GCC/Clang O0/O3 and ASan/UBSan builds are included. That large
number is not 2,097,152 independent language features.
