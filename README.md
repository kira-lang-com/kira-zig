# Kira Zig Toolchain Bootstrap

This monorepo bootstraps the Zig side of Kira’s compiler, bytecode pipeline, VM runtime, build orchestration, CLI, runtime ABI, hybrid/native contracts, and `KiraMain` C facade.

The VM path is real today:

- source -> lexer -> parser -> semantics -> IR -> bytecode -> VM
- `print(...)` works for integers and strings
- `kira` CLI commands build from the repo root
- `KiraMain` can load and run bytecode modules

Everything outside that path is present as a real package with typed APIs and explicit `NotImplemented` behavior where the implementation is intentionally deferred.

## Quick Start

```bash
zig build
zig build test
zig build run -- run examples/hello.kira
zig build run -- tokens examples/hello.kira
zig build run -- ast examples/hello.kira
zig build run -- check examples/hello.kira
zig build run -- build examples/hello.kira
zig build run -- new DemoApp generated/DemoApp
```

## Architecture

- `packages/kira_core` stays tiny and universal
- syntax and semantics are isolated from runtime/build/tooling packages
- `kira_ir` is the backend-facing shared IR
- `kira_bytecode` and `kira_vm_runtime` provide the working execution path
- native/hybrid/LLVM packages compile cleanly but return explicit not-implemented errors
- native library manifests live outside the root `Kira.toml`

See [docs/architecture.md](docs/architecture.md), [docs/package_graph.md](docs/package_graph.md), [docs/commands.md](docs/commands.md), and [docs/native_libraries.md](docs/native_libraries.md).
