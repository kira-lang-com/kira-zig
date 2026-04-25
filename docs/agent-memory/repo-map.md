# Repo Map

Internal implementation orientation for `kirac`.

## Shape

- `packages/` — Zig packages for compiler, runtime, build, CLI, manifest, package manager, shaders, etc.
- `tests/` — corpus-style integration coverage plus test harnesses.
- `examples/` — runnable Kira programs and library-ish showcases.
- `docs/` — public docs; this memory corpus stays separate under `docs/agent-memory/`.
- `templates/` — scaffolds used by `kira new` / installer flow.
- `generated/`, `.zig-cache/`, `zig-out/`, `.kira/` — build/install outputs; do not hand-edit.

## High-value directories

| Path | Purpose |
| --- | --- |
| `build.zig` | Package graph wiring, build steps, install/fetch logic, test entry points |
| `packages/kira_parser/src/` | Executable-language parser split into decl/block/expr modules |
| `packages/kira_semantics/src/` | Frontend analysis and lowering helpers |
| `packages/kira_ir/src/` | Shared executable IR lowerer |
| `packages/kira_vm_runtime/src/` | Bytecode VM and struct/native-state marshalling |
| `packages/kira_llvm_backend/src/` | Text-LLVM lowering, validation, native codegen, toolchain discovery |
| `packages/kira_hybrid_runtime/src/` | Mixed bytecode/native host runtime |
| `packages/kira_native_bridge/src/` | Native library loading, trampoline binding, runtime invoker bridge |
| `packages/kira_build/src/` | CLI/build orchestration and shader pipeline integration |
| `packages/kira_manifest/src/`, `packages/kira_project/src/`, `packages/kira_package_manager/src/` | Project/package/lockfile and registry flow |
| `packages/kira_ksl_*`, `packages/kira_shader_*`, `packages/kira_glsl_backend` | Dedicated shader language pipeline |

## Package list (short form)

- `kira_core` — ids, small shared core types/errors.
- `kira_source` — source text, spans, line maps.
- `kira_diagnostics` — diagnostic data/rendering.
- `kira_log` — structured logging.
- `kira_runtime_abi` — value model, bridge values, execution modes, trace hooks.
- `kira_syntax_model` — executable-language tokens/AST.
- `kira_lexer` / `kira_parser` — executable-language front end.
- `kira_semantics_model` / `kira_semantics` — HIR and lowering/analysis.
- `kira_ir` — backend-facing executable IR.
- `kira_bytecode` / `kira_vm_runtime` — VM bytecode and runtime.
- `kira_backend_api` — backend-agnostic compile request/result facade.
- `kira_native_lib_definition` / `kira_manifest` — native-library manifest contracts and parsing.
- `kira_project` / `kira_package_manager` / `kira_program_graph` — project discovery, package resolution, source graph.
- `kira_build_definition` / `kira_build` — build targets, artifacts, pipeline orchestration.
- `kira_hybrid_definition` / `kira_native_bridge` / `kira_hybrid_runtime` — hybrid manifest + runtime bridge.
- `kira_llvm_backend` — LLVM/native emission and helper symbols.
- `kira_ksl_syntax_model` / `kira_ksl_parser` / `kira_ksl_semantics` / `kira_shader_ir` / `kira_shader_model` / `kira_glsl_backend` — shader pipeline.
- `kira_cli` — command surface.
- `kira_main` — C ABI facade for generated apps.
- `kira_doc`, `kira_linter`, `kira_app_generation` — docs, lint, scaffolding.

## Where to inspect first

- Parser/syntax bug: `packages/kira_parser/src/parser_decls.zig`, `parser_types_exprs.zig`, `parser_statements.zig`, `parser_blocks.zig`.
- Semantics/lowering bug: `packages/kira_semantics/src/lower_*.zig`, `analyzer.zig`, `function_types.zig`.
- VM/backend parity bug: `packages/kira_ir/src/`, `packages/kira_bytecode/src/`, `packages/kira_vm_runtime/src/vm.zig`, `packages/kira_llvm_backend/src/`.
- Hybrid/native bridge bug: `packages/kira_hybrid_runtime/src/`, `packages/kira_native_bridge/src/`, `packages/kira_runtime_abi/src/`.
- CLI/build bug: `packages/kira_cli/src/`, `packages/kira_build/src/`, `build.zig`.
- Package management bug: `packages/kira_manifest/src/`, `packages/kira_project/src/`, `packages/kira_package_manager/src/`.
- Shader bug: `packages/kira_ksl_*`, `packages/kira_shader_*`, `packages/kira_glsl_backend/src/glsl.zig`.

## Hygiene

- Keep generated output out of source edits.
- Keep source roots anchored under package `app/` directories when the program graph is involved.
- Use `docs/agent-memory/testing.md` and `refactor-guidelines.md` before broad changes.
