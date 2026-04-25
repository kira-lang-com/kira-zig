# Internal Agent Memory

This directory is an implementation-oriented memory corpus for future agents working on `kirac`.
It is not public docs and should stay current with the repo’s real behavior.

## How to use

- Read this corpus before touching compiler, runtime, build, CLI, shader, or package-management code.
- Prefer the file-level inventories and “when touching X, check Y” notes over guessing from filenames.
- Treat this as a durable orientation layer, not a log of every patch.

## How to update

Update `docs/agent-memory/` when any durable fact changes:

- package boundaries or dependency direction
- syntax, semantics, or executable lowering behavior
- backend/runtime/hybrid/FFI contracts
- CLI commands, build/install, toolchain discovery, or artifact layout
- test corpus layout or expectations
- known pitfalls, oversized files, or refactor targets
- cross-repo interop boundaries such as `../kira-graphics`

Keep entries short, current, and specific. Remove stale facts instead of stacking contradictory notes.

## Index

- [repo-map.md](repo-map.md)
- [package-graph.md](package-graph.md)
- [language-surface.md](language-surface.md)
- [frontend-pipeline.md](frontend-pipeline.md)
- [runtime-and-backends.md](runtime-and-backends.md)
- [hybrid-runtime.md](hybrid-runtime.md)
- [native-ffi.md](native-ffi.md)
- [cli-build-toolchain.md](cli-build-toolchain.md)
- [shaders-ksl.md](shaders-ksl.md)
- [testing.md](testing.md)
- [refactor-guidelines.md](refactor-guidelines.md)
- [recent-context.md](recent-context.md)
