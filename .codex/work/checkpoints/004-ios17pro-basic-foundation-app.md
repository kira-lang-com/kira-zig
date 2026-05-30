# Checkpoint - 004 iPhone 17 Pro Simulator basic-foundation-app

Task: `.codex/work/tasks/004-ios17pro-basic-foundation-app.md`

Status: complete

## Completed

- Verified all lower-numbered queue tasks were complete before starting task 004.
- Used the available booted iPhone 17 Pro Simulator:
  - `03012DE8-E712-4C08-B84A-0BCFE82D0035`
  - iOS `26.5`
- Ran `basic-foundation-app` from `/Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app` through the real `ios-simulator` live path.
- Added the missing `aarch64-ios-simulator` native library target for Kira Graphics Sokol.
- Fixed the Kira Graphics immediate UI pipeline on the Metal-backed simulator target by adding Metal shader source.
- Added Kira-owned live markers for UI Foundation app/tree/retained-tree/layout/render-command evidence and Kira Graphics backend/frame/visible-content evidence.
- Split Android live/audit code out of `supervisor.zig` into `android_live.zig` so all opened/touched Zig files are under 600 lines.

## Final Simulator Evidence

Command:

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
event: live.session.ready
live.kira_graphics.visible_content.submitted
KIRA_UI_DRAW_COMMANDS_SUBMITTED
KIRA_APP_RENDERED_VISIBLE_CONTENT
event: live.ios.simulator.logs.captured source=simctl-log-show
event: live.shutdown.finished reason=quit-after
```

## Validation

- `zig build`: passed.
- `zig build test`: passed, corpus `1017 passed, 0 failed`.
- `zig build repo-truth`: passed.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac build --backend hybrid /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app`: passed.
- `/Users/priamc/.kira/toolchains/dev/0.1.0/bin/kirac live ios-simulator /Users/priamc/Coding/kira-projects/ui-foundation/Examples/basic-foundation-app --run-for 2s`: passed.

## CI Scope

No CI files, workflow files, release workflow files, CI-specific docs/scripts, or automated workflow configuration were edited or used for validation.

## Next Queue Position

Task 004 is complete. The next sorted incomplete task should be selected only after rechecking lower-numbered task status and the latest checkpoint.
