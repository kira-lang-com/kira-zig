# AGENTS.md

## Purpose

This repository is a Zig monorepo for the Kira compiler/bootstrap toolchain. Prefer repo-specific changes over generic cleanup, and keep the package layering intact.

## Repo Shape

- `packages/` contains the compiler, runtime, build, CLI, and toolchain packages.
- `tests/` contains corpus-style integration cases plus test helpers.
- `examples/` holds runnable sample programs.
- `docs/` holds architecture, command, package graph, native library, and language-surface docs.
- `templates/` is used by `kira-bootstrapper new`.
- `generated/`, `.zig-cache/`, `zig-out/`, and `.kira/` are build/install outputs. Do not hand-edit them.

## Preferred Commands

- Build the normal developer targets with `zig build`.
- Run the full test suite with `zig build test`.
- Use `kira-bootstrapper` for end-to-end CLI checks:
  - `kira-bootstrapper run examples/hello.kira`
  - `kira-bootstrapper check examples/hello.kira`
  - `kira-bootstrapper build examples/hello.kira`
- Use `zig build run -- ...` when iterating on the CLI itself because it rebuilds and runs in one step.
- Use `zig build install` or `zig build install-kirac` when validating the managed toolchain install flow.

## Architecture Rules

Follow the layered graph documented in `docs/package_graph.md` and encoded in `build.zig`.

- Keep lower layers independent of higher layers. Do not add upward imports.
- Frontend pipeline changes should stay aligned with the existing flow:
  `kira_source` -> `kira_lexer` -> `kira_parser` -> `kira_semantics` -> `kira_ir`.
- Backend selection belongs in `packages/kira_build`.
- `packages/kira_cli` is the leaf command surface. Keep business logic in lower packages when possible.
- `packages/kira_main` is the app-facing C ABI facade, not a place for compiler orchestration.
- Keep `root.zig` files small and focused on exports/wiring.

## Where To Change Things

- Lexer/token changes: `packages/kira_lexer`, `packages/kira_syntax_model`.
- Parser/AST changes: `packages/kira_parser`, `packages/kira_syntax_model`.
- Semantic analysis and HIR lowering: `packages/kira_semantics`, `packages/kira_semantics_model`.
- Shared IR changes: `packages/kira_ir`.
- VM execution changes: `packages/kira_bytecode`, `packages/kira_vm_runtime`.
- LLVM/native changes: `packages/kira_llvm_backend`, `packages/kira_native_bridge`.
- Hybrid execution changes: `packages/kira_hybrid_runtime`, `packages/kira_hybrid_definition`.
- CLI behavior and command UX: `packages/kira_cli`.
- Toolchain/install/fetch logic: `packages/kira_toolchain`, `packages/kira_build`, `packages/kira_bootstrapper`.

## Testing Expectations

Prefer targeted tests plus the repo-wide suite when practical.

- Add or update unit tests near the changed package when behavior is local.
- Add corpus cases under `tests/` for user-visible compiler/runtime behavior:
  - `tests/pass/run/` for successful execution cases
  - `tests/pass/check/` for successful analysis/check-only cases
  - `tests/fail/` for expected diagnostics
- Each corpus case should include `main.kira` and `expect.toml`.
- For runnable cases, declare the backend matrix explicitly in `expect.toml`, for example `["vm", "llvm", "hybrid"]` when all paths should agree.
- For failure cases, include the expected diagnostic code/title and stage when relevant.
- If LLVM or hybrid behavior is touched, make sure the affected corpus coverage still exercises those paths.

## Docs And Examples

Keep docs and samples in sync with behavioral changes.

- Update `README.md` and `docs/commands.md` when commands, install flow, or backend behavior changes.
- Update `docs/architecture.md` or `docs/package_graph.md` when package responsibilities or dependencies move.
- Update `docs/language_inventory.md` when the implemented frontend surface or executable lowering boundary changes.
- Update `examples/` when syntax or showcased workflows change.
- If `kira-bootstrapper new` output changes, update `templates/` and verify the generated app shape still makes sense.

## LLVM And Toolchain Notes

- LLVM discovery order is:
  1. `KIRA_LLVM_HOME`
  2. Kira-managed installs under `~/.kira/toolchains/llvm/...`
  3. older repo-managed fallback paths, if present
- Use `kira-bootstrapper fetch-llvm` or `zig build fetch-llvm` to install the pinned LLVM bundle before relying on LLVM backend tests locally.
- Be careful when changing install or launcher behavior: `zig build install` and `zig build install-kirac` are part of the intended developer workflow.

## Change Hygiene

- Avoid monolithic files. Split work across focused modules when a file starts accumulating multiple responsibilities.
- Treat 1000 lines as a hard upper limit for a source file, and prefer multi-file designs well before reaching it.
- This repo may be mid-refactor. Expect unrelated dirty-worktree changes and do not revert them unless explicitly asked.
- Preserve the current naming and layering style instead of introducing new abstractions casually.
- Prefer small, composable changes over cross-cutting rewrites.
- Do not commit generated artifacts from `generated/`, `.zig-cache/`, or `zig-out/` unless the task explicitly calls for them.
