# Examples

Each example now lives in its own folder with a `main.kira` entrypoint and any local support files or `native_libs/` manifests it needs.

Backend matrix:

- `hello/main.kira`: `vm`, `llvm`, `hybrid`
- `arithmetic/main.kira`: `vm`, `llvm`, `hybrid`
- `imports_demo/main.kira`: `vm`, `llvm`, `hybrid`
- `report_pipeline/main.kira`: `vm`, `llvm`, `hybrid`
- `geometry_story/main.kira`: `vm`, `llvm`, `hybrid`
- `status_board/main.kira`: `vm`, `llvm`, `hybrid`
- `callbacks/main.kira`: `llvm`, `hybrid`
- `callbacks_chain/main.kira`: `llvm`, `hybrid`
- `sokol_triangle/main.kira`: `llvm`, `hybrid`
- `sokol_runtime_entry/main.kira`: `llvm`, `hybrid`

Extra folderized examples:

- `hybrid_roundtrip/main.kira`: hybrid-only roundtrip demo
- `complex_language_showcase/main.kira`: frontend-focused showcase
- `ui_library/main.kira`: frontend-focused library sample

Useful commands:

```bash
kira-bootstrapper run examples/hello/main.kira
kira-bootstrapper run --backend llvm examples/callbacks/main.kira
kira-bootstrapper run --backend hybrid examples/sokol_triangle/main.kira
kira-bootstrapper check examples/sokol_runtime_entry/main.kira
```
