# Architecture

This bootstrap uses a strict layered package graph. Higher layers may depend on lower layers, and lower layers never depend upward.

The shared compiler pipeline is:

1. `kira_source` loads source text and spans
2. `kira_lexer` tokenizes
3. `kira_parser` builds AST
4. `kira_semantics` validates exactly one `@Main` function, resolves locals, and lowers to HIR
5. `kira_ir` lowers HIR into backend-facing IR
6. backend selection happens in `kira_build`

The VM backend path is:

1. `kira_bytecode` compiles shared IR into bytecode
2. `kira_vm_runtime` executes bytecode

The LLVM-native backend path is:

1. `kira_llvm_backend` discovers LLVM, loads the LLVM C API, lowers shared IR into LLVM IR, verifies it, and emits a real object file
2. `kira_native_bridge` provides the stable native helper symbols used by LLVM lowering for builtin printing
3. `kira_build` links the emitted object and helper object into a host-native executable through Zig's linker driver

The hybrid path is:

1. `@Runtime` functions compile to bytecode and stay under `kira_vm_runtime`
2. `@Native` functions compile to native code and are linked into a shared library
3. `kira_hybrid_runtime` loads both artifacts in one process
4. native-to-runtime calls go through an installed native bridge callback
5. runtime-to-native calls go through native trampolines resolved from the shared library

The current native and hybrid subset intentionally matches the current VM subset plus zero-argument calls: `@Main`, `@Runtime`, `@Native`, function declarations, integer and string literals, `let`, identifier loads, integer addition, builtin `print`, simple zero-argument calls, `return`, and block statements.

`kira_build_definition` and `kira_backend_api` stay backend-neutral. `kira_cli` stays a leaf command surface. `kira_main` remains the app-facing C ABI facade rather than becoming compiler glue.

Hybrid packages still remain separate, but the repo is no longer structurally VM-only. Shared IR, runtime ABI direction, and stable native helper calls keep future hybrid work additive instead of architectural repair work.

`kira_main` is intentionally separate from compiler packages. It is the app-facing C ABI facade that generated apps will link against.
