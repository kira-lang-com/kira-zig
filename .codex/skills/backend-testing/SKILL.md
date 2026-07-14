---
name: backend-testing
description: "Kira test/corpus policy: the Kira-native tests-kik suites (Test construct, FailTests, manifest Tests matrix), the parity/leak env gates, the 11 success layers no marker may skip ahead of, and negative-test requirements after a fake-success or memory bug is found. Read before adding or changing any test or backend-sensitive behavior."
---

# Backend testing & corpus policy

Targeted tests plus repo-wide when practical. The legacy `tests/` corpus is GONE
(deleted 2026-07-13); user-visible behavior lives in Kira-native suites under
`tests-kik/`, run through `kira test <pkg>`. `zig build test` is package unit
tests + the repo-purity gate (`build_support/repository_truth.zig`) only.

- Kai adds executable coverage as Foundation `Test` declarations (assert a scalar
  via `Result.Ok(...)`; a trap via `Result.Error(TestFailure.Runtime(""))`), and
  compile-failure coverage as `FailTest` declarations
  (`Result.Error(TestFailure.Compile("CODE"))`). A multi-file / import-graph /
  native-lib fail case uses FailTest **fixture mode**:
  `source { fixture("fixtures/<name>") }` compiling a real package DIR.
- Each package's `package.kira` declares its own matrix:
  `Tests { backends: [Backend.Vm, Backend.Llvm, Backend.Hybrid], phase: ... }`.
  VM-only or LLVM-only passing is insufficient for backend-sensitive work — prefer
  many small tests across the matrix over one broad one.
- Cross-backend `@Main` stdout parity: `KIRA_TEST_PARITY=1 kira test <pkg>`.
- Leak gate (VM live-count 0 + native `leaks --atExit` on any `@Main`):
  `KIRA_TEST_CHECK_LEAKS=1 kira test <pkg>`.
- Legacy corpus→kik map + guarantee map: `tests-kik/corpus/COVERAGE.md`.

## Success layers — a marker from one never satisfies a deeper one

1 host boot · 2 build success · 3 module load · 4 runtime startup ·
5 entrypoint invoked · 6 UI tree built · 7 layout done · 8 render commands
generated · 9 graphics backend init · 10 frame submitted · 11 visible
Kira-generated content.

Example: render-command generation (8) does not prove frame submission (10);
frame submission (10) does not prove visible content (11).

## When you find a bug

- Fake success path found → add a negative test proving it can't pass again.
- Memory bug (leak/UAF/double-free) → test every allocation path, every
  error-return branch, and the full ordering space of concurrent/interleaved
  operations on the affected structure.
