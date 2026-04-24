# Commands

Standalone CLI:

- `zig build install`
- `zig build install-kirac`
- `kira --help`
- `kira --version`
- `kira fetch-llvm`
- `kira run examples/hello`
- `kira run --backend llvm examples/hello`
- `kira run --backend hybrid examples/hybrid_roundtrip`
- `kira tokens examples/hello`
- `kira ast examples/hello`
- `kira check examples/hello`
- `kira build examples/hello`
- `kira shader check examples/shaders/textured_quad.ksl`
- `kira shader ast examples/shaders/textured_quad.ksl`
- `kira shader build examples/shaders/textured_quad.ksl`
- `kira shader build`
- `kira sync`
- `kira add FrostUI`
- `kira add --git https://github.com/Sunlight-Horizon/GameKit.git --rev <commit> GameKit`
- `kira remove FrostUI`
- `kira update`
- `kira package pack`
- `kira package inspect generated/DemoApp-0.1.0.tar`
- `kira new --lib GraphicsKit generated/GraphicsKit`
- `kira build --backend llvm examples/hello`
- `kira build --backend hybrid examples/hybrid_roundtrip`
- `kira new DemoApp generated/DemoApp`

Build-system convenience:

- `zig build`
- `zig build kirac`
- `zig build kira-bootstrapper`
- `zig build test`
- `zig build fetch-llvm`
- `zig build run -- run examples/hello`
- `zig build run -- run --backend llvm examples/hello`
- `zig build run -- run --backend hybrid examples/hybrid_roundtrip`
- `zig build run -- tokens examples/hello`
- `zig build run -- ast examples/hello`
- `zig build run -- check examples/hello`
- `zig build run -- build examples/hello`
- `zig build run -- shader check examples/shaders/textured_quad.ksl`
- `zig build run -- shader build examples/shaders/textured_quad.ksl`
- `zig build run -- shader build`
- `zig build run -- build --backend llvm examples/hello`
- `zig build run -- build --backend hybrid examples/hybrid_roundtrip`
- `zig build run -- new DemoApp generated/DemoApp`

Install notes:

- `zig build install` installs `kira` into `zig-out/bin/` by default and installs the active real toolchain into `~/.kira/toolchains/<channel>/<version>/`
- `zig build install-kirac` installs the same managed toolchain plus launcher flow without changing the rest of the repo install names
- `zig build install -p .local` installs into `.local/bin/` instead of `zig-out/bin/`
- `~/.kira/toolchains/current.toml` selects which real toolchain `kira` forwards to
- add the chosen launcher `bin/` directory to `PATH` to make direct `kira` invocation global for your shell session

CLI behavior:

- `fetch-llvm` reads `llvm-metadata.toml`, resolves the current host bundle, downloads the matching GitHub release asset, installs it into `~/.kira/toolchains/llvm/<llvm-version>/<target>/`, and skips when the install marker already matches
- `run`, `build`, `check`, `tokens`, and `ast` default to the current directory and discover `kira.toml` first, then legacy `project.toml`
- `run` defaults to the VM backend; `run --backend llvm` builds and runs a native executable
- `run --backend hybrid` builds a hybrid manifest, bytecode sidecar, and native shared library, then runs the mixed program in the hybrid host
- `run`, `build`, and `check` automatically sync dependencies before compiling; add `--offline` or `--locked` when you want cache-only or lockfile-only behavior
- VM, LLVM/native, and hybrid now share the ordinary executable surface for control flow, calls, arrays, named values, and mixed runtime/native interaction
- `tokens` dumps lexer output
- `ast` dumps the parsed AST
- `check` runs parse and semantics
- `build` defaults to writing a `.kbc` bytecode artifact into `generated/`
- `shader check` runs the dedicated `.ksl` lexer, parser, import loader, semantic pass, and typed shader IR validation
- `shader ast` dumps the parsed KSL module shape without routing through the executable `.kira` frontend
- `shader build <file.ksl>` emits GLSL 330 vertex/fragment source plus reflection JSON into `generated/shaders/` next to the source file by default, or `--out-dir <dir>`
- `shader build` with no explicit file discovers all top-level PascalCase `*.ksl` entry shaders under `Shaders/` in the current project root and writes outputs to `generated/Shaders/`
- `shader build` rejects compute shaders today with an explicit backend diagnostic because the current real graphics path in this repo is Sokol/OpenGL with GLSL 330 graphics shaders, not a compute-capable pipeline
- `sync` resolves registry, path, and git dependencies into `kira.lock`, verifies registry archive SHA-256 checksums, and populates the local cache under `~/.kira/cache/packages/`
- `add`, `remove`, and `update` edit `kira.toml` and then refresh `kira.lock`
- `package pack` writes a validated source-only `.tar` archive into `generated/`
- `package inspect` prints manifest metadata and archive contents without extracting package scripts because package scripts are not supported
- `build --backend llvm` writes both a native object file and a native executable into `generated/`
- `build --backend hybrid` writes a `.khm` hybrid manifest plus the bytecode, native object, and native shared library sidecars into `generated/`
- `new` scaffolds either an app or a library package; use `new --lib` for a library template with `kind = "library"`, `module_root`, and a root module file under `app/`

LLVM backend selection is explicit and host-native. Discovery order is:

1. `KIRA_LLVM_HOME`
2. `~/.kira/toolchains/llvm/<llvm-version>/<target>/`
3. older repo-managed fallback paths if they already exist

The pinned LLVM fetch flow intentionally does not use checksum verification.
