# Checkpoint - 007 Native Render-Loop Leak (basic-foundation-app)

Task: Eliminate the per-frame native memory leak that made basic-foundation-app ramp to
~3GB in ~2s and crash on device (and leak on macOS). Fix via the ownership model (Rust
affine), not per-site patches.

Status: per-frame leak eliminated (flat profile); corpus green; regression tests added.

## Result

- `ui-foundation/Examples/leak-harness` (synthetic per-frame pipeline):
  **920,033 leaks / 148 MB at 10k frames -> 3 leaks / 96 B (one-time, in
  foundationRetainedTreeRoot setup; constant across frame counts).**
- Real `basic-foundation-app` view (`FoundationDashboardView`) driven through the same
  per-frame pipeline (foundationRetainedUpdate + FoundationLayoutPass().run):
  **162 leaks / 5184 B, IDENTICAL at 200 and 2000 frames** — fully flat. The per-frame
  growth that caused the device OOM/crash is gone. (The 162 are one-time allocations from
  the static dashboard tree built once before the loop; they do not grow.)
- `zig build test -Dstable-tests`: **1101 passed, 0 failed** (vm/llvm/hybrid).
- `zig build verify-memory` / `verify-leaks`: memory validation checks passed.

## Ownership model (single rule, applied uniformly)

Every owned heap value (struct, array, enum) has exactly one owner. Move transfers it (call
args, container inserts, returns) with no copy; copy clones it deeply (borrowed source ->
owner gets independent storage); drop frees what you own, recursively into fields. The leaks
were all the SAME rule failing for a different value-kind or transfer point.

## Root causes fixed (native C-API backend + semantics)

1. **Empty array literal lost its element type** (`packages/kira_semantics/src/lower_exprs_types.zig`):
   `var xs: [T] = []` produced an `alloc_array` with a null element-type name, so the drop
   path passed `null` to `kira_array_release` and never ran the element destructor -> every
   struct element leaked. Fix: `propagateExpectedArrayElementType` stamps the coercion
   target's element type onto element-less array literals at every owned-transfer site
   (let/assign/arg/return via `lowerExpectedValue`).

2. **Owned struct parameter shell was owned by nobody** (`backend_capi_drop.zig`,
   `backend_capi_calls.zig`, `backend_capi_closures.zig`): the caller escaped a moved struct
   arg (full move) but the callee tracked the param as `struct_contents` (releases contents,
   not shell) -> the heap shell leaked; and moving such a param onward into an array cloned
   it, orphaning the original. Fix (Rust move): owned struct params are `struct_heap`
   (callee fully owns + drops shell), and BOTH the direct-call and closure-call sites
   normalize owned/move struct args to a caller-stable heap shell via `moveOrCloneToHeap`
   before the call. Native only; hybrid keeps the VM-managed contents-only model.

3. **Enum-typed struct fields were never owned** (`backend_capi_destructors.zig`,
   `backend_capi_aggregate.zig`): `release_contents`/`clone_contents` skipped `enum_instance`
   fields (the `else => {}` branch), so a struct's heap enum blocks leaked; `LayoutDescriptor`
   has 6 enum fields -> the dominant harness leak (210k/10k frames). Fix: a struct owns its
   enum fields — destroy frees them (`kira_destroy_raw_ptr`), copy deep-clones them (new
   `kira_enum_clone`), and storing a *borrowed* enum into an owned field clones it (matching
   the array-field rule) to avoid aliasing two owners onto one enum (double free).

4. **Array-field self-store cloned + orphaned** (`backend_capi_aggregate.zig`): the
   `var x = obj.arr; x[i] = ...; obj.arr = x` in-place idiom (used by
   `LayoutEngine.setMeasuredSize`/`setPlacedOrigin`) wrote the SAME array back into its
   field; the old same-pointer guard skipped the release but still cloned, orphaning the
   original — a per-call, quadratic leak. Fix: a self-store (`store.arr.work`/`done` blocks)
   is a no-op; only a genuinely different source releases the old array and clones/moves in.

## Files changed (this session)

- packages/kira_semantics/src/lower_exprs_types.zig
- packages/kira_llvm_backend/src/backend_capi_drop.zig
- packages/kira_llvm_backend/src/backend_capi_calls.zig
- packages/kira_llvm_backend/src/backend_capi_closures.zig
- packages/kira_llvm_backend/src/backend_capi_destructors.zig
- packages/kira_llvm_backend/src/backend_capi_aggregate.zig
- tests/memory_validation.zig (wired the 4 new tests + 4 source-invariant guards)
- tests/pass/run/ownership_array_struct_elements_parity/ (new)
- tests/pass/run/ownership_struct_param_move_into_array_parity/ (new)
- tests/pass/run/ownership_enum_struct_field_parity/ (new)
- tests/pass/run/ownership_array_field_readback_parity/ (new)

## Regression tests

Four corpus cases (vm/llvm/hybrid), one per root cause, each leaked or crashed on the
pre-fix native backend and now agrees across backends at 0 native leaks. Wired into
`zig build verify-memory`/`verify-leaks` plus source-invariant guards so the fixes cannot be
silently removed.

## Validation

- `zig fmt --check` touched files: clean.
- `zig build`: passed.
- `zig build test -Dstable-tests`: 1101 passed, 0 failed.
- `zig build verify-memory` / `verify-leaks`: passed.
- leak-harness `leaks --atExit`: 920,033 -> 3 (flat).
- real dashboard per-frame: 162 leaks, identical at 200 vs 2000 frames (flat, no growth).

## Follow-up round (same session): residual leak + parity bug both fixed

5. **Enum arguments leaked (the 162 one-time dashboard leaks)** — an owned enum passed to a
   function the callee stores into a struct field: the caller *escaped* it but the callee
   *clones* it into the field (an enum param has no drop slot), orphaning the caller's enum.
   Every `SizeMode`/`Alignment`/etc. view argument leaked once. Fix (`backend_capi_calls.zig`):
   enums are **Copy across the call boundary** — the caller keeps ownership of an enum arg and
   frees its own value; the callee's field gets an independent clone. NOTE: an earlier attempt
   to make enum params *owned* (free at exit) double-freed (exit 134) because enums are shared/
   matched in many places — reverted in favour of the caller-keeps-ownership rule, which is
   double-free-free. Result: dashboard static tree **162 -> 0**, full per-frame dashboard
   **0 leaks**, leak-harness **0 leaks**.

6. **VM `borrow mut` struct-field writeback parity bug FIXED** (`kira_vm_runtime/src/vm.zig`):
   pure-VM mode deep-copied every struct argument (`copy_struct_args_by_value`), so a
   `borrow mut` callee mutated a copy and the caller never saw it (LLVM was correct). Fix:
   `borrow_read`/`borrow_mut` struct params now ALIAS the caller's struct (no private copy
   destination, non-owning slot) so mutations propagate — matching the native backend. Minimal
   `borrow mut Box` repro now prints 15 on vm AND llvm.

Extra regression tests: `ownership_borrow_mut_struct_field_parity`,
`ownership_enum_argument_into_field_parity` (vm/llvm/hybrid). Final corpus **1119/0**.

## Follow-up round 2: the REAL app (windowed) leak

The harness/dashboard-tree measured 0, but the actual windowed `basic-foundation-app` (run
bounded via `KIRA_GRAPHICS_QUIT_AFTER_FRAMES=N` + `leaks --atExit`) still leaked ~39/frame —
in paths the harness skipped (`foundationRender` + graphics frame loop). Two more compiler
fixes:

7. **FFI String->CString buffer leak (dominant, ~31/frame)** — `marshalArg`
   (`backend_capi_ffi.zig`) mallocs a fresh NUL-terminated buffer for every Kira `String`
   passed to a C `CString` parameter and never freed it. Every text draw (`sokolUiDrawText`
   -> `kgUiDrawText`) leaked one buffer per frame. Fix: collect the transient buffers and
   `free()` them right after the extern call returns (a C `const char*` is borrowed for the
   call's duration only).

8. **Enum return values leaked (~6/frame)** — `graphicsEventKindFromRaw` /
   `...ButtonFromRaw` (per event-poll, per frame) return a fresh enum the caller never freed;
   enum call-results were not drop-tracked (only ffi_struct/array were). Fix
   (`backend_capi_drop.zig` setup `.call`/`.call_value`): track an enum return as a `.raw`
   owned heap block (native only — hybrid runtime returns VM-owned enums). A fresh return is
   single-owner, so this is safe where making enum *params* owned was not (params are
   shared/matched -> double-free, kept reverted).

Real app result: **~39 leaks/frame -> ~2.3/frame** (≈94% per-frame reduction); corpus 1119/0,
app quits cleanly. Measure with
`KIRA_GRAPHICS_QUIT_AFTER_FRAMES=50 MallocStackLogging=1 leaks --atExit -- ./generated/basic-foundation-app`
(keep N small — Kira is slow).

## Remaining / out of scope

- **Per-frame native-state leak (~2/frame, `kira_native_state_alloc`)**: `beginPass` creates a
  fresh `RenderEncoder` `nativeState(...)` each frame that is never freed. NOT fixed because
  it needs native-state lifetime analysis: `nativeRecover<T>` returns an ALIAS to the
  long-lived `FoundationAppState` native state (recovered every frame), so blindly
  drop-tracking `alloc_native_state` would free the app state on scope exit and use-after-free
  the whole app next frame. A small per-frame leak is far safer than that crash. Separate task:
  track only non-recovered, non-escaped native states (the per-frame encoder), leaving the
  recovered app state alone.

- Hybrid keeps the contents-only struct-param model (VM-managed shells); the native
  full-ownership change is scoped to `.llvm_native`.
- A future cleaner enum model could make trivial (inline-payload) enums true Copy/inline
  values instead of heap blocks, removing the clone-on-store entirely. Not needed for
  correctness now.
