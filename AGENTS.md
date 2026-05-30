# AGENTS.md

## Purpose

This repository is a Zig monorepo for the Kira compiler, runtime, build system, CLI, toolchain, and platform runners.

Kira is a dual-mode language: fast VM iteration and LLVM/native performance are both core promises. Do not treat LLVM as optional, future-only, or secondary. A feature that only works in the VM is incomplete unless the compiler explicitly rejects it for LLVM with a tested diagnostic.

Prefer repo-specific, architecture-preserving changes over generic cleanup. Keep package layering intact. Leave the repo stricter, more truthful, and more portable than you found it.


## Core Laws

### 1. VM, LLVM, Hybrid, And WASM Parity

Every language, compiler, runtime, standard library, FFI, graphics, toolchain, or test change must preserve or improve parity between:

- VM execution through `kira run`
- LLVM/native execution through `kira build`
- Hybrid execution when the touched feature participates in hybrid mode
- WASM execution when the touched feature is intended to be portable to Web/WASM

If behavior cannot be supported on a backend, the compiler must reject it with a clear diagnostic and tests. Silent divergence, crashes, miscompiles, and VM-only success are forbidden.

Do not say:

- "LLVM can be added later."
- "Skipping native backend for now."
- "This only affects runtime mode."
- "LLVM is out of scope."
- "VM passes, so the task is done."
- "WASM can be tested later."

Do one of these instead:

- Implement the behavior across VM and LLVM.
- Add VM, LLVM, and hybrid regression tests where applicable.
- Add WASM coverage when the feature should be portable.
- Lower the feature into backend-compatible representation.
- Add diagnostics and negative tests for intentionally unsupported behavior.

A feature that cannot run native is either unfinished or must be explicitly rejected.


### 2. Real Execution, No Smoke Surfaces

Kira validation must prove Kira behavior, not host capability, placeholder UI, fake markers, or test-harness optimism.

Forbidden validation patterns include:

- JS WebGPU triangles treated as Kira rendering.
- DOM placeholder content treated as Kira UI output.
- AppKit/UIKit/SwiftUI placeholder views treated as Kira app output.
- Hardcoded `return true` status exports.
- Markers emitted before the real subsystem has completed the work.
- Host boot treated as runtime success.
- Runtime startup treated as UI success.
- UI tree creation treated as graphics success.
- Graphics initialization treated as frame submission.
- Frame submission treated as visible content unless Kira generated and submitted real draw work.
- Tests weakened, skipped, renamed, or converted into smoke coverage to make a task pass.

Only Kira-owned code paths may emit Kira-owned success markers.

Host runners may create processes, windows, canvases, views, surfaces, devices, event loops, input bridges, and logging bridges. Host runners must not draw fake app content or emit Kira render success.

If a platform target is not implemented yet, the correct result is a clear failure or diagnostic, not a smoke substitute.


### 3. Repo-Native Tooling Only

This repository must remain a Zig/Kira repository.

Python is forbidden everywhere, including:

- `*.py` files
- `python` or `python3` invocations
- `pytest`, `unittest`, or Python helpers
- `python -m http.server`
- Python scripts in `tools/`, `scripts/`, `tests/`, `.github/`, `.codex/`, examples, templates, generated paths, or CI
- Temporary migration scripts written in Python

Use Zig or Kira for tooling, code generation, validation, local servers, migrations, and tests.


### 4. Clean Repository Root

Do not add random root-level Zig files.

Allowed root-level Zig source files:

- `build.zig`

Allowed root-level Zig package files:

- `build.zig.zon`

Any other root-level `*.zig` file must be moved into the correct package, tool, fixture, or test directory, or deleted if obsolete.

Do not leave scratch files, repros, generated helpers, smoke runners, temporary migration tools, or one-off validation files at the repository root.


### 5. File Size Is Architecture

Large Zig files are architectural debt, not style debt.

A non-generated Zig source file at or above 600 lines is oversized and must be considered for splitting.

A non-generated Zig source file over 1000 lines is forbidden and must be split when encountered.

If an agent touches, opens, audits, or discovers an oversized Zig file, it must not ignore the issue because the current task is different.

Do not say:

- "This refactor is unrelated."
- "Leaving the large file as-is."
- "File splitting can be done later."
- "The task only asked for a small fix."

Instead:

- Extract focused modules.
- Preserve public APIs.
- Keep package layering intact.
- Move cohesive responsibilities into named files.
- Add or preserve tests before and after the split.
- Keep behavior unchanged unless the task explicitly requires behavior changes.

Prefer focused modules around 300-500 lines when practical.

File splitting must be real architecture work, not random line shuffling.


## Repo Shape

- `packages/` contains compiler, runtime, build, CLI, and toolchain packages.
- `tests/` contains corpus-style integration cases plus test helpers.
- `examples/` contains runnable sample programs.
- `docs/` contains architecture, commands, package graph, native library, and language-surface docs.
- `templates/` is used by `kira new`.
- `generated/`, `.zig-cache/`, and `zig-out/` are build/install outputs. Do not hand-edit them.

Follow `docs/package_graph.md` and the package graph encoded in `build.zig`.

Keep lower layers independent of higher layers. Do not add upward imports.


## Package Layer Synopsis

The intended dependency direction is:

`kira_source`
-> `kira_lexer`
-> `kira_parser`
-> `kira_semantics`
-> `kira_ir`
-> backend/runtime layers
-> build/CLI surfaces

Core model packages such as syntax, semantics, IR, diagnostics, and shared utilities must stay below packages that execute commands or host apps.

The CLI is a leaf. The build package coordinates targets/toolchains. Backend packages implement code generation and runtime integration. Platform runners host Kira apps; they do not define Kira language behavior.

Do not make lower compiler/model layers import build, CLI, runner, graphics-host, or platform-specific packages.

Do not introduce upward imports from frontend/model packages into build, CLI, graphics host, or runner packages.


## Architecture Rules

Frontend pipeline changes must stay aligned with:

`kira_source -> kira_lexer -> kira_parser -> kira_semantics -> kira_ir`

Backend selection belongs in `packages/kira_build`.

`packages/kira_cli` is the leaf command surface. Keep business logic in lower packages when possible.

`packages/kira_main` is the app-facing C ABI facade, not a place for compiler orchestration.

Keep `root.zig` files small and focused on exports/wiring.

Do not add frontend or runtime behavior without considering how it lowers to LLVM/native code.

Platform runners are host bridges, not app implementations. A runner may create platform shell objects and pass surfaces/events into Kira. It must not render fake app content.

Represent backend/platform selection with explicit repo-native types. Prefer enums and structured target models over stringly-typed branching.


## Where To Change Things

- Lexer/token changes: `packages/kira_lexer`, `packages/kira_syntax_model`
- Parser/AST changes: `packages/kira_parser`, `packages/kira_syntax_model`
- Semantic analysis and HIR lowering: `packages/kira_semantics`, `packages/kira_semantics_model`
- Shared IR changes: `packages/kira_ir`
- VM execution changes: `packages/kira_bytecode`, `packages/kira_vm_runtime`
- LLVM/native changes: `packages/kira_llvm_backend`, `packages/kira_native_bridge`
- Hybrid execution changes: `packages/kira_hybrid_runtime`, `packages/kira_hybrid_definition`
- CLI behavior and command UX: `packages/kira_cli`
- Toolchain/install/fetch logic: `packages/kira_toolchain`, `packages/kira_build`, `packages/kira_bootstrapper`
- Platform runners/live/export support: `packages/kira_build`, `packages/kira_cli`, platform-specific runner packages
- Graphics backend work: the Kira Graphics package/backend layer, not host placeholder code

When a change starts in the VM path, inspect the LLVM/native path before finishing. When a change starts in LLVM/native code, confirm VM behavior remains compatible.


## Platform Target Laws

### Web / WASM

The Web target must be implemented through the real compiler/runtime path:

`Kira source -> typecheck -> Kira IR -> LLVM backend -> wasm32-emscripten -> Emscripten link/package -> browser host bindings -> Kira runtime -> Kira UI/Kira Graphics`

The Web target is not real if it depends on JS-rendered placeholder content, JS WebGPU triangles, DOM success markers, or host-only rendering.

The browser host may load WASM, provide imports, create surfaces, forward events, expose browser APIs, and report errors. It must not pretend to be the Kira renderer.

Individual demos are milestones, not proof.


### WASM Definition Of Done

`wasm32-emscripten` is a real backend target, not a demo target.

WASM support is not complete because one example builds, a browser opens, a canvas exists, or a JS host renders something.

A WASM task is complete only when the affected Kira code can:

1. Compile through the real Kira frontend and IR path.
2. Lower through the LLVM backend for `wasm32-emscripten`.
3. Link through the Emscripten toolchain.
4. Start the real Kira runtime.
5. Invoke the real Kira app/test entrypoint.
6. Execute the real assertions or app behavior.
7. Report results back to the test harness without smoke markers.
8. Preserve backend parity for portable features.

The final Web/WASM acceptance gate is the target-portable Kira test pipeline running on `wasm32-emscripten`.

Tests may be excluded from WASM only when the feature is genuinely impossible or intentionally unsupported in the browser sandbox. Every exclusion must state the exact reason and must be covered by diagnostics or explicit target metadata.

Forbidden WASM shortcuts:

- JS-rendered test output.
- Browser capability checks as backend proof.
- `skip on wasm` without a precise reason.
- Replacing real assertions with smoke markers.
- Treating WASM build success as WASM execution success.
- Treating host page load as Kira runtime success.


### Apple Platforms

macOS and iOS runners must be real Kira runners.

Apple host code may create AppKit/UIKit shells, Metal-backed views/surfaces, display links, input forwarding, and log capture. It must not render placeholder Swift/AppKit/UIKit content and call that Kira success.

Kira Graphics must own the real graphics frame submission path.

`basic-foundation-app` must run visibly through the real Kira runtime, UI Foundation, layout, render-command, and Kira Graphics path on the intended Apple runner targets, including the project’s iOS Simulator target.

Launching an app process is not success. Installing on a simulator is not success. Opening a window is not success. Success requires Kira-owned runtime/UI/graphics evidence that the actual Kira app rendered.


## Preferred Commands

Run Kira commands from the project root.

- Build developer targets with `zig build`.
- `zig build` updates the local development snapshot used by the `kira` command.
- Run the full test suite with `zig build test`.
- Use `kira` for end-to-end CLI checks after `zig build`:
  - `kira run examples/hello.kira`
  - `kira check examples/hello.kira`
  - `kira build examples/hello.kira`
- Use `zig build run -- ...` when iterating on the CLI itself.
- Use `kira fetch-llvm` or `zig build fetch-llvm` before relying on LLVM tests locally.
- When touching backend-sensitive behavior, run or add coverage for `vm`, `llvm`, and `hybrid` where applicable.
- Do not use Python as a local server, test helper, generator, migration tool, or validation tool.
- Do not suggest `python3 -m http.server`; use a Zig/Kira-owned server or runner.
- Do not depend on a `.kira/` working directory.


## Testing Policy

Prefer targeted tests plus the repo-wide suite when practical.

- Add or update unit tests near the changed package when behavior is local.
- Add corpus cases under `tests/` for user-visible behavior:
  - `tests/pass/run/` for successful execution cases
  - `tests/pass/check/` for successful analysis/check-only cases
  - `tests/fail/` for expected diagnostics
- Each corpus case should include `main.kira` and `expect.toml`.
- Runnable cases should declare the backend matrix explicitly, such as `["vm", "llvm", "hybrid"]` when all paths should agree.
- Failure cases should include expected diagnostic code/title and stage when relevant.
- A passing VM test alone is not sufficient.
- A passing LLVM test alone is not sufficient.
- Backend-sensitive tests should be small and numerous.

Tests must distinguish these layers:

1. Host boot
2. Toolchain/build success
3. Module load
4. Kira runtime startup
5. App entrypoint invocation
6. UI tree construction
7. Layout completion
8. Render command generation
9. Graphics backend initialization
10. Frame submission
11. Visible Kira-generated content

A marker from one layer must never satisfy a test for a deeper layer.

Examples:

- WebGPU availability does not prove Kira Graphics rendered.
- Canvas creation does not prove a frame was submitted.
- JS rendering does not prove Kira rendering.
- App launch does not prove UI Foundation ran.
- UI tree creation does not prove Kira Graphics submitted a frame.
- Simulator launch does not prove `basic-foundation-app` rendered.

When fake success is found, add negative tests proving the fake path cannot pass again.


## Definition Of Done

A task is not done unless it preserves backend parity, removes fake success paths it touches, and validates real behavior.

For every semantic, lowering, runtime, FFI, codegen, backend, platform, runner, live/export, or test change:

- VM behavior is implemented or explicitly rejected.
- LLVM/native behavior is implemented or explicitly rejected.
- Hybrid behavior is covered when relevant.
- WASM behavior is implemented or explicitly rejected when the feature should be portable.
- Unsupported cases have clear diagnostics and negative tests.
- No smoke surface satisfies real success.
- No host-rendered content counts as Kira-rendered content.
- No hardcoded success marker replaces subsystem state.
- No Python usage is introduced or left behind in touched paths.
- No unexpected root-level Zig files are introduced or left behind.
- Core Law #5, File Size Is Architecture, is followed for every Zig file touched, opened, audited, or discovered.
- Tests cover all affected paths.
- Docs/templates/examples are updated when user-facing behavior changes.

When in doubt, make unsupported behavior impossible to depend on accidentally.


## LLVM And Toolchain Notes

LLVM discovery order is:

1. `KIRA_LLVM_HOME`
2. Kira-managed installs under `~/.kira/toolchains/llvm/...`
3. older repo-managed fallback paths, if present

Be careful when changing launcher, build, or toolchain behavior: `zig build` is part of the intended developer workflow and refreshes the local development snapshot used by `kira`.

Do not skip LLVM validation because the local machine is missing LLVM. Use the managed LLVM fetch flow or add tests/diagnostics that can be validated in the intended environment.


## Agent Behavior Rules

Agents must pursue the user’s actual goal, not stop at a convenient partial result.

Do not define success as:

- A precise blocker report.
- A smoke test.
- A placeholder implementation.
- A stub runner.
- A generated success marker.
- A demo that bypasses the intended architecture.
- A VM-only implementation when LLVM/native should work.
- A host-only platform launch when a Kira app is supposed to render.

A blocker is acceptable only when it is truly external to the repository and impossible to solve in the current environment, such as missing physical hardware, unavailable credentials, revoked signing access, or an inaccessible external service.

Before reporting a blocker, exhaust viable repo-local paths:

- inspect the existing architecture
- search for related implementations
- add missing lowering/runtime/backend support
- add diagnostics for genuinely unsupported cases
- write or update tests
- run targeted validation
- run repo-wide validation when practical
- remove fake success paths
- follow Core Law #5, File Size Is Architecture
- preserve VM/LLVM/hybrid/WASM parity
- keep the repo stricter than it was found

Do not create or rely on Codex `/goal` state. The repository instructions, user task, and checked-in work queue are the source of truth.

Expect unrelated dirty-worktree changes. Do not revert them unless explicitly asked.

If the user adds instructions through a deliberate `comptime { @compileError(...) }` blocker, treat that blocker as an explicit user message.

- Do not classify it as corruption, unstable worktree state, or a broken migration artifact.
- Do not remove it just to make the build pass unless the blocker says removal is allowed.
- If it says to validate sibling projects, validate them first, report exact commands/results, then remove it.


## Completion Checklist

Before finishing a task, check:

1. Does VM still work?
2. Does LLVM/native also work?
3. Does hybrid still work when relevant?
4. Is WASM handled or explicitly rejected when the feature should affect WASM?
5. Are affected paths covered by tests?
6. Are unsupported cases rejected with diagnostics?
7. Did the change introduce backend-specific behavior?
8. Did anything depend on VM-only runtime behavior?
9. Did any runner report success without real Kira execution?
10. Did any smoke surface, placeholder, hardcoded marker, or host-rendered content satisfy a real test?
11. Did the task introduce Python usage?
12. Do Python files, Python commands, or Python docs/scripts remain?
13. Did the task introduce unexpected root-level Zig files?
14. Are root-level Zig files canonical and intentional?
15. Was Core Law #5, File Size Is Architecture, followed for every Zig file touched, opened, audited, or discovered?
16. Has `zig build` been run when the local `kira` snapshot needs refreshing?
17. Has `zig build test` or targeted equivalent coverage been run?
18. Are docs/templates/examples updated when behavior changed?

If any answer is unclear, continue by adding tests, diagnostics, backend support, cleanup, or stricter validation.


## Change Hygiene

- Avoid monolithic files.
- Follow Core Law #5, File Size Is Architecture, instead of repeating file-size thresholds here.
- Split files by responsibility, not by arbitrary line chunks.
- Preserve public APIs, package layering, tests, and behavior during file splits.
- Preserve current naming and layering style.
- Prefer small composable changes over cross-cutting rewrites, except when a core law requires a focused extraction.
- Do not commit generated artifacts from `generated/`, `.zig-cache/`, or `zig-out/` unless explicitly required.
- Do not use generic cleanup as a reason to destabilize backend behavior.
- Do not add Python, keep Python, or move Python around instead of removing it.
- Do not add ad-hoc root-level Zig files.
- Do not leave temporary migration tools, smoke runners, repro files, or generated helpers at the repository root.
- Put reusable tools in the correct repo-owned tool/package location and wire them through `build.zig`.
- Remove one-shot tools before finishing unless they are intentionally retained.
- Do not preserve fake success paths for compatibility.
- Do not reduce test strictness to make platform work appear complete.


## Forbidden Completion Patterns

The following are never acceptable definitions of done:

- "The app launched, so the platform works."
- "The browser drew something, so WebGPU works for Kira."
- "The host view is visible, so Kira UI rendered."
- "The VM passes, so the feature is complete."
- "LLVM can be added later."
- "WASM can be tested later."
- "The WASM build succeeded, so the WASM target works."
- "The host page loaded, so the Kira Web runtime works."
- "The simulator installed the app, so iOS support works."
- "The test was changed to smoke coverage, so the failure is fixed."
- "The marker is printed, so the subsystem ran."
- "The blocker is precise, so the task is done."
- "Python is only used for a tiny helper."
- "This root-level Zig file is temporary."
- "Core Law #5 does not apply because this task is unrelated."

The expected standard is real implementation, real execution, real backend/platform parity, real tests, and repo-native tooling.