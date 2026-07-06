# Native Leak Hunting

Internal memory for diagnosing and fixing native (LLVM backend) memory leaks.
State as of 2026-07-06 (evening), after closures-are-deep-values (class #2)
and typed enum payload teardown (class #4) landed on top of the
strings-are-deep-values model (class #1) and unconditional array-ownership
free (commits `88db4a1`, `a0b2b08`, `fce1d66`; history in
`.codex/work/reports/array-registry-leak-and-promotion.md`).

## Current state

`kira_array_release` frees owned arrays unconditionally on the pure-native
path (hybrid defers to the VM's destructors). The old
`KIRA_ARRAY_OWNERSHIP_FREE` gate and its `KIRA_ARRAY_OWNERSHIP_FREE_DEV` env
hook are GONE — do not reintroduce them. The ownership model is Rust-like
move/drop elaboration, NO refcounts: one release per owned value at its drop
point, moves transfer, borrows never dropped, borrow→owned promotions
deep-clone.

**Strings are deep values** (added 2026-07-06). Native `String` is a
`{ptr,len}` LLVM value; the malloc'd byte buffer is what leaked. The model,
implemented in `backend_capi_drop.zig` / `backend_capi_drop_slots.zig`:

- Producers OWN: `c_string_to_string`, concat (`.add` on strings), every
  aggregate read (struct field, native-state slot, array element, enum
  payload — all CLONE-on-read), and every call result (a `ret` of an
  untracked source clones first; hybrid runtime-call results are cloned in
  `lowerRuntimeCall`). Each producer register gets a `string_buf` cleanup
  slot; loop overwrite drops the prior occupant; exit frees the rest.
- Consumers CLONE, never move: struct field stores (drop old buffer first,
  native only, and only through a `field_ptr`/`subobject_ptr` — `reg_field_ptr`
  provenance), native-state field sets, array set/append elements, enum
  payload boxes, closure captures, string locals (`store_local` clones into a
  per-local slot; strings are EXCLUDED from the compile-time
  register<->local map — routing them through it re-creates the enum F1
  branch-reassignment UAF).
- Aggregates own their string contents: `kira_release_contents_<T>` frees
  string fields (native only — hybrid may hold VM-written buffers),
  `kira_clone_contents_<T>` deep-copies them, `kira_array_release` /
  `kira_array_store_release` free STRING-tag element buffers, and
  `kira_array_clone` deep-copies them.
- A string aliased into a `CString` field is copied to a fresh NUL-terminated
  unmanaged buffer unless the source is a `const_string` literal
  (`reg_string_literal` provenance) — every non-literal buffer is freed by
  some slot at scope exit.

The deep-copy primitive is the generated `kira_capi_string_clone(ptr,len)`
(backend_capi_destructors.zig). Guards: `tests/memory_validation.zig` +
corpus `tests/pass/run/ownership_string_deep_value_parity/` (vm/llvm/hybrid).

Proof of the model: a 20k-iteration struct-field/concat/array string churn
program measures **0 leaks / 0 bytes** under `leaks --atExit` (previously
every concat/coercion buffer leaked).

Measured baselines (`leaks --atExit`, offscreen frames, 2026-07-06 evening
after the closure + enum-payload models):

| Program | Residual | Notes |
|---|---|---|
| ui-foundation `Examples/leak-harness` (10k frames) | 2 leaks / 224 B | unchanged, checksum 80000 |
| ui-foundation `Examples/liquid-glass-app` (120 frames) | 647 leaks / ~372 KB | ~unchanged |
| ui-foundation `Examples/basic-foundation-app` (120 frames) | 2,030 leaks / ~483 KB | ~unchanged |
| project-matter `apps/editor` (120 and 300 frames) | 9,270 leaks / ~1.19 MB | frame-flat (identical at 120 and 300); was 11,207/1.30 MB |
| editor + 10 scripted clicks (120 frames) | 9,381 leaks / 1.17 MB | **click-flat to ~11 leaks/click** (was ~1,950/click); classes #2/#3 resolved |

Closure-model proof: 20k-iteration returned-closure churn, struct-field +
array-of-closure churn (8k each), and all 12 `ownership_closure_*` corpus
cases measure **0 leaks / 0 bytes**; `ownership_string_deep_value_parity` and
`ownership_enum_string_payload_free_parity` are 0-leak too (the string case's
old 2-leak enum-box residual was class #4, now freed).

The small count increases are one-time conservative clones into structures
that are themselves still leaked (closure capture blocks, enum payload boxes,
CString field dups) — they replace aliases into buffers that also leaked
before, and they remove the use-after-free risk. ROOT `malloc in kira_fn_*`
leaks with readable string content are GONE; remaining `kira_fn_*.body` roots
are closure blocks (class #2 below).

A residual that does NOT grow with `KIRA_METAL_OFFSCREEN_FRAMES` is one-time
setup; only frame-scaling leaks are per-frame bugs. All four programs above
are now frame-flat.

## Remaining leak classes (the actual TODO)

1. ~~Native String drop gap~~ — RESOLVED 2026-07-06 (see model above).
2. ~~Closure capture leaks~~ — RESOLVED 2026-07-06. **Closures are deep
   values** (`backend_capi_closure_dtors.zig`): per-program generated
   `kira_capi_closure_release` (fn_id switch, typed capture teardown per the
   IR capture_ownership — owned/move transferred in, copy deep-cloned in,
   borrows never touched; strings always cloned/owned) installed as the
   `kira_destroy_closure` hook by an `llvm.global_ctors` constructor (covers
   dylib artifacts), and tag-safe `kira_capi_closure_clone` used by every
   consumer: struct field stores (drop-replaced, self-store guarded), struct
   clone_contents, array elements (elementDestroy/elementClone fall back to
   the tag-safe closure pair), owned call args (borrowed sources clone),
   `ret` of untracked closure sources, and raw_ptr call results tracked as
   `.closure` drops. Tag-safety (high bit) makes all of it a no-op for plain
   FFI pointers/CStrings. NATIVE only; hybrid keeps the VM hook + alias
   semantics. Guards: corpus `ownership_closure_*` (12 cases, all
   check_leaks) + memory_validation.
3. ~~Native-state interiors + type-erased (Any/construct) values~~ — RESOLVED
   2026-07-06 (evening). **Runtime-typed dynamic teardown**
   (`backend_capi_dynamic_dtors.zig`): every `kira_struct_alloc` shell carries
   a type-id header, so `kira_capi_dynamic_destroy`/`kira_capi_dynamic_clone`
   switch on it to recover `kira_destroy_<T>`/`kira_clone_<T>` for
   construct_any values (widget trees!): `[Any]` array elements
   (elementDestroy/Clone fallback), Any struct fields, Any field stores
   (drop-replaced; owned moves / borrowed clones), owned call args, `ret`
   clones, tracked call results, and `.struct_ptr` slot drops. Unknown ids
   no-op/alias — the SAME lookup decides destroy and clone, keeping the
   deep-everywhere-or-nowhere pairing. `kira_capi_state_interior_release`
   (installed as the `kira_native_state_free` hook by the same global ctor)
   walks the state payload's bridge slots per declared field type (VM
   `freeNativeState` parity); state field sets of closures/Any now clone-in +
   drop-old like strings. Native only; hybrid unchanged.
   TRAP FIXED ALONG THE WAY: `lowerConstructFamilyVirtualCall` recorded
   construct_any results a SECOND time after `lowerCall` already did —
   dropPriorOccupant destroyed the just-stored result (widget-dispatch
   use-after-free). Guard: memory_validation "does not double-record".
   Editor effect: per-click residual ~1,950 → **~11 leaks/click**; idle
   11,207 → 9,270.
4. ~~Enum payload boxes~~ — RESOLVED 2026-07-06 for string payloads. **Typed
   enum teardown** (`backend_capi_enum_dtors.zig`): per-enum generated
   `kira_destroy_enum_<T>` / `kira_clone_enum_<T>` switch on the tag and
   free/deep-copy the string-payload box + buffer. Sound because every
   destroy AND clone site dispatches typed-or-generic through the same
   `Destructors.enum_map` (`enumDestroyFn`/`enumCloneFn`) — a type is
   deep-cloned everywhere iff deep-destroyed everywhere, so the box is never
   shared into a typed free. Native only (hybrid map empty → shallow pair).
   Non-string heap payloads (nested enum/array/struct) still leak the payload
   — extend the same switch when they show up in measurements. Guard:
   corpus `ownership_enum_string_payload_free_parity` (check_leaks).
5. **Font-engine setup** (`ft_add_renderer` etc.) in ui-foundation — one-time,
   low priority.
6. **`[U8]` storage amplification** (perf, not a leak): every byte element is a
   24-byte `KiraBridgeValue`, so `readFileRange` on a 32 MB file allocates
   768 MB transiently. Needs a packed byte-array representation.

Perf note: clone-on-read means every string read out of an aggregate is a
malloc+memcpy (+free at scope exit). If profiling shows hot compare/print
loops over aggregate strings, add a borrow-only-use peephole (skip the clone
when a read's only consumers are compare/print/string_len) — do NOT skip the
clone for values that escape.

Triage rule: a leak stack rooted in `kira_fn_<id>_<KiraName>` = backend drop
gap (fix in `kira_llvm_backend`) — since 2026-07-06 these are closure blocks,
not strings. A stack rooted in a C helper (`fs_*`, `kap_*`, `kira_dynamic_*`)
= helper or call-site bug (those were all fixed 2026-07-05; regressions are
corpus-guarded).

## Where the machinery lives

- `packages/kira_llvm_backend/src/backend_capi_drop.zig` — the runtime drop
  driver (`onAlloc`/`onEscape`, `emitExitCleanup`, `moveOrCloneToHeap`,
  `prepareStructReturn`, `cloneStringValue`/`trackStringRegister`,
  `onStoreLocalString`).
- `backend_capi_drop_slots.zig` — the `setup` entry-block pre-scan that
  allocates every cleanup slot (producers, per-local enum/string slots,
  owned params) plus `seedOwnedParams`/`teardown`.
- `backend_capi_value_repr.zig` — register<->storage conversion, bridge-value
  packing, string constants/concat, compare/convert (split from codegen).
- `backend_capi_codegen.zig` — `.ret` borrowed-return clones
  (`ret.arr.clone`/`ret.enum.clone`), moved field loads (`load.move.field`),
  native-state field get/set dispatch.
- `backend_capi_aggregate.zig` — native-state boxing clones
  (`state.struct.clone`/`state.arr.clone`/enum), store_indirect
  drop-before-overwrite, array set/append element move-or-clone.
- `backend_capi_destructors.zig` — generated `kira_destroy_<T>` /
  `kira_release_contents_<T>` / `kira_clone_<T>` / `kira_clone_contents_<T>`.
- `packages/kira_native_bridge/src/runtime_helpers.c` — `kira_array_release`
  (frees; hybrid defers), `kira_array_clone`, `kira_array_store_release`,
  `kira_array_release_replaced`, `kira_destroy_closure`,
  `kira_native_state_*`.
- Move facts: `kira_semantics/src/lower_exprs_types.zig` (`applyBindingMove`
  sets `FieldExpr.moved`) → `kira_ir/src/lower_from_hir.zig` →
  `LoadIndirect.moved` / `NativeStateFieldGet.moved`.
- VM parity references: `kira_vm_runtime/src/vm_interpreter_native_state.zig`
  (box field get = borrowed, set = clone-borrowed/drop-old),
  `vm_native_layout_destroy.zig`.
- Guards: `tests/memory_validation.zig` (`zig build verify-memory`) and corpus
  case `tests/pass/run/ownership_free_state_moveout_return_parity/`.

## Tooling and commands (verified working)

Build/test:

```sh
zig build                       # refreshes the dev toolchain snapshot (~/.kira/toolchains/dev)
zig build verify-memory         # memory invariants + leak-regression backend matrix
zig build test-full             # check+build+run corpus, all backends (2040/0 baseline)
KIRA_CORPUS_FILTER=<substr> zig build test-full          # one corpus case
.codex/work/tests/run_array_registry_leak_test.sh        # C-helper alloc/free counter test
```

Gotchas:

- Executing `zig-out/bin/kira` directly can die with SIGKILL (rc=137, no
  output) in agent shells. Copy it out first: `cp zig-out/bin/kira /tmp-dir/kira_copy`
  and run the copy. `zig build run -- ...` also works.
- The corpus runner binary under `.zig-cache/o/*/kira-corpus-tests` goes STALE
  after compiler changes — invoking it directly tests the OLD compiler. Use
  `zig build test-*` (rebuilds it), or re-locate the newest with
  `ls -t .zig-cache/o/*/kira-corpus-tests | head -1` after a `zig build test-full`.
- `kira ffi autobind <project>` writes regenerated bindings into the toolchain
  SNAPSHOT, not the repo — copy changed files back to `foundation/bindings/`.
- `KIRA_CAPI_DUMP=1` did not produce module dumps through the `kira` launcher
  in testing; disassemble the built binary instead (below).

Running UI apps headless and deterministic:

```sh
KIRA_METAL_OFFSCREEN=1 KIRA_METAL_OFFSCREEN_FRAMES=120 ./generated/<app>
# scripted input: KIRA_UI_CLICK_SCRIPT="f@x,y;..." KIRA_UI_DRAG_SCRIPT / KIRA_UI_KEY_SCRIPT / KIRA_UI_SCROLL_SCRIPT
```

Leak measurement (macOS):

```sh
leaks --atExit -- ./generated/<app>                      # rc=1 when leaks found — not a crash
MallocStackLogging=1 leaks --atExit -- ./generated/<app> # adds allocation stacks
# summarize distinct origins:
grep -E "INSTANCES OF" report.txt | sed 's/.*<malloc in \([^>]*\)>.*/\1/' | sort | uniq -c | sort -rn
```

Corpus-harness leak checking (tests/leak_check.zig, macOS only): a case opts
in with top-level `check_leaks = true` in expect.toml — after its llvm run
passes, the binary is re-run under `leaks --atExit` and ANY leak fails the
case. `KIRA_CORPUS_CHECK_LEAKS=1 zig build test-full` forces the pass for
every runnable llvm case (useful as a sweep to find the next class). Negative
sanity: `KIRA_CAPI_DROP=0` + a check_leaks case must FAIL (proves the check
fires).

Compare a 120-frame vs 600-frame run: identical totals = one-time setup;
scaling totals = per-frame leak.

Crash diagnosis (double-free / UAF with freeing enabled):

```sh
# 1. Crash reports land here (rc=133 SIGTRAP = malloc abort, 139 = SIGSEGV):
ls -t ~/Library/Logs/DiagnosticReports/<app>*.ips | head -1
grep -oE '"symbol":"[^"]*","symbolLocation":[0-9]*' <report> | head

# 2. libgmalloc traps AT the misuse (page-per-allocation). Old MallocGuardEdges
#    flags are ignored by the new xzone allocator — use gmalloc:
DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib ./generated/<app>

# 3. Under lldb, scope env to the TARGET (inserting gmalloc into lldb itself
#    makes it crawl for minutes):
lldb -b -o "settings set target.env-vars DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib KIRA_METAL_OFFSCREEN=1 KIRA_METAL_OFFSCREEN_FRAMES=10" \
     -o run -o "bt 30" ./generated/<app>

# 4. Frame-pointer chains are often 3 frames deep (tail calls). Disassemble
#    around the crash offset instead:
objdump -d --disassemble-symbols='_kira_fn_<id>_<Name>' generated/<app>
# call profile of a function:
objdump -d --disassemble-symbols='_kira_fn_...' generated/<app> | grep -E "bl\s" | awk '{print $NF}' | sort | uniq -c | sort -rn
```

Guard malloc (deterministic double-free aborts, per project-matter AGENTS.md):
`MallocGuardEdges=1 MallocScribble=1 MallocErrorAbort=1` — but see xzone
caveat above; gmalloc is what actually worked.

## Reproduction targets

```sh
K=<kira-or-copy>
# near-zero baseline, fast, no GPU — first thing to run after a drop change:
$K build --backend llvm ../ui-foundation/Examples/leak-harness
(cd ../ui-foundation/Examples/leak-harness && leaks --atExit -- ./generated/leak-harness)  # expect: 80000, 2 leaks/224 B

# GPU apps (Metal offscreen):
$K build ../ui-foundation/Examples/liquid-glass-app       # expect rc=0, ~628 leaks
$K build ../ui-foundation/Examples/basic-foundation-app   # expect rc=0, ~1951 leaks
(cd ../project-matter && $K build apps/editor)            # expect rc=0, ~10.9k leaks / 1.25 MB

# backend parity for the harness (checksum 80000 on all three):
$K run <dir>; $K run --backend hybrid <dir>; native binary
# project-matter engine tests:
(cd ../project-matter && $K test tests/harness)           # expect 78/78
```

If an example fails with "import does not resolve": its `kira.toml` may lack
`kind = "app"`, and a missing `kira.lock` needs `$K sync <dir>` once.

## Definition of done for a leak fix

Backend parity (vm/llvm/hybrid agree on output), full corpus green
(`zig build test-full`), `verify-memory` green, leak-harness still
2 leaks/224 B, the targeted app's residual reduced and frame-count-flat, and a
corpus case + `memory_validation.zig` guard pinning the new rule.
