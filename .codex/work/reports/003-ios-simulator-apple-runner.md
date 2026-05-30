# 003 - Real iOS Simulator Apple Runner Report

Status: complete

## Summary

Implemented and validated a real iOS Simulator live runner path for Kira apps.

The `ios-simulator` live command now builds an iOS Simulator Xcode runner, installs it on the booted simulator, launches it, accepts the live protocol client, sends the Kira bundle graph, waits for Kira runtime/link/entrypoint evidence, and requires `live.frame.presented` before reporting the session ready. Simulator install or launch alone is not accepted as success.

## Changes

- Added iOS Simulator target support in the LLVM backend:
  - `aarch64-ios-simulator` lowers to `arm64-apple-ios13.0-simulator`.
  - Clang SDK selection now uses `iphonesimulator`.
- Reworked live runner supervision into focused modules:
  - `supervisor.zig` remains command orchestration.
  - `live_args.zig` owns live CLI parsing.
  - `supervisor_shared.zig` owns diagnostics, process helpers, live server/session helpers, and file writes.
  - `apple_runner.zig` owns Xcode project generation, runner bundle IDs, Apple target selection, and Xcode validation.
  - `ios_live.zig` owns iOS Simulator and physical-device live flows.
  - `web_live.zig` owns Web live runner generation.
- Added real iOS Simulator live flow:
  - Builds live bundles for `aarch64-ios-simulator`.
  - Embeds native Kira app code into the simulator app where the simulator sandbox can link it.
  - Builds the generated runner with `xcodebuild -sdk iphonesimulator`.
  - Installs and launches with `xcrun simctl`.
  - Captures simulator logs through `simctl log show`.
  - Requires `live.bundle.loaded`, `live.bundle.linked`, `live.entrypoint.started`, and `live.frame.presented`.
- Added `examples/sokol_ios_runtime_entry` as a repo-local GLES3 Sokol simulator proof app.

## Real Runner Validation

Command:

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator examples/sokol_ios_runtime_entry --run-for 1s
```

Result: passed.

Observed evidence:

```text
event: live.bundle.compiled target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_ios_runtime_entry output_root=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_ios_runtime_entry/.kira-build/live
event: live.bundle.built artifact=.klbundle target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_ios_runtime_entry
event: live.ios.simulator.native_embedded target=aarch64-ios-simulator
event: live.ios.simulator.build.succeeded runner=xcode-ios
event: live.ios.simulator.install.succeeded bundle=com.kira.live.ios.dev
event: live.server.started host=127.0.0.1 port=42111 runner=ios-simulator
event: live.ios.simulator.launch.succeeded bundle=com.kira.live.ios.dev
event: live.client.connected target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_ios_runtime_entry
live.bundle.graph.received
live.client.bundle.received
live.bundle.loaded
live.bundle.linked
live.entrypoint.started
live.frame.presented
event: live.session.ready target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_ios_runtime_entry
event: live.ios.simulator.logs.captured source=simctl-log-show
event: live.shutdown.finished reason=quit-after
```

The frame marker is emitted by Kira app code after the Sokol frame commit path, not by simulator launch, UIKit host setup, bundle transfer, or runtime startup.

## Additional Validation

```text
zig build test
```

Result: passed. Corpus summary: `1017 passed, 0 failed`.

```text
zig build
```

Result: passed and refreshed the dev Kira toolchain.

```text
zig build repo-truth
```

Result: passed.

Forbidden-smoke search over touched live/LLVM/example paths returned no matches for Python server usage, legacy fake WebGPU markers, or temporary debug strings.

## File Size

Core Law #5 is satisfied for every touched or split Zig source file in this task:

```text
628 packages/kira_live/src/supervisor.zig
560 packages/kira_live/src/supervisor_shared.zig
513 packages/kira_live/src/bundle_builder.zig
472 packages/kira_live/src/apple_runner.zig
466 packages/kira_live/src/ios_live.zig
359 packages/kira_live/src/web_live.zig
243 packages/kira_llvm_backend/src/clang_driver.zig
176 packages/kira_llvm_backend/src/backend_platform_utils.zig
128 packages/kira_live/src/live_args.zig
```

Generated Sokol autobinding files from validation were removed after proving the clean source example regenerates and runs.

## CI Scope

No CI files, workflow files, release workflow files, CI-specific docs/scripts, or automated workflow configuration were edited or used for validation.

## Notes

- `basic-foundation-app` was not used because this run is restricted to local work in the `kira-zig` repo. The strongest repo-local simulator graphics proof is `examples/sokol_ios_runtime_entry`.
- Physical iPhone install/launch remains separate from iOS Simulator validation and is not reported as device success.
