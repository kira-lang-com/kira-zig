---
name: where-to-change
description: "Kira package map and layering rules: which package owns lexer/parser/semantics/IR/VM/LLVM/hybrid/CLI/toolchain/platform-runner/graphics changes, and the no-upward-imports layering constraint. Read when it's unclear which package a change belongs in."
---

# Where to change things

Dependency direction (no upward imports): `kira_source -> kira_lexer ->
kira_parser -> kira_semantics -> kira_ir -> backend/runtime layers ->
build/CLI surfaces`. Model packages (syntax, semantics, IR, diagnostics,
utils) stay below command/host packages. Follow `docs/package_graph.md` and
`build.zig` for the enforced graph.

## Package map

- Lexer/token: `kira_lexer`, `kira_syntax_model`
- Parser/AST: `kira_parser`, `kira_syntax_model`
- Semantics/HIR lowering: `kira_semantics`, `kira_semantics_model`
- Shared IR: `kira_ir`
- VM execution: `kira_bytecode`, `kira_vm_runtime`
- LLVM/native: `kira_llvm_backend`, `kira_native_bridge`
- Hybrid: `kira_hybrid_runtime`, `kira_hybrid_definition`
- CLI: `kira_cli` (leaf — keep logic lower when possible)
- C ABI facade (app-facing, not orchestration): `kira_main`
- Toolchain/install/fetch: `kira_toolchain`, `kira_build`,
  `kira_bootstrapper`
- Platform runners/live/export: `kira_build`, `kira_cli`, platform-specific
  runner packages
- Graphics backend: Kira Graphics package/backend layer, not host
  placeholder code

Top-level dirs: `packages/` (all of the above), `tests/` (corpus + helpers),
`examples/` (runnable samples), `docs/`, `templates/` (used by `kira new`).
`generated/`, `.zig-cache/`, `zig-out/` are build outputs — don't hand-edit.

Backend/platform selection: explicit repo-native enums/structured target
models, never stringly branching. Platform runners are host bridges (may
create shell objects, pass surfaces/events into Kira) — never app
implementations, never render fake content.

Start in VM -> inspect LLVM/native before finishing. Start in LLVM/native ->
confirm VM compatibility.
