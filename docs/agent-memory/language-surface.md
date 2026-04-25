# Language Surface

Internal memory for the implemented Kira language surface.

## Read first

- `README.md`
- `docs/language_inventory.md`
- `examples/README.md`
- `tests/pass/check/*` and `tests/pass/run/*`

## Top-level declarations

Implemented frontend forms include:

- `import`
- `annotation`
- `capability`
- `class`
- `struct`
- `construct`
- `function`
- construct-defined forms such as `Widget Button(...) { ... }`

See `packages/kira_syntax_model/src/ast.zig` and `packages/kira_parser/src/parser_decls.zig`.

## Entry points and execution annotations

- `@Main` selects the entry function.
- `@Runtime` and `@Native` are execution-boundary annotations, not blanket usability bans.
- Current examples show `@Main` combined with `@Runtime` or `@Native` in hybrid flows.
- `tests/pass/run/hybrid_roundtrip/main.kira` and `examples/hybrid_roundtrip/app/main.kira` show mixed calls.

## Declarations and types

- `struct` = value-oriented, non-inheriting type.
- `class` = inheriting type with `extends` lists.
- Fields can have defaults.
- Methods are supported on both.
- `override function ...` must match the inherited signature.
- `override let/var ...` replaces only the default value, not the storage slot.

Reference:

- `examples/hello/app/main.kira`
- `tests/pass/check/inheritance_parent_qualification/main.kira`
- `tests/pass/run/inheritance_multi_parent_parity/main.kira`

## Expressions and statements

Implemented core expression forms:

- integer, float, string, boolean literals
- arrays
- named/nested struct literals
- unary/binary operators
- grouped expressions
- member access and namespaced references
- indexing
- calls and callable-value invocations
- conditional expressions `cond ? then : else`
- inline callback values `{ value in ... }`

Implemented control flow:

- `if` / `else if`
- `for`
- `while`
- `break`
- `continue`
- `switch`
- `return`

## Callbacks

Current callable surface includes:

- direct function references
- function types like `(Int) -> Void`
- inline callback values
- trailing callback blocks, e.g. `graphics.run { frame in ... }`

Trailing callbacks are final function-typed call arguments; they do not add a new literal syntax.

Capture behavior in current corpus:

- immutable `let` captures by value
- mutable `var` uses shared mutable storage
- nested callbacks keep lexical capture behavior across `vm`, `llvm`, and `hybrid`

See `tests/pass/run/callback_value_parity/main.kira`, `tests/pass/check/callback_syntax_and_function_types/main.kira`, and trailing-callback tests.

## FFI / native concepts

Current compiler-recognized forms:

- `@FFI.Extern`
- `@FFI.Callback`
- `@FFI.Pointer`
- `@FFI.Struct`
- `@FFI.Alias`
- `@FFI.Array`
- `nativeState(...)`
- `nativeUserData(...)`
- `nativeRecover<T>(...)`

`@FFI.Struct { layout: c; }` is special for zero-filled explicit construction.
See `docs/native_libraries.md` and `tests/pass/run/ffi_struct_zero_init/main.kira`.

## Frontend-only vs executable-lowering

Frontend/semantic support is broader than executable lowering.

Executable lowering currently covers the ordinary subset exercised by parity corpus:

- `@Main`, `@Runtime`, `@Native`
- `function`
- locals, calls, returns
- arithmetic, comparison, boolean short-circuiting
- arrays and indexed access
- statement `if`/`while`/`for`/`switch`
- named structs and methods
- `print`
- a subset of FFI/native callback and struct behavior

When touching syntax, verify whether the change is frontend-only or needs `kira_ir`, `kira_bytecode`, `kira_vm_runtime`, and `kira_llvm_backend` updates.
