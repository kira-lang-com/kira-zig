# Missing Kira Syntax Audit

Purpose: identify missing, incomplete, awkward, inconsistent, and workaround-driven Kira syntax that currently blocks complex real-world code. This audit covers the current repository surface as of 2026-04-19: docs, examples, tests, parser/semantic/compiler code, FFI examples, declarative UI examples, and the new KSL shader surface.

## Executive Summary

Kira has a real and promising bootstrap language now: functions, classes, structs, construct-defined declarations, annotations, generated-member metadata, inheritance, arrays, field access, FFI annotations, and KSL shader files all exist in some form. The gap is that the language is still mostly a small compiler bootstrap plus a metadata grammar. Real application code quickly falls into workaround shapes.

The biggest syntax blockers are:

1. No expressive initialization syntax. Complex data is built with blank local structs plus field-by-field assignment. This dominates the Sokol graphics examples and makes descriptor-heavy APIs unpleasant.
2. No lambdas, closures, or inline callback syntax. FFI and lifecycle code require top-level named functions and explicit `RawPtr` user data threading.
3. Construct/UI syntax is parsed more deeply than it is semantically usable. Trailing builder blocks exist in the AST, but general call lowering ignores the child builder payload, so nested UI DSLs are structurally shallow.
4. Annotation and FFI syntax are doing too much work. FFI callback, pointer, array, alias, and enum-like declarations are encoded as fake empty structs with annotation blocks.
5. Type expressions are too small. Main Kira has named and array types only. There are no function types, optional/result types, pointer/reference syntax, generic/application syntax, tuple types, or first-class aliases.
6. Control flow and patterns are minimal. `switch` is expression-case only, `for` iterates arrays only, and there is no `while`, `break`, `continue`, `else if`, destructuring, enum cases, or pattern matching.
7. Class/struct modeling lacks constructors, static members, explicit `self`/`super`, interfaces/traits/protocols, and value-type methods. `examples/hello` currently fails `kira check` on a static/self-typed geometry shape.
8. KSL is a better language surface than main Kira in several expression areas, including indexing, but it is isolated from the app syntax and not yet consumed by Kira Graphics.

The areas hurt most are graphics descriptors, UI builder DSLs, lifecycle APIs, callbacks, serialization/data modeling, generated bindings, and any library that wants to expose a clean fluent or declarative API instead of a pile of declarations and mutation statements.

## Current Language Surface Observed

The repository currently supports, or at least parses/checks, these baseline features:

- Top-level declarations: `import`, `annotation`, `capability`, `construct`, `class`, `struct`, `function`, and construct-defined forms such as `Widget Button(...) { ... }`.
- Function declarations with `function`, parameter lists, optional return types using `:` or `->`, block bodies, extern-style declarations ending in `;`, `let`/`var`, assignment, return, expression statements, direct calls, member calls, and builtin `print`.
- Scalars: integer, float, string, boolean.
- Expressions: unary `-`/`!`, arithmetic, comparisons, equality, boolean `&&`/`||`, conditional `condition ? then : else`, grouping, member access, calls, array literals.
- Type expressions: named types and array types `[T]`.
- Control flow: statement and builder-context `if`, `for item in array`, and `switch`.
- Structs and classes: field declarations, class methods, inheritance with comma-separated parents, exact override checking, parent-qualified member access, imported parents, and field default overrides.
- Annotations: bare and namespaced annotations, positional/named annotation arguments, parsed block-form annotations, annotation declarations with parameter schemas and targets, built-in FFI/core annotations, and capability-composed generated function metadata.
- Constructs: construct sections including `annotations`, `requires`, `lifecycle`, `builder`, `representation`, custom sections, construct-defined declaration bodies, `content { ... }`, and some lifecycle checks.
- FFI: annotation-based extern functions, callbacks, pointers, aliases, fixed arrays, C-layout structs, `RawPtr`, `CString`, static-linking-first autobindings, native callbacks, and direct Sokol proof code.
- KSL: a sibling shader language with `shader`, `group`, resources, options, stage blocks, typed shader IR, indexing, reflection, and GLSL 330 graphics lowering. Compute shaders parse/check but do not build on the current GLSL backend.

Important compiler reality checks performed during this audit:

- `zig build run -- check examples/complex_language_showcase` passed.
- `zig build run -- check examples/ui_library` passed.
- `zig build run -- shader check examples/shaders/textured_quad.ksl` passed.
- `zig build run -- shader build examples/shaders/particle_integrate.ksl` failed with `KSL121` because compute shaders are not supported by the GLSL 330 backend.
- `zig build run -- check examples/hello` failed with `KSEM031` at `examples/hello/app/main.kira`, around the self-typed/static-looking `Rect.zero` default.
- `foundation/app/Types/Primitives.kira` still contains removed `type Color { ... }` syntax.

## Missing / Weak / Awkward Syntax Inventory

### Declarations And Modules

#### 1. Stale `type` Syntax Still Leaks Into Active Source

- Current state: main Kira intentionally replaced old `type` declarations with `class` and `struct`. The parser emits migration diagnostics for `type Old { }`. KSL deliberately still uses `type`.
- Why it is a problem: the same word now means "old invalid main Kira syntax" and "valid shader type syntax" depending on file extension. That is manageable, but active-looking code under `foundation/app/Types/Primitives.kira` still uses `type Color { ... }`.
- Real examples: `foundation/app/Types/Primitives.kira`; parser tests in `packages/kira_parser/src/parser.zig` explicitly reject old `type`.
- Workaround today: hand-convert old main Kira files to `struct` or `class`.
- Ideal syntax direction: keep `type` exclusive to KSL or reintroduce it in main Kira only as an explicit alias form, for example `type Color = struct { ... }`. Do not leave it as a ghost declaration form.
- Severity / priority: P1 for repo hygiene and onboarding clarity.
- Work type: parser/docs/examples migration, plus project scanning.

#### 2. Module Import Surface Is Too Coarse

- Current state: imports are `import Module` or `import Module as Alias`. Imported globals are surfaced by module/root name and leaf lookups.
- Why it is a problem: real packages need selective imports, re-exports, namespaces, visibility, and stable public API boundaries. Without them, larger apps either over-import or rely on fragile global names.
- Real examples: `examples/complex_language_showcase/app/main.kira` imports `complex_language_showcase.UI as Kit`; generated Sokol modules expose thousands of public names directly.
- Workaround today: alias whole modules and use qualified names.
- Ideal syntax direction: add `export`, `pub`, selective imports such as `import UI.{Widget, Button}`, re-export forms, and maybe package/module declarations.
- Severity / priority: P2.
- Work type: parser, semantic symbol tables, package tooling, docs.

#### 3. No Top-Level Constants Or Static Members

- Current state: class fields exist, but there is no explicit static/class-member syntax. `examples/hello` models defaults as class fields such as `let zero: Rect = Rect(...)` and uses `Rect.zero`, but `kira check examples/hello` currently fails on the `Rect` default.
- Why it is a problem: graphics, geometry, UI, and serialization libraries all need constants like `Rect.zero`, `Color.red`, `EdgeInsets.none`, default descriptors, and well-known capabilities.
- Real examples: `examples/hello/app/main.kira` (`Rect.zero`, `Point.zero`) fails semantic checking; Sokol descriptor defaults are built manually in `examples/sokol_triangle/app/main.kira`.
- Workaround today: construct values manually at use sites or use functions returning values.
- Ideal syntax direction: explicit static declarations, for example `static let zero = Rect(...)`, `static function default() -> Rect`, and deterministic initialization rules.
- Severity / priority: P1.
- Work type: parser, semantic model, initialization lowering, backend support.

#### 4. Declaration Visibility And API Ownership Are Missing

- Current state: all declarations are effectively public within imported modules. There is no syntax for private/internal/public, package-private, or friend-style generated access.
- Why it is a problem: complex compiler/runtime/app architecture needs real API boundaries. Generated FFI modules especially need to hide helper aliases and expose a curated layer.
- Real examples: generated Sokol bindings expose many synthesized callback, pointer, alias, and array structs in `examples/sokol_triangle/sokol.kira` and `tests/pass/run/ffi_sokol_triangle_native/sokol.kira`.
- Workaround today: naming conventions.
- Ideal syntax direction: `pub`, `internal`, private-by-default or public-by-default with explicit hiding, and generated-module visibility controls.
- Severity / priority: P2.
- Work type: parser, semantic resolver, package tooling, docs.

### Functions And Callbacks

#### 5. No Lambdas Or Inline Closures

- Current state: function values only appear indirectly as named function references when a callback-typed FFI parameter expects them. There is no lambda expression in the AST.
- Why it is a problem: callbacks are everywhere in UI, graphics, event routing, async APIs, serialization visitors, compiler passes, and collection operations. Requiring top-level named functions destroys locality.
- Real examples: `examples/callbacks/app/main.kira`, `examples/callbacks_chain/app/main.kira`, and Sokol app callbacks in `examples/sokol_triangle/app/main.kira` use top-level `@Native function init/frame/event/cleanup`.
- Workaround today: declare named `@Native` functions and thread `RawPtr` user data manually.
- Ideal syntax direction: closures such as `(event) => { ... }`, trailing closure syntax, capture analysis, and a clear distinction between Kira closures and C ABI callbacks.
- Severity / priority: P0 for real UI/graphics/app code.
- Work type: parser, type system, closure capture semantics, lowering/runtime, FFI bridge rules.

#### 6. Trailing Builder Blocks Parse But Do Not Carry Semantic Meaning For Calls

- Current state: `CallExpr` has `trailing_builder: ?BuilderBlock`, and examples use `Kit.Column("Operations") { ... }`. Semantic lowering of calls currently processes only `node.args`; the trailing builder payload is not turned into a function argument or construct child model.
- Why it is a problem: this is the core syntax needed for clean UI DSLs. If the parser accepts beautiful nested builder syntax but the semantic model discards or ignores child content, APIs become fake-builder glue.
- Real examples: `tests/pass/check/declarative_showcase/main.kira` and `examples/complex_language_showcase/app/main.kira` use nested `Kit.Column(...) { Kit.Text(...) }`.
- Workaround today: use `content { ... }` sections for top-level construct forms and treat nested calls as check-only structure.
- Ideal syntax direction: make trailing builder blocks lower into an explicit builder parameter, slot, or construct child list, with type-checked builder result types.
- Severity / priority: P0 for Kira UI.
- Work type: semantic model, construct system, type checking, lowering/runtime once UI executes.

#### 7. No First-Class Function Types

- Current state: type expressions do not include function types. FFI callbacks are represented by annotated empty structs such as `struct kira_i64_callback {}`.
- Why it is a problem: APIs cannot say "this parameter is a callback" without generating fake nominal wrappers. Higher-order functions, event buses, visitors, reducers, and command handlers are awkward or impossible.
- Real examples: `@FFI.Callback { abi: c; params: [I64, RawPtr]; result: I64; } struct kira_i64_callback {}` in callback examples and generated Sokol bindings.
- Workaround today: annotated callback structs and named functions.
- Ideal syntax direction: readable function type syntax, for example `(I64, RawPtr) -> I64`, plus `extern c (I64, RawPtr) -> I64` or a capability annotation on function types.
- Severity / priority: P0.
- Work type: parser, type model, semantic resolver, IR/runtime/FFI.

#### 8. No Method Receiver Syntax Or Explicit `self`

- Current state: class methods can read fields and call sibling methods through implicit self. Parent-qualified access uses parent type names like `Left.doubled()`.
- Why it is a problem: implicit receiver lookup becomes fragile in large types and conflicts with locals/imports. It also makes it hard to express callbacks capturing instance state, property setters, and method references.
- Real examples: `tests/pass/run/inheritance_multi_parent_parity/main.kira`; `examples/hello/app/main.kira` methods use bare `x`, `width`, etc.
- Workaround today: rely on implicit field/method lookup and parent-qualified names.
- Ideal syntax direction: support explicit `self.field`, `self.method()`, and `super`/parent access. Keep implicit lookup only if it remains unambiguous.
- Severity / priority: P1.
- Work type: parser token reservation, semantic resolver, diagnostics.

#### 9. No Async, Defer, Or Cleanup/Lifecycle Control Flow

- Current state: lifecycle is a construct section with hook names; ordinary functions have only synchronous blocks and returns.
- Why it is a problem: graphics and UI code need setup/teardown, resource ownership, event loops, and async effects. Without `defer`, resource cleanup becomes manual and error-prone.
- Real examples: `examples/sokol_triangle/app/main.kira` manually creates and destroys Sokol resources across `init` and `cleanup`.
- Workaround today: split lifecycle across top-level callback functions and trust naming.
- Ideal syntax direction: `defer`, scoped resource blocks, async/task syntax later, and lifecycle hooks that can bind resource scopes.
- Severity / priority: P2.
- Work type: parser, semantics, runtime model.

### Initialization And Literals

#### 10. No Struct/Object Literal With Named Fields

- Current state: type calls such as `Pair(4, 8)` and `Color(r: 255, g: 0, b: 0)` are parsed as calls. Argument labels are stored in the AST, but constructor lowering is positional and does not enforce named-field initialization semantics.
- Why it is a problem: real structs are not stable under positional initialization. Descriptor-heavy APIs become unreadable and fragile when every field assignment is separate.
- Real examples: `tests/pass/run/struct_state_parity/main.kira` uses positional `Pair(4, 8)` and `State(seed, Pair(1, 2), 0)`; Sokol examples allocate blank descriptors and assign many fields.
- Workaround today: declare a local with a type, then assign fields one by one.
- Ideal syntax direction: true named struct literals such as `Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 }`, update syntax `desc { width: 640 }`, and label validation for constructor calls if call syntax stays.
- Severity / priority: P0.
- Work type: parser, AST, semantic constructor resolution, lowering/backend.

#### 11. No Nested Descriptor Initialization Or `with` Blocks

- Current state: nested fields are mutated one assignment at a time: `shader_desc.vertex_func.source = "..."; pipeline_desc.shader = state.shader`.
- Why it is a problem: graphics APIs naturally use nested descriptors. Without nested literal/update syntax, Kira code mirrors C setup ceremony rather than providing a high-level language.
- Real examples: `examples/sokol_triangle/app/main.kira`, `examples/sokol_runtime_entry/app/main.kira`, `tests/pass/run/ffi_sokol_triangle_native/main.kira`.
- Workaround today: blank local plus field mutation.
- Ideal syntax direction: nested literals and mutation blocks:

```kira
let desc = sokol.sapp_desc {
    width: 640
    height: 480
    window_title: "Kira Sokol Triangle"
    init_userdata_cb: init
}
```

- Severity / priority: P0 for graphics and app architecture.
- Work type: parser, semantic initialization, lowering, FFI struct layout safety.

#### 12. No Map/Dictionary, Set, Tuple, Or Record Literals

- Current state: arrays exist. There is no syntax for key-value maps, sets, tuples, anonymous records, or named record updates.
- Why it is a problem: serialization, compiler metadata, UI style dictionaries, build options, and annotations often need structured ad hoc data.
- Real examples: annotation blocks imitate key-value metadata for FFI; KSL reflection emits JSON externally because Kira has no in-language data literal shape.
- Workaround today: define structs or use annotation blocks for metadata-only cases.
- Ideal syntax direction: decide on a record/map literal family, for example `{ key: value }` for records and `["key": value]` or `Map { ... }` for maps.
- Severity / priority: P1.
- Work type: parser, type inference, runtime collections.

#### 13. No Optional, Null, Result, Or Error Literal Surface

- Current state: `RawPtr` null is represented through integer `0` in examples. There is no `null`, `none`, `some`, `Result`, `try`, or error propagation syntax.
- Why it is a problem: native interop, graphics handles, parser/compiler APIs, serialization, and app state all need absence and failure.
- Real examples: callback calls pass `0` for `user_data` in `examples/callbacks/app/main.kira`.
- Workaround today: use sentinel integers/pointers or custom structs once available.
- Ideal syntax direction: `null`/optional types, `Result<T, E>` or Kira-style error effects, `try`/`catch`, and FFI null-pointer conversions.
- Severity / priority: P1.
- Work type: lexer/parser, type system, IR/runtime, diagnostics.

#### 14. String Literal Surface Is Too Primitive For Assets

- Current state: multiline strings work in examples by embedding newlines inside quotes. There is no raw string, heredoc, interpolation, asset reference, or shader import syntax in main Kira.
- Why it is a problem: shader code, HTML/templates, SQL, serialization schemas, and UI text become brittle when embedded as ordinary strings.
- Real examples: GLSL source strings in `examples/sokol_triangle/app/main.kira` and `examples/sokol_runtime_entry/app/main.kira`.
- Workaround today: inline multiline strings or use separate `.ksl` CLI workflow outside app code.
- Ideal syntax direction: raw strings, interpolation, and asset syntax such as `shader TexturedQuad from "Shaders/textured_quad.ksl"` or `asset("...")` with typed build integration.
- Severity / priority: P1 for graphics.
- Work type: lexer/parser, build integration, package/asset model.

### Control Flow And Patterns

#### 15. `switch` Has No Real Pattern Language

- Current state: `switch` cases parse a single expression as the pattern. No enum cases, destructuring, ranges, guards, multiple alternatives, or exhaustiveness.
- Why it is a problem: compilers, UI state machines, event routing, and serialization all need expressive pattern matching.
- Real examples: `tests/pass/run/control_flow_parity/main.kira` and builder switch examples use integer cases only.
- Workaround today: chained `if`/`else` or simple literal switches.
- Ideal syntax direction: enum/sum types plus `match`/`switch` patterns, guards, `_`, `case .name(value)`, and exhaustiveness diagnostics.
- Severity / priority: P1.
- Work type: AST, parser, type system, lowering.

#### 16. Loop Syntax Is Array-Only And Has No Control Statements

- Current state: executable `for` loops currently require array values. There is no `while`, numeric ranges, iterator protocol, `break`, or `continue`.
- Why it is a problem: compiler passes, graphics buffers, UI diffing, search, and parsers all need loops that are not array literals.
- Real examples: `lower_exprs.zig` reports "for loop requires an array iterator"; tests cover only arrays.
- Workaround today: use arrays or unroll simple logic.
- Ideal syntax direction: `while`, `loop`, range syntax (`for i in 0..<count`), iterator protocols, `break`, and `continue`.
- Severity / priority: P1.
- Work type: lexer/parser, semantics, IR/backend.

#### 17. `else if` Is Not A First-Class Syntax Shape

- Current state: parser accepts `else` followed by a block only. Chained conditionals require nested blocks.
- Why it is a problem: event handling and compiler logic produce deeply nested code.
- Real examples: parser `finishIfStatement` only parses `else_block = parseBlock()`.
- Workaround today: `else { if condition { ... } }`.
- Ideal syntax direction: parse `else if` chains into either nested AST or explicit branches.
- Severity / priority: P2.
- Work type: parser and formatting/docs.

#### 18. Conditional Expressions Are Ternary-Only

- Current state: `condition ? then : else` exists. Statement `if` is not an expression.
- Why it is a problem: Kira otherwise leans readable; ternary syntax becomes awkward for larger expressions and does not scale to builder/value contexts.
- Real examples: `examples/hello/app/main.kira` uses ternaries for geometry math.
- Workaround today: ternary or local variables with statement `if`.
- Ideal syntax direction: consider expression-form `if condition { value } else { value }`, especially for DSL and typed initialization.
- Severity / priority: P2.
- Work type: parser, type checking, lowering.

### Annotations

#### 19. User Annotation Blocks Are Parsed But Mostly Not Semantically Supported

- Current state: the AST supports `@Name { ... }`. `docs/language_inventory.md` says block-form annotations such as `@Doc { ... }` exist. Semantic lowering only allows blocks for headers marked `allows_block`; built-in FFI annotations are registered this way. User annotation declarations do not expose a block schema.
- Why it is a problem: documentation, serialization, routing metadata, shader metadata, and UI styling want structured annotation blocks. The parser promise is ahead of semantic reality.
- Real examples: `@Doc("...")` works in examples, but the documented `@Doc { ... }` shape is not generally useful for declared annotations.
- Workaround today: use positional/named literal parameters or FFI-only block syntax.
- Ideal syntax direction: annotation declarations should be able to define block schemas:

```kira
annotation Doc {
    block {
        summary: String
        details: String
    }
}
```

- Severity / priority: P1.
- Work type: annotation declaration grammar, semantic schema validation, docs.

#### 20. Annotation Parameter Types Are Too Limited

- Current state: user annotation parameters currently support only `Bool`, `Int`, `Float`, and `String` literal values. FFI metadata uses special block parsing for type names, arrays of type names, counts, and identifiers.
- Why it is a problem: real annotations need types, arrays, enums, symbols, paths, blocks, expressions, and sometimes constant references.
- Real examples: `@FFI.Callback { abi: c; params: [I64, RawPtr]; result: I64; }` is handled outside the normal annotation parameter system.
- Workaround today: special-case built-in annotations or encode values as strings/identifiers.
- Ideal syntax direction: typed annotation constants including `Type`, `[Type]`, symbol references, enum values, and schema-defined blocks.
- Severity / priority: P1.
- Work type: type system, constant evaluation, annotation lowering.

#### 21. Annotation Targets Are Incomplete

- Current state: targets include `class`, `struct`, `function`, `construct`, and `field`. Parameters can syntactically carry annotations, but there is no `parameter` target. There is no module/package/local/method/content/lifecycle target.
- Why it is a problem: real metadata often applies to params, modules, properties, generated files, UI slots, lifecycle hooks, or individual builder children.
- Real examples: `ParamDecl` has `annotations`, but target validation cannot express parameter-only annotations.
- Workaround today: accept annotations only in places the current model validates, or do not validate target meaning.
- Ideal syntax direction: expand target vocabulary and make method/field/property/parameter/content distinctions explicit.
- Severity / priority: P2.
- Work type: semantic model and validation.

#### 22. Generated Members Are Metadata-Level And Function-Only

- Current state: `generated { ... }` supports functions only. The semantic model stores generated function signatures but not a full synthesized implementation body in the normal function list.
- Why it is a problem: serialization, UI state, reflection, and ORM-style APIs need generated fields, properties, constructors, protocol conformance, serializers, visitors, and sometimes real lowered bodies.
- Real examples: `tests/pass/check/game_item_generated/main.kira` uses `Serializable` and `GameItem`, but this is mostly checked shape and override metadata.
- Workaround today: generated functions as declaration metadata plus manual overrides.
- Ideal syntax direction: generated members should synthesize real declarations or require explicit macro/derivation semantics, with support for fields/properties/constructors and implementation templates.
- Severity / priority: P1 for serialization and ecosystem work.
- Work type: semantic expansion phase, type checking, lowering, docs.

### Constructs And DSLs

#### 23. Construct Sections Are Mostly Declarative Shells

- Current state: `annotations`, `requires content`, and lifecycle allowlists have semantic checks. `modifiers`, `builder`, `representation`, and custom sections are parsed/preserved but do not drive much language behavior.
- Why it is a problem: construct-defined libraries cannot really define the shape of their own DSL. Public APIs stay stuck in descriptor soup or fake builder calls.
- Real examples: `construct Widget { builder { content; } representation { children: [Widget]; } }` in declarative examples has little semantic force beyond `content` requirement.
- Workaround today: hardcode known behavior in semantics or leave sections as documentation.
- Ideal syntax direction: construct sections should define typed slots, builder result types, allowed child forms, modifiers, representation fields, and generated members.
- Severity / priority: P0 for Kira UI and DSLs.
- Work type: construct semantics, type system, lowering/model preservation.

#### 24. Lifecycle Hook Syntax Is Hardcoded To Three Names

- Current state: parser recognizes lifecycle hook starts only for `onAppear`, `onDisappear`, and `onChange`. A construct cannot introduce arbitrary hook names even if the `lifecycle` section lists them.
- Why it is a problem: frameworks need hooks such as `onMount`, `onUpdate`, `onEvent`, `onLayout`, `onDraw`, `onDispose`, `onFocus`, and graphics-specific lifecycle phases.
- Real examples: parser `isLifecycleHookStart`; tests cover invalid `onDisappear` when not declared.
- Workaround today: use one of the three hardcoded names or encode custom hooks as named rules instead of lifecycle hooks.
- Ideal syntax direction: parse hook-like members generically and let construct declarations validate names and argument schemas.
- Severity / priority: P1.
- Work type: parser and construct semantic validation.

#### 25. Only One Hardcoded `content` Section Exists

- Current state: `content { ... }` is recognized by name in construct bodies. There is no syntax for multiple named slots like `header`, `footer`, `overlay`, `toolbar`, `routes`, or `children`.
- Why it is a problem: real UI and DSL constructs need multiple typed child regions.
- Real examples: `Widget Dashboard` can only declare one `content` block.
- Workaround today: fake slots through function calls inside `content` or fields.
- Ideal syntax direction: construct-declared slots:

```kira
construct Screen {
    slots {
        header: Widget?
        content: [Widget]
        footer: Widget?
    }
}
```

- Severity / priority: P1.
- Work type: parser, construct semantic model, builder lowering.

#### 26. Builder Blocks Cannot Declare Local Values

- Current state: builder blocks contain expressions and builder `if`/`for`/`switch`. They cannot contain `let`, `var`, assignments, or local helper declarations.
- Why it is a problem: UI code often computes local display values, derived state, filters, and small helpers inside builder bodies.
- Real examples: `content { ... }` examples only call child builders and control flow.
- Workaround today: compute before the content block, or create helper functions elsewhere.
- Ideal syntax direction: allow scoped `let` and maybe `where`/`do` forms inside builders while preserving builder output type rules.
- Severity / priority: P2.
- Work type: parser, builder AST, semantic scoping.

### Classes, Structs, And Inheritance

#### 27. No Constructors Or Initializers

- Current state: type calls allocate/initialize by field order/defaults. There are no declared constructors, init blocks, validation hooks, or overloads.
- Why it is a problem: complex types need invariant checks, defaulting, computed fields, and ergonomic construction.
- Real examples: geometry types in `examples/hello/app/main.kira`; state structs in tests.
- Workaround today: positional type calls, named call labels that are not true field labels, or field mutation after blank declaration.
- Ideal syntax direction: `init(...) { ... }`, generated memberwise init, named field literals, and private init support.
- Severity / priority: P1.
- Work type: parser, semantic type model, lowering.

#### 28. Structs Cannot Have Methods

- Current state: semantic tests explicitly reject methods in `struct`.
- Why it is a problem: value types like `Point`, `Rect`, `Color`, `EdgeInsets`, `Transform`, and AST nodes naturally need methods. Forcing methods onto `class` blurs value/reference modeling.
- Real examples: `examples/hello/app/main.kira` uses `class Rect` and `class Point` even though these look like value types.
- Workaround today: use `class` for method-bearing value shapes.
- Ideal syntax direction: allow methods on structs, while keeping inheritance class-only if desired.
- Severity / priority: P1.
- Work type: semantic model, lowering, docs.

#### 29. Inheritance Exists But Conflict Resolution Is Thin

- Current state: multiple inheritance works, ambiguous inherited field/method lookup is rejected, and parent-qualified access can disambiguate. There is no aliasing, renaming, explicit conflict resolution, interface separation, or trait composition model.
- Why it is a problem: real mixins and capabilities will collide. Library authors need intentional composition tools rather than relying on ambiguity errors.
- Real examples: tests under `tests/fail/semantics/ambiguous_inherited_*` and `tests/pass/run/inheritance_multi_parent_parity`.
- Workaround today: parent-qualified access and exact overrides.
- Ideal syntax direction: traits/interfaces/protocols, `implements`, `uses`, `as`, `hides`, or explicit conflict blocks.
- Severity / priority: P2.
- Work type: type system and semantic inheritance model.

#### 30. Field Defaults Are Too Restricted

- Current state: lowering reports "Field default values in the executable pipeline currently require a literal or simple unary literal." Complex defaults and self-typed values are weak.
- Why it is a problem: real data models need defaults based on constructors, constants, arrays, nested structs, and computed expressions.
- Real examples: `kira check examples/hello` fails around `let zero: Rect = Rect(...)`; `lower_program.zig` contains the explicit default restriction.
- Workaround today: initialize inside functions or assign after declaration.
- Ideal syntax direction: constant evaluation for field defaults, static initialization phases, and constructor/default compatibility checks.
- Severity / priority: P1.
- Work type: semantic const-eval, lowering/runtime initialization.

### FFI And Native Interop

#### 31. FFI Type Syntax Is Annotation Soup

- Current state: FFI aliases, arrays, pointers, callbacks, and structs are all encoded as empty structs with annotations.
- Why it is a problem: generated bindings are huge and noisy. Human-written FFI code is hard to read and does not teach the language's type system.
- Real examples: generated Sokol binding files contain many forms such as `@FFI.Alias { target: U32; } struct sg_pixel_format {}` and `@FFI.Pointer { target: sg_desc; ownership: borrowed; } struct sg_desc_ptr {}`.
- Workaround today: rely on autobinding generation and avoid hand-writing FFI.
- Ideal syntax direction: first-class `typealias`, `extern struct`, `ptr<T>`, fixed arrays, callback/function pointer types, and C enum declarations.
- Severity / priority: P1.
- Work type: parser, type model, FFI lowerer, generator update.

#### 32. Pointer And Address Operations Are Not Source-Level

- Current state: `RawPtr` exists; pointer aliases are nominal annotated structs. There is no address-of, dereference, optional pointer, borrowing, or safe pointer conversion syntax.
- Why it is a problem: native interop cannot be both ergonomic and safe without explicit pointer forms and ownership semantics.
- Real examples: Sokol callbacks receive `RawPtr`, then cast to `app_state_ptr` by assignment.
- Workaround today: implicit coercion from `RawPtr` to pointer wrapper and manual field access.
- Ideal syntax direction: pointer/reference type forms, nullability, borrow ownership annotations, and explicit casts.
- Severity / priority: P1.
- Work type: parser, semantics, FFI/runtime safety.

#### 33. Callback User Data Is Manual And Unsafe

- Current state: FFI callbacks must be native/extern named functions. `void*` context is passed explicitly as `RawPtr`.
- Why it is a problem: every UI or graphics callback API becomes state plumbing. Captures are impossible.
- Real examples: `desc.user_data = state`; `init(user_data: RawPtr)` casts to `app_state_ptr` in Sokol examples.
- Workaround today: top-level functions plus user data fields.
- Ideal syntax direction: captured callback adapters where possible, explicit `extern c` callback wrappers where needed, and syntax to bind context safely.
- Severity / priority: P0 for app architecture.
- Work type: closure lowering, native trampoline generation, lifetime analysis.

#### 34. C Enums And Bitflags Have No Native Shape

- Current state: generated C enums appear as `@FFI.Alias { target: U32; } struct enum_name { ... }` or carrier structs with integer fields/defaults.
- Why it is a problem: graphics APIs use enums and bitflags constantly. Without enum/flags syntax, generated APIs lose readability and type safety.
- Real examples: many `sg_*` enum-like types in generated Sokol bindings.
- Workaround today: integer aliases and generated constants/fields.
- Ideal syntax direction: `enum`, `flags`, scoped enum cases, explicit C representation, and conversion rules.
- Severity / priority: P1.
- Work type: parser, type checker, FFI generator, lowering.

### Collections, Loops, And Builders

#### 35. Main Kira Has No Indexing Syntax

- Current state: KSL has `IndexExpr` and supports `particles[index]`. Main Kira AST has no index expression, although IR/runtime contain array get/set instructions used internally for `for`.
- Why it is a problem: arrays are only iterable, not directly usable as collections.
- Real examples: KSL compute example uses `particles[index]`; main Kira cannot express similar array access.
- Workaround today: loop over arrays or encode access in native/FFI helpers.
- Ideal syntax direction: `array[index]` for get/set, with bounds diagnostics/runtime behavior.
- Severity / priority: P1.
- Work type: parser, semantics, IR/backend.

#### 36. No Collection Builders, Ranges, Or Comprehensions

- Current state: array literals exist, but no ranges, comprehensions, appends, spread, slicing, or builder collection syntax.
- Why it is a problem: compiler and UI work constantly transforms lists.
- Real examples: tests use small array literals only.
- Workaround today: fixed arrays and `for` iteration.
- Ideal syntax direction: ranges, `for` comprehensions, `array.append`, slices, and maybe builder-to-array lowering.
- Severity / priority: P2.
- Work type: collections runtime, parser, semantics.

### Graphics-Oriented API Ergonomics

#### 37. Sokol App Code Is Descriptor Soup

- Current state: the Sokol proof builds descriptors by declaring locals and mutating fields line by line.
- Why it is a problem: Kira should improve over C setup code, not reproduce it. Descriptor APIs are central to graphics, UI, ECS, serialization, and app configuration.
- Real examples: `examples/sokol_triangle/app/main.kira` and `examples/sokol_runtime_entry/app/main.kira`.
- Workaround today: manual descriptor mutation.
- Ideal syntax direction: named/nested struct literals, descriptor update blocks, default descriptors, and typed builder APIs.
- Severity / priority: P0.
- Work type: initialization syntax and FFI struct lowering.

#### 38. Shader Assets Are Not Integrated With App Syntax

- Current state: KSL exists and can build graphics shaders, but Sokol app examples still embed GLSL strings directly.
- Why it is a problem: graphics apps need typed shader assets, reflection-driven binding, and compile-time validation connected to host code.
- Real examples: `shader_desc.vertex_func.source = "#version 330 ..."` in Sokol examples; `docs/ksl.md` says Kira Graphics should evolve from raw strings to `.ksl` assets.
- Workaround today: run `kira shader build` separately or embed strings.
- Ideal syntax direction: shader asset declarations, typed reflection imports, and host binding syntax based on group/resource names.
- Severity / priority: P1.
- Work type: build system, asset model, Kira Graphics API design, semantics.

#### 39. Compute Shader Surface Is Ahead Of Backend Integration

- Current state: KSL compute parses/checks. GLSL 330 build rejects compute with `KSL121`.
- Why it is a problem: the syntax exists enough to invite use, but app code cannot build/run compute assets yet.
- Real examples: `examples/shaders/particle_integrate.ksl`.
- Workaround today: keep compute as check-only or add a compute-capable backend.
- Ideal syntax direction: keep KSL compute syntax, but mark backend availability clearly and integrate with future SPIR-V/WGSL/MSL pipelines.
- Severity / priority: P2.
- Work type: backend and graphics runtime, not mostly parser.

### UI-Oriented API Ergonomics

#### 40. UI State/Binding Syntax Is Marker-Only

- Current state: examples use annotations like `@State`, `@Binding`, `@Env`, but there are no property wrappers, reactive values, binding expressions, or state access/update syntax.
- Why it is a problem: serious UI code needs state identity, binding projection, environment reads, computed view invalidation, and lifecycle semantics.
- Real examples: `examples/complex_language_showcase/app/main.kira`, `tests/pass/check/declarative_showcase/main.kira`.
- Workaround today: annotated fields with ordinary values.
- Ideal syntax direction: decide whether this is annotation-driven (`@State var count`) or dedicated syntax (`state count = 0`, `$count` binding projection), then make it semantic.
- Severity / priority: P1.
- Work type: construct semantics, runtime/UI framework, type system.

#### 41. UI Builders Do Not Have Typed Result Or Child Constraints

- Current state: `construct Widget` can require content and declare representation children, but builder children are not type-checked as a real `[Widget]` result.
- Why it is a problem: DSL users need diagnostics when they put the wrong child in a slot or omit required regions.
- Real examples: `representation { children: [Widget]; }` appears in examples but does not drive rich checking.
- Workaround today: structural parsing/check-only examples.
- Ideal syntax direction: builder result types, slot types, child constraints, and typed lowering to framework data.
- Severity / priority: P0 for UI.
- Work type: construct system and semantic model.

### Documentation And Metadata Syntax

#### 42. Documentation Is An Annotation, Not A Language Feature

- Current state: docs are modeled with `annotation Doc { parameters { text: String } }` and `@Doc("...")`.
- Why it is a problem: doc comments, markdown extraction, symbol docs, examples, deprecation, availability, and generated docs need a first-class, low-friction surface.
- Real examples: `examples/hello/app/main.kira` has long multiline `@Doc` strings.
- Workaround today: verbose `@Doc("...")` annotations.
- Ideal syntax direction: doc comments (`///`), structured doc attributes when needed, and doc generator support.
- Severity / priority: P2.
- Work type: lexer/parser trivia retention, doc tooling.

#### 43. Metadata Links In Docs Are Stale Absolute Paths

- Current state: `docs/native_libraries.md` contains absolute links under `/Users/priamc/...`.
- Why it is a problem: not a syntax gap by itself, but it shows docs drift and makes compiler-reality auditing harder.
- Real examples: native library proof links in `docs/native_libraries.md`.
- Workaround today: mentally map paths.
- Ideal syntax direction: repo-relative links and generated docs validation.
- Severity / priority: P3.
- Work type: docs cleanup.

### Compile-Time And Metaprogramming Surface

#### 44. No Compile-Time Evaluation Model For Normal Kira

- Current state: KSL has compile-time `option` values. Main Kira has annotation literal checking and field default restrictions, but no general `const`, compile-time expression, macro, or build-time reflection model.
- Why it is a problem: serialization, generated members, asset manifests, FFI binding refinement, and DSL definitions all need compile-time values.
- Real examples: annotation values are special-cased; field defaults reject non-literal expressions.
- Workaround today: encode metadata in annotations or TOML manifests.
- Ideal syntax direction: `const`, compile-time evaluable expressions, type-level reflection hooks, and constrained macro/derive mechanisms.
- Severity / priority: P1.
- Work type: semantic const-eval, compiler phase design.

#### 45. No Generic Or Type-Parameterized Surface

- Current state: Kira laws in `docs/ksl.md` reject visible angle-bracket generics, but main Kira still needs a way to express reusable containers, callbacks, serializers, result/optional, and UI state.
- Why it is a problem: without some generic-like abstraction, every library either generates many nominal wrappers or weakens type safety.
- Real examples: FFI fixed arrays and callbacks synthesize many named wrapper structs; no `Array<T>` or `Callback<T>` surface exists.
- Workaround today: nominal generated types and `[T]` arrays only.
- Ideal syntax direction: a readable non-angle-bracket type-application model, associated types, or capability-based generic constraints.
- Severity / priority: P1.
- Work type: type system, parser, semantic instantiation strategy.

## Syntax Mismatch Between Docs And Compiler Reality

1. `examples/hello` is listed as a normal quick-start example, but `zig build run -- check examples/hello` currently fails with a semantic type mismatch around `Rect.zero`.
2. `foundation/app/Types/Primitives.kira` still uses removed `type` syntax even though parser tests reject `type Old { }`.
3. `docs/language_inventory.md` says block-form annotations such as `@Doc { ... }` are part of the surface, but semantic support for blocks is effectively built-in/FFI-only. User annotation declarations do not define block schemas.
4. `docs/architecture.md` still describes the native/hybrid executable subset as much smaller than newer README/language inventory claims. This is a documentation mismatch, but it matters because syntax confidence depends on backend reality.
5. KSL compute is described as part of the source language and semantic model, correctly, but users can still hit a backend rejection when building. This boundary is documented in `docs/ksl.md`; app-facing docs should make it impossible to confuse "checks" with "builds/runs".
6. KSL has indexing syntax and main Kira does not. The two sibling languages now demonstrate different expression maturity, which is fine if intentional but should be called out.
7. Construct sections imply more semantic power than they currently carry. `builder` and `representation` look declarative, but only a small part of that model affects checking.
8. Docs and tests show generated members as a language direction, but generated members are still function-only metadata, not a complete synthesis system.

## Workaround-Driven APIs

### Sokol / Graphics Descriptors

Sokol code is the clearest syntax smell in the repo. App code declares a descriptor, assigns nested fields, then passes it:

```kira
let desc: sokol.sapp_desc
desc.init_userdata_cb = init
desc.frame_userdata_cb = frame
desc.cleanup_userdata_cb = cleanup
desc.event_userdata_cb = event
desc.user_data = state
desc.width = 640
desc.height = 480
desc.window_title = "Kira Sokol Triangle"
sokol.sapp_run(desc)
```

This is not merely verbose. It forces public APIs toward mutable descriptor structs because Kira lacks named/nested literals, defaults, field update syntax, and inline callbacks.

### FFI Callback Types

Generated callback types use empty structs plus annotations:

```kira
@FFI.Callback { abi: c; params: [I64, RawPtr]; result: I64; }
struct kira_i64_callback {}
```

This exists because Kira lacks first-class function types, pointer/function-pointer types, and type aliases. The API is distorted by syntax absence, not by domain need.

### FFI Pointer, Alias, Array, And Enum Carriers

Generated bindings synthesize many declarations such as `@FFI.Pointer`, `@FFI.Array`, and `@FFI.Alias` over empty structs. This makes generated files valid Kira, but it creates a nominal-type thicket where the language should have type forms.

### UI Builder Calls

Nested syntax like `Kit.Column("Operations") { Kit.Text("Operations") }` is exactly the direction Kira should support, but the current semantic lowering does not give trailing builders enough meaning. This risks creating UI APIs that look clean in examples but cannot yet drive real framework behavior.

### State And Binding Annotations

`@State`, `@Binding`, and `@Env` are marker annotations today. Real UI needs state identity, binding projection, environment lookup, mutation rules, and invalidation semantics. Without syntax/semantics, libraries will fake this through naming and boilerplate.

### KSL Versus Raw Shader Strings

The repo now has KSL, but Sokol examples still assign GLSL text into descriptor fields. That is a transitional workaround. The ideal graphics API should consume typed shader assets and reflection, not source strings.

### Documentation Metadata

`@Doc("...")` works, but long docs in annotation strings are clumsy. This is a workaround for missing doc comments and documentation extraction.

## Highest-Value Syntax Additions

1. Named and nested struct literals with field update syntax. This unlocks graphics descriptors, UI configuration, data modeling, tests, FFI ergonomics, and default values.
2. First-class function types plus lambdas/trailing closures. This unlocks callbacks, UI event handlers, visitors, app architecture, and higher-order library APIs.
3. Real trailing-builder semantics. This turns the existing parsed UI syntax into an actual typed DSL mechanism.
4. Static members/top-level constants and constant evaluation. This fixes `Rect.zero`-style APIs and supports clean defaults.
5. Indexing and richer collections. This closes the gap between KSL and main Kira and enables real data manipulation.
6. Enum/sum types plus pattern matching. This is critical for compiler work, UI state, event handling, and serialization.
7. Type aliases, pointer types, fixed arrays, and callback type syntax. This reduces FFI annotation soup dramatically.
8. Generalized construct slots and lifecycle hooks. This lets libraries define real DSL surfaces instead of relying on hardcoded `content` and three hook names.
9. User annotation block schemas and richer annotation parameter types. This makes metadata extensible without built-in special cases.
10. Struct methods and constructors. This makes value modeling natural and reduces misuse of classes.

## Suggested Implementation Order

1. Fix repo/compiler reality drift first.
   - Convert stale main Kira `type` uses or clearly exclude them.
   - Fix or quarantine `examples/hello` so quick-start examples check again.
   - Update docs that overstate or understate backend/language support.

2. Implement named/nested struct literals.
   - Start with parser/AST and semantic field-name validation.
   - Lower to existing struct allocation/field store IR.
   - Extend to FFI structs so Sokol descriptors improve immediately.

3. Add static constants and constant-evaluable field defaults.
   - Support `static let`.
   - Allow constructor/literal defaults where safe.
   - Re-enable geometry constants like `Rect.zero`.

4. Give trailing builder blocks semantic meaning.
   - Decide whether trailing builders become implicit final arguments, construct child lists, or builder-result values.
   - Type-check builder results against construct-declared slots.
   - Preserve child structure in HIR/model.

5. Add first-class function types and lambdas.
   - Implement non-capturing lambdas first.
   - Then captured closures for runtime code.
   - Then explicit `extern c` callback adapters for FFI.

6. Replace FFI fake type wrappers with real type syntax.
   - Add `typealias`, pointer types, fixed arrays, callback/function pointer types, C enum/flags syntax.
   - Keep annotation compatibility during migration.

7. Add indexing and collection operations to main Kira.
   - Parser support for `a[i]`.
   - Semantic type checks for arrays and future slices.
   - Lower to existing IR array get/set where possible.

8. Expand constructs.
   - General hook names, typed hook arguments, named slots, builder local declarations, and meaningful `representation`.

9. Add enums/sum types and pattern matching.
   - Begin with simple enums and exhaustive switches.
   - Add payload cases and destructuring later.

10. Add doc comments and richer annotations.
    - Use doc comments for ordinary documentation.
    - Use annotation block schemas for structured metadata.

## Appendix

### Representative Current Syntax That Works

```kira
@Main
function entry() {
    let values = [1, 2, 3]
    for item in values {
        print(item)
    }
    return
}
```

```kira
class Child extends Left, Right {
    override let value = 11

    function total(): I64 {
        return Left.doubled() + Right.tripled()
    }
}
```

```kira
Widget Dashboard(title: String, theme: ThemeConfig) {
    @State
    let selectedTab: Int = 0

    content {
        Kit.Column("Operations") {
            Kit.Text("Operations")
        }
    }
}
```

### Representative Workaround Syntax

```kira
@FFI.Pointer { target: app_state; ownership: borrowed; }
struct app_state_ptr {}
```

```kira
let state: app_state
state.viewport_width = 128
state.viewport_height = 128
```

```kira
@Native
function add_two(value: I64, user_data: RawPtr): I64 {
    return value + 2
}
```

### Compiler Limitations Observed In Code

- Main Kira AST has no index expression, no lambda, no object literal, no tuple/record/map literal, and no function type expression.
- KSL AST does have index expressions, confirming the syntax problem is not conceptually unknown to the repo.
- Main Kira semantic model has `function_ref`, but it is currently used for callback coercion rather than a general function value system.
- Generated functions in annotation/capability semantics store signatures but not general lowered bodies.
- Construct lifecycle parsing is hardcoded to `onAppear`, `onDisappear`, and `onChange`.
- Field default lowering rejects non-literal/simple unary defaults.
- Annotation parameter values are intentionally restricted to literal primitives outside built-in special cases.

### Suggested Future Audit Checks

- Add corpus cases that assert desired syntax fails today with clear diagnostics, so future work can flip them one by one.
- Add a "syntax pressure" example that rewrites the Sokol triangle using ideal descriptor literals and inline callbacks.
- Add a "real UI" example that depends on typed slots, state, binding, and trailing builder lowering.
- Add a "serialization derive" example that requires generated members beyond function signatures.
- Add a "compiler AST visitor" example that requires enums, pattern matching, function values, and collection operations.
