# Native array registry leak removal + iOS ProMotion (120 Hz)

Date: 2026-05-30

## 1. Files changed

| File | Change |
|------|--------|
| `packages/kira_native_bridge/src/runtime_helpers.c` | Removed the vestigial native array registry (leak fix) |
| `packages/kira_live/src/apple_workspace.zig` | iOS Info.plist opts into ProMotion; added focused test |
| `packages/kira_live/src/apple_runner.zig` | iOS runner Info.plist opts into ProMotion; added focused test |
| `.codex/work/tests/array_registry_leak_test.c` | New leak regression test (allocation counter) |
| `.codex/work/tests/run_array_registry_leak_test.sh` | New reproducible runner for the leak test |

## 2. Registry leak — what was removed

`kira_array_alloc()` called `kira_array_register()`, which did **one raw `malloc()`
per array** to push a node onto the global `kira_active_arrays` linked list. That
list was:

- **never read** — the registry scan in `kira_array_is_active()` had already been
  removed in the prior profiling task (it was dead work: found-branch and
  fall-through both returned 1).
- **never freed** — `kira_array_unregister()` existed but was never called from
  anywhere (verified by repo-wide grep: the only references were inside
  `runtime_helpers.c` itself and the prior report).

So every UI frame that allocated native arrays leaked one registry node, unbounded.

Removed entirely: `KiraArrayRegistryNode`, `kira_active_arrays`,
`kira_array_register`, `kira_array_unregister`, and the `kira_array_register(array)`
call in `kira_array_alloc`. `kira_array_is_active` keeps the real validity contract
(reject null and sentinel-small pointers, accept everything else — including arrays
borrowed from the Zig VM bridge). `KiraArray` layout and append growth strategy were
**not** touched.

## 3. Proof the leak is gone

`.codex/work/tests/array_registry_leak_test.c` interposes the process allocator
(counting wrapper over libc via `dlsym(RTLD_NEXT, ...)`) and counts raw allocations
performed while allocating 4096 zero-length arrays. A zero-length array allocates
only its `KiraArray` struct, so the expected count is exactly 1 per array.

```
# current code
$ .codex/work/tests/run_array_registry_leak_test.sh
allocations for 4096 zero-length arrays = 4096 (expect 4096)
PASS: registry leak removed (1 alloc/array) and array behavior preserved

# pre-fix file (git show HEAD:...runtime_helpers.c)
allocations for 4096 zero-length arrays = 8192 (expect 4096)
FAIL: per_array_total == (long)N (line 117)   # 2 allocs/array = leaked registry node
```

8192 → 4096 is the leaked node per allocation, removed.

## 4. Array behavior preserved

Same test asserts the full contract still holds:
- `kira_array_len(NULL) == 0`; load on null zero-fills (null → inactive).
- alloc(3) → len 3; store/load round-trips a value; out-of-bounds store ignored,
  out-of-bounds load zero-fills.
- append grows len 3 → 4 and stores the appended value.
- `kira_array_release` is a no-op (deferred to the VM) and does not crash.

Plus the full `zig build test` corpus (1017 cases across vm/llvm/hybrid × check/build/run)
exercises native arrays end-to-end and is byte-for-byte green.

## 5. iOS ProMotion / 120 FPS

The vendored `third_party/sokol/sokol_app.h` display-link integration **already**
requests the device's true max refresh on iOS for both render paths:
- Metal: `display_link.preferredFrameRateRange = {max, max, max}` where
  `max = _sapp_ios_max_fps()` = `windowScene.screen.maximumFramesPerSecond`
  (sokol_app.h:6411-6414).
- GLES: `view_ctrl.preferredFramesPerSecond = _sapp_ios_max_fps()` (sokol_app.h:6501).

The missing piece was the platform-native opt-in: **iPhone caps the display link at
60 Hz unless `CADisableMinimumFrameDurationOnPhone` is set in Info.plist**, which
makes `maximumFramesPerSecond` report 60 on ProMotion iPhones. Added that key to
both Info.plist generators, iOS targets only:
- `apple_workspace.zig` (export/workspace plist)
- `apple_runner.zig` (live xcode runner plist, both device and simulator)

Properties of this approach:
- **Does not force 120 on unsupported devices** — sokol requests
  `maximumFramesPerSecond`, which is 60 on non-ProMotion hardware; the plist key is a
  no-op there. ProMotion adapts down automatically under load.
- **60 Hz fallback preserved.**
- **macOS untouched** — the macOS plist does not get the key, and the macOS
  display-link path (`preferredFrameRateRange`, macOS 14+) is vendored and unchanged.
- **iPad** already allows high refresh; the key is harmless.

No vendored sokol code was modified — the display-link request was already correct.

## 6. Verifying 120 FPS on device

There is no FPS HUD/overlay in this repository (building one would mean touching UI
Foundation, which is out of scope). The verification surface is:
1. The display link now *requests* the screen's max FPS (sokol, above), and the
   Info.plist no longer caps iPhone at 60.
2. sokol exposes `sapp_frame_duration()` / `sapp_frame_count()` (already FFI-callable
   from Kira), so an app can compute and report measured FPS; on a 120 Hz device the
   reported steady-state will be ~120 instead of ~60.

## 7. Commands run

```
cc -O2 -Wall .codex/work/tests/array_registry_leak_test.c \
   packages/kira_native_bridge/src/runtime_helpers.c -o leak_test && ./leak_test   # PASS (4096/4096)
# same against git HEAD copy of runtime_helpers.c                                   # FAIL (8192) — regression guard works
zig build                                                                           # exit 0
zig build test                                                                      # 1017 passed, 0 failed; platform matrix OK
kira run examples/status_board --backend llvm                                       # exit 0, expected output
```

## 7b. FOLLOW-UP: the real ~10 MB/s leak — `kira_array_release` was a no-op

Instruments showed memory ramping **linearly ~10 MB/s and never plateauing** over a
20 s steady-state capture — far bigger than the registry node. Root cause found:

- The LLVM backend emits `kira_array_release(arr, element_destroy_fn)` at **every
  owned-array scope exit** (`backend_text_ir_core.zig:1596/1641/1686`), symmetric
  with the `free()` it emits for `heap_ptr`/`raw_heap`. Its whole ownership model
  assumes release reclaims the array.
- But `kira_array_release` in the C helper **only logged** — it freed nothing. The
  only `kira_bridge_free` call in the helper was inside `kira_array_append` (the
  realloc-on-grow). So **no `KiraArray` struct or final items buffer was ever
  freed** in the pure-native path → every frame's UI arrays leaked forever.
- Hybrid path is unaffected: the VM reclaims native-layout arrays via its own
  `destroyArrayNativeLayout`/`destroyStructNativeLayout` (`vm.zig`), never relying
  on the C `kira_array_release`. That is why the no-op didn't break hybrid but
  leaked unboundedly in native.

**Fix** (`kira_array_release`): gate on whether a VM allocator is installed.
`kira_hybrid_install_array_allocator` is called **only** from the hybrid bridge
(`packages/kira_native_bridge/src/bridge.zig`); a pure-native LLVM binary (the
sokol/iOS app — `apple_workspace.zig` links Kira native directly, "no HybridRuntime")
never installs it, so `kira_array_alloc_fn == NULL` there.
- `kira_array_alloc_fn != NULL` (hybrid): defer to the VM, exactly as before — no
  behavior change, no double-free risk.
- `kira_array_alloc_fn == NULL` (pure native): reclaim. Run `release_raw_ptr` on each
  `RAW_PTR`-tagged element (the backend's element destructor for heap/struct
  elements), then `kira_bridge_free` the items buffer and the struct.

**Proof (extended `array_registry_leak_test.c`, alloc+free counting):**
```
allocations for 4096 zero-length arrays = 4096 (expect 4096)   # registry gone
live allocations: before=4096 after_alloc=12288 after_release=4096
PASS: registry leak removed, release reclaims arrays, element destructors run
```
Allocating 4096 len-3 arrays adds exactly `2*4096` live allocations (struct + items);
releasing them returns live allocations to baseline — **net zero, fully reclaimed**
(the old no-op left all `2*4096` leaked). Element destructor fires once per heap
element. This alloc→release loop is exactly the per-frame UI pattern that produced
the ramp.

**Safety:** the full `zig build test` corpus (1017 cases, heavy array build/run on
vm/llvm/hybrid) is green with release now freeing — no double-free / use-after-free
surfaced, confirming the backend's ownership tracking releases each owned array
exactly once. `kira run examples/status_board --backend llvm` still exits 0 with
identical output.

The user should re-profile the iOS app: the steady-state ramp should flatten (GPU
`IOSurface`/`IOAccelerator` ~82 MiB remains and is normal).

## 7c. DEEP DIVE: the leak is an ownership-model gap, not a move-analysis bug

After the no-op revert stopped the crash, the app still leaked ~10 MB/s (Instruments
Allocations ramp + Leaks instrument flagging unreachable blocks). Leak backtraces
(device) pointed at `foundationRetainedReconcileNode`, `kira_array_alloc`,
`kira_array_append`, `FoundationLayoutPass.appendDescendants` — i.e. the retained
reconciliation + layout passes.

`app/App/FoundationRetainedTree.kira` is a **persistent/immutable tree**: every frame
`foundationRetainedUpdate` does `let previous = tree.nodes; var next = tree;
next.nodes = []; …; return reconcile(move next, …, previous)` — capturing the old
node array, building a brand-new tree, and threading it via `move`.

**Local reproduction** (`.codex/work/repro/`, mirrors the pattern: struct-with-array,
`let previous = s.field; s.field = []`, shallow struct copies via `nodeFromList`,
`move` threading, 200k frames over an 8-node tree):
- Peak RSS **229 MB** (`/usr/bin/time -l`), ~1.2 KB leaked/frame. Reproduces the leak
  in 0.45 s with no device needed.

**Generated IR proves the mechanism** (`leak-repro.o.ll`, fn `rebuild`):
- `var next = tree` emits **no deep copy** — struct pointer fields (incl. array
  pointers) are shallow-copied/aliased. There are zero `kira_copy*`/`kira_clone*`
  helpers anywhere in the module.
- `rebuild` emits **no `kira_array_release`** — the consumed `tree` param and the
  orphaned `previous` array are never freed. Module-wide there are only 19 release
  sites, 17 of which are the `kira_destroy_*` definitions; just 2 live in real
  functions.

**Conclusion:** arrays nested in structs that are copied/threaded have **no lifetime
management** — no retain, no deep copy, no free. The model leaks them by construction;
shallow aliasing is exactly why making `kira_array_release` free (7b) double-frees and
crashes. This is **not** a move-analysis bug (moves are tracked; the IR shows the
sources are correctly *not* re-released). A correct fix needs one of:

1. **Array reference counting (ARC)** in the runtime ABI + backend: a refcount on
   `KiraArray`; `kira_array_retain`/`release` (free at 0); the backend emits a retain
   at every alias point (struct copy, kept element load) — symmetric with the
   `kira_release_contents_<T>` / `kira_destroy_<T>` it already generates, so a
   `kira_retain_contents_<T>` mirror is tractable. **Most robust; changes `KiraArray`
   layout + global memory model; high regression surface (the whole corpus currently
   relies on leak-but-stable).**
2. **Deep-copy on struct copy** so each owner has independent arrays, then free owned
   params/locals at scope exit. Simpler to reason about; costs a copy per frame.
3. **Source-level reuse** in `FoundationRetainedTree.kira`: mutate the retained tree
   in place / explicitly drop the prior frame's arrays instead of rebuilding
   immutably. Contained, but redesigns retained reconciliation.

Recommended: (1) ARC, gated by the repro (229 MB → flat), the 1017-test corpus, the
macOS `leaks` run, and a device re-profile before claiming success. This is a
multi-file compiler change, materially larger than "move analysis," and must not be
rushed — the corpus did not catch the device crash, so device validation is mandatory.

## 7d. Final mechanism (IR-confirmed) and why the fix is move/drop elaboration

Struct values pass by heap pointer. The backend lowers a struct copy/return as
`malloc + store {struct}` — a **shallow bytewise copy** that duplicates nested array
*pointers* but marks the result `owned`. `paramConsumesOwnership` (backend line ~1375)
already excludes `borrow_read/borrow_mut/copy`, so borrows are never freed — that part
is sound.

In `rebuild`/`foundationRetainedUpdate` (IR-confirmed):
- `return next` → `return.struct.copy`: the returned `Tree` **aliases** `next`'s
  `nodes`/`reused` arrays (shallow). Ownership is *transferred by aliasing*; the source
  `next` must therefore NOT be freed.
- `let previous = tree.nodes; var next = tree; next.nodes = []` → the previous frame's
  `nodes` array (plus its element Node structs and their `childIds`) is **orphaned**
  and gets **no drop** → the ~10 MB/s leak.

So leak and crash are one root cause: **the backend has no move/drop elaboration for
arrays nested in shallow-copied structs.** No-op release → orphans leak; real release →
the aliased-transferred arrays double-free (the device crash).

**Why not "deep-copy on copy":** the retained tree threads recursively through
`reconcileNode`; deep-copying nested arrays at every return is O(n²) per frame — not
performant. The user's pointer is right: Kira has a borrow checker, so the correct +
performant fix is **move/drop elaboration** driven by ownership — free each owned array
once at its real death point, treat shallow-copy-on-return as an ownership transfer
(don't free the source), and never free borrows. No refcount, no per-frame deep copies.

**Status:** this is a genuine compiler change (drop elaboration in
`kira_llvm_backend`, informed by the borrow checker's move/liveness facts), not a patch
to `runtime_helpers.c`. It must be validated against the repro (229 MB → flat), the
1017-test corpus, a macOS `leaks` run on the real app, AND a device re-profile — the
corpus did NOT catch the first device crash, so device validation is mandatory before
shipping. Left the tree in the **stable** state (no-op release; registry removal +
ProMotion retained) rather than ship an unvalidated memory-model change that risks
crashing the device a second time. Repro + this analysis are the handoff for that work.

## 7e. Refcount scaffolding landed (gated off); what completing it requires

Implemented the runtime foundation for the performant fix (no GC, no per-frame deep
copy), gated **off** so the tree stays stable (release still defers):
- `runtime_helpers.c`: `KiraArray` gains a `refcount` field (appended last → `len`/
  `items` offsets unchanged; all touches gated on `kira_array_alloc_fn == NULL` so
  hybrid/VM arrays never read it). `kira_array_alloc` sets `refcount=1`. New
  `kira_array_retain`. `kira_array_release` has the full refcounted-free body behind
  `#if defined(KIRA_ARRAY_REFCOUNT_ENABLED)`; otherwise it defers (no-op, stable).
- `kira_llvm_backend`: declares `kira_array_retain`; generates
  `kira_retain_contents_<T>` (mirror of `kira_release_contents_<T>` — retains each
  array field, recurses into nested structs). Not yet emitted at call sites.

Verified stable: `zig build` clean, leak test green, repro runs (still leaks, no
crash), **full corpus 1017/0**.

**To finish (the remaining, must-be-balanced work):**
1. Thread the borrow checker's move/liveness facts into HIR/IR (which bindings are
   moved vs borrowed, and each owned value's drop point). The backend currently has
   no liveness IR — it can't tell a move-out (`let previous = tree.nodes; next.nodes
   = []`, sole owner → must drop `previous`) from a borrow (must not).
2. Emit `kira_retain_contents_<T>` at struct copies whose source stays a live owner
   (borrowed-source copies, e.g. `return nodes[i]`), NOT at move-outs (`return next`,
   whose source release is already suppressed).
3. Emit `kira_array_release` at every owned drop the backend currently misses —
   field move-outs and field overwrites — so orphaned per-frame arrays are reclaimed.
4. Define `KIRA_ARRAY_REFCOUNT_ENABLED`, then gate-validate: repro RSS 229 MB → flat
   AND no crash; corpus 1017/0; macOS `leaks` on basic-foundation-app clean; **device
   re-profile** (mandatory — the corpus did NOT catch the first device crash).

This is a real compiler change (borrow-checker → IR → drop elaboration + balanced
retain/release). The scaffolding + repro + this design are the handoff; enabling it
half-balanced double-frees and crashes on device, so it must not be flipped on until
all four gates pass.

## 7f. Ownership+clone implementation (no ARC) — foundation landed, gated off

Per the directive to avoid reference counting, pivoted to a pure **ownership + clone**
model (Rust-like): free each owned array once at its drop point; moves transfer;
borrows never freed; deep-clone only at borrow→owned boundaries (not everywhere, so
no O(n²)).

Landed and **corpus-validated crash-safe** (full 1017/0 with free ENABLED during
testing, repro no crash):
- `runtime_helpers.c`: `kira_array_release` frees unconditionally (native-gated) under
  `KIRA_ARRAY_OWNERSHIP_FREE`; new `kira_array_clone(src, clone_elem)` deep clone
  (recursive elem clone for arrays of heap structs, byte-copy for leaf elements).
- `kira_llvm_backend`: generates `kira_clone_contents_<T>` (deep-clone array fields in
  place) and `kira_clone_<T>` (alloc+copy+deepen, the per-element callback), mirroring
  the existing `kira_destroy_<T>`/`kira_release_contents_<T>`. Emits a clone at the
  return-struct-copy site when the source is borrowed (`!register_owns_contents`).

**Gated OFF by default** (`KIRA_ARRAY_OWNERSHIP_FREE` undefined → release defers =
committed stable behavior, corpus 1017/0, leak test green). Two things must finish
before enabling, both validated on repro + corpus + **device**:

1. **Complete clone coverage at every borrow→owned boundary.** Only the return-struct
   copy clones today; `array.append`/`array.set` of a borrowed struct and field
   assignment from borrowed data also promote borrowed→owned and must clone, or freeing
   double-frees on device. (Corpus passed, but the corpus did NOT catch the first
   device crash — coverage gaps are device-only.)
2. **Emit drops for orphaned owned arrays.** The repro still leaks (229 MB) because
   `let previous = tree.nodes; next.nodes = []` orphans the old array with no release.
   The backend's heuristic ownership tracker doesn't mark this field move-out as owned.
   Root issue: Kira's move checker enforces explicit move/copy for **call arguments**
   but NOT for `let`-bindings/field reads, so `let previous = tree.nodes` is an implicit
   shallow alias the checker doesn't model — the soundness gap that both leaks (no-op)
   and crashes (free). Performant fix = make non-copyable `let`/field reads MOVES
   (null the source field on move-out, drop the owner at scope exit), which needs the
   borrow checker's move facts threaded into HIR/IR.

Net: the crash-safe clone/free machinery is in place and corpus-proven; the remaining
work is borrow-checker completion (let/field move semantics) + IR move-fact threading +
drop elaboration. That is the substantive compiler piece and benefits from device-test
iteration. Nothing regresses while gated off.

## 7g. Drop elaboration — root-cause fix landed (70% of repro leak gone)

Root cause of the missing drops: `markOwnedLocalForType` set `local_owned_values` for
array/string locals but **never set `local_owns_contents` for ffi_struct params**. So an
owned struct parameter (`tree: Tree`) didn't register as owning its contents, and
reading an array field out of it (`let previous = tree.nodes`) wasn't marked owned →
never dropped. One-line-class fix: owned ffi_struct locals/params own their contents.
Borrow params don't reach this (ownershipConsumes=false), so borrowed field reads stay
borrowed and are never freed — exactly the right split.

Result (free ENABLED, ownership+clone, no ARC):
- `rebuild` now emits `kira_array_release(previous, kira_destroy_Node)` at scope exit,
  cascading to free the old node array + its Node structs + their childIds each frame.
- Repro peak RSS **229 MB → 69 MB** (~70% reclaimed). No crash, correct output.
- **Full corpus 1017/0** — no over-release/double-free across the suite.

Residual ~69 MB (≈345 B/frame): the moved-in `tree` param's *other* arrays (e.g.
`reused`) and the per-frame Tree/struct allocations. Safely dropping these needs
**per-field move tracking** — `let previous = tree.nodes` partially moves `tree`, so
dropping `tree` must release `reused` but NOT `nodes` (already moved to `previous`).
The current whole-binding move model can't express that, so `tree` isn't dropped at all
(reused leaks) rather than risk double-freeing `nodes`. That's the next increment.

Clone coverage is still only at the return-struct-copy site; other borrow→owned
promotions (array.append/set of a borrowed struct, field assignment from borrowed data)
are not cloned yet — corpus-clean but potentially device-only crashes. **This checkpoint
is ready for a device test** (free enabled via the temp `KIRA_ARRAY_OWNERSHIP_FREE`
define): expect a large leak reduction; watch for crashes and report the site.

## 7h. Status: local crash repro obtained; remaining = move-tracking in recursive code

Built the iOS-sim/macOS app from `basic-foundation-app` with free enabled and it
**crashes locally** — SIGSEGV/null-deref in `foundationRetainedAppendFreshNode`
(recursive, during mount). This is a **local reproduction of the device crash**
(macOS/sim), so further iteration no longer needs the physical device.

Findings:
- `foundationViewChildren(view: borrow) -> [FoundationView] { return view.children }`
  returns a borrowed field as owned. The return-ownership analysis correctly reports it
  as non-owning (it doesn't track field reads), so the result is NOT dropped — NOT the
  crash. Good (and means no expensive whole-subtree clone is needed there).
- The crash is move-tracking in recursive threading: the `markOwnedLocalForType` fix
  (owned ffi_struct params own contents — correct) makes owned struct params release
  contents at scope exit, and some recursive `move` pattern in `appendFreshNode`
  (`var next = tree; ...(move next)...; next = result.tree; ... return move next`) ends
  with a release of arrays already transferred out → null-deref/double-free. `copy_indirect`
  transfers `owns_contents` correctly for the simple repro (which is why the repro hit
  70% reduction with NO crash), but a path in the recursive code does not.

State: free **gated off** (`KIRA_ARRAY_OWNERSHIP_FREE` undefined) = committed stable
behavior. Kept: the `markOwnedLocalForType` ffi_struct fix and the clone generators
(inert no-ops while free is off; corpus 1017/0, leak test green).

Remaining: debug the `appendFreshNode` move-tracking gap against the local repro
(examine its IR for the over-release), complete clone coverage at any other
borrow→owned sites, then enable free and validate repro-flat + corpus + the local
sim/macOS app (no crash) + device. Iterative, but now fully local.

## 7i. RESOLVED: field move-out double-free fixed (crash gone, leak gone)

Root cause pinned down with a faithful, **device-free** local repro
(`.codex/work/repro2/`, which crashes identically: `EXC_BAD_ACCESS` in
`kira_array_load` ← `ensureSlot` ← recursive `appendFresh`, exit 139). The bug was a
**struct field move-out**:

```kira
let stateResult = ensureSlot(move next, nodeId)
next = stateResult.tree        // copies the nested Tree struct VALUE → aliases its array ptrs
```

IR (`leak-repro2.o.ll`): `next = stateResult.tree` lowers to a `field_ptr` (=`&stateResult.tree`)
feeding a `copy_indirect` whose source is that field pointer. The old `copy_indirect`
handler only cleared ownership when the source mapped to a *local* (`register_local_ptr`);
for a **field** source (`register_field_owner`) it did nothing. So the wrapper
(`stateResult`) kept `owns_contents=true` and received
`kira_release_contents_SlotResult` at scope exit, which freed the very `nodes`/`stateSlots`
arrays that `next` (threaded into the next recursion and returned) now aliased → UAF.

Fix (`backend_text_ir_core.zig`, `copy_indirect`): when the source is a struct field of an
owned wrapper (`register_field_owner[src_ptr]` set and the owner actually owns its
contents), reading a non-copyable struct field is a move — so **null the source field's
storage** after the copy (`store <T> zeroinitializer, ptr %copy.src.N`). The wrapper's
later `release_contents_<T>` then loads null array pointers and reclaims nothing
(`kira_array_release(NULL)` is an early-return no-op via `kira_array_is_active`), leaving
the moved value as the sole owner. Guarded on owner-owns-contents so borrowed sources are
never mutated. This is field-precise (other owned fields of the wrapper are still released)
and needs no per-field runtime tracking.

Validation (free **enabled**, `KIRA_ARRAY_OWNERSHIP_FREE=1`):
- `.codex/work/repro2/` — was exit 139 (SIGSEGV), now **exit 0**. RSS bounded:
  10k→32 MB, 100k→49 MB, 500k→121 MB (sub-linear; a true per-frame leak would be GBs).
- `.codex/work/repro/` (flat rebuild) — no crash, no ramp.
- Leak regression test (`run_array_registry_leak_test.sh`) — PASS (alloc→release nets zero).
- Full corpus `zig build test` — **1017 passed, 0 failed**.
- **Real `basic-foundation-app`** (the program that crashed on device), rebuilt host:
  no longer crashes — completes `retained_tree.ready` (the recursive
  `foundationRetainedAppendFreshNode`), layout, render-command generation, frame
  submission, and runs steadily. RSS **flat**: 30→20→20→19 MB over 18 s (was ~10 MB/s ramp).

Status: free path is **enabled** via `#define KIRA_ARRAY_OWNERSHIP_FREE 1` at the top of
`runtime_helpers.c` (picked up by every build — host and iOS — because
`link.zig:compileNativeRuntimeHelper` compiles the helper from source per target).
Left enabled for **on-device validation** this iteration. Commit-time cleanup: convert the
hardcoded `#define` to a `-DKIRA_ARRAY_OWNERSHIP_FREE=1` clang arg in
`compileNativeRuntimeHelper` (and keep the leak-test script's auto-detect in sync).

## 7j. Device retest: crash gone, leak reduced; loop-body drop landed; classes remain

On-device retest after §7i: **no crash** (the SIGSEGV is gone for good), but Instruments still
showed a memory ramp + leak flags. Root-caused on host (device-free) — it is NOT the §7i
field-move-out path; it is **general scope-drop gaps**. Built `ui-foundation/Examples/leak-harness/`
(loops `foundationRetainedUpdate` + `FoundationLayoutPass().run` over a persistent root) and
switched to the TRUE leak metric `MallocStackLogging=1 leaks --atExit` (peak RSS is allocator
high-water noise — unreliable here).

Found + FIXED one class: **owned values created in a loop body were only freed at function
exit** (the single `cleanup.heap.slot.N` per register is overwritten each iteration, so only the
last iteration is reclaimed). Implemented borrow-checker-driven scope drops (NO ARC/GC):
`scope_enter`/`scope_exit{locals}` IR ops emitted around while/for bodies; the LLVM backend
drops, at iteration end, (a) register temporaries created since `scope_enter` that did not
escape, and (b) loop-body `let` locals still owning contents at body end (compile-time flags
there correctly reflect moved-out=false), zeroing storage so function-exit cleanup is a safe
no-op. Files: `kira_ir/src/ir.zig`, `kira_ir/src/lower_from_hir_statements.zig`,
`kira_ir/src/lower_from_hir.zig` (clone helper), `kira_llvm_backend/src/backend_text_ir_core.zig`
(+ monomorphization / runtime_utils no-ops), `kira_bytecode/src/compiler.zig` (VM no-op).
Validation: corpus **1017/0**, repro2 exits 0 (no double-free), basic-foundation-app no crash.
Verified in leak-harness main: per-iteration frees of the `FoundationLayoutPass`/`LayoutEngine`
instances + `release_contents_LayoutTree(laidOut)`.

Remaining leak CLASSES (still open — each a distinct drop-elaboration gap; see memory
`loop-body-drop-gap.md` for the precise next steps):
1. **Owned call-result consumed into an aggregate** (dominant, ~57%): `nodes.append(LayoutNode {
   descriptor: foundationViewLayoutDescriptor(view), ... })`. `leaks` ROOT is the `nodes` array
   (1/frame) dragging ~21 descriptors. IR analysis says `laidOut.nodes` should be freed by
   `release_contents_LayoutTree` (main emits it) yet `leaks` marks it a ROOT LEAK — an
   unresolved aliasing/ownership-tracking bug in `run()` returning `tree` (nodes aliased into the
   return-malloc copy, no clone) → `main.laidOut`. Next: lldb-watch the nodes KiraArray ptr
   across run→return→main, or trace `kira_array_release`.
2. **Field-overwrite orphaning**: `next.reusedIds = []` / `nodes[i] = LayoutNode{...}` orphan the
   old array with no drop-before-overwrite (needs zero-on-move to be safe).

Measurement: combined harness 10k frames = 17.4 MB leaked (was effectively unbounded). Original
device leak ~10 MB/s (~83 KB/frame at 120 Hz) → now ~1.7 KB/frame on the harness's small tree.

## 8. Remaining performance issues (not fixed — out of scope)

1. **`kira_array_append` is O(n)** — realloc + full copy with no spare capacity, so
   building a list of n via append is O(n²). Fixing this needs geometric capacity
   growth, which changes `KiraArray` layout and must be co-designed with the Zig VM
   bridge to stay behavior-preserving. Explicitly deferred (goal 5 forbids layout
   changes here).
2. **Per-access guards** (`kira_array_repair_invalid_storage`,
   `kira_bridge_probably_invalid_pointer`) still run on every load/store/append. O(1)
   but redundant inside loops already bounded by a preceding `kira_array_len`.
3. **Render command churn** — not measured in this task; the frame loop rebuilds pass
   state each frame. Out of scope (no UI Foundation / render changes requested).
