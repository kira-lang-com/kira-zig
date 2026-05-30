# 002 - Real macOS Apple Runner

Status: complete

## Hard Precondition

Do not execute this task until all earlier tasks are complete.

Required completed tasks:

- `000-repository-truth-cleanup.md`
- `001-wasm32-emscripten-backend.md`

If any required task is not marked `Status: complete`, stop immediately and return to the earliest incomplete task.

Do not inspect this task as permission to begin Apple runner work early.

## Objective

Implement a real macOS runner for Kira apps with real Kira Graphics support.

The macOS runner must host Kira. It must not be the app.

Opening a window is not success. Rendering placeholder native content is not success. Success requires Kira-owned runtime/UI/graphics evidence that the actual Kira app rendered.



## Scope

This task covers:

- macOS runner architecture
- AppKit or appropriate native macOS app shell
- real Kira runtime startup
- real app entrypoint invocation
- real Kira Graphics surface integration
- Metal-backed surface or repo-approved graphics backend surface
- frame scheduling
- resize handling
- input/event forwarding if needed by the app path
- log capture
- validation that distinguishes host launch from Kira rendering



## Required Architecture

The runner may:

- create the process
- create a window
- create a native view
- create or expose a Metal-backed surface
- run a display loop
- forward input, resize, timing, and logs
- call into the Kira runtime entrypoint

The runner must not:

- draw placeholder app UI
- render native Swift/AppKit content and call it Kira output
- emit Kira runtime/UI/graphics success markers directly
- bypass Kira Graphics for app rendering
- treat app launch as Kira app success



## Required Kira Path

The runner must drive this real path:

    macOS app shell
    -> graphics surface
    -> Kira runtime startup
    -> Kira app entrypoint
    -> UI Foundation, if app uses it
    -> layout
    -> render command generation
    -> Kira Graphics frame submission
    -> Kira-owned success evidence

Markers or logs must prove each layer separately when available.



## Required Validation

Add or update validation proving:

- macOS host launches
- Kira runtime starts
- Kira app entrypoint is invoked
- Kira Graphics receives a real surface
- frame submission is Kira-owned
- host-only window creation cannot satisfy Kira render success

Run:

    zig build
    zig build test

Run the macOS runner with the strongest available real Kira example.

Prefer `basic-foundation-app` if it is already ready for macOS at this stage. If not, use the smallest real Kira app that exercises the true runtime and graphics path, then document what remains for the UI Foundation target.



## Completion Criteria

This task is complete only when:

- macOS runner exists as real platform runner infrastructure
- runner does not render fake app content
- Kira runtime starts through the runner
- Kira app entrypoint is invoked through the runner
- Kira Graphics owns the frame path
- host-only launch cannot satisfy render success tests
- real macOS runner validation exists
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or remaining failures are proven external and documented
- macOS runner command succeeds to the strongest real rendering level currently expected by the task



## Report

Write a report under:

    .codex/work/reports/002-macos-apple-runner.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/002-macos-apple-runner.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
