# Kira Zig Toolchain Bootstrap

This monorepo now carries a real dual-backend Kira pipeline in Zig: frontend lowering, shared IR, VM bytecode execution, LLVM-native code generation, native runtime helpers, build orchestration, CLI, runtime ABI, hybrid/native contracts, and the `KiraMain` C facade.

The working execution paths today are:

- source -> lexer -> parser -> semantics -> IR -> bytecode -> VM
- source -> lexer -> parser -> semantics -> IR -> LLVM IR -> object file -> native executable
- source -> lexer -> parser -> semantics -> IR -> bytecode plus native shared library -> hybrid runtime host
- `print(...)` works for integers and strings
- `kira-bootstrapper` launches the active managed Kira toolchain
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
zig build install
kira-bootstrapper --help
kira-bootstrapper fetch-llvm
kira-bootstrapper run examples/hello.kira
kira-bootstrapper run --backend llvm examples/hello.kira
kira-bootstrapper run --backend hybrid examples/hybrid_roundtrip.kira
kira-bootstrapper tokens examples/hello.kira
kira-bootstrapper ast examples/hello.kira
kira-bootstrapper check examples/hello.kira
kira-bootstrapper build examples/hello.kira
kira-bootstrapper build --backend llvm examples/hello.kira
kira-bootstrapper build --backend hybrid examples/hybrid_roundtrip.kira
kira-bootstrapper new DemoApp generated/DemoApp
zig build test
```

`zig build install` and `zig build install-kirac` now do two things:

- install the PATH-facing launcher into `zig-out/bin/kira-bootstrapper` by default
- install the real active Kira toolchain into `~/.kira/toolchains/<channel>/<version>/`

The managed toolchain layout is:

```text
~/.kira/toolchains/<channel>/<version>/
  bin/
    kirac[.exe]
  templates/
  llvm-metadata.toml

~/.kira/toolchains/current.toml
~/.kira/toolchains/llvm/<llvm-version>/<host-key>/
```

On Windows, you can run the launcher directly as `.\zig-out\bin\kira-bootstrapper.exe`, or add `zig-out\bin` to `PATH`:

```powershell
$env:Path = "$PWD\zig-out\bin;$env:Path"
```

If you want a different install location, use Zig's prefix flag, for example `zig build install -p .local`, then add `.local\bin` to `PATH`.

For development:

- `zig build kirac` builds the real managed CLI binary
- `zig build kira-bootstrapper` builds the forwarding launcher
- `zig build install-kirac` installs the active toolchain and launcher together

Install the pinned LLVM bundle with `kira-bootstrapper fetch-llvm` before using the LLVM backend. `zig build fetch-llvm` remains available as the build-step convenience path. Kira reads `llvm-metadata.toml`, resolves the current host bundle from the published GitHub release assets, and installs it into `~/.kira/toolchains/llvm/<llvm-version>/<host>/`.

LLVM discovery order is:

1. `KIRA_LLVM_HOME`
2. Kira-managed install from `llvm-metadata.toml`
3. older repo-managed fallback paths, if present

If you need to override the managed install, point Kira at a different LLVM tree explicitly:

```powershell
$env:KIRA_LLVM_HOME = "C:\path\to\llvm"
kira-bootstrapper run --backend llvm examples/hello.kira
```

The pinned LLVM download flow intentionally does not use checksum verification. The release tag, asset name, host mapping, and install marker are the source of truth for reuse.

## Development Flow

The standalone binary is now the normal path:

```bash
kira-bootstrapper run examples/hello.kira
kira-bootstrapper build examples/hello.kira
kira-bootstrapper check examples/hello.kira
```

`zig build run -- ...` is still useful when iterating on the CLI itself because it rebuilds and runs in one step:

```bash
zig build run -- run examples/hello.kira
zig build run -- build --backend llvm examples/hello.kira
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
