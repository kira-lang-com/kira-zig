# 001 - Real LLVM To wasm32-emscripten Backend

Status: complete

## Hard Precondition

Do not execute this task until all earlier tasks are complete.

Required completed tasks:

- `000-repository-truth-cleanup.md`

If any required task is not marked `Status: complete`, stop immediately and return to the earliest incomplete task.

Do not inspect this task as permission to begin Web/WASM work early.

## Objective

Implement real Kira LLVM backend support for `wasm32-emscripten`.

This task must make Web/WASM a real platform target through the compiler/runtime/toolchain path, not through JS demos, smoke pages, fake markers, or host-rendered output.



## Required Architecture

The intended path is:

    Kira source
    -> typecheck
    -> Kira IR
    -> LLVM backend
    -> wasm32-emscripten
    -> Emscripten link/package
    -> browser host bindings
    -> Kira runtime
    -> Kira app/test entrypoint
    -> real assertions or app behavior

The Web target is not real if it depends on:

- JS-rendered placeholder content
- JS WebGPU triangles
- DOM success markers
- host-only rendering
- build-only WASM success
- skipped tests without precise platform reasons



## Scope

This task covers:

- target model support for `wasm32-emscripten`
- LLVM target emission for WASM
- Emscripten toolchain discovery
- Emscripten link/package flow
- browser host binding ABI
- Kira runtime startup in WASM
- test execution path for WASM where practical
- explicit diagnostics or target metadata for unsupported browser-sandbox behavior
- anti-smoke validation for WASM



## Required Target Modeling

Add or update a real target representation.

Use explicit repo-native types.

Do not add stringly-typed platform branching where an enum or structured target model belongs.

The target model must distinguish at least:

- native targets
- `wasm32-emscripten`
- browser host environment
- target capabilities
- platform-impossible features, if any



## Required Toolchain Work

Implement Emscripten discovery and validation.

The implementation should be able to find and validate the Emscripten toolchain through repo-supported configuration.

If the toolchain is missing, report a clear diagnostic.

Missing Emscripten is not proof that the backend is unsupported. It is a setup diagnostic.



## Required Backend Work

Implement real LLVM lowering/emission for `wasm32-emscripten`.

Do not fake success by emitting a placeholder WASM module.

Do not create test-only exports returning success.

Do not bypass the Kira frontend, typecheck, IR, or LLVM backend path.



## Required Runtime Work

WASM output must start the real Kira runtime and invoke the real app/test entrypoint.

Host JS may provide imports, instantiate the module, forward events, expose browser APIs, and report errors.

Host JS must not render Kira app content.

Host JS must not emit Kira render success.



## Required Test Pipeline Work

Move toward this command shape, or the repo’s equivalent:

    kira test --target wasm32-emscripten

or:

    zig build test-wasm

The command must execute real Kira test code on the WASM target, not merely build artifacts.

A passing WASM build is not enough.

A loaded host page is not enough.

A browser capability check is not enough.



## WASM Skip Policy

Tests may be excluded from WASM only when the feature is genuinely impossible or intentionally unsupported in the browser sandbox.

Every exclusion must include:

- exact feature
- exact reason
- target/capability metadata or diagnostic
- test coverage proving unsupported behavior is not silently accepted

Vague `skip on wasm` is forbidden.



## Required Validation

Run targeted WASM validation.

Run native/backend validation touched by this task.

Run:

    zig build
    zig build test

If Emscripten is unavailable, add and run all repo-local validation possible, then document the exact missing toolchain state.

Do not mark complete if the implementation path is untested because of avoidable local setup.



## Completion Criteria

This task is complete only when:

- `wasm32-emscripten` exists as a real target
- Kira code can lower through LLVM for the WASM target
- Emscripten link/package flow exists
- Kira runtime startup works on WASM for at least the minimal real runtime case
- real Kira test/app entrypoint invocation works on WASM
- host JS does not render fake Kira content
- WASM tests execute real assertions or app behavior where implemented
- unsupported browser-sandbox behavior is explicitly diagnosed or target-excluded with reason
- no smoke marker satisfies WASM success
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or remaining failures are proven external and documented
- WASM-target validation passes to the strongest level available in this environment



## Report

Write a report under:

    .codex/work/reports/001-wasm32-emscripten-backend.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/001-wasm32-emscripten-backend.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
