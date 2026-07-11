---
name: backend-testing
description: "Kira test/corpus policy: tests/pass/run, tests/pass/check, tests/fail layout, backend matrix declarations, the 11 success layers no marker may skip ahead of, and negative-test requirements after a fake-success or memory bug is found. Read before adding or changing any test or backend-sensitive behavior."
---

# Backend testing & corpus policy

Targeted tests plus repo-wide when practical.

- Corpus for user-visible behavior: `tests/pass/run/` (execution),
  `tests/pass/check/` (analysis-only), `tests/fail/` (diagnostics). Each case
  needs `main.kira` + `expect.toml`.
- Runnable cases declare an explicit backend matrix, e.g.
  `["vm", "llvm", "hybrid"]`.
- Failure cases include the expected diagnostic code/title/stage.
- VM-only or LLVM-only passing is insufficient for backend-sensitive work —
  prefer many small tests across the matrix over one broad one.

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
