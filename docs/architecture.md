# Architecture

This bootstrap uses a strict layered package graph. Higher layers may depend on lower layers, and lower layers never depend upward.

The working path today is VM-only:

1. `kira_source` loads source text and spans
2. `kira_lexer` tokenizes
3. `kira_parser` builds AST
4. `kira_semantics` validates `main`, resolves locals, and lowers to HIR
5. `kira_ir` lowers HIR into backend-facing IR
6. `kira_bytecode` compiles IR into bytecode
7. `kira_vm_runtime` executes bytecode

LLVM, hybrid, native bridge, doc generation, and richer build orchestration are scaffolded as real packages with stable types and honest placeholder behavior.

`kira_main` is intentionally separate from compiler packages. It is the app-facing C ABI facade that generated apps will link against.
