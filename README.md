# Kira Zig Toolchain Bootstrap

This monorepo now carries a real dual-backend Kira pipeline in Zig: frontend lowering, shared IR, VM bytecode execution, LLVM-native code generation, native runtime helpers, build orchestration, CLI, runtime ABI, hybrid/native contracts, and the `KiraMain` C facade.

The working execution paths today are:

- source -> lexer -> parser -> semantics -> IR -> bytecode -> VM
- source -> lexer -> parser -> semantics -> IR -> LLVM IR -> object file -> native executable
- source -> lexer -> parser -> semantics -> IR -> bytecode plus native shared library -> hybrid runtime host
- `print(...)` works for integers and strings
- `kira` CLI commands build from the repo root
- `KiraMain` can load and run bytecode modules

The native path currently supports the same bootstrap subset as the VM path:

- `@Main`
- `@Runtime`
- `@Native`
- `function`
- integer literals
- string literals
- local `let`
- identifier loads
- integer `+`
- builtin `print`
- simple zero-argument function calls
- `return`
- block statements

## Quick Start

```bash
zig build
zig build test
zig build run -- run examples/hello.kira
zig build run -- run --backend llvm examples/hello.kira
zig build run -- run --backend hybrid examples/hybrid_roundtrip.kira
zig build run -- tokens examples/hello.kira
zig build run -- ast examples/hello.kira
zig build run -- check examples/hello.kira
zig build run -- build examples/hello.kira
zig build run -- build --backend llvm examples/hello.kira
zig build run -- build --backend hybrid examples/hybrid_roundtrip.kira
zig build run -- new DemoApp generated/DemoApp
```

If LLVM is not installed in a repo-managed location, point Kira at it explicitly before using the native backend:

```powershell
$env:KIRA_LLVM_HOME = "C:\path\to\llvm"
zig build run -- run --backend llvm examples/hello.kira
```

## Bootstrap Syntax

The working bootstrap syntax uses `function` declarations and an explicit `@Main` entrypoint annotation:

```kira
@Main
function main() {
    let x = 1 + 2;
    print(x);
    print("hello from kira");
    return;
}
```

## Architecture

- `packages/kira_core` stays tiny and universal
- syntax and semantics are isolated from runtime/build/tooling packages
- `kira_ir` is the backend-facing shared IR
- `kira_bytecode` and `kira_vm_runtime` provide the VM execution path
- `kira_llvm_backend` lowers shared IR through LLVM C API and emits native objects/executables
- `kira_native_bridge` owns the native runtime helper surface used by LLVM lowering
- `kira_hybrid_runtime` hosts mixed bytecode/native programs and routes boundary calls through explicit bridge/trampoline logic
- hybrid contracts remain layered and future-facing without forcing the repo back into VM-only assumptions
- native library manifests live outside the root `Kira.toml`

See [docs/architecture.md](docs/architecture.md), [docs/package_graph.md](docs/package_graph.md), [docs/commands.md](docs/commands.md), and [docs/native_libraries.md](docs/native_libraries.md).
