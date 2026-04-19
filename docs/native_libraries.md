# Native Libraries

Kira's first real FFI system is intentionally strict:

- C ABI only
- static linking first
- per-library TOML manifests
- Clang-driven autobinding generation
- generated bindings emitted as real Kira source files
- direct LLVM/native extern calls with no public wrapper layer
- hybrid runtime/native argument and result marshalling
- explicit native callback support

This pass does not implement dynamic linking, libffi, a stable Kira ABI, non-C ABIs, variadics, or captured closures across the boundary.

## Package Split

Native library work is intentionally split across packages:

- `kira_native_lib_definition` defines manifest and resolved-library contracts
- `kira_manifest` parses the native library TOML shape
- `kira_build` discovers manifests near source files, builds static archives when needed, and runs autobinding generation
- `kira_backend_api` carries resolved native libraries into the backend
- `kira_llvm_backend` emits direct extern declarations/calls and hybrid bridge wrappers
- `kira_native_bridge` and `kira_hybrid_runtime` marshal arguments and results across the runtime/native boundary

## Manifest Shape

Projects list native-library manifests explicitly in `project.toml`, and each native library keeps its own detail in a dedicated TOML file.

```toml
[project]
name = "sokol_triangle"
version = "0.1.0"
native_libraries = ["NativeLibs/sokol.toml"]
```

Per-library detail then lives in the referenced manifest:

```toml
[library]
name = "sokol"
link_mode = "static"
abi = "c"

[headers]
entrypoint = "../../third_party/sokol/sokol_bindings.h"
include_dirs = ["../../third_party/sokol"]
defines = ["SOKOL_NO_ENTRY", "SOKOL_GLCORE"]

[autobinding]
module = "sokol"
output = "../sokol.kira"
headers = ["../../third_party/sokol/sokol_app.h", "../../third_party/sokol/sokol_gfx.h", "../../third_party/sokol/sokol_glue.h"]

[bindings]
mode = "all_public"

[build]
sources = ["../../third_party/sokol/sokol_impl.m"]
include_dirs = ["../../third_party/sokol"]

[target.aarch64-macos-none]
static_lib = "../generated/native/aarch64-macos/libsokol.a"
frameworks = ["AppKit", "QuartzCore", "OpenGL"]
```

Important rules:

- `project.toml` explicitly lists every native-library manifest used by the project
- one TOML per native library
- the library TOML owns header paths, autobinding inputs, binding filters, and target artifacts
- Kira source does not hardcode binary paths
- `.bind.toml` sidecar files are no longer used

## Autobindings

Clang parses the configured headers and the autobinder emits real Kira modules.

Generated output uses annotation-based declarations such as:

```kira
@FFI.Callback { abi: c; params: [I64, RawPtr]; result: I64; }
struct kira_i64_callback {}

@FFI.Extern { library: callbacks; symbol: kira_invoke_callback; abi: c; }
function kira_invoke_callback(callback: kira_i64_callback, user_data: RawPtr, value: I64): I64;
```

Current generated type shapes:

- `@FFI.Extern` for native functions
- `@FFI.Callback` for function-pointer typedefs
- `@FFI.Pointer` for opaque/native pointer aliases
- `@FFI.Alias` for public typedefs and enum carrier types
- `@FFI.Array` for fixed-size array typedefs synthesized from public headers
- `@FFI.Struct` for C-layout structs

The emitted files are normal Kira source, so imports, linting, navigation, and diagnostics see them as ordinary modules.

## Callbacks

Callbacks are explicit in this first version:

- callback typedefs lower to real native function pointers
- native/external functions can accept callback parameters directly
- callback targets must currently resolve to `@Native` or extern functions
- `void*`/context parameters are passed explicitly as `RawPtr`
- no captured-closure magic crosses the ABI boundary

The callback proof path lives in:

- [tests/pass/run/ffi_callback_native/main.kira](/Users/priamc/Coding/kira-projects/kira-zig/tests/pass/run/ffi_callback_native/main.kira)
- [tests/pass/run/ffi_callback_hybrid/main.kira](/Users/priamc/Coding/kira-projects/kira-zig/tests/pass/run/ffi_callback_hybrid/main.kira)

## Hybrid Support

Hybrid mode now uses a real bridge value ABI for boundary calls:

- runtime-to-native calls marshal arguments into bridge values
- native-to-runtime calls marshal arguments and results back through the installed runtime invoker
- native Kira functions compile as typed internal implementations plus exported bridge wrappers
- imported extern functions are not exposed as bridge entrypoints

The current bridge value set matches the executable subset:

- `void`
- integer
- string
- boolean
- raw pointer

## Proof Target

The real proof target for this pass is a full generated Sokol binding and a native triangle app:

- real upstream headers:
  - [third_party/sokol/sokol_app.h](/Users/priamc/Coding/kira-projects/kira-zig/third_party/sokol/sokol_app.h)
  - [third_party/sokol/sokol_gfx.h](/Users/priamc/Coding/kira-projects/kira-zig/third_party/sokol/sokol_gfx.h)
  - [third_party/sokol/sokol_glue.h](/Users/priamc/Coding/kira-projects/kira-zig/third_party/sokol/sokol_glue.h)
- a normal upstream-style implementation TU:
  - [third_party/sokol/sokol_impl.m](/Users/priamc/Coding/kira-projects/kira-zig/third_party/sokol/sokol_impl.m)
- manifest-driven binding generation and static library build:
  - [examples/sokol_triangle/NativeLibs/sokol.toml](/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_triangle/NativeLibs/sokol.toml)
- generated Kira module emitted directly from the public headers:
  - [examples/sokol_triangle/sokol.kira](/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_triangle/sokol.kira)
- fully Kira-written app logic using the generated bindings directly:
  - [examples/sokol_triangle/app/main.kira](/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_triangle/app/main.kira)
  - [examples/sokol_runtime_entry/app/main.kira](/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_runtime_entry/app/main.kira)
- runnable native proof case:
  - [tests/pass/run/ffi_sokol_triangle_native/main.kira](/Users/priamc/Coding/kira-projects/kira-zig/tests/pass/run/ffi_sokol_triangle_native/main.kira)

To regenerate the bindings without launching the app, run:

```bash
kira check examples/sokol_triangle
```

To build and launch the native triangle proof, run:

```bash
kira run --backend llvm examples/sokol_triangle
```
