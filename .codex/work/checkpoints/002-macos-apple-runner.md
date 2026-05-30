# Checkpoint - 002 macOS Apple Runner

Task: `.codex/work/tasks/002-macos-apple-runner.md`

Status: complete

## Completed

- Fixed the generated macOS Xcode runner link model so the host executable links only `libkira_live_runner_support_xcode.a`.
- Kept app graphics/native code in the live-loaded Kira bundle dylib.
- Fixed `examples/sokol_runtime_entry` ownership diagnostics for Sokol descriptor transfers.
- Added Kira-owned live frame evidence after real Sokol `sg_commit()` in:
  - `examples/sokol_runtime_entry/app/main.kira`
  - `examples/sokol_triangle/app/main.kira`
- Added a unit test proving macOS runner projects do not link the Kira app object into the host executable.
- Validated the real macOS runner with `examples/sokol_runtime_entry`.

## Validation

- `zig-out/bin/kira check --backend hybrid examples/sokol_runtime_entry`: passed.
- `zig-out/bin/kira build --backend hybrid examples/sokol_runtime_entry`: passed.
- `zig-out/bin/kira live macos examples/sokol_runtime_entry --run-for 2s`: passed with `live.entrypoint.started`, `live.frame.presented`, and `live.session.ready`.
- `zig build test`: passed, corpus `1017 passed, 0 failed`.
- `zig build`: passed.
- `zig build repo-truth`: passed.

## CI Scope

No CI files, workflow files, release workflow files, or CI-specific docs/scripts were edited or used for validation.

## Follow-Up

`packages/kira_live/src/supervisor.zig` remains a pre-existing oversized file and should be split into runner/session/tooling modules in a dedicated architecture pass.
