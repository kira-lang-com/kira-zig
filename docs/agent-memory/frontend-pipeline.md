# Frontend Pipeline

Internal orientation for executable-language front end changes.

## Pipeline shape

1. `kira_source` loads file text and line maps.
2. `kira_lexer` tokenizes.
3. `kira_parser` builds executable AST.
4. `kira_program_graph` resolves imports and app-root source graphs.
5. `kira_semantics` validates and lowers to HIR.
6. `kira_ir` lowers HIR to backend-facing IR.
7. `kira_build` selects VM / LLVM-native / hybrid execution.

## Important files

### `packages/kira_source`

- `source_file.zig` — owned source text, `fromPath`, `initOwned`, deinit.
- `line_map.zig` — line/column mapping.
- `span.zig` — spans/slicing.

### `packages/kira_lexer`

- `lexer.zig` — tokenization and lexer diagnostics.
- `root.zig` — `tokenize` export.

### `packages/kira_syntax_model`

- `token.zig` — executable-language token kinds.
- `syntax_kinds.zig` — small syntax-kind enum.
- `ast.zig` — full executable AST surface.

### `packages/kira_parser`

- `parser.zig` — parser coordinator, recovery helpers, top-level parsing.
- `parser_decls.zig` — declarations, annotations, constructs.
- `parser_statements.zig` — blocks/statements.
- `parser_types_exprs.zig` — type expressions and expression precedence.
- `parser_blocks.zig` — builder/callback block parsing.

### `packages/kira_semantics`

- `analyzer.zig` — top-level semantic analysis, import-aware lowering.
- `lower_shared.zig` — shared type/annotation/FFI utilities.
- `lower_exprs*.zig` — expression lowering split by concern.
- `lower_program*.zig` — program/field/annotation lowering.
- `function_types.zig` — function type helpers.

### `packages/kira_semantics_model`

- `hir.zig` — HIR shapes.
- `types.zig` — resolved types.
- `ffi.zig` — FFI type metadata.
- `symbols.zig`, `scopes.zig` — symbol/scope bookkeeping.

### `packages/kira_ir`

- `ir.zig` — shared executable IR.
- `lower_from_hir.zig` and split helpers — HIR→IR lowering.

## Diagnostics and boundaries

- Frontend diagnostics should stay precise about stage and span.
- `kira_build/src/pipeline.zig` is where frontend failures get classified into lexer/parser/graph/semantics/ir/backend_prepare.
- `kira_ir` returns `UnsupportedExecutableFeature` / `UnsupportedType` for non-lowered constructs; build turns those into user-facing diagnostics.

## When touching frontend code, check

- `tests/pass/check/*` for user-visible frontend success.
- `tests/fail/parser/*`, `tests/fail/semantics/*`, `tests/fail/pipeline/*` for diagnostics.
- `examples/` when syntax showcased to users changes.
- `docs/language_inventory.md` if executable surface changes.
