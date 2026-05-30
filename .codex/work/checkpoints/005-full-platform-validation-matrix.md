# Checkpoint - 005 Full Platform Validation Matrix

Task: `.codex/work/tasks/005-full-platform-validation-matrix.md`

Status: complete

## Completed

- Verified all lower-numbered tasks were complete before starting task 005.
- Added `tests/platform_validation_matrix.zig`.
- Added `zig build platform-validation-matrix`.
- Wired the platform matrix into `zig build verify-real-runtime` and `zig build test`.
- Preserved the repo-purity gate through `zig build repo-truth`.
- Preserved VM/LLVM/hybrid corpus validation through `zig build test`.
- Preserved wasm32-emscripten real entrypoint execution through package tests and an explicit `kirac run --backend wasm32-emscripten` command.
- Validated Web live output through served `http://127.0.0.1` output, not `file://`.
- Validated macOS live runner evidence through bundle load/link/entrypoint/frame markers.
- Validated iOS Simulator `basic-foundation-app` evidence through UI Foundation, layout, render, Kira Graphics frame, and visible-content markers.
- Split `build.zig` package test roots into `build_support/test_roots.zig` so touched Zig files remain below 600 lines.

## Validation

- `zig build`: passed.
- `zig build platform-validation-matrix`: passed.
- `zig build repo-truth`: passed.
- `zig build verify-real-runtime`: passed.
- `zig build test`: passed, corpus `1017 passed, 0 failed`.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac run --backend wasm32-emscripten tests/pass/run/if_basic_parity/main.kira`: passed and printed `if-then`.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live web examples/hello --run-for 1s`: passed with localhost serving and `kira-app.wasm`.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live macos examples/sokol_runtime_entry --run-for 1s`: passed with `live.frame.presented`.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app --run-for 2s`: passed with UI Foundation and Kira Graphics visible-content markers.

## CI Scope

No CI files, workflow files, release workflow files, CI-specific docs/scripts, or automated workflow configuration were edited or used for validation. CI-specific cleanup remains intentionally untouched under the user's temporary restriction.

## Queue State

Tasks `000` through `005` are complete. Recheck the sorted task directory before selecting any next task.
