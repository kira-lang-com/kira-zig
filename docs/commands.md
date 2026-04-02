# Commands

Root commands:

- `zig build`
- `zig build test`
- `zig build run -- run examples/hello.kira`
- `zig build run -- run --backend llvm examples/hello.kira`
- `zig build run -- run --backend hybrid examples/hybrid_roundtrip.kira`
- `zig build run -- tokens examples/hello.kira`
- `zig build run -- ast examples/hello.kira`
- `zig build run -- check examples/hello.kira`
- `zig build run -- build examples/hello.kira`
- `zig build run -- build --backend llvm examples/hello.kira`
- `zig build run -- build --backend hybrid examples/hybrid_roundtrip.kira`
- `zig build run -- new DemoApp generated/DemoApp`

CLI behavior:

- `run` defaults to the VM backend; `run --backend llvm` builds and runs a native executable
- `run --backend hybrid` builds a hybrid manifest, bytecode sidecar, and native shared library, then runs the mixed program in the hybrid host
- `tokens` dumps lexer output
- `ast` dumps the parsed AST
- `check` runs parse and semantics
- `build` defaults to writing a `.kbc` bytecode artifact into `generated/`
- `build --backend llvm` writes both a native object file and a native executable into `generated/`
- `build --backend hybrid` writes a `.khm` hybrid manifest plus the bytecode, native object, and native shared library sidecars into `generated/`
- `new` copies the app template into a new destination with `@Main function main() { ... }` in `src/main.kira`

LLVM backend selection is explicit and host-native. If LLVM is not already installed under the repo-managed path, set `KIRA_LLVM_HOME` before calling the LLVM backend commands.
