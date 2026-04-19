# Language Inventory

This file tracks the frontend surface implemented in the compiler today. The language target is the Kira design model, not the small checked-in example corpus.

## Implemented Frontend Surface

- Top-level declarations: `import`, `construct`, `class`, `struct`, `annotation`, `capability`, `function`, and construct-defined declaration forms such as `Widget Button(...) { ... }`
- Annotation syntax: bare annotations, namespaced annotations, annotation arguments, and block-form annotations such as `@Doc { ... }`
- Annotation declarations: parameter schemas, `targets: ...`, `uses CapabilityName`, and explicit `generated { ... }` function members
- Capability declarations: reusable generated function members composed into annotations
- Core execution annotations with compiler semantics: `@Main`, `@Native`, `@Runtime`
- FFI annotations with compiler semantics: `@FFI.Extern`, `@FFI.Callback`, `@FFI.Pointer`, `@FFI.Struct`
- Function syntax: parameters, optional return types, blocks, `let`, expression statements, `return`, calls, typed locals, and local inference
- Class inheritance: comma-separated `extends` lists, inherited field/method lookup, parent-qualified member access, exact-signature method overrides, and inherited field-default overrides
- Struct declarations: field-only, non-inheriting value shapes
- Expressions: integer, float, string, boolean, arrays, unary operators, binary operators, grouped expressions, member access, namespaced references, and call syntax
- Conditional expressions `condition ? then : else`
- Control flow syntax: `if`, `for`, and `switch` in statement and builder/content contexts
- Construct sections: `annotations`, `modifiers`, `requires`, `lifecycle`, `builder`, `representation`, plus custom sections preserved structurally
- Builder/content blocks with sequential composition and control-flow builder items
- Lifecycle hook forms such as `onAppear()`, `onDisappear()`, and `onChange(of: value) { ... }`
- Type inference and explicit-coercion rules for declarations
- Migration diagnostics for removed `func` and old surface `type` declaration syntax
- Construct-driven semantic checks for declared annotations, lifecycle hooks, and required `content { ... }`

## Current Executable Lowering Boundary

The frontend and semantic model understand the broader language surface above. The shared executable IR and current VM/LLVM lowering still intentionally execute a smaller subset:

- `@Main`, `@Runtime`, `@Native`
- `function`
- integer, float, string, and boolean literals
- local `let`
- identifier loads
- integer `+`, `-`, `*`, `/`, `%`
- float `+`, `-`, `*`, `/`, `%`
- unary `-` on integers and unary `!` on booleans
- unary `-` on floats
- integer, float, and boolean comparisons in the lowered executable subset
- short-circuit `&&` and `||` on booleans
- conditional expressions in the lowered scalar/pointer subset
- array literals, array locals, array params/returns, and `for` iteration over array values
- statement-form `if`
- statement-form `for` over array literals
- statement-form `switch`
- builtin `print`, including named-struct formatting on the VM executable path
- direct function calls with arguments and results in the lowered scalar/pointer subset
- `return` with or without a value in the lowered scalar/pointer subset
- block statements
- lowered named-struct construction and field access on the VM executable path
- lowered inheritance dispatch across `vm`, `llvm`, and `hybrid`, including multiple parents, imported parents, parent-qualified field/method access, inherited method calls, and inherited field-default overrides
- explicit FFI extern declarations
- callback-typed arguments targeting native/external functions
- `RawPtr`, `CString`, and callback/pointer typedefs used by the current FFI path

`kirac check`, `kirac ast`, and `kirac tokens` operate on the broader frontend. `kirac run` and `kirac build` continue to require the currently lowered executable subset. The broadest runtime-value printing support currently lives on the VM/default execution path.

Executable arrays currently use a shared handle-based runtime representation. The VM and the native/text-LLVM path agree on the same array object layout, so array locals, params, returns, and `for` iteration stay in parity across `vm`, `llvm`, and `hybrid`.

## Design Boundary

- The compiler implements language mechanisms needed by construct-defined libraries, including Kira UI-style builder/content semantics.
- The compiler does not hardcode the full UI framework, design packs, or branded theming/runtime behavior in Zig.
- Higher-level framework behavior remains a Kira/library concern once the language surface has been validated and modeled.

## Dedicated Sibling Surfaces

- `.ksl` is now a real dedicated shader language surface rather than an extension of the executable `.kira` frontend.
- The implemented pipeline lives in [docs/ksl.md](ksl.md) and the dedicated packages `kira_ksl_syntax_model`, `kira_ksl_parser`, `kira_ksl_semantics`, `kira_shader_ir`, `kira_shader_model`, and `kira_glsl_backend`.
- KSL v1 currently parses, validates, reflects, and lowers graphics shaders to GLSL 330.
- Compute shaders are part of the source language and semantic model, but the current GLSL 330 backend rejects them intentionally with a clear diagnostic because the repo's real graphics stack today is Sokol/OpenGL graphics-only shader source.
