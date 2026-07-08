# Incremental Native Codegen (`@Native` / LLVM backend)

Status: **landed and default-on for native executable links.** Content hashing
(`cgu_hash.zig`), the on-disk object cache (`cgu_cache.zig`), the per-function +
support module split, in-process object emission, and the full build wiring are
all implemented, unit-tested, and corpus-green. `KIRA_INCREMENTAL=0` forces the
whole-program path. See "Status: default ON" and the cold-build verdict below.

## Goal

A one-line edit to a `@Native` program should recompile only the affected
function(s), not the whole program. Target: the 30s+ full native rebuild of a
real app (Project Matter, the editor) drops to well under a second on a warm
cache.

Design: **incremental compilation + full linking.** Optimize and codegen changed
functions only; always relink the full set of objects (linking is cheap; LLD /
clang linking of a few hundred small objects is milliseconds).

## Why the whole-program build is slow

`backend.compile` → `backend_capi.buildModule` builds ONE whole-program LLVM
module (one `LLVMContext`), then `emitObjectFileViaClang` prints it to a single
`.ll` and runs `clang -O2 -c -x ir whole.ll -o whole.o`. That single clang
invocation optimizes and codegens **every** function in the program. A one-line
edit re-runs `-O2` over the entire module — for the editor, ~7s of the ~8.5s
backend time is this one external clang process.

Optimization happens in clang on the whole `.ll`, NOT via an in-process
`PassManager`. So the only way to make it incremental is to produce
**separately-compilable units** — there is no shortcut that re-optimizes just
one function inside a single monolithic clang invocation.

## Unit of caching: the per-function CGU

A codegen unit (CGU) is one Kira function. Function symbols are already unique
per function (`kira_fn_{id}_{name}` native, `kira_native_impl_{id}` hybrid) and
IDs are unique, so per-function modules never collide on the user-function
symbol.

### The support CGU

`buildModule` emits, besides user-function bodies, a set of **shared
definitions** that many user functions call:

- Per-type destructor / deep-clone helpers (`kira_release_contents_<T>`,
  `kira_destroy_<T>`, `kira_clone_contents_<T>`) — `backend_capi_destructors.zig`
  + `backend_capi_drop.zig`.
- Closure capture teardown/clone (`kira_capi_closure_release/clone`) —
  `backend_capi_closure_dtors.zig`.
- Typed enum destroy/clone — `backend_capi_enum_dtors.zig`.
- Runtime-typed dynamic dispatchers (`kira_capi_dynamic_destroy/clone`,
  state-interior release) — `backend_capi_dynamic_dtors.zig`.
- One `call_value` dispatcher per distinct signature —
  `backend_capi_dispatch.zig`.
- The named struct types, the runtime extern declarations, the two bool globals.
- The native host `main` (calls the entry function).
- Hybrid trampolines (`kira_native_fn_{id}`) per native function.

These bodies are shared and relatively few. They go in ONE **support CGU**
(`support.o`). Every per-function CGU **declares them extern** (name + type, no
body) so calls resolve against `support.o` at link time.

This split is mandatory: if per-function modules each *defined* the dtor bodies
with external linkage, the link fails on duplicate symbols; with internal
linkage, every function object carries a full copy of every helper — massive
bloat that re-optimizes the helpers on every CGU and defeats the purpose.

### Module layout per build

```
support.o          shared defs: dtors, dispatchers, struct types, runtime
                   externs, globals, host main, hybrid trampolines
kira_fn_<id>.o     exactly one user-function body; everything it references
                   (other user functions, dtors, dispatchers) declared extern
...                one object per lowered user function
```

Link: `clang support.o kira_fn_*.o <runtime helpers> <native libs> -o app`.

## Hashing (`cgu_hash.zig`) — what invalidates a CGU

A CGU's cache key is a SHA-256 over a length-prefixed framing of:

1. `codegen_format_version` — bump on ANY change to lowering/hashing that could
   alter emitted code for unchanged IR. Guarantees stale objects from an old
   compiler are never reused.
2. `CguConfig` — target triple, opt flag, backend mode (`llvm_native`/`hybrid`),
   drop-enabled. Objects built for one config must never be handed to another;
   the cache directory is also keyed by this (see below), but it is hashed too
   for defense in depth.
3. The **full reflective IR of the function** (`hashReflect` walks every field
   via `@typeInfo`, so a new IR field cannot be silently omitted from the hash).
   This is why a one-line body edit changes exactly that function's digest.
4. The **signature (not body) of every callee** referenced by the function
   (resolved from `const_function` / `const_closure` instruction ids). A callee
   *signature* change invalidates the caller (its extern decl / call type
   changed); a callee *body* change does NOT (the caller's emitted code is
   identical — only the callee's own CGU changes). This is the key property that
   makes incremental builds tight.
5. A digest of **all type layouts** (struct field types, enum shapes), sorted
   for determinism. A struct-layout change invalidates every function that could
   touch that layout — conservative but correct, since layout affects field
   offsets, sizes, and the shared dtor/clone helpers.

Unit tests assert the four load-bearing properties: body edit → exactly one CGU
invalidated; struct-layout change → users invalidated; callee signature change →
caller invalidated but callee body change → caller NOT invalidated; determinism.

The support CGU is hashed as its own unit over (version, config, all type
layouts, all dtor/dispatcher shapes, entry id). It changes when types, the set
of dtor/dispatcher signatures, or the entry point change — i.e. rarely on a
one-line body edit.

## Cache (`cgu_cache.zig`)

Content-addressed store at `<incremental_root>/<config-key>/<hexdigest>.o`.

- `config-key` = sanitized `triple-opt-mode-drop`, so debug/release/cross builds
  never collide.
- Lookup is "does `<digest>.o` exist" — content-addressed, no side index to keep
  consistent.
- `store` copies a freshly emitted object in under its digest (idempotent).
- GC is mark-and-sweep: each build `markLive`s every digest it needs, then
  `collectGarbage` deletes every `.o` not marked. Reclaims objects for deleted,
  renamed, or changed functions (their old digest is no longer live). Rename or
  delete is thus handled with no special case — the old digest simply stops
  being marked.

## Build flow (incremental path)

1. Lower to IR as today (frontend already cut from ~24s to the low seconds by
   the algorithmic fixes landed separately).
2. Compute the support-CGU digest and each function CGU digest.
3. `markLive` all of them.
4. For each digest with no cached `.o`: emit that one module (support, or a
   single-function module with extern decls) to `.ll`, run `clang -O2 -c` on
   just that unit, `store` the object.
5. For each digest already cached: reuse verbatim.
6. Link all live objects + runtime helpers → executable (always full relink).
7. `collectGarbage`.

On a one-line body edit, step 4 runs for exactly one small single-function
module; everything else is a cache hit. That is where the <1s comes from.

## Status: default ON

The split is the default for native executable links (`KIRA_INCREMENTAL` unset →
on). Set `KIRA_INCREMENTAL=0` to force the whole-program path — recommended for
cold/one-shot builds (CI, clean checkouts), which are ~2x slower when split into
per-function objects (see the verdict below). Only native executable links take
the split path; VM/hybrid/wasm and object-only/validate builds are unaffected.

Correctness gate (met):

- Full corpus (`zig build test-backends`, vm/llvm/hybrid) passes with the split as
  the default (499/0) — every case that passes whole-program passes split.
- **Golden parity test**: for representative programs, a clean whole-program
  build and an incremental (split) build must produce behaviorally identical
  binaries (same stdout / exit / leak profile). A change that only touches one
  function, rebuilt incrementally, must match a from-scratch whole-program build
  of the edited source.
- Negative: a stale object must never be reused — covered by version bump (input
  1), config keying, and content addressing.

## Measured performance and the cold-build verdict

Editor (`project-matter/apps/editor`, 1264 lowered native functions), on the
managed LLVM, objects emitted **in-process** (`LLVMRunPasses` + `EmitToFile`, no
clang subprocess, no textual-IR round trip):

| Build | Wall | Breakdown |
| --- | --- | --- |
| Whole-program (default path) | **~12 s** | frontend 3.4 s + one clang `-O2` ~8.5 s + link |
| Incremental **warm**, one-function body edit | **~4.75 s** | frontend + 1 CGU re-emitted + link |
| Incremental **cold** (empty cache) | **~26 s** | frontend 3.4 s + **emit 20.5 s** + link 0.5 s |

Cold journey while building this: 153 s (serial clang) → 48 s (parallel clang) →
35 s (in-process) → 26 s (per-CGU minimal declarations).

**Cold does not beat whole-program, and the reason is structural.** The emit
phase is ~20.5 s and is dominated by fixed *per-CGU* work — building each of the
1265 modules' scaffold (struct types, dtor/dispatcher declarations, runtime
externs, target machine) and running `EmitToFile` codegen — repeated once per
unit. Whole-program does that work once.

Crucially, **optimization is not the bottleneck.** Emit time is essentially flat
across pass pipelines (`KIRA_CGU_PASSES`): `no-op-module` 20.6 s, `default<O1>`
20.7 s, `default<O2>` 23.0 s. So a cheaper pipeline buys ~2.5 s at most — nowhere
near the ~14 s needed to reach 12 s. Link is already trivial (0.5 s) because
in-process objects skip the text round trip.

Verdict: per-function splitting inherently multiplies fixed per-unit codegen
overhead by N, so a cold build that populates the whole cache cannot beat a single
whole-program compile. The remaining levers (reuse one `TargetMachine` per worker
instead of per CGU; restrict the per-CGU type/dtor scaffold to referenced types)
would shave seconds, not cross 12 s. And cold is the wrong target: it is paid
once, after which every edit is ~4.75 s instead of ~12 s (break-even after two
edits). The incremental win is the **warm** path, which works.

## Files

| File | Role | Status |
| --- | --- | --- |
| `cgu_hash.zig` | per-function + support digests; all-signatures completeness | landed, tested |
| `cgu_cache.zig` | content-addressed on-disk store + GC | landed, tested |
| `backend_capi.zig` `buildModulePlanned` | whole-program / support / per-function via `ModulePlan` | landed |
| `backend_capi_calls.zig` `collectBodyFunctionRefs` | per-CGU declared-function set (incl. virtual/family) | landed |
| `cgu_build.zig` | split orchestrator: hash → cache → in-process parallel emit → relink → GC | landed |
| `backend.zig` `compileViaCApi` | dispatch to the split path (default on; `KIRA_INCREMENTAL=0` opts out) | landed |
