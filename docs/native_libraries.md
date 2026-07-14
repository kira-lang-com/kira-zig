# Native Libraries

Kira's first real FFI system is intentionally strict:

- C ABI only
- static linking first
- native libraries declared inline in `package.kira` (legacy per-library TOML manifests still load for unmigrated projects)
- Clang-driven autobinding generation
- generated bindings emitted as real Kira source files
- direct LLVM/native extern calls with no public wrapper layer
- hybrid runtime/native argument and result marshalling
- explicit native callback support
- VM-side dynamic linking and direct FFI through LibFFI (no LLVM required)

The native-compiling backends (LLVM and hybrid) still require an `@Native`
boundary for direct FFI. The VM additionally executes direct FFI itself by
loading the named library at runtime and marshalling the call through LibFFI;
see [VM Dynamic FFI through LibFFI](#vm-dynamic-ffi-through-libffi). This pass
does not implement a stable Kira ABI, non-C ABIs, variadics, by-value
aggregate arguments through the VM LibFFI path, or captured closures across the
boundary.

## Package Split

Native library work is intentionally split across packages:

- `kira_native_lib_definition` defines manifest and resolved-library contracts
- `kira_manifest` parses inline `NativeLibrary` declarations in `package.kira` (and the legacy per-library TOML shape for unmigrated projects)
- `kira_build` discovers manifests near source files, builds static or shared archives when needed, and runs autobinding generation
- `kira_backend_api` carries resolved native libraries into the backend
- `kira_llvm_backend` emits direct extern declarations/calls and hybrid bridge wrappers
- `kira_native_bridge` and `kira_hybrid_runtime` marshal arguments and results across the runtime/native boundary

## Manifest Shape

Native libraries are declared inline in `package.kira` under `nativeLibraries` —
see [docs/package-manifest.md](package-manifest.md) for the full manifest
format and schema. (Legacy `project.toml`/`kira.toml` projects instead list
each library's manifest path via `native_libraries = ["NativeLibs/*.toml"]`,
with per-library detail in a dedicated TOML file; that format still loads for
unmigrated packages.)

[examples/sokol_triangle/package.kira](../examples/sokol_triangle/package.kira)
declares its native library this way:

```kira
Package sokol_triangle {
    let version = "0.1.0"
    let kira = "0.1.0"
    let kind = PackageKind.App
    let defaults = Defaults { executionMode: Backend.Llvm, buildTarget: BuildTarget.Host }
    let nativeLibraries = [
        NativeLibrary {
            name: "sokol",
            linkMode: LinkMode.Static,
            headers: Headers {
                entrypoint: "../../third_party/sokol/sokol_bindings.h",
                includeDirs: ["../../third_party/sokol"],
                defines: ["SOKOL_NO_ENTRY", "SOKOL_GLCORE"]
            },
            sources: ["../../third_party/sokol/sokol_impl.m"],
            autobind: Autobind {
                module: "sokol",
                headers: ["../../third_party/sokol/sokol_app.h", "../../third_party/sokol/sokol_gfx.h", "../../third_party/sokol/sokol_glue.h"],
                mode: AutobindMode.AllPublic
            },
            nativeTargets: [
                NativeTarget { triple: "aarch64-macos-none", frameworks: ["AppKit", "QuartzCore", "OpenGL"] },
                NativeTarget { triple: "x86_64-linux-gnu", systemLibs: ["X11", "Xi", "Xcursor", "GL", "dl", "pthread", "m"] },
                NativeTarget { triple: "x86_64-windows-msvc" }
            ]
        }
    ]
}
```

Important rules:

- each `NativeLibrary { ... }` entry lives inline in `package.kira`'s `nativeLibraries` list — there is no separate per-library manifest file
- one `NativeLibrary` entry per native library
- the entry owns header paths, autobinding inputs, binding filters, and per-target settings (`nativeTargets`)
- Kira source does not hardcode binary paths — libraries are compiled from source into `.kira-build/native/<arch>-<os>-<abi>/lib<name>.a` (or the shared-object equivalent for `LinkMode.Dynamic`)
- generated bindings always land at `app/bindings/<module>.kira` (the autobind output law; see docs/package-manifest.md)
- `.bind.toml` sidecar files are no longer used

## Per-Target Compiler and Linker Flags

Each `NativeTarget { triple: "..." }` entry may carry extra flags that are
threaded through the native toolchain for that target only:

```kira
NativeTarget {
    triple: "wasm32-emscripten-unknown",
    compilerFlags: ["--use-port=emdawnwebgpu"],
    linkerFlags: ["--use-port=emdawnwebgpu", "-sASYNCIFY"]
}
```

- `compilerFlags` are appended to every source-compile command for this
  library on this target (e.g. Emscripten ports, `-fno-exceptions`).
- `linkerFlags` are appended verbatim to the final program/library link.

Both are generic across every backend, not just Emscripten.

## WebAssembly / Emscripten Targets

Declare a `NativeTarget { triple: "wasm32-emscripten-unknown" }` entry
(architecture `wasm32`, OS `emscripten`, ABI `unknown`) to make a native
library available under `kira build --target wasm32-emscripten`. Its sources
compile with `emcc` (no `-target` flag — `emcc` implies `wasm32-emscripten`)
and archive with `emar`, both discovered next to the active `emcc` (or on
`PATH`). C++ translation units dispatch to `em++` by file extension.

A library that omits a matching wasm target still reports diagnostic `KTC003`
("unsupported native library target") for a wasm build, so Web/WASM support is
opt-in per library and never silently skipped.

## Autobindings

Clang parses the configured headers and the autobinder emits real Kira modules.

Generated output uses annotation-based declarations such as:

```kira
@FFI.Callback { abi: c; params: [I64, RawPtr]; result: I64; }
struct kira_i64_callback {}

@FFI.Extern { library: callbacks; symbol: kira_invoke_callback; abi: c; }
function kira_invoke_callback(callback: kira_i64_callback, user_data: RawPtr, value: I64): I64;
```

Current generated declaration shapes:

- `@FFI.Extern` for native functions
- `@FFI.Callback` for function-pointer typedefs
- `@FFI.Pointer` for opaque/native pointer aliases
- `@FFI.Alias` for public typedefs and enum carrier types
- `@FFI.Array` for fixed-size array typedefs synthesized from public headers
- `@FFI.Struct` for C-layout structs

The emitted files are normal Kira source, so imports, linting, navigation, and diagnostics see them as ordinary modules.

## C-Layout Struct Construction

`@FFI.Struct { layout: c; }` uses construction-time zero fill for omitted fields:

```kira
let desc = sapp_desc {
    init_userdata_cb: init
    frame_userdata_cb: frame
    cleanup_userdata_cb: cleanup
    user_data: state
    width: 640
    height: 480
    window_title: "Kira Sokol Triangle"
}
```

The same rule applies to `sapp_desc()`: Kira constructs a zeroed C-layout value first, then applies explicit field initializers. This does not change declaration semantics. `var desc: sapp_desc` is still just an uninitialized local declaration.

## Callbacks

Callbacks are explicit in this first version:

- callback typedefs lower to real native function pointers
- native/external functions can accept callback parameters directly
- direct FFI callback targets must currently resolve to `@Native` or extern functions
- `void*`/context parameters are passed explicitly as `RawPtr`
- no captured-closure magic crosses the ABI boundary

## Opaque Native Callback State

Kira now has a first-class opaque callback-state model for native APIs that carry `void*` userdata:

```kira
struct CounterState {
    var count: Int
    var total: Int
}

var state = nativeState(CounterState {
    count: 0
    total: 0
})

var token = nativeUserData(state)

@Native
function onValue(value: I64, user_data: RawPtr) -> I64 {
    var state = nativeRecover<CounterState>(user_data)
    state.count = state.count + 1
    state.total = state.total + value
    return value + state.count
}
```

The important distinction is:

- `nativeState(...)` boxes and copies a Kira-owned value into stable callback-state storage
- `nativeUserData(...)` exports the opaque userdata token that native code can carry and hand back later
- `nativeRecover<T>(...)` re-enters that boxed storage as typed mutable Kira access
- `nativeStateFree(...)` releases the boxed storage when the native API no longer holds the token; outstanding `nativeRecover` views become invalid
- this is not a C-layout promise for ordinary Kira structs
- this is not a general-purpose raw-pointer reinterpret cast
- this avoids forcing globals for callback-oriented native APIs

Current lifetime model:

- native callback state lives in Kira-managed heap storage
- the boxed state currently survives for the lifetime of the process
- multiple `nativeUserData(state)` calls on the same handle return the same opaque token
- recovery returns mutable access to the original stored state, not a copy

`@FFI.Struct { layout: c; }` remains a separate feature:

- use `@FFI.Struct { layout: c; }` when native code must read or write the struct fields directly by C layout
- use `nativeState` / `nativeUserData` / `nativeRecover<T>` when native code should only store and return an opaque token

The callback proof paths now live in:

- [tests/pass/run/ffi_callback_native/main.kira](../tests/pass/run/ffi_callback_native/main.kira)
- [tests/pass/run/ffi_callback_hybrid/main.kira](../tests/pass/run/ffi_callback_hybrid/main.kira)
- [tests/pass/run/ffi_callback_state_parity/main.kira](../tests/pass/run/ffi_callback_state_parity/main.kira)

## Hybrid Support

Hybrid mode now uses a real bridge value ABI for boundary calls:

- runtime-to-native calls marshal arguments into bridge values
- native-to-runtime calls marshal arguments and results back through the installed runtime invoker
- native Kira functions compile as typed internal implementations plus exported bridge wrappers
- imported extern functions are not exposed as bridge entrypoints

That bridge is the normal execution boundary, not a usability quarantine:

- direct FFI usage on the native-compiling backends (LLVM, hybrid) still requires `@Native` (diagnostic `KSEM093`)
- the VM lifts that requirement and executes direct FFI through LibFFI (see below)
- indirect use remains allowed
- `@Runtime` code can call `@Native` Kira helpers, construct and mutate native-annotated values, and pass them through hybrid honestly
- `@Native` code can call back into `@Runtime` helpers the same way

The current bridge value set covers the ordinary executable surface used by mixed runtime/native code:

- `void`
- integer
- float
- string
- boolean
- raw pointer

## VM Dynamic FFI through LibFFI

The VM can call dynamically linked native functions directly, without LLVM
native compilation. This makes `kira run` (the pure VM) a real FFI host: an
`@FFI.Extern` function can be called from ordinary runtime code, and the VM
loads the library and marshals the call through LibFFI at runtime.

How it works:

- The bytecode compiler emits each `@FFI.Extern` declaration as a metadata-only
  stub that carries the library name, symbol, calling convention, declared
  parameter types, and return type (KBC5 container format).
- For the VM target, semantics lifts the `KSEM093` `@Native` requirement
  (`AnalysisOptions.allow_runtime_direct_ffi`); the native-compiling backends
  keep it.
- At a `call_native` instruction the interpreter routes through the LibFFI
  dispatcher (`packages/kira_vm_runtime/src/vm_ffi.zig`), which opens (and
  caches) the named library, resolves the symbol, builds a LibFFI signature from
  the declared FFI primitive types, marshals the arguments, invokes the
  function, and lifts the result.
- The dispatcher loads the LibFFI runtime from the managed toolchain
  (`~/.kira/toolchains/libffi/...`, installed with `zig build fetch-libffi`).

Library resolution mirrors the rest of the native-library system. A library
built or shipped as a shared object is declared with `linkMode:
LinkMode.Dynamic`; the build compiles a dynamic library from `sources` just
like a static archive:

```kira
NativeLibrary {
    name: "ffimath",
    linkMode: LinkMode.Dynamic,
    sources: ["ffimath.c"],
    nativeTargets: [
        NativeTarget { triple: "x86_64-windows-msvc" }
    ]
}
```

Supported VM LibFFI types are the scalar primitives (`I8`…`I64`, `U8`…`U64`,
`Bool`, `F32`, `F64`), `RawPtr`, and `CString` (marshalled as a borrowed
NUL-terminated copy for the duration of the call). By-value aggregates,
callbacks, and non-C calling conventions are rejected rather than mis-marshalled.

The runnable proof case is:

- [tests/pass/run/ffi_dynamic_vm/app/main.kira](../tests/pass/run/ffi_dynamic_vm/app/main.kira)

```bash
kira run --backend vm tests/pass/run/ffi_dynamic_vm
```

## Proof Target

The real proof target for this pass is a full generated Sokol binding and a native triangle app:

- real upstream headers:
  - [third_party/sokol/sokol_app.h](../third_party/sokol/sokol_app.h)
  - [third_party/sokol/sokol_gfx.h](../third_party/sokol/sokol_gfx.h)
  - [third_party/sokol/sokol_glue.h](../third_party/sokol/sokol_glue.h)
- a normal upstream-style implementation TU:
  - [third_party/sokol/sokol_impl.m](../third_party/sokol/sokol_impl.m)
- manifest-driven binding generation and static library build:
  - [examples/sokol_triangle/package.kira](../examples/sokol_triangle/package.kira)
- generated Kira module emitted directly from the public headers (lands at
  `examples/sokol_triangle/app/bindings/sokol.kira` per the autobind output
  law; regenerated on every `kira check`/`kira build`/`kira run`, not
  committed, so there is no file to link here)
- fully Kira-written app logic using the generated bindings directly:
  - [examples/sokol_triangle/app/main.kira](../examples/sokol_triangle/app/main.kira)
  - [examples/sokol_runtime_entry/app/main.kira](../examples/sokol_runtime_entry/app/main.kira)
- runnable native proof case:
  - [tests/pass/run/ffi_sokol_triangle_native/main.kira](../tests/pass/run/ffi_sokol_triangle_native/main.kira)

To regenerate the bindings without launching the app, run:

```bash
kira check examples/sokol_triangle
```

To build and launch the native triangle proof, run:

```bash
kira run --backend llvm examples/sokol_triangle
```
