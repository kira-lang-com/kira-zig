# Commands

Standalone CLI:

- `zig build install`
- `zig build install-kirac`
- `kira-bootstrapper --help`
- `kira-bootstrapper --version`
- `kira-bootstrapper fetch-llvm`
- `kira-bootstrapper run examples/hello/main.kira`
- `kira-bootstrapper run --backend llvm examples/hello/main.kira`
- `kira-bootstrapper run --backend hybrid examples/hybrid_roundtrip/main.kira`
- `kira-bootstrapper tokens examples/hello/main.kira`
- `kira-bootstrapper ast examples/hello/main.kira`
- `kira-bootstrapper check examples/hello/main.kira`
- `kira-bootstrapper build examples/hello/main.kira`
- `kira-bootstrapper build --backend llvm examples/hello/main.kira`
- `kira-bootstrapper build --backend hybrid examples/hybrid_roundtrip/main.kira`
- `kira-bootstrapper new DemoApp generated/DemoApp`

Build-system convenience:

- `zig build`
- `zig build kirac`
- `zig build kira-bootstrapper`
- `zig build test`
- `zig build fetch-llvm`
- `zig build run -- run examples/hello/main.kira`
- `zig build run -- run --backend llvm examples/hello/main.kira`
- `zig build run -- run --backend hybrid examples/hybrid_roundtrip/main.kira`
- `zig build run -- tokens examples/hello/main.kira`
- `zig build run -- ast examples/hello/main.kira`
- `zig build run -- check examples/hello/main.kira`
- `zig build run -- build examples/hello/main.kira`
- `zig build run -- build --backend llvm examples/hello/main.kira`
- `zig build run -- build --backend hybrid examples/hybrid_roundtrip/main.kira`
- `zig build run -- new DemoApp generated/DemoApp`

Install notes:

- `zig build install` installs `kira-bootstrapper` into `zig-out/bin/` by default and installs the active real toolchain into `~/.kira/toolchains/<channel>/<version>/`
- `zig build install-kirac` installs the same managed toolchain plus launcher flow without changing the rest of the repo install names
- `zig build install -p .local` installs into `.local/bin/` instead of `zig-out/bin/`
- `~/.kira/toolchains/current.toml` selects which real toolchain `kira-bootstrapper` forwards to
- add the chosen launcher `bin/` directory to `PATH` to make direct `kira-bootstrapper` invocation global for your shell session

CLI behavior:

- `fetch-llvm` reads `llvm-metadata.toml`, resolves the current host bundle, downloads the matching GitHub release asset, installs it into `~/.kira/toolchains/llvm/<llvm-version>/<target>/`, and skips when the install marker already matches
- `run` defaults to the VM backend; `run --backend llvm` builds and runs a native executable
- `run --backend hybrid` builds a hybrid manifest, bytecode sidecar, and native shared library, then runs the mixed program in the hybrid host
- `tokens` dumps lexer output
- `ast` dumps the parsed AST
- `check` runs parse and semantics
- `build` defaults to writing a `.kbc` bytecode artifact into `generated/`
- `build --backend llvm` writes both a native object file and a native executable into `generated/`
- `build --backend hybrid` writes a `.khm` hybrid manifest plus the bytecode, native object, and native shared library sidecars into `generated/`
- `new` copies the app template into a new destination with a starter `@Main`-annotated function in `src/main.kira`

LLVM backend selection is explicit and host-native. Discovery order is:

1. `KIRA_LLVM_HOME`
2. `~/.kira/toolchains/llvm/<llvm-version>/<target>/`
3. older repo-managed fallback paths if they already exist

The pinned LLVM fetch flow intentionally does not use checksum verification.
