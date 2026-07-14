# Skipped check-surface cases

> RESOLVED 2026-07-13: `imported_global_namespace` (the one remaining skip) is
> now MIGRATED via FailTest fixture mode. `app/CsfCheckTests.kira` declares
> `CsfImportedGlobalNamespace` whose
> `source { fixture("fixtures/imported_global_namespace") }` compiles the real
> multi-file `import UI as Kit` package clean (Result.Ok sentinel). All 19
> check-surface cases are now covered. Historical rationale retained below.

18 of 19 legacy `tests/pass/check/` cases migrated into
`app/CsfCheckTests.kira` as `FailTest` must-compile assertions.

## Skipped: 1 (multi-file)

### `imported_global_namespace` (tests/pass/check/imported_global_namespace)

Multi-file case. `main.kira` opens with a module import:

```kira
import UI as Kit
```

and depends on a sibling `UI.kira` support module that declares the `Card`
widget referenced (both unqualified `Card(...)` and alias-qualified
`Kit.Card(...)`).

The locked `FailTest` grammar inlines a single-file `source { ... }` body; it
cannot express a second module (`UI.kira`) nor the `import UI as Kit`
resolution against it. Inlining only `main.kira` would leave `import UI` /
`Card` / `Kit.Card` unresolved, changing the case from a clean-compile
assertion into a compile error — i.e. it would not be verbatim-faithful.

No prominent multi-file warning is warranted: only 1 of 19 cases is
multi-file (well under the 5-of-19 threshold).
