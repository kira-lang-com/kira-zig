# Package Graph

Internal layering map for repo changes.

## Layering rule

- Higher layers may depend on lower layers.
- Lower layers must never import upward.
- If a change feels like it needs an upward import, the dependency is probably in the wrong package.

`build.zig` is the authoritative module wiring.

## Layer model

| Layer | Packages |
| --- | --- |
| 0 | `kira_core`, `kira_source`, `kira_diagnostics`, `kira_log`, `kira_runtime_abi` |
| 1 | `kira_syntax_model`, `kira_lexer`, `kira_parser`, `kira_ksl_syntax_model`, `kira_ksl_parser` |
| 2 | `kira_semantics_model`, `kira_shader_model`, `kira_ksl_semantics`, `kira_semantics` |
| 3 | `kira_ir`, `kira_shader_ir`, `kira_hybrid_definition`, `kira_backend_api`, `kira_native_lib_definition` |
| 4 | `kira_glsl_backend`, `kira_bytecode`, `kira_vm_runtime`, `kira_native_bridge`, `kira_hybrid_runtime`, `kira_llvm_backend` |
| 5 | `kira_manifest`, `kira_project`, `kira_package_manager`, `kira_build_definition` |
| 6 | `kira_program_graph` |
| 7 | `kira_build` |
| 8 | `kira_linter`, `kira_doc`, `kira_app_generation` |
| 9 | `kira_cli` |
| 10 | `kira_main` |

## Source of truth

- `build.zig` package list and import wiring.
- `docs/architecture.md` for pipeline shape.
- `docs/package_graph.md` in the public docs is a shorter version; this memory adds the “what to touch” rules.

## Change routing

| Change type | Main packages |
| --- | --- |
| Lexer/token changes | `kira_lexer`, `kira_syntax_model` |
| Parser/AST changes | `kira_parser`, `kira_syntax_model` |
| Semantic analysis / HIR lowering | `kira_semantics`, `kira_semantics_model` |
| Shared executable IR | `kira_ir` |
| Bytecode or VM | `kira_bytecode`, `kira_vm_runtime` |
| LLVM/native emission | `kira_llvm_backend`, `kira_native_bridge` |
| Hybrid runtime | `kira_hybrid_runtime`, `kira_hybrid_definition`, `kira_runtime_abi`, `kira_native_bridge`, `kira_vm_runtime` |
| Native-library manifests / FFI | `kira_manifest`, `kira_native_lib_definition`, `kira_build`, `kira_llvm_backend` |
| Project discovery / package graph | `kira_project`, `kira_package_manager`, `kira_program_graph` |
| CLI UX | `kira_cli` |
| Install / fetch / build orchestration | `kira_build`, `kira_toolchain`, `build.zig` |
| Shader language pipeline | `kira_ksl_*`, `kira_shader_*`, `kira_glsl_backend` |

## Root export guidance

- Keep `root.zig` files small.
- Export stable surface types/functions only; do not turn roots into orchestrators.
- If a root is growing, move logic into package-local modules and leave `root.zig` as wiring.

## Do not add upward imports

- `kira_source` should stay foundational.
- `kira_runtime_abi` must remain tiny and shared.
- `kira_cli` should stay leaf-like and call into lower packages.
- `kira_main` is a C ABI facade, not compiler orchestration.
- `kira_build_definition` and `kira_backend_api` should remain backend-neutral.
