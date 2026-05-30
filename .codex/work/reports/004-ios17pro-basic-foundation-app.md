# 004 - iPhone 17 Pro Simulator basic-foundation-app Report

Status: complete

## Summary

`basic-foundation-app` now runs on the iPhone 17 Pro Simulator through the real Kira live path: live bundle build, iOS Simulator Xcode runner build/install/launch, live protocol bundle load/link, Kira app entrypoint invocation, UI Foundation tree/layout/render work, Kira Graphics frame submission, and Kira-generated visible content markers.

This is not satisfied by simulator install, native host view creation, or UIKit placeholder rendering. The success markers are emitted by Kira runtime/UI/graphics code paths.

## Simulator Evidence

The required simulator was available and booted:

```text
-- iOS 26.5 --
iPhone 17 Pro (03012DE8-E712-4C08-B84A-0BCFE82D0035) (Booted)
```

Final command:

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app --run-for 2s
```

Result: passed.

Required Kira evidence observed:

```text
event: live.bundle.compiled target=/Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app
event: live.bundle.built artifact=.klbundle target=/Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app
event: live.ios.simulator.native_embedded target=aarch64-ios-simulator
event: live.ios.simulator.build.succeeded runner=xcode-ios
event: live.ios.simulator.install.succeeded bundle=com.kira.live.ios.dev
event: live.ios.simulator.launch.succeeded bundle=com.kira.live.ios.dev
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
event: live.session.ready target=/Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app
live.kira_graphics.visible_content.submitted
KIRA_UI_DRAW_COMMANDS_SUBMITTED
KIRA_APP_RENDERED_VISIBLE_CONTENT
event: live.ios.simulator.logs.captured source=simctl-log-show
event: live.shutdown.finished reason=quit-after
```

## Changes

- Added the missing `aarch64-ios-simulator` native target to `kira-graphics/NativeLibs/Sokol.toml` so `KiraGraphics` can build for the simulator target used by `basic-foundation-app`.
- Added Metal shader source for the Kira Graphics immediate UI pipeline in `kira-graphics/NativeLibs/Sokol/sokol_impl.c`; the previous immediate UI shader path was GLSL-only and stopped the Foundation frame before render-command evidence on the Metal-backed iOS Simulator target.
- Added one-shot Kira Graphics live markers at the real native commit point:
  - `live.kira_graphics.frame.submitted`
  - `live.kira_graphics.visible_content.submitted`
- Added UI Foundation live markers in `RunFoundationApp` for app start, tree build, retained tree readiness, non-empty layout, and render-command generation.
- Added Kira Graphics native helper markers for UI Foundation and backend initialization without calling direct FFI from non-`@Native` Kira functions.
- Split Android live/audit logic from `packages/kira_live/src/supervisor.zig` into `packages/kira_live/src/android_live.zig` to satisfy Core Law #5 for the opened live supervisor file.
- Removed temporary bundle-builder debug output before final validation.

## Validation

```text
zig build
```

Result: passed and refreshed `/Users/priamc/.kira/toolchains/dev/0.1.0`.

```text
zig build test
```

Result: passed. Corpus summary: `1017 passed, 0 failed`.

```text
zig build repo-truth
```

Result: passed.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac build --backend hybrid /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app
```

Result: passed and wrote `.kbc`, `.khm`, `.o`, and `.dylib` artifacts.

```text
/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app --run-for 2s
```

Result: passed with live bundle load/link, entrypoint, UI Foundation, Kira Graphics frame submission, presented frame, visible content, and simulator log capture markers.

## File Size

Core Law #5 was followed for every Zig source file opened or touched in this task:

```text
560 packages/kira_live/src/supervisor_shared.zig
518 packages/kira_live/src/supervisor.zig
517 packages/kira_live/src/bundle_builder.zig
497 packages/kira_live/src/apple_runner.zig
466 packages/kira_live/src/ios_live.zig
122 packages/kira_live/src/android_live.zig
```

No touched/opened Zig file remains at or above 600 lines.

## CI Scope

No CI files, workflow files, release workflow files, CI-specific docs/scripts, or automated workflow configuration were edited or used for validation. CI-related work was intentionally untouched per explicit user instruction.
