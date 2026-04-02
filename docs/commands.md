# Commands

Root commands:

- `zig build`
- `zig build test`
- `zig build run -- run examples/hello.kira`
- `zig build run -- tokens examples/hello.kira`
- `zig build run -- ast examples/hello.kira`
- `zig build run -- check examples/hello.kira`
- `zig build run -- build examples/hello.kira`
- `zig build run -- new DemoApp generated/DemoApp`

CLI behavior:

- `run` compiles through the VM pipeline and executes `main`
- `tokens` dumps lexer output
- `ast` dumps the parsed AST
- `check` runs parse and semantics
- `build` writes a `.kbc` bytecode artifact into `generated/`
- `new` copies the app template into a new destination
