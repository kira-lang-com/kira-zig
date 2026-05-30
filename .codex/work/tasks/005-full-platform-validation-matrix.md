# 005 - Full Platform Validation Matrix

Status: complete

## Hard Precondition

Do not execute this task until all earlier tasks are complete.

Required completed tasks:

- `000-repository-truth-cleanup.md`
- `001-wasm32-emscripten-backend.md`
- `002-macos-apple-runner.md`
- `003-ios-simulator-apple-runner.md`
- `004-ios17pro-basic-foundation-app.md`

If any required task is not marked `Status: complete`, stop immediately and return to the earliest incomplete task.

## Objective

Add and run the full validation matrix that proves Kira platform support is real across the implemented targets.

This task must lock in the anti-smoke guarantees from the previous tasks and make future regressions obvious.



## Scope

This task covers:

- repo-wide validation organization
- backend/platform matrix commands
- VM/LLVM/hybrid parity checks
- WASM target validation
- macOS runner validation
- iOS Simulator runner validation
- no-Python validation
- root-level Zig validation
- no-smoke validation
- marker-layer validation
- reports/checkpoints proving the whole queue state



## Required Matrix

The matrix must cover every applicable implemented path:

- `zig build`
- `zig build test`
- VM corpus tests
- LLVM/native corpus tests
- hybrid corpus tests where applicable
- WASM build and execution tests where implemented
- Web/WASM host validation without smoke surfaces
- macOS runner validation
- iOS Simulator runner validation where local tooling allows
- `basic-foundation-app` on the strongest available Apple runner targets
- repo purity checks
- no-Python checks
- root-level Zig checks
- fake-marker negative tests



## Required Layer Assertions

The validation matrix must preserve the 11-layer distinction:

1. host boot
2. toolchain/build success
3. module load
4. Kira runtime startup
5. app entrypoint invocation
6. UI tree construction
7. layout completion
8. render command generation
9. graphics backend initialization
10. frame submission
11. visible Kira-generated content

No layer may satisfy a deeper layer.

The matrix must fail if:

- host boot is treated as runtime success
- runtime startup is treated as app success
- app entrypoint is treated as UI success
- UI tree creation is treated as layout/render success
- graphics initialization is treated as frame submission
- host-rendered content is treated as Kira-visible content
- WASM build success is treated as WASM execution success
- simulator launch is treated as app rendering success



## Required WASM Gate

The matrix must include the strongest available version of the final WASM gate:

    target-portable Kira test pipeline on wasm32-emscripten

If the full gate is not yet possible because of a genuine external blocker, the matrix must still include:

- target modeling tests
- LLVM lowering tests
- Emscripten toolchain diagnostics
- WASM link/package tests where available
- runtime startup tests where available
- real assertion/app-entrypoint execution tests where available
- explicit unsupported-feature diagnostics



## Required Apple Gate

The matrix must include:

- macOS runner validation
- iOS Simulator runner validation where tooling is available
- `basic-foundation-app` validation on the strongest available Apple target
- exact evidence for iPhone 17 Pro simulator availability or unavailability

Host-only Apple app launch must fail Kira render success validation.



## Required Repo-Purity Gate

The matrix must fail on:

- Python files
- Python invocations
- Python docs/scripts/tests/CI helpers
- `python -m http.server`
- unexpected root-level Zig files
- smoke runners
- fake success markers
- placeholder render success
- generated root clutter



## Required Validation

Run:

    zig build
    zig build test

Run every new or updated matrix command.

Run all platform validations available on this machine.

If a platform is unavailable, document exact command evidence and keep only that platform-specific portion blocked. Do not mark unrelated repo-local work as blocked.



## Completion Criteria

This task is complete only when:

- full validation matrix exists
- matrix is wired into repo-native commands
- no-Python check exists and passes
- root-level Zig check exists and passes
- no-smoke/fake-marker checks exist and pass
- VM/LLVM/hybrid validation passes
- WASM validation runs to the strongest implemented level
- macOS runner validation runs to the strongest implemented level
- iOS Simulator validation runs to the strongest available level
- `basic-foundation-app` validation is included for Apple runners
- host-only success cannot pass deeper Kira success layers
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or remaining failures are proven external and documented
- all reports/checkpoints accurately reflect queue completion state



## Report

Write a report under:

    .codex/work/reports/005-full-platform-validation-matrix.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/005-full-platform-validation-matrix.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
