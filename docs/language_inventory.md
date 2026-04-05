# Language Inventory

This file tracks the frontend surface implemented in the compiler today. The language target is the Kira design model, not the small checked-in example corpus.

## Implemented Frontend Surface

- Top-level declarations: `import`, `construct`, `type`, `function`, and construct-defined declaration forms such as `Widget Button(...) { ... }`
- Annotation syntax: bare annotations, namespaced annotations, annotation arguments, and block-form annotations such as `@Doc { ... }`
- Core execution annotations with compiler semantics: `@Main`, `@Native`, `@Runtime`
- FFI annotations with compiler semantics: `@FFI.Extern`, `@FFI.Callback`, `@FFI.Pointer`, `@FFI.Struct`
- Function syntax: parameters, optional return types, blocks, `let`, expression statements, `return`, calls, typed locals, and local inference
- Expressions: integer, float, string, boolean, arrays, unary operators, binary operators, grouped expressions, member access, namespaced references, and call syntax
- Control flow syntax: `if`, `for`, and `switch` in statement and builder/content contexts
- Construct sections: `annotations`, `modifiers`, `requires`, `lifecycle`, `builder`, `representation`, plus custom sections preserved structurally
- Builder/content blocks with sequential composition and control-flow builder items
- Lifecycle hook forms such as `onAppear()`, `onDisappear()`, and `onChange(of: value) { ... }`
- Type inference and explicit-coercion rules for declarations
- Construct-driven semantic checks for declared annotations, lifecycle hooks, and required `content { ... }`

## Current Executable Lowering Boundary

The frontend and semantic model understand the broader language surface above. The shared executable IR and current VM/LLVM lowering still intentionally execute a smaller subset:

- `@Main`, `@Runtime`, `@Native`
- `function`
- integer and string literals
- local `let`
- identifier loads
- integer `+`
- builtin `print`
- direct function calls with arguments and results in the lowered scalar/pointer subset
- `return` with or without a value in the lowered scalar/pointer subset
- block statements
- explicit FFI extern declarations
- callback-typed arguments targeting native/external functions
- `RawPtr`, `CString`, and callback/pointer typedefs used by the current FFI path

`kirac check`, `kirac ast`, and `kirac tokens` operate on the broader frontend. `kirac run` and `kirac build` continue to require the currently lowered executable subset.

## Design Boundary

- The compiler implements language mechanisms needed by construct-defined libraries, including Kira UI-style builder/content semantics.
- The compiler does not hardcode the full UI framework, design packs, or branded theming/runtime behavior in Zig.
- Higher-level framework behavior remains a Kira/library concern once the language surface has been validated and modeled.
