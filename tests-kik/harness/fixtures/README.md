# Kira driver-backed fail harness

A `kira test` suite that asserts the compiler **rejects** ill-formed packages and
**accepts** well-formed ones — i.e. diagnostic/compile-failure coverage expressed
as runnable `kira test` cases.

## Why this exists

The Foundation `Test` construct asserts a computed **runtime scalar** inside one
compilable package. A program with a compile error cannot live in that package,
so compile-failure cases (the `tests/fail/` corpus) cannot be expressed directly.

This harness sidesteps that by driving the **in-process Kira compiler** at
test-evaluation time. Each `Test` calls `Foundation.checkPackage(path, backend)`
(the `DeveloperSession` C-ABI driver, statically linked into `kira`) on a fixture
package and reduces the returned `DeveloperCommandReport { success, text, error }`
to a scalar the runner compares.

The ill-formed fixtures live under `fixtures/`, **outside** this package's `app/`
directory, so they are never compiled as part of the harness itself — only
through the driver, at test time.

## Layout

- `app/main.kira` — `@Main` entry (imports Foundation) + package docs.
- `app/runparity/FailDriverTests.kira` — the `Test` declarations (prefix `fh`/`Fh`).
- `fixtures/reject_unknown_name/` — MUST FAIL: references an undefined name.
- `fixtures/reject_arg_type/` — MUST FAIL: argument type mismatch.
- `fixtures/accept_trivial/` — MUST COMPILE: positive control.

## Run

```sh
# Run from the repo root: the fixture paths in FailDriverTests.kira are repo-relative.
kira test tests-kik/harness
```

Expected: `4 passed; 0 failed`.

## Adding a case

1. Add a fixture package `fixtures/<name>/` (`kira.toml` + `app/main.kira`).
2. Add a `Test` in `FailDriverTests.kira` calling `fhRejected(...)` (for a MUST-FAIL
   case) or `fhAccepted(...)` (for a MUST-COMPILE case) with the repo-relative
   fixture path, asserting `Result.Ok(1)`.

This is the migration target for the `tests/fail/` diagnostic corpus.
