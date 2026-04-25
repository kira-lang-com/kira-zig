# CLI, Build, and Toolchain

Internal memory for command surface and installer/fetch flow.

## CLI responsibilities

Main files:

- `packages/kira_cli/src/main.zig` — process entry, error boundary.
- `packages/kira_cli/src/app.zig` — command dispatch.
- `packages/kira_cli/src/support.zig` — shared CLI helpers, diagnostics, path resolution.

The CLI currently exposes:

- `run`, `build`, `check`, `tokens`, `ast`
- `shader check|ast|build`
- `sync`, `add`, `remove`, `update`
- `package pack|inspect`
- `new`
- `fetch-llvm`

## Build system responsibilities

Main files:

- `build.zig`
- `packages/kira_build/src/build_system.zig`
- `packages/kira_build/src/pipeline.zig`
- `packages/kira_build/src/fetch_llvm.zig`
- `packages/kira_build/src/llvm_metadata.zig`

Build system handles:

- package module wiring
- install steps
- managed toolchain install
- fetch-LLVM helper
- test orchestration
- build/run convenience step

## Toolchain layout

Managed toolchain state is under `~/.kira/toolchains/`.

Important paths:

- `~/.kira/toolchains/current.toml`
- `~/.kira/toolchains/<channel>/<version>/`
- `~/.kira/toolchains/llvm/<llvm-version>/<host-key>/`

`kira_toolchain` owns these path helpers.

## LLVM discovery / fetch flow

Discovery order:

1. `KIRA_LLVM_HOME`
2. managed install under `~/.kira/toolchains/llvm/...`
3. older repo-managed fallback paths if present

`kira fetch-llvm`:

- reads `llvm-metadata.toml`
- maps host target to metadata target key
- downloads the pinned GitHub release asset
- installs into the managed LLVM tree
- skips when the install marker matches

## Project/package discovery

- `kira_project` finds `kira.toml`, legacy `project.toml`, or repo-root variants.
- `kira_package_manager` syncs registry/path/git dependencies and writes `kira.lock`.
- `kira_program_graph` keeps source rooted under package `app/` directories.

## When touching CLI/build/toolchain code, check

- `docs/commands.md`
- `docs/llvm_toolchain.md`
- `docs/package_management.md`
- `tests/` corpus around command behavior
- `examples/README.md` if scaffolding or install behavior changes
