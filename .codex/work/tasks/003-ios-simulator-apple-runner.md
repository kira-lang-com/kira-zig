# 003 - Real iOS Simulator Apple Runner

Status: complete

## Hard Precondition

Do not execute this task until all earlier tasks are complete.

Required completed tasks:

- `000-repository-truth-cleanup.md`
- `001-wasm32-emscripten-backend.md`
- `002-macos-apple-runner.md`

If any required task is not marked `Status: complete`, stop immediately and return to the earliest incomplete task.

## Objective

Implement a real iOS Simulator runner for Kira apps with real Kira Graphics support.

The iOS runner must reuse the Apple runner architecture where possible, while correctly handling iOS Simulator app packaging, install, launch, surface creation, frame scheduling, and log capture.

Installing or launching the simulator app is not success. Success requires Kira-owned runtime/UI/graphics evidence.



## Scope

This task covers:

- iOS Simulator runner architecture
- UIKit or appropriate native iOS shell
- simulator build/package/install/launch flow
- Metal-backed view/surface
- real Kira runtime startup
- real Kira app entrypoint invocation
- real Kira Graphics frame path
- log capture through simulator tools
- validation that distinguishes simulator launch from Kira rendering



## Required Architecture

The runner may:

- create an iOS app shell
- create a `UIView` or equivalent native surface host
- expose a Metal-backed layer or approved graphics surface
- install and launch on an iOS Simulator
- forward display ticks, resize, input, and logs
- call into Kira runtime

The runner must not:

- render placeholder Swift/UIKit content and call it Kira output
- emit Kira render success from host code
- treat simulator install as app success
- treat simulator launch as render success
- bypass Kira Graphics for app rendering



## Required Shared Apple Design

Reuse or extract shared Apple runner infrastructure from the macOS runner where appropriate.

Shared concepts should include:

- runtime bridge
- graphics surface bridge
- frame scheduling abstraction
- log/marker capture
- common runner validation model
- host/Kira marker separation

Do not duplicate large Apple runner logic into separate monolithic files.



## Required Validation

Add or update validation proving:

- iOS Simulator app builds
- simulator app installs, if a simulator runtime is available
- simulator app launches, if a simulator runtime is available
- Kira runtime starts
- Kira app entrypoint is invoked
- Kira Graphics owns the frame path
- simulator launch alone cannot satisfy Kira render success

Run:

    zig build
    zig build test

Run the strongest available iOS Simulator validation.

If the local machine lacks the required simulator runtime, Xcode tools, or iOS platform support, prove that with exact command output and keep the task incomplete/blocking only for that external part. Still complete all repo-local implementation and validation possible.



## Completion Criteria

This task is complete only when:

- iOS Simulator runner exists as real platform runner infrastructure
- runner does not render fake app content
- simulator package/build flow exists
- Kira runtime startup is wired through the runner
- Kira app entrypoint is wired through the runner
- Kira Graphics owns the intended frame path
- simulator launch alone cannot satisfy render success tests
- shared Apple runner infrastructure is reused where appropriate
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or remaining failures are proven external and documented
- iOS Simulator runner validation succeeds to the strongest level available in this environment



## Report

Write a report under:

    .codex/work/reports/003-ios-simulator-apple-runner.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/003-ios-simulator-apple-runner.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
