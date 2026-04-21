# Examples

Each example now lives in its own folder with a root `project.toml`, an `app/main.kira` entrypoint, and any local support files or `NativeLibs/` manifests it needs.

Current language-facing examples now prefer:

- canonical `struct` and `class` declarations
- brace-style named struct literals such as `Rect { width: 10.0 }`
- struct methods for value types

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
- `shaders/`: real `.ksl` shader examples that compile through the dedicated KSL frontend to GLSL 330 plus reflection JSON via `kira shader build`

Useful commands:

```bash
kira run examples/hello
kira run --backend llvm examples/callbacks
kira run --backend hybrid examples/sokol_triangle
kira check examples/sokol_runtime_entry
kira shader check examples/shaders/textured_quad.ksl
kira shader build examples/shaders/lit_surface.ksl
kira shader build
```

The `callbacks/` example now demonstrates Kira-owned persistent callback state with:

- `nativeState(...)` to box ordinary Kira state
- `nativeUserData(...)` to hand an opaque token to native code
- `nativeRecover<T>(...)` inside the callback to mutate the original state across repeated invocations
