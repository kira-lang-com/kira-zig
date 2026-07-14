# Pipeline fail-corpus — skipped cases

> RESOLVED 2026-07-13: `declarative_showcase` is now MIGRATED via FailTest
> fixture mode. `app/FplFailTests.kira` declares `FplDeclarativeShowcase` whose
> `source { fixture("fixtures/declarative_showcase") }` compiles the real
> multi-file `import UI as Kit` package, asserting KSEM060 (duplicate annotation
> across the import boundary). The two entries below
> (`defaulted_construction_and_function_field_defaults`,
> `ffi_nested_fixed_array_assignment`) remain skipped — they are pass-cases with
> no diagnostic to assert, not FailTest material. Historical rationale retained.

Cases in `tests/fail/pipeline/` that were NOT migrated into `app/FplFailTests.kira`,
with the reason each is inexpressible as a single-file `FailTest`.

## declarative_showcase — multi-file import (not single-file expressible)
Legacy dir has two `.kira` files: `main.kira` (which does `import UI as Kit`) and the
support module `UI.kira`. The declared diagnostic is `KSEM060` "duplicate annotation
declaration" (semantics), which arises **across the import boundary** — both `main.kira`
and the imported `UI.kira` declare `annotation State/Binding/Env` and `construct Widget`.
A `FailTest` `source` block is a single compilation unit and cannot bring in a second
imported module, so the duplicate-across-import condition cannot be reproduced.
`SKIPPED` per the migration rule for `declarative_showcase`'s import-support module.

## defaulted_construction_and_function_field_defaults — PASS case, not a fail case
`expect.toml` declares `[phases.check] result = "pass"`, `[phases.build] result = "pass"`,
`[phases.run] result = "pass"` (backends `["hybrid"]`). There is no diagnostic — nothing
for a `FailTest` to assert. It belongs in the pass corpus, not the expected-diagnostic
`FailTest` corpus.

## ffi_nested_fixed_array_assignment — PASS case, not a fail case
`expect.toml` declares check/build/run all `pass` with `stdout = "7\n0\n7\n"`
(backends `["hybrid","llvm"]`, `check_leaks = true`). No diagnostic to assert; belongs in
the pass corpus.
