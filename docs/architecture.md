# Checked engine: invariants and acceptance ladder

## Representation

A compilation lives in an arena. The front end reuses the pinned `core:odin/parser` AST instead of maintaining a competing Odin grammar. Source files are sorted, package names checked, and conditional/test file selection rejected until a proper target resolver exists.

Procedure signatures are collected before bodies. Name scopes, constant dependencies, contextual literal typing, explicit distinct types, immutable parameters, and numeric representability are checked before emission. Recursive constants fail with a dependency diagnostic. Constant evaluation has depth and magnitude budgets; these are resource limits, not an alternate integer language.

The IR is a `#soa[dynamic]Instruction` array with distinct value, slot, label, and procedure IDs. Calls use contiguous argument spans. AST pointers never enter the IR. Source positions survive lowering. Mutable storage is explicit; value registers are single-definition within a dynamic traversal, not an assertion of full SSA form.

The verifier constructs a compact CFG, computes immediate dominators in reverse postorder, and uses dominator-tree intervals for constant-time value-use queries. Corrupted-IR unit tests exercise invalid indices, spans, labels, types, forward references, non-dominating values, and falling off a procedure. Unreachable instructions still receive shape/type checks.

## Semantics that must not leak through C

Integer constants are mathematical integers until materialized into a type. Typed constants must fit. Runtime values are normalized to their declared widths. Signed arithmetic is performed through unsigned bit patterns and converted back with representable C99 arithmetic. No `-fwrapv` contract or implementation-defined unsigned-to-signed cast is necessary in generated code.

Short-circuiting is explicit control flow. Nested call arguments are evaluated before committing the outer argument span. Assignment right-hand sides are captured before any left-hand-side stores. Return values are captured before defers. A defer captures the lexical bindings at declaration and reads their values when executed, including exit by return, break, or continue. Inclusive ranges test their endpoint before incrementing, avoiding a maximum-value wraparound loop.

The interpreter and C emitter consume the same IR. This catches backend discrepancies but is not an independent semantic oracle: therefore native Odin and separately computed expected values are also required. Interpreter recursion and instruction budgets are bounded. Generated executables have ordinary native-code privileges and are not sandboxed.

## Optimization policy

The initial pass propagates constants through local slots, folds total arithmetic, and simplifies constant branches. Labels invalidate slot facts, preventing a pre-loop value from leaking across a back edge. The C backend performs reachability, public-root procedure liveness, and dead pure-value/store emission. Calls, assertions, division, and remainder retain effects even when their results are unused.

A performance improvement must keep the complete semantic/rejection/unit gates green, retain before/after measurements, and report tradeoffs. Unsupported syntax is a diagnostic, not a fallback to native Odin or a claim of successful compilation.

## Next acceptance slices

1. Unify the complementary `master` pointer/URL-encoding slice with checked types and memory operations. Preserve both implementations as differential controls until the verified replacement passes the original fixture and randomized buffer tests.
2. Add a target/type-layout table, fixed arrays, records, bounds checks, and a freestanding runtime ABI. Gate size/alignment/layout and out-of-bounds behavior before optimization.
3. Add slices/strings and multiple returns, then imports, tagged unions, and explicit context/allocator semantics. Match the existing Codin feature ladder with native-Odin-valid fixtures.
4. Add monomorphization with canonical type identities, specialization caching, and source-level diagnostics. Do not claim generics because one identity example compiles.
5. Add incremental dependency fingerprints only after dependency semantics are stable; require cold/warm cache equivalence and invalidation tests. Pursue self-hosting once the compiler's own dependencies have genuine support.

These are future acceptance gates, not implemented features. The project does not promise a JIT, complete Odin ABI compatibility, or a particular person's endorsement.
