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

The `callbacks/`, `sokol_triangle/`, and `sokol_runtime_entry/` examples demonstrate Kira-owned persistent callback state with:

- `nativeState(...)` to box ordinary Kira state
- `nativeUserData(...)` to hand an opaque token to native code
- `nativeRecover<T>(...)` inside the callback to mutate the original state across repeated invocations

For Sokol examples, descriptor values such as `sapp_desc`, `sg_desc`, `sg_shader_desc`, `sg_pipeline_desc`, and `sg_pass` remain C-layout FFI structs because Sokol reads those fields directly. App callback state is ordinary Kira state boxed with `nativeState`; Sokol only carries the opaque `RawPtr` from `nativeUserData(state)` through `user_data` and never depends on the Kira state layout.

That split is the intended execution model for larger apps too:

- direct Sokol or C ABI edges stay `@Native`
- higher-level Kira logic can remain `@Runtime`
- runtime/native calls and value flow go through hybrid bridging rather than forcing transitive native contagion
