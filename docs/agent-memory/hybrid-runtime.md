# Hybrid Runtime

Internal memory for the two-sided hybrid execution model.

## Rule of thumb

Hybrid behavior must be handled as **both**:

1. backend/native lowering and artifact generation, and
2. bridge/trampoline/runtime plumbing at run time.

Do not treat hybrid as “VM plus a little native glue.”

## Main files

- `packages/kira_hybrid_definition/src/module_manifest.zig`
- `packages/kira_hybrid_definition/src/bridge_descriptor.zig`
- `packages/kira_hybrid_definition/src/runtime_contracts.zig`
- `packages/kira_hybrid_definition/src/symbol_links.zig`
- `packages/kira_hybrid_runtime/src/runtime.zig`
- `packages/kira_hybrid_runtime/src/loader.zig`
- `packages/kira_hybrid_runtime/src/binder.zig`
- `packages/kira_native_bridge/src/bridge.zig`
- `packages/kira_native_bridge/src/trampoline.zig`
- `packages/kira_native_bridge/src/symbol_resolver.zig`
- `packages/kira_runtime_abi/src/bridge_value.zig`
- `packages/kira_runtime_abi/src/calling.zig`
- `packages/kira_vm_runtime/src/vm.zig`

## Artifact / manifest flow

- `kira_build` writes a hybrid manifest (`.khm`).
- The manifest records bytecode path, native library path, entry function, execution mode, and per-function manifests.
- `kira_hybrid_runtime.loadHybridModule()` reads the manifest.
- `HybridRuntime.init()` loads bytecode, binds native symbols, and installs the runtime invoker.

## Call flow

- runtime→native calls go through `kira_native_bridge.NativeBridge.call()` and a trampoline resolved from the shared library.
- native→runtime calls go through the installed runtime invoker exported by the native bridge.
- `runtime_abi.emitExecutionTrace()` is the standard trace channel.

## Struct / payload marshalling

Current hybrid handling is two-layout:

- runtime-owned payloads stay in runtime layout for VM recovery/sync,
- native callbacks receive native-layout payloads when crossing the boundary.

This matters for `@FFI.Struct` and hybrid callback/state flows.

The recent `../kira-graphics` basic-triangle bug came from exposing runtime-layout struct pointers to native callbacks when the native side expected native-layout values.
The fix split the payloads so native code sees native layout while runtime retains recoverable runtime payloads.

## Callback / native-state flow

- `nativeState(...)` creates Kira-managed boxed callback state.
- `nativeUserData(...)` exports an opaque token.
- `nativeRecover<T>(...)` re-enters the boxed state.
- Hybrid callback paths must sync both directions around native calls.

## Trace/debug workflow

Use execution tracing when hybrid fails early:

- enable `--trace-execution` (or the repo’s equivalent trace toggle in the current command path)
- watch for `[trace][BRIDGE][CALL] runtime->native ...`
- identify whether failure is in manifest binding, trampoline resolution, native→runtime callback, or struct marshalling

## When touching hybrid code, check

- `tests/pass/run/hybrid_roundtrip`
- `tests/pass/run/native_runtime_struct_bridge`
- `tests/pass/run/runtime_native_struct_bridge`
- `tests/pass/run/native_runtime_struct_callback_bridge`
- `tests/pass/run/ffi_sokol_triangle_native`
- `examples/sokol_triangle/`
