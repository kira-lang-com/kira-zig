# Native FFI

Internal memory for the repository’s C-ABI FFI path.

## Model

Current FFI is:

- C ABI only
- static-linking first
- per-library TOML manifests
- Clang-driven autobinding generation
- generated bindings emitted as real Kira source
- direct extern calls (no wrapper API layer)
- explicit native callback support

## Manifest flow

Packages/files:

- `packages/kira_manifest/src/parser.zig` — parses project/package/native-lib manifests.
- `packages/kira_native_lib_definition/src/native_library.zig` — manifest shapes.
- `packages/kira_native_lib_definition/src/target_resolution.zig` — target selection and resolution.
- `packages/kira_build/src/native_lib_resolver.zig` — resolves relative manifest paths.

Manifest pattern:

```toml
[project]
native_libraries = ["NativeLibs/sokol.toml"]
```

Per-library TOML owns:

- `library` metadata
- `headers` / include paths / defines
- `autobinding` inputs and generated module path
- `build` recipe
- per-target static or dynamic artifact paths and link extras

## Generated bindings

Autobinding emits Kira source with annotations such as:

- `@FFI.Extern`
- `@FFI.Callback`
- `@FFI.Pointer`
- `@FFI.Alias`
- `@FFI.Array`
- `@FFI.Struct`

Generated source lives under normal Kira modules, so it participates in imports and diagnostics like hand-written code.

## Struct rules

- `@FFI.Struct { layout: c; }` is C-layout, zero-filled on explicit construction.
- `sapp_desc { ... }` and `sapp_desc()` both start from zeroed storage for omitted fields.
- This is a construction rule only; typed declaration still leaves locals uninitialized.

## Native callback state

Three important helpers:

- `nativeState(value)` — box and copy Kira-owned state.
- `nativeUserData(state)` — export opaque userdata token.
- `nativeRecover<T>(token)` — recover typed mutable access.

Use this for native APIs that store and later hand back `void*` userdata.

## Constraints

- no dynamic-linking-first story
- no non-C ABIs
- no variadics
- no captured-closure magic across the C ABI boundary
- direct FFI callback targets should resolve to `@Native` or extern functions

## Cross-reference

Hybrid runtime uses the same bridge-value model and state marshalling, so update `docs/agent-memory/hybrid-runtime.md` together with FFI changes.

## Representative files/tests/examples

- `examples/sokol_triangle/`
- `examples/sokol_runtime_entry/`
- `tests/pass/run/ffi_struct_zero_init`
- `tests/pass/run/ffi_sokol_triangle_native`
- `tests/pass/run/native_runtime_struct_callback_bridge`
- `tests/fail/semantics/direct_ffi_requires_native`
