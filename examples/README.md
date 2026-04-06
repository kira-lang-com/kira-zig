# Examples

Each example now lives in its own folder with a root `project.toml`, an `app/main.kira` entrypoint, and any local support files or `native_libs/` manifests it needs.

Backend matrix:

- `hello/`: `vm`, `llvm`, `hybrid`
- `arithmetic/`: `vm`, `llvm`, `hybrid`
- `imports_demo/`: `vm`, `llvm`, `hybrid`
- `report_pipeline/`: `vm`, `llvm`, `hybrid`
- `geometry_story/`: `vm`, `llvm`, `hybrid`
- `status_board/`: `vm`, `llvm`, `hybrid`
- `callbacks/`: `llvm`, `hybrid`
- `callbacks_chain/`: `llvm`, `hybrid`
- `sokol_triangle/`: `llvm`, `hybrid`
- `sokol_runtime_entry/`: `llvm`, `hybrid`

Extra folderized examples:

- `hybrid_roundtrip/`: hybrid-only roundtrip demo
- `complex_language_showcase/`: frontend-focused showcase
- `ui_library/`: frontend-focused library sample

Useful commands:

```bash
kira run examples/hello
kira run --backend llvm examples/callbacks
kira run --backend hybrid examples/sokol_triangle
kira check examples/sokol_runtime_entry
```
