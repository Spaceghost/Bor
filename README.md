# Bor

Bor is an Odin-to-C compiler written in Odin.

The executable is `bor`. The repository is deliberately built around the current Odin toolchain instead of carrying a second language front end around forever.

## Architecture

```text
Odin source
    |
    v
core:odin/parser + core:odin/ast   <- syntax authority
    |
    v
Bor semantic normalization / MIR  <- Bor owns meaning from here
    |
    v
strict readable C99
    |
    +--> GCC
    +--> Clang
    +--> Zig cc / cross targets
```

Bor uses the parser and AST shipped with Odin itself. It does **not** maintain a separate Odin grammar or parser.

The project has two historical/reference compilers:

- **Thor** (`graphitemaster/Thor`, with `Spaceghost/Thor` as the working fork) is the modern architectural reference. Its data-oriented AST and planned middle-IR direction are useful guidance.
- **Codin** (`graphitemaster/codin`, with `Spaceghost/codin` as the executable fork) is the behavioral oracle for the C99 work already proven during the melodica shootout.

We port behavior and tests, not old implementation baggage.

## Verification rule

Every supported language feature must earn its way in through executable evidence:

1. Parse with Odin's own tooling parser.
2. Emit deterministic strict `-std=c99 -pedantic-errors` C.
3. Compile the generated C with GCC and Clang.
4. Compare observable behavior with native Odin.
5. Where useful, compare against Codin and Thor too.
6. If an upstream project has weak/no tests, characterize the reference implementation by source inspection plus instrumentable differential behavior instead of inventing expected semantics.

That last rule came out of the libpiano compatibility work: executable behavior is a better oracle than nostalgia.

## Current executable slice

The bootstrap backend already lowers the melodica URL-encoding acceptance fixture through `core:odin/parser`. The slice covers:

- `u8`, `u32`, `uintptr`, `bool`
- `[^]u8`
- `proc "c"` and `proc "contextless"`
- scalar casts
- calls, indexing, unary/binary expressions
- local declarations and inference for the exercised subset
- assignments
- `if` / `else`
- bounded `for i in a..<b` and `..=` ranges
- returns

Unsupported AST shapes fail loudly. They are not guessed.

```sh
make test

# or directly
odin build src -out:build/bor -o:speed
./build/bor emit-c test/melodica -o build/melodica.c
cc -std=c99 -pedantic-errors -Wall -Wextra -Werror build/melodica.c test/c99/smoke.c
```

## Direction

Next, the bootstrap AST-to-C lowering gets split cleanly into semantic normalization and a compact MIR. Then the feature ladder proceeds under the same shootout: structs, arrays, enums, slices/strings, multiple returns, defer, unions, imports, generics, and finally the broader Odin/runtime surface.

The target is not merely "Odin that happens to compile to C." Bor should emit small, readable C, cross-compile easily, have useful diagnostics, and remain inspectable enough that a compiler engineer can understand why the output exists without performing an archaeological dig.
