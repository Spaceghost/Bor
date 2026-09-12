# Borr

**An Odin-to-C compiler, written in Odin.** Repository: `Spaceghost/Bor`; executable: `bor`.

Borr translates a checked subset of Odin into ordinary C99. The same indexed intermediate representation can be inspected, interpreted under a fuel budget, and lowered to GCC, Clang, or Zig cc. It has its own semantic checker and verifier; it is not a regex translator or a wrapper around native Odin code generation.

```text
Odin source → core:odin/parser → Borr checker → indexed SoA IR
                                                │
                                      verify → optimize → verify
                                                │
                              ┌─────────────────┼────────────────┐
                         bounded eval        IR listing       portable C99
                                                               │
                                                       GCC · Clang · Zig cc
```

## Run it

With Odin `dev-2026-09`, GCC, Clang, Python 3.10+, and Make installed:

```sh
make test
./build/bor eval tests/semantics --entry sum_upto --arg 10
# 45
./build/bor emit-c tests/bench -o build/mix32.c
cc -std=c99 -pedantic-errors -O2 -c build/mix32.c -o build/mix32.o
./build/bor ir tests/bench
```

`emit` aliases `emit-c`. `check` stops after semantic/IR verification. `--no-opt` disables the IR optimization pass. The interpreter supports `--entry`, repeated `--arg`, and a shared `--steps` budget; it is a testing engine, not a security sandbox.

A checksum-verified Linux/amd64 bootstrap is available without changing the host installation:

```sh
sh tools/setup-toolchains.sh "$PWD/build/toolchains"
export PATH="$PWD/build/toolchains/odin:$PWD/build/toolchains/zig:$PATH"
make test cross
make references shootout
```

The official Odin Linux binary requires a compatible libc environment. Existing installations can be selected with `ODIN=/path/to/odin`; no containers or emulation are required.

## Implemented profile

The checked scalar engine supports signed/unsigned 8-, 16-, 32-, and 64-bit integers; distinct `int`, `uint`, and `uintptr`; booleans; exact integer constants; forward declarations and recursion; scalar C exports; local declarations; simultaneous assignment; casts and equal-width integer transmutes; arithmetic/bitwise/comparison expressions; lazy logical and conditional expressions; `if`; numeric ranges including inclusive maximum endpoints; condition and clause loops; `break`, `continue`, and scoped LIFO `defer`.

Constants use `core:math/big`. Runtime arithmetic uses explicit wrapping operations and defined C conversions, rather than relying on signed-overflow undefined behavior. Calls and potentially trapping operations remain ordered. Every IR pass is checked for operand types, indices, call spans, labels, control-flow fallthrough, and dominance.

**This is not yet a complete or self-hosting Odin compiler.** Aggregates, pointers, arrays, strings, imports, generics, multiple/named results, shifts, floating point, and the broader runtime/context surface remain outside this engine's profile and are rejected. `int`, `uint`, and `uintptr` currently have an explicit 64-bit profile. Cross-object tests on 32-bit targets prove C portability of that profile, not native Odin ABI compatibility there. Default-context procedures have no externally compatible Odin context ABI; public entry points require `proc "c"`.

The separate implementation developed concurrently on `master` is preserved. Its pointer/URL-encoding work is complementary; it has not been silently replaced or advertised as integrated into this verified engine.

## Shootout, not folklore

`make test` compares golden and seeded generated programs against native Odin, optimized/unoptimized IR interpretation, GCC and Clang at `-O0`/`-O2`, and Clang undefined-behavior sanitization. Zig cc joins when installed. Rejection tests distinguish invalid Odin from intentionally unsupported valid features and check that output aliases cannot overwrite source files.

`make shootout` uses one common source corpus for Borr, the pinned Codin C99 fork, and native Odin. It verifies emitted-C determinism and the compiled results before reporting timings. It retains raw samples, medians/MAD, source/tool hashes, commands, object sizes, available peak-RSS measurements, and observable runtime checksums. Source-to-C time is not ranked against native source-to-object time.

The runtime workload is a 32-bit LCG dependency chain: useful as a regression probe, **not evidence of universal compiler superiority**. Missing backends are explicitly unmeasured. Thor's pinned executable only parses/dumps a hard-coded source file; it is not assigned a fictitious C-backend score.

One known reference divergence is retained rather than disguised as a pass: on the pinned Linux/amd64 Odin build, runtime `i64` minimum divided by `-1` raises SIGFPE. Borr follows the documented wrapping result. The report lists this separately from ordinary passes and unexpected failures.

## References and direction

[Thor](https://github.com/Spaceghost/Thor) informs stable indices, data-oriented storage, and inspectable intermediate forms. [Codin](https://github.com/Spaceghost/codin) provides a runnable C99 reference and a broader existing feature ladder. [Sulong](https://www.graalvm.org/latest/reference-manual/llvm/) is a conceptual inspiration for making an intermediate language executable; Borr does not embed Graal, LLVM, Truffle, or a JIT.

Odin's own tooling parser is the syntax authority. Borr owns semantics from the checker onward. Original implementation code is MIT-licensed; the linked Odin library retains its [own license](licenses/Odin.txt). Reference compiler sources are fetched at pinned commits and are not vendored.

See [architecture and acceptance ladder](docs/architecture.md) and [benchmark protocol](docs/shootout.md).
