# Macros

Kira has two macro forms. `macro` is **declarative**: it binds expression fragments and
substitutes them into a fixed template, with no compile-time execution. `comptime macro` is
**procedural**: it is a real compile-time function that receives syntax, runs arbitrary Kira code
against it (loops, conditionals, string building, calls into the compiler reflection API), and
returns the syntax to splice in.

Both forms are a pure **frontend AST → AST transform** that runs after parsing and before
semantic analysis / HIR lowering. Expansion output flows through the normal
`kira_source -> kira_lexer -> kira_parser -> [macro expansion] -> kira_semantics -> kira_ir ->
backends` pipeline like any hand-written code, so **VM, LLVM/native, hybrid, and WASM parity is
structural**: there is no per-backend macro work. A macro can never produce code that runs on one
backend and not another, because by the time a backend sees it, it is ordinary Kira AST.

`comptime macro` *bodies* execute on the same compile-time evaluator as `comptime function`. The
reflection types (`Syntax`, `Declaration`, `Field`, `TypeRef`, `Identifier`, `Diagnostics`) are
compile-time runtime surface and are validated by their own tests; they never reach a backend.

This page documents the macro language surface. Forms below are exercised by the corpus under
`tests/pass/check/macro_*`, `tests/pass/run/macro_*`, and
`tests/fail/semantics/macro_*` / `tests/fail/parse/macro_*`.

## Invocation summary

| Form | Declared with | Invoked as | Backed by |
| --- | --- | --- | --- |
| Declarative | `macro Name(p: expr) { expand { … } }` | `Name!(arg)` | fixed template |
| Procedural, function | `comptime macro Name { kind { function } … }` | `Name!(arg)` | compile-time code |
| Procedural, attribute | `comptime macro Name { kind { attribute } … }` | `@Name` above a declaration | compile-time code |
| Procedural, derive | `comptime macro Name { kind { derive } … }` | `@Derive(Name, …)` above a declaration | compile-time code |
| Procedural, field-triggered | `comptime macro Name { kind { attribute } trigger { field } replace { true } … }` | `@Name` on a FIELD of a declaration | compile-time code |
| Procedural, wrapper | `comptime macro Name { kind { wrapper } … }` | `@Name` on a struct declares a wrapper template; the template's name on a FIELD summons the macro | compile-time code |

A trailing `!` at the call site marks every value-position macro, declarative or procedural-function
— the user always sees that arguments are *unevaluated syntax*, not values. Attribute and derive
macros attach to a declaration with `@`. `@Derive` takes a comma-separated list and runs each derive
over the same declaration.

## Fragment evaluation and ownership (the load-bearing rule)

A `macro` parameter is a **fragment**: a piece of syntax captured at the call site. Each fragment is
declared with a *kind*. v1 has two:

- `expr` — a single expression, captured **call-by-value**.
- `place` — an assignable lvalue path (a variable, field, or index target).

### `expr` is evaluated exactly once

This is the rule that makes macros compose with Kira's affine ownership instead of fighting it. An
`expr` fragment is evaluated **exactly once** at the call site into a hygienic temporary; that
temporary is then substituted at every occurrence of the parameter in `expand`. Concretely:

```kira
macro square(value: expr) {
    expand {
        value * value
    }
}

let n = square!(buildThing())
```

expands as if written:

```kira
let n = {
    let _value$0 = buildThing()   // evaluated once
    _value$0 * _value$0
}
```

`buildThing()` runs **once**, never twice — there is no C-style double-evaluation footgun, even
though `value` appears twice in the template.

Ownership is **unchanged** by macros. If the fragment's value is a non-`Copy` (owned) type and the
template *consumes* it in more than one position, that is an ordinary affine move error
(`KSEM` move diagnostics) — exactly the error the same code would produce written by hand. Macros do
not relax, hide, or duplicate ownership; they only guarantee single evaluation. The mental model is:
**`expr` macros are referentially transparent with respect to evaluation count, and transparent with
respect to ownership.**

### `place` is an assignable lvalue

Some macros need to read *and write* their arguments — `swap!` is the canonical case. Those
parameters are declared `place`. A `place` fragment is substituted as an lvalue path and is read or
written exactly where the template reads or writes it, with normal Kira semantics — the same as
hand-writing the path.

```kira
macro swap(a: place, b: place) {
    expand {
        let temporary = a
        a = b
        b = temporary
    }
}

swap!(left, right)
```

expands to:

```kira
let temporary$0 = left
left = right
right = temporary$0
```

Each side is moved exactly once, so this is a correct affine swap for owned values as well as
`Copy` ones. A `place` argument must be a real assignable path; passing a non-lvalue
(`swap!(1, x)`) is a diagnostic (`KMAC004`). Index/field paths used as `place` arguments evaluate
their sub-expressions where they appear in the template; prefer `expr` for everything that does not
genuinely need to be written through.

`ident` (a bare name) and `type` (a type reference) are reserved fragment kinds for a near-term
extension; v1 ships `expr` and `place` only.

## Hygiene

Any identifier introduced inside `expand` that is **not** one of the macro's own fragment
parameters is hygienic. Each expansion gets a fresh, compiler-generated name for it (shown above as
`temporary$0`, `_value$0`), so:

- Two separate `swap!` calls in the same function never share a `temporary`.
- A real variable named `temporary` at the call site is never shadowed or captured by the macro, and
  the macro's `temporary` is never visible to the caller.

Fragment parameters are the *only* names that cross the boundary, and they cross as the caller wrote
them, resolved in the caller's scope. This is non-negotiable: a macro cannot reach into the call
site and bind, shadow, or capture a name the caller did not pass in.

## `expand` is a block-expression

`expand { … }` is a block. Where the macro is invoked determines how it is used:

- In **expression position** (`let x = clamp!(…)`), the block's **trailing expression** is its
  value.
- In **statement position** (`swap!(left, right)`), the block's statements are spliced in place.

A macro whose `expand` ends in a statement (like `swap!`) is statement-position only; using it as a
value is a diagnostic (`KMAC005`). A macro whose `expand` ends in an expression works in both
positions.

```kira
macro clamp(value: expr, low: expr, high: expr) {
    expand {
        if value < low {
            low
        } else if value > high {
            high
        } else {
            value
        }
    }
}

let opacity: Float64 = clamp!(rawOpacity, 0.0, 1.0)
```

The trailing `if/else` is the block's value because `clamp!` is used in expression position.

A multi-statement expansion in statement position:

```kira
swap!(left, right)
// =>
let temporary$0 = left
left = right
right = temporary$0
```

## Procedural macros: `comptime macro`

```kira
comptime macro Name {
    kind { function }                       // or: attribute | derive
    appliesTo { struct, class, enum, form } // required for attribute/derive; omitted for function
    trigger { field }                       // optional: auto-apply when a FIELD carries `@Name`
    replace { true }                        // optional: output REPLACES the annotated declaration

    expand(input: Syntax) -> Syntax {       // function:  (Syntax)      -> Syntax
        body                                // attribute: (Declaration) -> Syntax
    }                                       // derive:     (Declaration) -> Syntax
}
```

`kind` is required and fixed to one of `function`, `attribute`, `derive`, `wrapper`; it
determines both the call syntax and the signature of `expand` (`wrapper` takes
`expand(target: Declaration, wrapper: Declaration)` — see the property-wrapper case study).
`appliesTo` is required for `attribute` and `derive` (it lists the declaration kinds the macro is
legal on) and omitted for `function`; `form` admits construct-backed declaration forms
(`Widget Counter(...) { ... }`). `expand` is the one member every `comptime macro` must define,
and its body is ordinary Kira run at compile time on the same evaluator as `comptime function`.

Two opt-in members extend attribute macros:

- `trigger { field }` — the macro auto-applies to a whole declaration whenever one of the
  declaration's *fields* carries an annotation matching the macro's name. This is the
  property-wrapper shape: `@State var count: Int = 0` inside `Widget Counter` summons macro
  `State` over the `Counter` declaration (the macro sees the full declaration; the field
  annotation itself is just the trigger). A field-triggered macro must also be `replace { true }`
  (KMAC029): its purpose is rewriting the declaration that carries the field.
- `replace { true }` — the macro's generated declarations REPLACE the annotated declaration
  instead of being appended alongside it. At most one replace-mode macro may apply to a
  declaration (KMAC028) — a second replacer would have no original left to observe.

### Expansion ordering and visibility

When a declaration carries several macros (`@A @B` and/or `@Derive(C, D)`):

- Every attribute and derive macro observes the **original** declaration. No macro ever sees another
  macro's output.
- Outputs are **concatenated** with the original declaration; the result order follows source order
  of the annotations.
- Because no macro sees another's output, sibling-generated blocks can never form an ordering
  dependency on each other.

### Compiler reflection API

```kira
struct Syntax {
    function identifiers() -> [Identifier]
    static function join(items: [Syntax], separator: String) -> Syntax
    // Declaration-shaped Syntax only (a value derived from `target.syntax`):
    function dropField(name: Identifier) -> Syntax                 // remove a field declaration
    function rewriteProperty(
        name: Identifier,        // the property whose uses to rewrite
        read: Syntax,            // replaces every bare, unshadowed read (e.g. `__get_count()`)
        writeCallee: Syntax,     // `name = v` becomes `writeCallee(v)`
    ) -> Syntax
}

struct Identifier {
    function asString() -> String
    // No `String -> Identifier`. See "Hygiene boundary" below — this absence is deliberate.
}

struct Declaration {
    var name: Identifier
    var fields: [Field]
    var syntax: Syntax        // the declaration's exact source text
}

struct Field {
    var name: Identifier
    var type: TypeRef
    var initializer: Syntax   // source of the initial-value expression ("" when absent)
    var syntax: Syntax        // the whole field declaration, annotations included
    function hasAnnotation(name: String) -> Bool
}

struct TypeRef {
    function asSyntax() -> Syntax
}

struct Diagnostics {
    static function error(message: String, at: Syntax)
}
```

`Syntax.rewriteProperty` and `Syntax.dropField` are *span edits* over the declaration's original
source: the machinery parses the text, walks every member body with full lexical-scope tracking
(a read is rewritten only when the property is not shadowed by a local binding, parameter,
callback parameter, for/builder-for binding, match or handler binding), and splices the
replacement text back — untouched source survives byte-for-byte, comments included. Assigning
*through* a wrapped property (`name.x = v`, `name[i] = v`) is KMAC027: the proxy has no place to
write through; read the value, mutate the copy, assign it back.

#### Hygiene boundary: no `String → Identifier`

There is **no** way to turn a `String` into an `Identifier`. A macro can only obtain an identifier
from reflection (`target.name`, `field.name`) or from a hygienic gensym introduced inside `quote`.
This is a deliberate hygiene guarantee: a macro **cannot fabricate a name from a string and use it
to capture** something at the call site. It is also why the use-site property-wrapper rewrite
(below) is compiler-owned rather than a macro — a macro literally cannot mint the `_count` / `$count`
names.

The controlled escape hatch reserved for a later version is
`Identifier.derived(base: Identifier, prefix: String, suffix: String)`, which can only *extend* an
identifier the macro already legitimately holds — never conjure one from thin air.

### `quote` and `#{ … }` splicing

`quote { … }` is a compiler intrinsic, not a function: the literal Kira syntax inside the braces
becomes a `Syntax` value instead of running. Inside `quote`, `#{ value }` splices a value in. **What
it splices to is chosen by the static type of the value, not by where it sits** — so there is no
case-by-case ambiguity:

| Static type of `value` | Splices as |
| --- | --- |
| `Syntax` | the syntax, as-is |
| `Identifier` | a bare name (usable as a binding, type name, or member access) |
| `String` | a quoted string literal |
| `Int` / `Bool` | its literal |
| `[T]` of any of the above | each element in sequence, nothing between them |

Array splicing inserts elements with nothing between them, which is correct for statement lists and
declaration bodies. Where a comma-separated list is needed (a parameter list), build it explicitly
with `Syntax.join(items, separator: ", ")` and splice the single joined `Syntax`.

The same source expression can splice two different ways by type. `target.name` is an `Identifier`
and splices bare as `Player`; `target.name.asString()` is a `String` and splices as `"Player"`.

### Function-like procedural macro

The case a declarative `macro` genuinely cannot reach — the output size depends on the input:

```kira
comptime macro bitflags {
    kind { function }

    expand(input: Syntax) -> Syntax {
        let names: [Identifier] = input.identifiers()
        var constants: [Syntax] = []
        var value: Int = 1

        for name in names {
            constants.append(quote {
                static let #{name}: Int = #{value}
            })
            value = value * 2
        }

        return quote {
            struct Flags {
                #{constants}
            }
        }
    }
}

bitflags!(Read, Write, Execute)
```

expands to:

```kira
struct Flags {
    static let Read: Int = 1
    static let Write: Int = 2
    static let Execute: Int = 4
}
```

### Attribute macro

Attached to one declaration; sees only that declaration; returns syntax added alongside it.

```kira
comptime macro Loggable {
    kind { attribute }
    appliesTo { struct, class }

    expand(target: Declaration) -> Syntax {
        var lines: [Syntax] = []
        for field in target.fields {
            lines.append(quote {
                output = output + #{field.name.asString()} + ": " + self.#{field.name}.toString() + " "
            })
        }
        return quote {
            extend #{target.name} {
                function log() {
                    var output: String = #{target.name.asString()} + " { "
                    #{lines}
                    Console.print(output + "}")
                }
            }
        }
    }
}
```

### Derive macro

Same shape as attribute, invoked through `@Derive(...)`, list-friendly.

```kira
comptime macro MemberwiseInit {
    kind { derive }
    appliesTo { struct }

    expand(target: Declaration) -> Syntax {
        var parameters: [Syntax] = []
        var assignments: [Syntax] = []
        for field in target.fields {
            parameters.append(quote { #{field.name}: #{field.type.asSyntax()} })
            assignments.append(quote { self.#{field.name} = #{field.name} })
        }
        let parameterList: Syntax = Syntax.join(parameters, separator: ", ")
        return quote {
            extend #{target.name} {
                init(#{parameterList}) {
                    #{assignments}
                }
            }
        }
    }
}

@Derive(Debug, MemberwiseInit)
struct Vec2 {
    var x: Float64
    var y: Float64
}
```

`@Derive(Debug, MemberwiseInit)` runs both and produces both `extend` blocks.

### Builtin derives shipped in Foundation

Foundation ships four derive macros written in pure Kira (`foundation/app/Derive.kira` for
`Equatable` / `Clone`, `foundation/app/DeriveSerde.kira` for `Serializable` / `Deserializable`).
All four are available as `@Derive` targets in any file that has its own `import Foundation`
(imports are file-scoped). The only user-facing top-level names they introduce are the macro
names themselves, so they cannot collide with user code. The serde pair also defines a set of
shared runtime helpers under the reserved `__kira_deser_` prefix (defined once in
`DeriveSerde.kira`) that the generated `deserialize_*` functions call; the prefix keeps them
out of the user's namespace.

| Derive | Generated free function | Contract |
| --- | --- | --- |
| `Equatable` | `function eq_<Type>(a: borrow <Type>, b: borrow <Type>) -> Bool` | structural, per-field equality |
| `Clone` | `function clone_<Type>(v: borrow <Type>) -> <Type>` | independent deep-value copy |
| `Serializable` | `function serialize_<Type>(v: borrow <Type>) -> String` | value → compact wire string |
| `Deserializable` | `function deserialize_<Type>(s: borrow String) -> <Type>` | wire string → value, traps on malformed input |

The generated function name is glued to the derived type's exact name (`eq_Point`, `clone_Point`,
`serialize_Point`, `deserialize_Point`) — a fixed contract other tooling relies on.

```kira
@Derive(Equatable, Clone)
struct Point {
    var x: Int
    var y: Int
}

@Derive(Equatable, Clone)
struct Segment {
    var from: Point      // nested derived struct: eq_/clone_ recurse
    var to: Point
    var label: String
}

let p = clone_Point(origin)            // independent copy
let same = eq_Segment(left, right)     // recurses through eq_Point on `from`/`to`
```

Field classification (shared by both):

- A **builtin scalar** field (`Int`, `Float`, `Bool`, `String`, and the sized numeric / C types) is
  compared with `!=` (Equatable) and copied by direct field read (Clone). `String` copies deeply
  under the value-string model, so a cloned struct never aliases the original's buffer.
- A field whose type is **another bare named type** is treated as a nested derived type and handled
  by recursion (`eq_<FieldType>(a.f, b.f)` / `clone_<FieldType>(v.f)`). That field's type must
  itself be `@Derive(Equatable)` / `@Derive(Clone)`; a missing `eq_X`/`clone_X` surfaces as an
  ordinary unknown-call diagnostic.

Limitations (v1):

- **Array / generic / optional field types are unsupported.** The compile-time evaluator has no
  string-slicing surface to derive an element type or synthesize a per-element loop, so rather than
  emitting broken code the macro raises a `Diagnostics.error` (`KMAC021`) naming the field.
  Detection is exact: a type is "bare" iff concatenating its identifiers reproduces its source text
  (`[Int]` → `"Int"` ≠ `"[Int]"`).
- `appliesTo { struct }` only; enums are a follow-up.

Both builtins are exercised across vm / llvm / hybrid in `tests-kik/corpus/derive` (scalar/String/
nested equality, clone independence for scalars, Strings, and nested structs, combined
`@Derive(Equatable, Clone)`, and a user-defined derive macro running alongside them). The
not-a-derive-macro path (`KMAC011`) is pinned by `tests/fail/semantics/macro_derive_not_a_macro`.

#### `Serializable` / `Deserializable`

These two build on the value-String primitives (`String(x)`, `s.count`, `s.charAt`, `s.substring`,
`s.indexOf`) to expand into ordinary Kira that serializes a struct to a compact string and parses it
back. Because expansion is a frontend pass, the generated parser/printer is identical Kira on every
backend.

**Wire format (v1)** — compact, deterministic, single line:

```
TypeName{field1=VALUE;field2=VALUE;...}
```

with these grammar productions per field type:

| Field type | `VALUE` production | Example |
| --- | --- | --- |
| `Int` | `String(x)` — optional leading `-`, then decimal digits | `n=-42` |
| `Bool` | `true` / `false` | `flag=true` |
| `Float` (Serializable only) | `String(x)` — shortest round-trip decimal | `ratio=0.5` |
| `String` | the text wrapped in `"` (see the escaping caveat below) | `label="hi"` |
| nested `@Derive` struct | `serialize_<FieldType>(x)`, recursed inline | `from=Point{x=1;y=2}` |

Deserialization is the exact inverse. It validates the leading `TypeName{`, then for each field in
declaration order locates `label=`, carves the value with a **brace-aware scanner** (a top-level `;`
or `}` — one at brace-depth 0 — terminates the value, so a nested struct's own balanced `{…}` with
internal `;` is consumed whole), converts by field type, and consumes the `;` / `}` delimiters. A
nested struct value is handed to `deserialize_<FieldType>` on its balanced-brace substring.

**Malformed input traps.** Any structural violation — wrong type name, a missing `=` / `;` / `}`,
truncated text, or a non-digit where an `Int` is expected — drives an out-of-range `charAt` or an
inverted `substring`, both of which the runtime turns into a hard trap on every backend. There is no
partial or best-effort parse: a value either round-trips or the program traps deterministically.

**Round-trip law.** For every value `v` of a supported type,
`deserialize_T(serialize_T(v)) == v` field-wise (asserted with `eq_T` from `@Derive(Equatable)`).

```kira
@Derive(Equatable, Serializable, Deserializable)
struct Point { var x: Int; var y: Int }

let wire = serialize_Point(Point { x: 1, y: -2 })   // "Point{x=1;y=-2}"
let back = deserialize_Point(wire)                  // Point { x: 1, y: -2 }
```

Limitations (v1):

- **Supported field types are `Int`, `Bool`, `String`, and nested `@Derive` structs, plus `Float`
  for `Serializable` only.** `Float` is **rejected by `Deserializable`** with a `Diagnostics.error`
  (`KMAC021`) — there is no lossless `Float` parsing primitive, so rather than ship a lossy parser
  the macro refuses the field. Array / generic / optional (non-bare) field types are rejected by
  both, exactly as `Equatable` / `Clone` do (`KMAC021`, bare-type detection identical).
- **String values are not escaped in v1.** A `String` field whose text contains `"`, `;`, or `}` is
  **out of contract** — no error is raised (kept simple), but the wire string is then ambiguous and
  will not round-trip. Escaping is a follow-up.
- `appliesTo { struct }` only; enums are a follow-up.

Both are exercised across vm / llvm / hybrid in `tests-kik/corpus/derive-serde` (exact-string
serialization of scalar / negative / String / Bool / empty-String / nested structs; deserialization
from literals; the round-trip law for flat, negative, String, empty-String, Bool, and nested values;
and malformed-input trap guards for a garbage prefix, truncated text, a wrong type name, a non-digit
`Int`, and an unquoted `String`).

### `@Derive(Copy)` — the builtin copyability assertion

`Copy` is a **compiler builtin**, not a Foundation macro: it generates no code and produces no free
function. It is the Kira analog of Rust's `#[derive(Copy)]` lang item — an *opt-in assertion* that a
type is structurally copyable, checked at compile time.

Kira already classifies `Copy`-ness automatically and structurally: a type is `Copy` when every
field / variant payload is `Copy` (scalars and other `Copy` aggregates), and it *moves* the moment
it gains a heap-owning field (`String`, an array), an opaque payload (a callback, native state), or
anything that transitively contains one. That classification is silent — adding one such field flips
a type from copy to move at every call site with no signal at the declaration. `@Derive(Copy)` makes
the contract explicit and enforced:

- On an **eligible** (structurally copyable) type, `@Derive(Copy)` is a **no-op**: it compiles and
  the type behaves exactly as before. It grants no new powers — the automatic classification of the
  type (and of every unannotated type) is unchanged.
- On an **ineligible** type, `@Derive(Copy)` is a **compile error** (`KIR005`, `type is not
  copyable`, raised in the mid-IR lowering/ownership pass). The diagnostic names the first offending
  field or variant payload and its type, and its help suggests removing the derive (let it move),
  borrowing, or giving the type an explicit `Clone`-style duplication.

```kira
@Derive(Copy)                 // ok: every field is a scalar -> eligible, assertion holds
struct Point {
    var x: Int
    var y: Int
}

@Derive(Copy)                 // error[KIR005]: type is not copyable
struct Label {                //   `Label` derives `Copy`, but its field `text` has type
    let id: Int               //   `String`, which is not copyable (it owns heap storage), so
    let text: String          //   `Label` moves rather than copies.
}
```

The check is transitive: a struct whose field type is itself non-`Copy` (e.g. a nested struct that
owns a `String`) is rejected at the nested member. Enums are covered too — `@Derive(Copy)` on an
enum verifies every variant payload is copyable.

`Copy` composes with the Foundation derives: `@Derive(Copy, Equatable)` runs the builtin assertion
*and* generates `eq_<Type>`. Because `Copy` is recognized before the user-macro lookup, it never
trips the not-a-derive-macro path (`KMAC011`).

Coverage: `tests-kik/corpus/derive-copy` exercises the eligible/no-op cases (scalar struct combined
with `Equatable`, fieldless enum, and Copy-field reuse proving no move) across vm / llvm / hybrid;
the rejection cases (`String` field, array field, non-copyable enum payload, nested transitive
non-copyable) are pinned by `tests/fail/pipeline/derive_copy_*`.

## Case study: property wrappers (where the macro line falls)

`PropertyWrapper` is an ordinary attribute macro. It validates that the annotated struct has a
`wrappedValue` member, records whether it also has `projectedValue`, and generates conformance
query functions for the type:

```kira
comptime macro PropertyWrapper {
    kind { attribute }
    appliesTo { struct }

    expand(target: Declaration) -> Syntax {
        var hasWrappedValue: Bool = false
        var hasProjectedValue: Bool = false
        for field in target.fields {
            if field.name.asString() == "wrappedValue" { hasWrappedValue = true }
            if field.name.asString() == "projectedValue" { hasProjectedValue = true }
        }
        if hasWrappedValue == false {
            Diagnostics.error("PropertyWrapper requires a wrappedValue field", at: target.syntax)
            return quote { }
        }
        return quote {
            function is_#{target.name}_propertyWrapper() -> Bool { return true }
            function has_#{target.name}_projectedValue() -> Bool { return #{hasProjectedValue} }
        }
    }
}

@PropertyWrapper
struct State {
    var wrappedValue: Int
    var projectedValue: Bool
}
```

The conformance is surfaced as free functions whose names are glued to the annotated type via a
mid-identifier splice (`is_#{target.name}_propertyWrapper` → `is_State_propertyWrapper`), because
Kira `extend` applies only to *constructs* — not plain structs — and Kira has no `static` members,
so the `extend T: Conformance { static let ... }` shape is not expressible here. The behaviour is
identical in spirit: the macro sees one declaration, validates it, and emits a Bool-returning
conformance surface derived from its fields. This exact macro is exercised end-to-end across
vm / llvm / hybrid in `tests/pass/run/macro_property_wrapper` (with the missing-`wrappedValue`
diagnostic, `KMAC021`, pinned by `tests/fail/semantics/macro_property_wrapper_missing`).

The full property-wrapper feature is `kind { wrapper }` — one macro defines the *protocol*, and
every wrapper type is an ordinary annotated struct:

```kira
comptime macro PropertyWrapper {
    kind { wrapper }
    appliesTo { form }    // what a wrapper may rewrite when summoned by a field

    expand(target: Declaration, wrapper: Declaration) -> Syntax { … }
}

@PropertyWrapper
struct State {
    var wrappedValue: Wrapped     // `Wrapped` = the macro's placeholder for the field's type
    var key: String = ""

    function get() -> Wrapped { …storage read…  }
    function set(value: Wrapped) { …storage write… }
}

Widget Counter() {
    @State var count: Int = 0      // works because State IS a @PropertyWrapper
    body { /* bare `count` reads, `count = v` writes */ }
}
```

Machinery semantics of `kind { wrapper }`:

- Annotating a struct with the macro's name registers it as a wrapper **template** and runs the
  macro's *validation invocation* — `expand(template, template)` (`target.name == wrapper.name`
  discriminates the path). The macro validates the protocol (`wrappedValue`, …) and may emit
  conformance declarations. The template itself is then **removed from the program**: it may
  carry placeholder types (`Wrapped`) and is never compiled as-is. Templates are registered in a
  pre-scan, so declaration order between packages never matters.
- A field annotated with a registered template's name summons the macro over the enclosing
  declaration — `expand(target = the form, wrapper = the template)` — and the output **replaces**
  the form. One summon per template per declaration; the macro loops over the wrapped fields.

Inside the rewrite path the macro *monomorphizes* the template per wrapped field with
`Syntax.replaceIdentifier` (whole-identifier textual substitution, string literals and comments
untouched): rename `State` → `__pw_Counter_count` (including internal self-references such as
`nativeRecover<State>`), substitute `Wrapped` → the field's declared type — so **any field type
works** without generics. It then emits per-property get/set accessor functions that construct
the monomorphized wrapper (seeded with the field's initializer and an `"Owner.property"` key) and
rewrites the form with `dropField` + `rewriteProperty`. Storage policy lives entirely in the
wrapper struct's own `get`/`set` — Kira UI's `State` persists through an ambient native slot so
widget state survives per-frame rebuilds; the compiler knows nothing about any of it.

The generated names (`__pw_Counter_get_count`, …) are deterministically derived by splice gluing —
not hygienic gensyms — because the rewritten uses must name them. The whole protocol is exercised
across vm / llvm / hybrid in `tests/pass/run/macro_wrapper_state` (validation conformance,
Int + String state side by side, reads/writes rerouted, shadowed locals untouched); the
standalone `trigger { field }` + `replace { true }` machinery is pinned separately by
`tests/pass/run/macro_field_trigger_rewrite`.

## Diagnostics

| Code | Condition |
| --- | --- |
| `KMAC001` | unknown macro at a `!` call site |
| `KMAC002` | wrong fragment count at a `!` call site |
| `KMAC003` | `expr`/`place` fragment kind mismatch (e.g. non-expression for `expr`) |
| `KMAC004` | `place` fragment given a non-assignable argument |
| `KMAC005` | statement-only macro used in expression position |
| `KMAC006` | `comptime macro` missing `kind`, or `kind` not one of `function`/`attribute`/`derive` |
| `KMAC007` | attribute/derive macro applied to a declaration kind not in `appliesTo` |
| `KMAC008` | `appliesTo` present on a `function` macro, or absent on attribute/derive |
| `KMAC009` | `#{ … }` splice of a type with no splice rule |
| `KMAC010` | macro recursion/expansion-depth limit exceeded |
| `KMAC011` | `@Derive(X)` where `X` is not a `derive`-kind macro |
| `KMAC012` | `comptime macro` `expand` signature does not match its `kind` |
| `KMAC016` | a function macro used in statement position whose expansion does not parse as statements |
| `KMAC017` | a function macro used in expression position whose expansion is not a single expression |
| `KMAC025` | `Syntax.dropField` on a field that does not exist |
| `KMAC026` | `Syntax.dropField`/`rewriteProperty` on a value that is not a declaration |
| `KMAC027` | assignment through a wrapped property path (`name.x = v`, `name[i] = v`) |
| `KMAC028` | more than one replace-mode macro (or wrapper summon) on one declaration |
| `KMAC029` | a `trigger { field }` macro that is not `replace { true }` |

## Implementation status

**Declarative `macro` — implemented and parity-verified.** Lexing (`macro` keyword), parsing
(`macro Name(p: expr|place) { expand { ... } }` and `name!(args)` calls), and the AST→AST expansion
pass (`packages/kira_build/src/macro_expand.zig` + `macro_instantiate.zig`) are complete. The pass
runs at every frontend entry (`compileFileToIr`, `checkFileFrontend`, `checkPackageRoot`) before
semantics. Covered by `tests/pass/run/macro_declarative` (vm + llvm + hybrid, all green) and the
negative cases `tests/fail/semantics/macro_{unknown,arg_count,place_not_lvalue,stmt_only_as_value}`.

Current declarative limitations (each produces a clear diagnostic, never silent or wrong):

- A macro used in expression position must have a template whose trailing item is a real
  *expression*. The `clamp` example above ends its `expand` in an `if/else`; Kira `if` is a
  *statement*, so that template currently raises `KMAC005`. Making it work needs block/if
  expressions (a separate language feature), at which point no macro change is required.
- Invoking a macro from inside another macro's template (`KMAC015`) is not yet expanded.
- Template bodies support let / assignment / expression / return / if / for / while; other
  statement forms raise `KMAC014`.

**Procedural `comptime macro` — derive and attribute macros implemented and parity-verified.** A
focused compile-time tree-walking evaluator (`packages/kira_build/src/macro_eval.zig`) runs the
`expand` body at compile time over `Value`s, with `Syntax` modeled as Kira source text:
`quote { ... }` renders to source (filling `#{}` splices by value type) and the expansion pass
re-parses the result with `parser.parseSource` and splices the generated declarations. Implemented
reflection surface: `Declaration.{name,fields,syntax}`, `Field.{name,type}`, `Identifier.asString`,
`TypeRef.asSyntax`, `Syntax.join`, array `.append`/`.len`, and `Diagnostics.error`; plus `for`/`if`/
`while`, `let`/`var`/assignment, Int/Bool/String arithmetic and concatenation, and `quote`/`#{}`.

Invocation: `@Derive(A, B)` runs each derive macro over the original declaration; `@Name` runs an
attribute macro; both strip their annotation and append the generated declarations. Validated across
vm/llvm/hybrid in `tests-kik/harness/app/macros/MxxMacroTests.kira` (`MxxDeriveFieldCount`,
`MxxDeriveSum`, `MxxAttributeMacro`).

**Function-position** procedural macros (`name!(args)` backed by code, e.g. `bitflags`) are
implemented in **all three positions**:

- **Top level** (declaration position): a `name!(args)` item parses to a `macro_invocation`
  declaration, the arguments are rendered to source as the macro's `Syntax` `input`, and
  `expand(input)` runs and splices the generated declarations. Validated by `MxxFunctionMacro`.
- **Statement position**: the expansion is re-parsed as a statement list and spliced in place of the
  `name!(...)` call (`KMAC016` if the output does not parse as statements). Procedural macros emit
  raw source and are **not** hygienic, so generated names bind in the caller's scope by design.
  Validated by `MxxFuncMacroStmt`.
- **Expression position**: the expansion must re-parse as a single expression, which becomes the
  value (`KMAC017` otherwise). Validated by `MxxFuncMacroExpr`.

`input.identifiers()` lexes the argument text.

`quote` splices glue by **source adjacency**: `mxp_#{name}` (no space before `#{`) renders as a
single identifier `mxp_Foo`, while `a + b` keeps its spaces. Validated by `MxxSpliceGlue`.

Attribute/derive macros apply to `struct`, `class`, **and `enum`** declarations; an enum's variants
surface through `target.fields` (`field.name` is the variant name, `field.type` its payload type or
empty). `appliesTo` is enforced: applying a macro to a declaration kind not in its `appliesTo` list
reports `KMAC007`. Validated by `MxxEnumDerive`.

Procedural limitations (clear behavior, no fake success):
- Evaluator coverage is the documented reflection surface; an unsupported construct in an `expand`
  body reports `KMAC020` rather than miscompiling.

## Parity and execution notes

- Expansion is a frontend pass producing ordinary AST; **all backends are unaffected and identical
  by construction**. No `vm`/`llvm`/`hybrid`/`wasm` split exists in macro handling.
- `comptime macro` bodies run on the compile-time evaluator (the VM used for `comptime function`).
  The reflection API is compile-time-only runtime surface; it is not lowered to any backend and is
  covered by dedicated tests.
- Expansion has a depth limit (`KMAC010`) to bound recursive and mutually-recursive macros.
- Declarative `macro` performs **no** compile-time execution; it is pure template substitution with
  single-evaluation `expr` semantics and hygiene.
