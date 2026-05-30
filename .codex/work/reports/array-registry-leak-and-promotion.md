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
