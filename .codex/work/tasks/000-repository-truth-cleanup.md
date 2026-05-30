# 000 - Repository Truth Cleanup

Status: complete



## Objective

Reorganize the repository so future platform work cannot pass through fake validation.

This task must remove smoke surfaces, fake success markers, Python usage, root-level Zig clutter, and validation ambiguity before any Web/WASM or Apple runner implementation proceeds.

The result must be a stricter repo where host capability cannot be mistaken for Kira execution.

This task is the queue gatekeeper.

No Web/WASM, macOS runner, iOS runner, simulator app, or full matrix implementation may begin until this task is complete.

If later task files mention platform work, treat them as future instructions only. Do not start them early.

The only platform-related work allowed in this task is removing fake/smoke validation and preventing host-only success from satisfying future platform tests.

## Scope

This task covers:

- smoke surface removal
- fake marker removal
- host/Kira marker separation
- Python removal
- root-level Zig cleanup
- validation-layer reorganization
- anti-regression tests for fake success
- repo-purity checks
- Core Law #5 enforcement for any Zig file touched, opened, audited, or discovered



## Required Audits

Audit the repo for fake validation and smoke paths.

Search for at least:

    rg -n "smoke|placeholder|fake|stub|KiraWebGpuSmoke|APP_RENDERED_VISIBLE_CONTENT|FRAME_RENDERED|WEBGPU_FRAME|WEBGPU_PIPELINE|rendered visible|basic-foundation-app smoke|return true" .

Audit for Python usage.

Search for at least:

    rg -n "python|python3|pytest|unittest|http.server|#!/usr/bin/env python|#!/usr/bin/python|\\.py\\b" .
    fd -e py .

Audit for unexpected root-level Zig files.

Search for at least:

    fd -e zig . -d 1

Audit validation markers and classify every platform/runtime/render marker into layers:

1. host boot
2. toolchain/build success
3. module load
4. Kira runtime startup
5. app entrypoint invocation
6. UI tree construction
7. layout completion
8. render command generation
9. graphics backend initialization
10. frame submission
11. visible Kira-generated content



## Required Changes

### 1. Remove smoke surfaces

Delete or replace smoke-only success paths, including:

- JS WebGPU triangle rendering treated as Kira success
- DOM placeholder content treated as Kira UI
- native placeholder view content treated as Kira app output
- hardcoded success exports
- generated success markers not backed by real subsystem state
- tests accepting host-only rendering as Kira rendering

Host capability checks may remain only if they are clearly named as host capability and cannot satisfy Kira success tests.



### 2. Separate marker ownership

Every marker must be clearly owned by one layer.

Allowed examples:

- `HOST_WASM_FETCHED`
- `HOST_WEBGPU_AVAILABLE`
- `KIRA_RUNTIME_STARTED`
- `KIRA_APP_ENTRYPOINT_INVOKED`
- `KIRA_UI_TREE_BUILT`
- `KIRA_LAYOUT_NON_EMPTY`
- `KIRA_RENDER_COMMANDS_GENERATED`
- `KIRA_GRAPHICS_FRAME_SUBMITTED`
- `KIRA_APP_RENDERED_VISIBLE_CONTENT`

Host markers must never satisfy Kira-owned success requirements.

A marker from one layer must never satisfy a test for a deeper layer.



### 3. Remove Python everywhere

Remove all Python files, invocations, docs, CI helpers, test helpers, local-server suggestions, generators, and migration scripts.

Replace required tooling with Zig or Kira.

Forbidden:

- `*.py`
- `python`
- `python3`
- `pytest`
- `unittest`
- `python -m http.server`

Add a repo-native validation check that fails if Python is reintroduced.



### 4. Clean root-level Zig files

Keep only canonical root-level Zig files:

- `build.zig`

Keep canonical root-level Zig package files:

- `build.zig.zon`

Move valid files into the correct package/tool/test/fixture directory.

Delete obsolete scratch, repro, generated, smoke, or migration files.

Add a repo-native validation check that fails if unexpected root-level Zig files appear.



### 5. Enforce no-smoke validation

Add negative tests proving fake success cannot pass.

At minimum, ensure that:

- host launch without Kira runtime cannot satisfy runtime success
- runtime startup without app entrypoint cannot satisfy app success
- app entrypoint without UI tree cannot satisfy UI success
- UI tree without layout cannot satisfy layout success
- layout without render commands cannot satisfy render success
- WebGPU/device/canvas availability cannot satisfy Kira Graphics frame success
- host-rendered content cannot satisfy visible Kira-generated content



## Required Validation

Run the most specific validation available for the changed areas.

Also run:

    zig build
    zig build test

If `zig build test` cannot complete because of a real external blocker, document the exact blocker and run the strongest targeted subset that is available.

Do not mark this task complete if failures are caused by repo code changed in this task.



## Completion Criteria

This task is complete only when:

- no Python usage remains
- no unexpected root-level Zig files remain
- smoke surfaces no longer satisfy real success
- host markers cannot satisfy Kira markers
- fake success paths have negative tests
- repo-native checks guard against Python reintroduction
- repo-native checks guard against root-level Zig clutter
- touched validation tests distinguish the 11 execution layers
- Core Law #5 was followed for every Zig file touched, opened, audited, or discovered
- `zig build` passes
- `zig build test` passes, or any remaining failure is proven external and documented



## Report

Write a report under:

    .codex/work/reports/000-repository-truth-cleanup.md



## Checkpoint

Write a checkpoint under:

    .codex/work/checkpoints/000-repository-truth-cleanup.md



## Completion Mark

Only after all completion criteria are satisfied, change:

    Status: incomplete

to:

    Status: complete
