# Language Inventory

This file tracks the frontend surface implemented in the compiler today. The language target is the Kira design model, not the small checked-in example corpus.

## Implemented Frontend Surface

- Top-level declarations: `import`, `construct`, `class`, `struct`, `enum`, `annotation`, `capability`, `function`, and construct-defined declaration forms such as `Widget Button(...) { ... }`
- Documentation comments: consecutive `///` lines immediately preceding a declaration or member
- Annotation syntax: bare annotations, namespaced annotations, annotation arguments, and block-form annotations
- Annotation declarations: parameter schemas, `targets: ...`, `uses CapabilityName`, and explicit `generated { ... }` function members
- Capability declarations: reusable generated function members composed into annotations
- Core execution annotations with compiler semantics: `@Main`, `@Native`, `@Runtime`
- Type execution annotations: `@Native` and `@Runtime` on `struct` and `class`, with structs reserved for execution-boundary and compiler FFI annotations only
- FFI annotations with compiler semantics: `@FFI.Extern`, `@FFI.Callback`, `@FFI.Pointer`, `@FFI.Struct`, plus zero-filled explicit construction for `@FFI.Struct { layout: c; }` values
- Native callback-state expressions with compiler semantics: `nativeState(value)`, `nativeUserData(state)`, `nativeRecover<Type>(raw_ptr)`, and `nativeStateFree(state_or_token)`
- Function syntax: parameters, function types such as `(Float) -> Void`, optional return types, blocks, `let`/`var`, inferred local declarations, explicit typed local declarations with or without initializer expressions, strict declared-type matching for annotated initializers, expression statements, `return`, calls, `match`, and direct trailing callback blocks such as `app.onFrame { frame in ... }`
- Construct-qualified `any ConstructName` type qualifiers for executable code; the VM/hybrid runtime path keeps runtime dispatch metadata, while `@Native` lowering monomorphizes concrete construct implementations. `any` is rejected for classes, primitives, aliases, and other non-construct symbols.
- Class inheritance: comma-separated `extends` lists, inherited field/method lookup, parent-qualified member access, exact-signature method overrides, and inherited field-default overrides
- Struct declarations: non-inheriting value shapes with stored members, default values, methods, and compiler-validated `@Printable` dispatch through `onPrint() -> String`
- Enum declarations: payload-less variants, single-payload variants, default payload values, generic type parameters in type position, expected-type member construction outside `match`, and inferred unqualified variant names inside `match`
- Expressions: integer, float, string, boolean, arrays, named/nested struct literals, unary operators, binary operators, grouped expressions, member access, expected-type implicit members, namespaced references, indexing, call syntax, named function references, inline callback values, and callable-value invocations. A leading-dot expression such as `.Red`, `.Loaded(4)`, `.ConcreteWidget()`, or `.makeDefault()` resolves in an expected enum/class/construct/result/callback context supplied by a typed local, field, parameter, return, typed array element, comparison peer, or outer payload. An unanchored leading-dot expression is rejected with `KSEM166`; a missing member in an anchored namespace is `KSEM167`. Qualified spellings remain valid when no expected type exists.
- Value binder unification (Construct 2.0): `=` is the canonical binder everywhere a value is bound — call/construction args (`Text(text = "title")`) and struct literals (`Point { x = 1 }`, `Defaults { executionMode = .Hybrid }`). `:` stays accepted for the transition window (both forms normalize to the same AST) and is reserved for type annotations; no deprecation diagnostics yet
- Content-block expressions: a `{ ... }` builder body in expression position (`let header: [some Widget] = { Text("a"); child; For(x in xs) { ... } }`) evaluates to a `[some Widget]` children list — the exact trailing-builder-block grammar (constructions / bare let-bound children / `if` / `For`). Disambiguated from closures by closure-param grammar (`{ ident, ... in ... }` / `{ in ... }` stay closures); `{}` is an empty content block. The element type is anchored by an annotation or a receiving field/argument type; an unanchored content block is rejected (`KSEM160`). Ownership is a fresh value (like an inline array literal), so a content block may fill an array field while a named array into the same field still aliases (`KSEM118`)
- Conditional expressions `condition ? then : else`
- Trailing callbacks are native call syntax, for example `graphics.run { frame in frame.draw() }`,
  `graphics.runWithConfig(config) { frame in ... }`, and zero-parameter `app.tick { in update() }`; the trailing block binds as the final function-typed call argument.
  Trailing callbacks may capture surrounding locals: immutable `let` bindings are captured by value, while mutable `var` bindings are captured as shared mutable storage.
  Nested callbacks and multiple callbacks share mutable captures according to lexical scope across `vm`, `hybrid`, and `llvm`.
  This syntax does not introduce standalone callback literals beyond the existing inline callback-value surface.
- Control flow syntax: `if`, `else if`, `for`, `while`, `break`, `continue`, `match`, and `switch` in statement position, plus `if`/`else if`, `for`, and `switch` in builder/content contexts
- Construct sections: `annotations`, `modifiers`, `requires`, `lifecycle`, `builder`, `representation`, plus custom sections preserved structurally
- Construct declaration families (see [docs/construct_family.md](construct_family.md)): `construct C extends A, B` inheritance with cycle/unknown-parent diagnostics; `requires { function ... }` required functions with first-concrete-child satisfaction across the mixed construct/declaration graph, override signature checks, and `Self`. Construct 2.0 REMOVED the legacy schema surfaces: a `properties { [required] name: Type }` schema (declaration or fill) is rejected (`KSEM164`), and named content channels `content { chan { accepts T; count min..max } }` plus the composition directives `content sealed`/`refine`/`passthrough`/`project` are rejected (`KSEM165`) — a construct expresses caller-provided values as `@Required let`/`let field = default` fields and child slots as `some X` / `[some X]` fields instead. The SwiftUI-style direct surface adds top-level construct members: `@Required let`/`@Required function` requirements and computed default members (`let node: Node { body.node }`), with the terminal-`node` rule (an explicit `node` discharges the required `body`) and diagnostics for a missing required member on a declaration (`KSEM140`) and self-recursive `body` expansion (`KSEM141`). Caller-provided children are declared as child slots — in Construct 2.0 simply by typing a construct-form field `some X` or `[some X]` (slot-by-type, no annotation), or with the compat `@Content` annotation; field names are the channel names, no string labels. A trailing `{ ... }` block on a construction is routed by callee inspection — single `some X` (exactly one) vs `[some X]` (ordered many), named fills for multiple slots — with diagnostics for bare children on a slot-less declaration (`KSEM142`), content-count mismatch (`KSEM143`), an ambiguous bare block (`KSEM144`), and a non-widget child (`KSEM145`). A child slot is filled ONLY by bare children in the trailing block, never by a constructor parens argument or an override member (`KSEM162`). The trailing block may ALSO carry `let field = value` override members (Construct 2.0 items 1/5) that set non-slot fields — `Dialog(title = "Hi") { let subtitle = "…"; <bare children> }` — coexisting with parens arguments and bare children; an override naming a field the type does not declare is rejected (`KSEM163`), and an override outside a construction block is rejected. A `@Required` field satisfied by neither a constructor argument nor an override member at a construction site is rejected (`KSEM161`). Slot-by-type applies to construct-form fields only; a `some X` / `[some X]` field on a plain `struct`/`class` remains an ordinary constructor-filled field. Fluent modifiers are added with `extend C { function modifier(...) -> C { ... } }` (the chainable `.padding(...)` surface, distinct from the `node` bridge), with an unknown-target diagnostic (`KSEM146`); modifier bodies and construction sites are validated pre-backend (not yet lowered to runtime values).
- Linear error handling `attempt { ... try expr ... } handle { Variant { ... } }` over `Result<Value, Failure>`: validated (try-outside-attempt, try-on-non-Result, missing/unknown handle case, incompatible failure enums) and **executed** on vm/hybrid by desugaring to enum `match` (the `try` keyword, not `?`)
- Builder/content blocks with sequential composition, control-flow builder items, and preserved nested trailing-builder child trees on call expressions
- Lifecycle hook forms such as `onAppear()`, `onDisappear()`, and `onChange(of: value) { ... }`
- Type inference plus explicit uninitialized declarations and strict annotated-initializer matching
- Migration diagnostics for removed legacy declaration and documentation syntax
- Construct-driven semantic checks for declared annotations, lifecycle hooks, and required `content { ... }`
- Language-wide type aliases `type Name = Target`, with alias-cycle and duplicate diagnostics; Foundation uses them for `type Byte = U8` / `type ByteBuffer = [Byte]`
- Async task spine: `async function` declarations, `Task { call(...) }` deferred spawn, `handle.await` join, `handle.requestCancel()` cooperative cancel, `handle.detach()`, the `taskYield()` cooperative suspend point, and `taskSleep(ms)` timed parking

## Current Executable Lowering Boundary

The frontend and semantic model understand the broader language surface above. The shared executable IR and current VM/LLVM/hybrid lowering now execute the ordinary language core used by the checked-in parity and interop corpus:

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
- array literals, array locals, array params/returns, indexing, indexed assignment, and `for` iteration over array values
- statement-form `if`
- statement-form `while`, `break`, and `continue`
- statement-form `for` over array literals
- statement-form `switch`
- statement-form `match` with exhaustive enum coverage, nested destructuring, payload binding, and duplicate-arm diagnostics
- builtin `print`, including named-struct formatting, enum formatting, `@Printable` method dispatch, and array summaries across `vm`, `llvm`, and `hybrid`
- direct function calls with arguments and results in the lowered scalar/pointer subset
- `return` with or without a value in the lowered scalar/pointer subset
- block statements
- lowered named-struct construction, field access, and struct methods across `vm`, `llvm`, and `hybrid`
- lowered enum construction, enum payload transport, generic `Result<Value, Failure>` instantiation, and enum tag/payload branching across `vm`, `llvm`, and `hybrid`
- lowered zero-filled `@FFI.Struct { layout: c; }` construction through both `Type()` and `Type { ... }`, with omitted C-layout fields preserved as zero
- lowered inheritance dispatch across `vm`, `llvm`, and `hybrid`, including multiple parents, imported parents, parent-qualified field/method access, inherited method calls, and inherited field-default overrides
- explicit FFI extern declarations
- callback-typed arguments targeting native/external functions
- `RawPtr`, `CString`, and callback/pointer typedefs used by the current FFI path
- boxed callback-state handles for Kira-owned native userdata transport, with typed field-oriented recovery across `llvm` and `hybrid`
- function types, named function references, inline callback literals, direct trailing callbacks, immutable by-value callback captures, shared mutable `var` callback captures, nested captures, and callable-value invocations through locals and fields across the shared executable backends
- language-wide `type Name = Target` aliases, canonicalized before lowering so aliased and canonical spellings execute identically across `vm`, `llvm`, and `hybrid`
- the deferred async task spine across `vm`, `llvm`, and `hybrid`: `async function` bodies execute like synchronous functions when called directly (no reactor-backed suspend points yet; `is_async` is carried through HIR/IR/bytecode for the later executor phases); `Task { call(...) }` spawns a deferred task (arguments evaluate at the spawn site, the call runs at first drive); `handle.await` joins it (running the deferred call and yielding its result); `handle.requestCancel()` before the first drive prevents the call from ever running; `handle.detach()` drives the task and discards the result. Awaiting a cancelled task and joining twice are runtime traps on every backend. The current slice restricts task bodies to a direct call to a named function with scalar (`Int`/`Float`/`Bool`) parameters and a scalar or `Void` result (a `Void` task joins as `Int` 0), or a pure scalar literal (`KSEM159` otherwise); task handles are opaque — any use other than `.await`/`.requestCancel()`/`.detach()` is rejected (`KSEM158`). `taskYield()` is a cooperative suspend point: eligible async task bodies (scalar params/locals, spawned-only) are compiled into saved-frame state machines — a yield suspends the body (its params/locals persist in a heap task frame), the executor round-robins the ready queue, and the body resumes at the yield point on its next drive, identically on `vm`, `llvm`, and `hybrid`; cancellation is observed at suspend points (a cancelled suspended task never resumes and its join traps). Ineligible bodies keep the stack-nested drive at yield points

`kirac check`, `kirac ast`, and `kirac tokens` operate on the broader frontend. `kirac run` and `kirac build` use the shared executable lowering across VM, LLVM/native, and hybrid backends rather than treating LLVM/native as a permanently tiny subset.

Executable arrays currently use a shared handle-based runtime representation. The VM and the native/text-LLVM path agree on the same array object layout, so array locals, params, returns, and `for` iteration stay in parity across `vm`, `llvm`, and `hybrid`.

## Design Boundary

- The compiler implements language mechanisms needed by construct-defined libraries, including Kira UI-style builder/content semantics and preserved nested child trees.
- The compiler does not hardcode the full UI framework, design packs, or branded theming/runtime behavior in Zig.
- Higher-level framework behavior remains a Kira/library concern once the language surface has been validated and modeled.

## Dedicated Sibling Surfaces

- `.ksl` is now a real dedicated shader language surface rather than an extension of the executable `.kira` frontend.
- The implemented pipeline lives in [docs/ksl.md](ksl.md) and the dedicated packages `kira_ksl_syntax_model`, `kira_ksl_parser`, `kira_ksl_semantics`, `kira_shader_ir`, `kira_shader_model`, `kira_glsl_backend`, and `kira_wgsl_backend`.
- KSL v1 currently parses, validates, reflects, and lowers graphics shaders to GLSL 330 and WGSL.
- HLSL, MSL, and SPIR-V are recognized KSL target identities, but the compiler rejects them with a clear diagnostic until validated lowerers exist.
- Compute shaders are part of the source language and semantic model, but the current validated graphics backends reject them intentionally with a clear diagnostic because there is not yet a compute-capable KSL backend path.
