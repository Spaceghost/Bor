# Evidence protocol

Run `make test cross references shootout`, with `ROUNDS=7` or a larger odd sample count. The commands use fresh processes, one excluded warmup, a warm filesystem cache, and a deterministic interleaving seed. CPU model, platform, tools, commands, source hashes, compiler hashes, medians and median absolute deviations are retained in `build/shootout/shootout.json`. Do not substitute an isolated best run for the distribution.

The shared compile corpus consists of 128 exported procedures generated from `tests/bench/main.odin`. Every resulting procedure is exercised through a C driver and checked with independent affine-composition arithmetic. Borr and Codin emit exactly the same Odin input without rewriting the language for either competitor. Native Odin compiles that same input to an object. Emission and object production remain separate phases; the latter does more work.

The runtime probe is a long observable LCG dependency chain with varied state and a checksum. A handwritten C control and native Odin are included. The C compiler and optimization level are part of a lane's identity. This microbenchmark permits algebraic optimization by the downstream compiler; this is valid work reduction, not a claim to measure a fixed instruction count. It is unsuitable for concluding that one compiler wins on arbitrary applications.

The semantic corpus is much broader than the performance kernel. Test counts refer to input/backend/mode checks, not distinct language features. A seeded generator emits bounded well-typed expressions over all supported integer widths and compares them with independent Python bit-vector results. The full generated source, seed, inputs, expected outputs, and results remain in the artifact. The generator is not coverage-guided fuzzing and has no automatic minimizer yet.

Cross-target gates stop at object generation; they do not execute foreign binaries or imply native ABI compatibility for the fixed 64-bit word profile. When Zig is unavailable locally its lanes are explicitly unmeasured; CI installs the pinned release. The bootstrap/reference sources are pinned, but the hosted GCC/Clang/OS toolchain is identified in each report rather than claimed hermetic.

## Reference revisions

- Odin: `dev-2026-09`, Linux/amd64 archive SHA-256 `167c3e1d7056419dad2e04bb3bd98715b7ff286d4c125f3c5a5ee337c6254283`.
- Zig: `0.16.0`, Linux/x86-64 archive SHA-256 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`.
- Codin: `Spaceghost/codin@5cd28a63023c24079f16e9a51a0140501cebdfa2`, including that revision's experimental strict-C99 build script.
- Thor: `Spaceghost/Thor@c9665a453aeaab31ec728d2d9c3172f41b52b87b`. Its `src/main.cpp` opens `test/ks.odin`, parses and dumps AST statements, and offers no C output command. A zero process exit is not proof of successful compilation: the retained probe also inspects its diagnostics.

Codin has aggregate/import/generic work beyond Borr's scalar engine. That coverage advantage is not erased by a scalar benchmark. Conversely, fast AST dumping is not a completed compiler. Compare supported semantics first, then comparable work.

## Documented native divergence

Odin's [language overview](https://odin-lang.org/docs/overview/#integer-overflow) specifies deterministic signed integer overflow, including division. The pinned native Linux/amd64 build traps on dynamically evaluated `i64` minimum divided by `-1`; the checked interpreter and generated C return the minimum. `tests/semantics/main.odin:divide_edge` plus the retained C driver reproduce this case. The harness records the observed SIGFPE as a **reference divergence**, never as a pass. Any other unexpected mismatch still fails the gate.
