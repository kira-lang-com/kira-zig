# 006 — Consuming receivers and the move-only Any model

## Summary

This work completed the native move-only ownership model for type-erased
(`some`/`any`) values — the "checker-enforced move-only Any" roadmap item in
`.codex/KIRA_MEMORY_MODEL.md` §9. It destroyed every corpus-visible native memory
leak, then unblocked the `project-matter` editor build (previously rejected by
the move-only-Any checker) by implementing consuming receivers plus the
Any-move flows the editor exercises.

Two validation gates are green end to end:

- `zig build test-full` — full corpus, vm/llvm/hybrid parity.
- `KIRA_CORPUS_CHECK_LEAKS=1 zig build test-full` — the same corpus with every
  LLVM binary re-run under `leaks --atExit`: **2292 passed, 0 failed**.
- `zig build verify-memory` — invariant guards, green.

`../ui-foundation/Examples/leak-harness` measures **0 leaks / 0 bytes** (was
2/224 before enum-call-result tracking). The `../project-matter/apps/editor`
builds, runs, is frame-flat under offscreen frame sweeps, and no longer
double-frees; residual leaks dropped from ~9,270 to a few hundred one-time
setup allocations.

## What landed

### 1. Native leak classes destroyed

- **Enum call results.** Plain, closure, and hybrid call results are tracked
  and typed-destroyed (the returned-enum invariant: every call yields a fresh
  owned block). `enum_map` now also registers enums whose payload is itself a
  heap-owning enum, so nested chains (`Result → RenderFailure → String`) free
  fully.
- **Native-state boxes.** A C-runtime registry plus an `atexit` teardown frees
  surviving state tokens (VM `deinitTrackedNativeStates` parity). Enum state
  slots are owned (destroy-replaced + typed interior release); struct slots
  store the shell pointer directly instead of re-boxing it (the boxing pack was
  orphaning one shell per store).
- **Widget/Any trees.** A new per-function *fresh-Any return analysis*
  (`backend_capi_fresh_any.zig`) proves when a callee returns a freshly built
  tree on every path; those plain-call results are tracked as `.struct_ptr`
  drops and runtime-typed-destroyed. This reclaims `body`/factory widget trees
  without cloning.

### 2. Rust-parity partial moves

A binding may reach scope exit with fields moved out when every moved field's
type transfers by pointer with storage nulling — arrays, enums, and Any values.
Bytecode format `KBCA` carries a `moved` flag on `load_indirect`; the VM voids
the field slot, the LLVM backend nulls it. `KSEM107`/`KIR003` are relaxed for
those transferable field kinds; a moved struct field still blocks the drop
(struct reads copy with aliasing Any interiors). The four
`ownership_let_field_alias_*` negative tests became leak-gated positive
partial-move tests.

### 3. Consuming receivers (body-consumes-self)

A construct-declaration method marked `@Consuming` — and every synthesized
`body` accessor implicitly — takes its receiver **owned** (the Rust `self`
receiver). Every concrete implementation inherits the owned receiver so virtual
dispatch stays uniform. The decision lives in `methodConsumesSelf`
(`lower_shared_construct_queries.zig`) and is consulted identically at all four
header/lowering registration sites plus the mid-IR family fallback.

Receiver transfer at the call site (`lower_exprs_receivers.zig`):

- owned local receiver → implicit move (no `move` keyword for method calls);
- `self.field` receiver → partial move (field slot nulled);
- borrowed receiver carrying Any storage → **KSEM157** (with a KIR002 mid-IR
  backstop);
- borrowed plain-struct receiver → deep clone into the callee.

A body block's `{ content }` capture becomes a partial move out of owned self.
Tracked Any values MOVE through consuming dispatch — `moveOrCloneToHeap`'s
`.struct_ptr` case hands the shell over and nulls the slot rather than running a
per-dispatch runtime-typed clone (which would deep-copy a widget tree per call).

VM and hybrid needed **zero** backend changes — their owned-param machinery
already handled owned receivers, strong evidence the model composes.

### 4. Editor-unblock Any-move flows

Enabling Any teardown exposed three aliasing patterns that previously leaked
silently and now would double-free. Each was closed as a **move**, never a
clone:

- **Owned-array element drain.** `widgets[index].lower(ctx)` on an owned
  `[any Widget]` drains the element: `array_get moved` tombstones the source
  slot to VOID (VM `kira_array_take` / LLVM `kira_array_take`), so the array's
  release skips it. Bytecode `KBCA` carries the flag.
- **`For`-builder re-emit.** `For(child in children) { child }` (the
  `EdOpenMenuTap` content-forward shape) drains each element out of the source
  array instead of aliasing it.
- **Single→array content forward.** `SurfaceBox(...) { content }` where a single
  `content` field feeds an array-content widget as `[content]`: the Any field
  read into the array element is a partial move out of self.

One shared helper (`markAnyFieldMovedIntoOwned`) drives the partial-move
marking for construct-literal fields, owned call arguments, and array elements.

## Files split (Core Law #5)

- `backend_capi_returns.zig` — return-value ownership promotions, extracted from
  `backend_capi_codegen.zig`.
- `lower_shared_construct_queries.zig` — construct-surface ownership queries,
  extracted from `lower_shared.zig`.
- `lower_exprs_receivers.zig` — consuming-receiver bookkeeping, extracted from
  `lower_exprs_members.zig`.

## Guards added

`tests/memory_validation.zig` pins: the fresh-Any analysis existence, the
tracked-Any MOVE (no per-dispatch clone), the partial-move marking at all three
sites, the `For`-builder drain, and leak-gated corpus cases for the
wrapper/drain/for-reemit/single-to-array patterns.

## Known follow-up (not addressed here)

**Editor interaction frame rate (~40 fps under interaction).** The frame driver
(`ui-foundation/App/RunFoundationApp.kira`) is not naive: idle frames re-present
the cached GPU batch, and layout is retained/incremental
(`foundationRetainedUpdate`). But every input-event batch — including each
scroll frame — re-runs `buildRoot()`, reconstructing the entire widget tree
(thousands of individual `kira_struct_alloc`/free). Enabling Any teardown made
that per-frame churn heavier (the tree is now freed each frame instead of
leaked). Scrolling a viewport rebuilds the whole tree just to change an offset.

Candidate directions, in rough leverage order: a scroll-offset-only fast path
(apply scroll as a transform/clip without rebuilding), arena-allocating the
per-frame tree (bump alloc, free the whole frame in O(1) — the "arena trees"
idea in `.codex/KIRA_MEMORY_MODEL.md` §9), or caching the rebuild when only the scroll
offset changed. Measure first with `KIRA_METAL_BENCH=1` (idle re-present) vs
`KIRA_METAL_BENCH=1 KIRA_METAL_RESIZE_BENCH=1` (rebuild path) to confirm the
rebuild is the bottleneck before committing to a rearchitecture.

## Sibling-repo changes (separate repos, committed there, not in kira-zig)

- `kira_ui/app/WidgetModel.kira` — `Widget.lower` is now `@Consuming`;
  `loweredChildren` takes its `[any Widget]` by value (drained).
- `project-matter/modules/editor/app/Editor.kira` — FPS overlay re-enabled
  (`showFpsOverlay: true`).
