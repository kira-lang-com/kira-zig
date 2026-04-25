# Recent Context

Internal note on the recent `../kira-graphics` hybrid/native graphics issue.

## Failure symptom

Hybrid execution of `../kira-graphics/examples/basic_triangle` stopped at:

`[trace][BRIDGE][CALL] runtime->native fn=5 symbol=kira_native_fn_5 args=2`

Function id `5` mapped to `sokolRunApplication(app: GraphicsApplication, runtimeUserData: RawPtr)`.
`sokolRunApplication` then calls `sapp_run(desc)`.

## Root cause

The runtime-created `nativeState` exposed runtime-layout struct pointers to native callbacks while the native side expected native-layout values.

That meant the hybrid bridge handed the wrong layout to Sokol-facing callbacks.

## Fix shape

- touched `packages/kira_vm_runtime/src/vm.zig`
- touched `packages/kira_native_bridge/src/runtime_helpers.c`
- native callbacks now receive native-layout payloads
- runtime retains runtime payloads for recovery/sync

## Verification that passed

- `zig build`
- `zig build test`
- `../kira-graphics/examples/basic_triangle` progressed through the Sokol lifecycle and returned from fn=5
- LLVM still ran

## Current direction

- build broad memory first
- inventory oversized/risky files
- split by responsibility
- verify behavior after each scoped change
