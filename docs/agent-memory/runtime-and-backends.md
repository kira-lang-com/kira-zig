# Runtime and Backends

Internal orientation for VM, LLVM/native, and build artifact behavior.

## VM path

Files:

- `packages/kira_bytecode/src/instruction.zig`
- `packages/kira_bytecode/src/compiler.zig`
- `packages/kira_bytecode/src/bytecode.zig`
- `packages/kira_vm_runtime/src/vm.zig`
- `packages/kira_vm_runtime/src/builtins.zig`
- `packages/kira_vm_runtime/src/module_loader.zig`

Notes:

- Bytecode is serialized as `KBC0`.
- VM runtime executes bytecode modules and handles builtins like `print`.
- `vm.zig` owns locals/registers, control flow, closures, arrays, struct copies, and native-state handling.
- `vm.zig` was already over 1000 lines before the recent hybrid fix; treat it as a split candidate.

## LLVM/native path

Files:

- `packages/kira_llvm_backend/src/backend.zig`
- `packages/kira_llvm_backend/src/backend_text_ir_core.zig`
- `packages/kira_llvm_backend/src/backend_text_ir_calls.zig`
- `packages/kira_llvm_backend/src/backend_utils.zig`
- `packages/kira_llvm_backend/src/toolchain.zig`
- `packages/kira_llvm_backend/src/toolchain_layout.zig`
- `packages/kira_llvm_backend/src/runtime_symbols.zig`

Notes:

- Backend validates and lowers through a text-LLVM path, then emits object/native executable/shared library artifacts.
- Native helper symbols are kept stable; printing and runtime callbacks go through helper exports.
- `build.zig` wires LLVM include discovery and `KIRA_LLVM_HOME` support.

## Backend selection

Source of truth:

- `packages/kira_build/src/pipeline.zig`
- `packages/kira_build/src/build_system.zig`
- `packages/kira_backend_api/src/compile_request.zig`

Execution targets:

- `vm`
- `llvm_native`
- `hybrid`

Artifact shapes:

- `.kbc` bytecode
- native object (`.o`/`.obj`)
- native library (`.so`/`.dylib`/`.dll`)
- executable (`.exe` or no suffix on Unix)
- hybrid manifest (`.khm`)

## Parity expectations

- VM, LLVM/native, and hybrid share the ordinary executable surface where current lowering supports it.
- Parity corpus covers arithmetic, control flow, arrays, struct methods, inheritance, callbacks, and selected FFI/native-state behavior.
- If one backend changes behavior, inspect the others before landing.

## When touching backend code, check

- `tests/pass/run/*_parity/main.kira` and `expect.toml`
- `tests/fail/backend/*`
- `docs/runtime-and-backends.md` if behavior changes
- `docs/commands.md` if artifact/CLI behavior changes
