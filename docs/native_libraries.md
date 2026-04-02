# Native Libraries

Native library resolution is intentionally split across packages:

- `kira_native_lib_definition` defines library, symbol, target, and link metadata contracts
- `kira_manifest` parses native library TOML files into those contracts
- `kira_build` resolves the active target to a concrete artifact
- `kira_backend_api` can carry resolved native library metadata to bytecode, LLVM, or hybrid backends
- `kira_native_bridge` and `kira_hybrid_runtime` reserve the runtime-side integration points

The root `Kira.toml` stays small. Noisy per-platform details live in dedicated native manifests such as `examples/native_libs/glfw.toml`.

Example shape:

```toml
[library]
name = "glfw"
link_mode = "static"
abi = "c"

[headers]
include_dirs = ["include"]
defines = ["GLFW_INCLUDE_NONE"]

[target.x86_64-linux-gnu]
static_lib = "vendor/glfw/linux/x86_64/libglfw3.a"
```
