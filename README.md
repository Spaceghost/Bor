# Bor

Bor is an Odin-to-C compiler written in Odin.

The executable is `bor`. Bor deliberately builds on the current Odin toolchain instead of carrying a second Odin grammar around until everyone involved forgets why there are two parsers.

## Architecture

```text
Odin source
    |
    v
core:odin/parser + core:odin/ast   <- syntax authority
    |
    v
Bor semantic lowering
    |
    +------------------------------+
    |                              |
    v                              v
flat MIR                      direct AST lane
(values / blocks / ops)       (shootout control)
    |                              |
    v                              v
goto-based unity C99          structured C99
    |                              |
    +-------------+----------------+
                  |
          GCC / Clang / Zig cc
```

`bor emit-c` uses the **flat MIR backend**. `bor emit-c-direct` keeps the smaller direct AST-to-C backend alive as a permanent control. `bor emit-c-mir` names the product backend explicitly.

Bor uses `core:odin/parser` and `core:odin/ast` shipped with Odin itself. It does **not** maintain a separate Odin parser.

The project also keeps two historical/reference compilers in the shootout:

- **Thor** (`graphitemaster/Thor`, with `Spaceghost/Thor` as the working fork) is the modern architectural reference. Its data-oriented AST and middle-IR direction are useful guidance.
- **Codin** (`graphitemaster/codin`, with `Spaceghost/codin` as the executable fork) is a behavioral oracle for the strict-C99 work proven during the melodica experiments.

We port behavior and tests, not implementation sediment.

## Flat MIR

The MIR is intentionally boring data:

- integer `Proc_ID`, `Block_ID`, and `Value_ID` handles;
- dense module arrays for procedures, blocks, values, instructions, globals, and call arguments;
- procedures own contiguous ranges of blocks, instructions, values, and parameters;
- blocks own contiguous instruction ranges;
- one fixed-layout enum-backed `MIR_Inst` record;
- explicit `Jump` / `Jump_If_False` control flow;
- short-circuit boolean expressions and loops become real basic blocks before C emission;
- the C backend does not need to understand Odin's AST.

The unity C emitter is therefore a sequential pass over dense arrays. Complex Odin control flow is emitted as predictable labels and `goto`s, leaving ordinary C optimizers a simple control-flow graph.

## Verification rule

Every supported language feature must earn its way in through executable evidence:

1. Parse with Odin's own tooling parser.
2. Lower unsupported AST shapes **loudly** instead of guessing.
3. Emit deterministic strict `-std=c99 -pedantic-errors` C.
4. Compile both Bor backends with GCC and Clang under `-Wall -Wextra -Werror`.
5. Compare observable behavior with native Odin.
6. Compare the same fixture with Codin and Thor when useful.
7. If an upstream project has weak/no tests, characterize the real reference implementation using source plus instrumentable differential behavior rather than inventing expected semantics.
8. Keep performance claims behind repeatable shootouts.

That last pair of rules came out of the libpiano compatibility work. Executable behavior is a considerably better oracle than archaeology conducted with confidence.

## First backend shootout

The first shared acceptance workload is melodica's binary-safe URL encoder. All lanes produce the same ABI behavior and the benchmark verifies the same deterministic sink (`667156061`). A GitHub-hosted run produced:

| lane | runtime median | generated C | GCC executable |
|---|---:|---:|---:|
| Bor direct → GCC | 541.96 MiB/s | 1,879 B | 3,328 B |
| **Bor MIR → GCC** | **552.81 MiB/s** | 5,796 B | **3,280 B** |
| Bor direct → Clang | 556.17 MiB/s | 1,879 B | 3,398 B |
| **Bor MIR → Clang** | **589.61 MiB/s** | 5,796 B | 3,398 B |
| native Odin | 561.50 MiB/s | — | — |
| Codin → GCC | 543.76 MiB/s | 1,868 B | 3,328 B |

Compiler-side measurements on the same runner:

| operation | direct | MIR | Codin |
|---|---:|---:|---:|
| 40 parse+emit+write invocations | 0.03 s | 0.03 s | 0.28 s |
| 25 GCC `-O3` C compilations | 0.74 s | 0.85 s | 0.74 s |
| emitter peak RSS | 4.4 MiB | 4.6 MiB | 14.7 MiB |

The MIR output is currently about 3× larger as text and costs GCC roughly 15% more frontend time on this tiny fixture, but it won runtime under both GCC and Clang, tied Clang's final size, produced the smallest GCC binary, and did not measurably slow Bor's own emission. That earned it the default. The direct lane remains in CI because one benchmark is evidence, not scripture.

## Current executable slice

The bootstrap language slice covers:

- `u8`, `u32`, `uintptr`, `bool`
- `[^]u8`
- `proc "c"` and `proc "contextless"`
- `@(export)` linkage as a semantic property in MIR
- scalar casts
- direct calls and indexing
- unary and binary expressions
- short-circuit `&&` / `||`
- local declarations and basic inferred locals
- assignments and indexed stores
- `if` / `else`
- bounded `for i in a..<b` and `..=` ranges
- returns

```sh
make test
make bench

odin build src -out:build/bor -o:speed
./build/bor emit-c test/melodica -o build/melodica.c
cc -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 \
  build/melodica.c test/c99/smoke.c
```

## Direction

The next feature ladder stays under the same dual-backend shootout:

1. structs
2. fixed arrays
3. enums
4. slices / strings
5. multiple returns
6. `defer`
7. unions
8. imports / package-qualified names
9. generics / monomorphization
10. the broader Odin and runtime surface

The MIR type system will grow as dense tables and IDs rather than recursive compiler-object graphs. Cross-target C compilation, deterministic MIR dumps, sanitizer builds, differential fixtures, and compile/runtime scorecards belong in CI as the language surface expands.

The target is not merely “Odin that happens to compile to C.” Bor should emit portable C, cross-compile almost offensively easily, produce useful diagnostics, remain inspectable, and give C optimizers enough simple structure to do excellent work without requiring the reader to decode a compiler's emotional state.
