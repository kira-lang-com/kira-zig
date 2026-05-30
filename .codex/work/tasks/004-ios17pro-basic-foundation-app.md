# 004 - iPhone 17 Pro Simulator basic-foundation-app

Status: complete

## Hard Precondition

Do not execute this task until all earlier tasks are complete.

Required completed tasks:

- `000-repository-truth-cleanup.md`
- `001-wasm32-emscripten-backend.md`
- `002-macos-apple-runner.md`
- `003-ios-simulator-apple-runner.md`

If any required task is not marked `Status: complete`, stop immediately and return to the earliest incomplete task.

## Objective

Run `basic-foundation-app` on the iPhone 17 Pro simulator through the real Kira runtime, UI Foundation, layout, render-command, and Kira Graphics path.

This is not a simulator install test.

This is not a host view visibility test.

This is not a placeholder UIKit/SwiftUI rendering test.

The app must be the actual Kira app.



## Scope

This task covers:

- selecting or creating the iPhone 17 Pro simulator target
- building `basic-foundation-app` for iOS Simulator
- installing the app on the simulator
- launching the app
- capturing logs/markers
- proving Kira runtime startup
- proving app entrypoint invocation
- proving UI Foundation tree construction
- proving layout completion
- proving render command generation
- proving Kira Graphics frame submission
- proving visible Kira-generated content when available



## Required Simulator Target

Use the iPhone 17 Pro simulator if available.

If the exact simulator is not installed, inspect available devices and runtimes with repo-safe commands, such as:

    xcrun simctl list devices
    xcrun simctl list runtimes

If iPhone 17 Pro is unavailable because of local Xcode/runtime limitations, document exact evidence.

Do not silently substitute another simulator without reporting it.

If substitution is necessary for repo-local progress, prefer the closest available iPhone Pro simulator and keep the exact iPhone 17 Pro requirement documented as incomplete/blocking.



## Required Kira Evidence

Success requires evidence for the real Kira path:

1. Kira runtime started
2. Kira app entrypoint invoked
3. UI Foundation app started
4. UI tree built
5. retained tree ready, if applicable
6. layout produced non-empty output
7. render commands generated
8. Kira Graphics initialized the Apple graphics backend
9. Kira Graphics submitted a frame
10. visible Kira-generated content was produced, when the rendering stack supports this marker

Host-only launch, simulator install, and placeholder native UI cannot satisfy these requirements.



## Required Validation

Run:

    zig build
    zig build test

Run the iOS Simulator command for `basic-foundation-app`.

Capture the exact command used, logs, marker output, and result.

If the run fails, fix repo-local issues instead of accepting the failure.

Only external simulator/tooling limitations may remain as blockers, and they must be documented with exact command output.



## Completion Criteria

This task is complete only when:

- `basic-foundation-app` builds for iOS Simulator
- iPhone 17 Pro simulator is used, or exact external evidence proves it is unavailable
- app installs on the simulator when the simulator runtime is available
- app launches on the simulator when the simulator runtime is available
- Kira runtime starts
- Kira app entrypoint is invoked
- UI Foundation path runs for the app
- layout path runs for the app
- render command path runs for the app
- Kira Graphics owns frame submission
- host-only native content cannot satisfy success
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or remaining failures are proven external and documented
- the task report contains exact simulator evidence



## Report

Write a report under:

    .codex/work/reports/004-ios17pro-basic-foundation-app.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/004-ios17pro-basic-foundation-app.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
