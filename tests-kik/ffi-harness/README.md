# FFI / native-bridge catch-all harness

A monolithic Kira suite of Foundation `Test` declarations that stress the
`@Native` ↔ `@Runtime` hybrid bridge in depth — struct/scalar/enum/array
returns and arguments crossing the boundary, native→VM closures, the
native→VM→native "crash sandwich", borrow/move across the bridge, and
allocation churn. 224 tests across `app/<purpose>/`:

- `structs/` — native struct return-by-value, struct-borrow into `@Runtime`,
  scalar round-trips, native→VM callback (prefix `fsb`/`Fsb`).
- `enums/` — enums returned to native, enum fields in native structs,
  payload/payload-less variants, state machines (`fen`/`Fen`).
- `collections/` — `[Int]` / arrays-of-structs across the bridge, `borrow mut`
  mutation + sync, nested array fields, churn (`far`/`Far`).
- `closures/` — native-invoked VM closures, sandwich re-entry, loop churn
  (`fcb`/`Fcb`).
- `scalars/` — Int/Bool/Float scalars, multi-hop N→R→N→R round-trips, strings
  across the bridge (`fmx`/`Fmx`).

## How to run

This suite is HYBRID-only (the `@Native` + `@Runtime` mix is rejected on pure
vm/llvm). It runs through the pure-Kira test driver, which executes each `Test`
at build time on the hybrid runtime — so the `@Native` calls bridge and the
verdict is backend-independent:

```sh
kira test --backend hybrid tests-kik/ffi-harness
```

(The pure-Kira driver is the default; `KIRA_LEGACY_TEST=1` opts back into the
historical Zig runner.)

Every test reduces a bridge exercise to a scalar and asserts it with
`Result.Ok(...)`; the comparison runs in Kira (no Zig override). See `FINDINGS.md`
for bridge bugs this harness surfaced.

## Authoring notes

- No `import Foundation` outside `main.kira` (flat package; `Test`/`Result`/
  `TestFailure` are package-wide).
- Every top-level name uses a per-domain prefix so the flat namespace stays clean.
- `test` typically returns an Int/Bool/String; struct results are now compared
  structurally by the driver (see `tests-kik/corpus/driver-structural-eq`), so a
  struct result is fine too. End with a clean trailing `return`.
- Trap-style tests (`Result.Error(TestFailure.Runtime(...))`) are not used here:
  they SKIP under the pure-Kira driver until runtime traps are catchable in Kira.
