---
name: working-with-kira
description: >
  Write Kira and prove it. One source, many backends (vm / llvm-native / hybrid /
  wasm); parity is sacred. Syntax, structs/enums/classes, closures, ownership
  (Rust affine), FFI + native-state, attempt/handle, the Foundation `Test`
  construct, the `kira` CLI. Read BEFORE writing/editing a `.kira` file, adding a
  backend/runtime feature, or claiming a change works.
  Trigger: "write kira", "edit .kira", "new kira project", "validate kira",
  "kira for / cast / FFI / nativeState / Test", "kira run / build / check / test".
---

## Parity = the law
Same source, all backends agree: `vm`, `llvm` (native), `hybrid`, `wasm32-emscripten`. `--backend vm|llvm|hybrid` works on `run`/`build`/`check`; default from `kira.toml` `[defaults] execution_mode`. **VM has no FFI** → libs using Kira Graphics / UI Foundation need `hybrid`/`llvm`. DONE = works (or rejected with a diagnostic) on every targeted backend, not one.

Project: `kira.toml` (`[package] name/version/kind/module_root`, `[defaults] execution_mode`) + `app/main.kira` holding `@Main`.

## Core syntax
- `let` immutable, `var` mutable; type optional (`let n: I64 = 3`). `@Main function main() { ...; return }`, `function f(a: Int) -> Int {}`.
- Types: `Int Float Bool String Void`; width ints `I8…U64`; floats `F32 F64`; `RawPtr CString CBool`. Cast `Int(x) U64(x) F32(x)…` = same-kind identity at runtime; Int auto-widens into wider param (cast often needless).
- Annotations: `@Main @Native @Runtime @FFI.Extern @State @Printable`.
- Methods inside struct/class body, implicit `self`: `struct Point { var x: Int; function sum() -> Int { return self.x } }`; build `Point { x: 1 }`.
- `@Printable` → define `onPrint() -> String`; `print(v)` dispatches.
- Arrays `[T]`: `var xs: [Int] = []`, `xs.append(3)`, `xs.count`, `xs[0]`, `for v in xs {}`. Struct may own array field.
- Imports: `import Foundation` (bare → names in scope), `import X as Y`. Top-level names globally unique (dup=KSEM003); don't import Foundation twice.

## Enums + match
```kira
enum E { InvalidFormat: String = "def"   // single payload + default
         UnexpectedEnd }                  // payload-less
let e = E.InvalidFormat                   // qualified outside match
match e { InvalidFormat(t) -> ...; UnexpectedEnd -> ... }  // unqualified inside, payload bound
```
`match` exhaustive (missing/dup-arm diagnostics). `Result<Value,Failure>` = canonical 2-variant (`Result.Ok(v)`/`Result.Error(f)`). Fieldless enums are Copy.

## Classes / inheritance
`class` adds inheritance over `struct`. `class Child extends Left, Right { override let value = 11; function t() -> I64 { return Left.doubled() + Right.value } }` — multi-parent, `override` field default, parent-qualified field/method access, exact-signature overrides; parity across backends.

## Closures
Type `(Int) -> Void`; value `{ x in ... }`; trailing-callback `app.onFrame { frame in ... }` (binds as final fn arg), zero-param `app.tick { in ... }`. Capture: `let` by value, `var` as shared-mutable; nested/multiple share by lexical scope, all backends. Non-Copy capture into escaping closure = KSEM117 (reject).

## Control flow
`if/else`, `while`, `x ? a : b`, `break/continue/return` — standard. `switch x { case 1 { ... } }` (brace block, not `->`). Range `for i in start..end`: half-open Int (`0..5`→0..4), `i` immutable, empty if `start>=end`; replace `var i=0; while i<n{…;i+=1}` with `for i in 0..n{}`. `..` valid only in for slot.

## attempt / try / handle
Linear `Result` unwrap with `try` keyword (NOT `?`); desugars to `match` on vm/hybrid.
```kira
attempt { let v = try render(); print(v) }
handle { MissingNode(r) { print(r) }  InvalidState(r) { print(r) } }  // brace per variant
```
`try expr`: Ok → value flows on; Error → jump to matching handle (binds payload). Diagnostics: try-outside-attempt, try-on-non-Result, missing/unknown handle case, incompatible failure enums.

## Ownership = Rust affine
Non-Copy MOVES on use; use-after-move = compile error. `move expr` consumes into callee/container. Params: `borrow T` (read alias), `borrow mut T` (mutable alias + writeback), untagged = owned/consumed. Prefer `borrow` on hot read paths (avoid deep copy). Invalid code must fail compile, not crash.

## FFI / native
```kira
@Native function doNative(user_data: RawPtr, v: I64) -> I64 {}
@FFI.Extern { library: kira_runtime; symbol: kira_dynamic_write_f32_at; abi: c; }
function dynWriteF32At(ptr: RawPtr, offset: U64, value: F32): Void;
```
Native state: `nativeState(S{...})` → `nativeUserData(s)` → later `nativeRecover<S>(tok)`. Cost: `nativeRecover` materializes the whole struct each call; struct-array marshal across `@Native` = deep copy O(fields×elems), flat `[Float]`/raw buffer = cheap memcpy; closures don't survive nativeState round-trip (pass via `borrow` app). Per-element crossing is the cost — batch into one span/bulk FFI call.

## CLI
`kira new <name>` · `kira add <pkg>` · `kira check [--backend b] <path>` (analyze, fast) · `kira run` (build+exec) · `kira build` (native/wasm artifact) · `kira test <path>` (run `Test` decls) · `kira fetch-llvm` (before llvm/native). `<path>` = dir, manifest, or single `.kira`.

## Test
```kira
Test SumsRange {
    test { var s = 0; for i in 0..5 { s = s + i }; return s }   // must end with trailing return <scalar>
    expect { let e: Result<Int, TestFailure> = Result.Ok(10); return e }
}
```
`import Foundation` once; `kira test` must end "0 failed". Reduce each test to a SCALAR (Int/Bool/String) — runner compares scalars only. `return` solely inside a match/if arm infers Void → KSEM031 (use a `var out` accumulator). Trap test: `expect { ... Result.Error(TestFailure.Runtime("")) }` passes iff body traps.

## Catches (don't guess from Rust/Swift/TS)
- Keyword is `function`, never `fn`/`func`/`def`. No `pub`/`void`/`mut` keyword (use `var`). Return type accepts both `-> Int` and `): Int` (colon common); omit for Void.
- **No `++`/`--`/`+=`/compound assign** — write `i = i + 1`. Count up with `for i in 0..n`.
- **No string `+` concat, no `"\(x)"` interpolation** — text via `@Printable onPrint()` or pass values straight to `print`.
- **No builtin null/nil/optional** — model absence with your own enum or `Result`; `None` only exists if declared.
- Inside a method fields are bare (`value`) or `self.x`. Array API is `.append`/`.count`/`xs[i]` — not push/len/size; typed-uninit decl `var xs: [Int]` is allowed.

## Gotchas
- `print` block-buffered → output LOST when stdout redirected and host exits without flush. Use pty (`script -q F kira run …`), trust exit code, or runtime log markers (they fflush).
- `zig build` refreshes the `~/.kira/toolchains/dev` snapshot `kira` runs from — only matters when working on Kira itself.
- KIR001 "not executable in current backend pipeline" = lowering gap; `kira check` names construct+span.
- Headless env may SIGKILL (137) GUI/graphics `kira run`; validate with `kira check` + `kira test` instead.
