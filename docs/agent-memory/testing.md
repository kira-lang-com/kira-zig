# Testing

Internal memory for the test/verification workflow. The legacy `tests/` corpus
was deleted 2026-07-13; behavior is covered by Kira-native suites under
`tests-kik/`, run through `kira test`.

## tests-kik layout

- `tests-kik/corpus/<pkg>/` — user-visible runtime behavior as Foundation `Test`
  declarations (assert a scalar via `Result.Ok(...)`; a trap via
  `Result.Error(TestFailure.Runtime(""))`).
- `tests-kik/fail-corpus/<pkg>/` — compile-failure + analysis-only coverage as
  `FailTest` declarations (`Result.Error(TestFailure.Compile("CODE"))`, or
  `Result.Ok(1)` for a must-compile check-surface case).
- `tests-kik/harness/` — deep language stress + `@Main` checksum parity/leak run.
- `tests-kik/ffi-harness/` — FFI/native-bridge stress.
- `tests-kik/shaders/pass|fail/` — KSL golden fixtures (consumed by `kira_build` /
  `kira_cli` shader unit tests).

## Conventions

- Each package's `package.kira` declares its backend matrix:
  `Tests { backends: [Backend.Vm, Backend.Llvm, Backend.Hybrid], phase: TestPhase.Both }`.
  `kira test <pkg>` iterates it. VM-only/LLVM-only passing is insufficient for
  backend-sensitive work — prefer many small Tests across the matrix.
- One flat `app/` package: every top-level name must be globally unique
  (per-domain prefixes); `Test`/`Result`/`TestFailure` are package-wide (import
  `Foundation` only in `main.kira`).
- FailTest **fixture mode** — a multi-file / import-graph / native-lib fail case
  uses `source { fixture("fixtures/<name>") }` to compile a real on-disk package
  DIR through the per-backend check path (e.g. duplicate-annotation-across-import,
  outside-app-import, invalid callback signature).

## Env gates (opt-in)

- `KIRA_TEST_PARITY=1 kira test <pkg>` — byte-diffs the `@Main` stdout across the
  manifest matrix (packages with an `@Main`); fails on divergence. A native
  `@Main`'s stdout is not capturable in-process, so its diff is skipped.
- `KIRA_TEST_CHECK_LEAKS=1 kira test <pkg>` — the Test driver's post-run VM
  live-count must be 0, and any `@Main` additionally runs its llvm binary under
  macOS `leaks --atExit`. Nonzero leaks fail the suite with a clear line.

## Verification commands

- `zig build test` — package unit tests + the repo-purity gate
  (`build_support/repository_truth.zig`). Fast; no corpus.
- `kira test tests-kik/corpus/<pkg>` (and `fail-corpus`, `harness`,
  `ffi-harness`) — the behavior suites; each must end `0 failed`.
- `zig build` when build/install/toolchain wiring changed (also refreshes the
  dev `kira` snapshot).
- `kira run|build|check|shader ...` when command behavior or generated output
  changed.

## Legacy → kik map

`tests-kik/corpus/COVERAGE.md` maps every legacy corpus case to its kik home and
carries the guarantee map (stdout parity → parity mode, leak gate → env/manifest,
fail corpus → FailTests incl. fixtures, check corpus → check-surface, matrix →
Tests config).

## When you find a bug

- Fake success path found → add a negative test proving it can't pass again.
- Memory bug (leak/UAF/double-free) → test every allocation path, every
  error-return branch, and the full ordering space of concurrent/interleaved
  operations on the affected structure.
