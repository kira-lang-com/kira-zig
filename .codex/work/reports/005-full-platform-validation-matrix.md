# 005 - Full Platform Validation Matrix Report

Status: complete

## Summary

Added a repo-native platform validation matrix and ran the implemented local platform gates. The matrix is wired into `zig build platform-validation-matrix`, `zig build verify-real-runtime`, and `zig build test`.

The matrix locks in the anti-smoke evidence for repo purity, VM/LLVM/hybrid corpus coverage, wasm32-emscripten real execution, live marker-layer ordering, macOS runner ownership, iOS Simulator install/launch/log capture, and Web live localhost serving.

## Changes

- Added `tests/platform_validation_matrix.zig`.
- Added `zig build platform-validation-matrix`.
- Updated `zig build verify-real-runtime` and `zig build test` to run the platform matrix.
- Extracted package test roots from `build.zig` to `build_support/test_roots.zig` so touched Zig files stay below 600 lines.

## Matrix Coverage

- Repo purity:
  - Python file/command guard.
  - Unexpected root-level Zig guard.
  - Fake marker guard.
  - Live supervisor cannot translate visible-content markers into frame success.
- VM/LLVM/hybrid:
  - `zig build test` corpus remained wired and passed.
  - Corpus summary: `1017 passed, 0 failed`.
- WASM:
  - `wasm32-emscripten` unit test builds `.js`/`.wasm` and runs Node against the real Kira entrypoint.
  - Explicit local wasm run passed.
- Web:
  - `kira live web` served `http://127.0.0.1:42111/`, built `kira-app.wasm`, and did not use `file://`.
- macOS:
  - Live macOS runner loaded the Kira bundle, linked it, invoked the entrypoint, and required `live.frame.presented`.
- iOS Simulator:
  - iPhone 17 Pro Simulator was available and used for `basic-foundation-app`.
  - Runner built, installed, launched, loaded/linked the Kira bundle, invoked UI Foundation, produced layout/render markers, submitted a Kira Graphics frame, and produced visible Kira content markers.

## Validation

```text
zig build
```

Result: passed and refreshed `/Users/priamc/.kira/toolchains/dev/0.1.0`.

```text
zig build platform-validation-matrix
```

Result: passed:

```text
matrix row ok: repo purity rejects Python, root Zig clutter, and fake markers
matrix row ok: VM, LLVM, and hybrid corpus paths remain wired through zig build test
matrix row ok: wasm32-emscripten executes a real Kira entrypoint
matrix row ok: live supervision preserves marker-layer ordering
matrix row ok: macOS runner keeps Kira graphics code in the loaded bundle
matrix row ok: iOS Simulator runner installs, launches, and captures simulator logs
matrix row ok: web live validation uses served localhost output, not file URLs
platform validation matrix checks passed
```

```text
zig build repo-truth
```

Result: passed, `repository truth checks passed`.

```text
zig build verify-real-runtime
```

Result: passed, including repo truth and platform matrix checks.

```text
zig build test
```

Result: passed. Corpus summary: `1017 passed, 0 failed`. The test step also ran repo truth and the platform matrix.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac run --backend wasm32-emscripten tests/pass/run/if_basic_parity/main.kira
```

Result: passed and printed `if-then`.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live web examples/hello --run-for 1s
```

Result: passed with `url=http://127.0.0.1:42111/`, `live.web.wasm.generated`, `live.bundle.served`, and `live.session.ready`.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live macos examples/sokol_runtime_entry --run-for 1s
```

Result: passed with `live.bundle.loaded`, `live.bundle.linked`, `live.entrypoint.started`, `live.frame.presented`, and `live.session.ready`.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app --run-for 2s
```

Result: passed with:

```text
live.bundle.loaded
live.bundle.linked
live.entrypoint.started
live.ui_foundation.app.started
live.kira_graphics.backend.initialized
live.ui_foundation.tree.built
live.ui_foundation.retained_tree.ready
live.ui_foundation.layout.non_empty
live.ui_foundation.render_commands.generated
live.kira_graphics.frame.submitted
live.frame.presented
live.kira_graphics.visible_content.submitted
KIRA_UI_DRAW_COMMANDS_SUBMITTED
KIRA_APP_RENDERED_VISIBLE_CONTENT
event: live.ios.simulator.logs.captured source=simctl-log-show
event: live.shutdown.finished reason=quit-after
```

## File Size

Core Law #5 was followed for every Zig file touched/opened in this task:

```text
575 build.zig
560 packages/kira_live/src/supervisor_shared.zig
518 packages/kira_live/src/supervisor.zig
517 packages/kira_live/src/bundle_builder.zig
497 packages/kira_live/src/apple_runner.zig
466 packages/kira_live/src/ios_live.zig
122 packages/kira_live/src/android_live.zig
113 tests/platform_validation_matrix.zig
30 build_support/test_roots.zig
```

No touched/opened Zig file remains at or above 600 lines.

## CI Scope

No CI files, workflow files, release workflow files, CI-specific docs/scripts, or automated workflow configuration were edited or used for validation. CI-specific no-Python cleanup was intentionally untouched per explicit user instruction.

## Notes

- The Web live gate proves repo-owned local serving and WASM packaging without `file://`; actual browser assertion execution remains separate from the wasm32-emscripten Node execution gate.
- CI portions of a full platform matrix remain intentionally out of scope for this run because of the explicit temporary restriction.
