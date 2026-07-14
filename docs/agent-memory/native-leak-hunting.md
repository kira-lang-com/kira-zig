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

2026-07-10 re-measurement (worktree with partial moves + consuming receivers,
reports in kira-zig `.codex/tmp/editor-leaks-{120,600}.txt`):

| Program | Residual | Notes |
|---|---|---|
| project-matter `apps/editor` (120 and 600 frames) | **428 leaks / ~297 KB** | byte-identical at 120 and 600 frames — fully frame-flat |

The entire §3 widget-tree/Any conservative residual is ABSENT in this build:
zero `kira_struct_alloc` roots, zero closure blocks, zero enum payload boxes.
What remains is one-time setup only: ~83% FreeType/text-engine
(`kira_text_face_load` tree ~247 KB — class #5), ~16.5% Metal host objects
(pipelines/shaders/samplers/queues via `metalContextAlloc` and friends —
`kira_dynamic_alloc` appearing there is the graphics context block, NOT a §3
widget leak), plus ~1.2 KB of dispatch-source retain cycles and one 48 B
font-path string clone held by font-load state.

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

Late-night follow-up (2026-07-06): the post-model `apps/editor` add-entity
19–33 GB blow-up was **not** another Any/construct ownership regression.
The remaining growth split into two sibling-repo issues:

- `kira-graphics` Metal offscreen runs were missing the per-frame autorelease
  pool that the on-screen loop already drains; multi-pass runs (`apps/deferred`,
  editor gizmo pass) therefore held autoreleased command-buffer / encoder
  objects until process exit and inflated physical footprint.
- `project-matter` editor world-save serialization bounced the growing `[U8]`
  buffer through owned return values (`edPushLine` / `edIntLine`), which on the
  native editor save path regressed into giant transient `kira_array_append`
  allocations after add-entity clicks. Rewriting the serializer to mutate the
  destination buffer in place removed that spike.

Measured with the fixed sibling code paths: `apps/deferred`
`KIRA_METAL_OFFSCREEN_FRAMES=200000` stays flat (~174 MB at 0 s and 5 s),
editor no-click `120` frames stays flat (~72–73 MB), and editor add-entity
click runs complete end-to-end (`120` frames returns a real readback value;
`5000` frames samples 305 MB at 5 s and falls back to ~67 MB by 20 s instead
of growing toward tens of GB). Re-run `leaks --atExit` separately for updated
residual counts; the key result here is that the runaway growth path is gone.

## 2026-07-10: corpus-visible drop gaps + task runtime destroyed

Forced sweep (`KIRA_CORPUS_CHECK_LEAKS=1 zig build test-full`) is green again
at 2373/0 after fixing, on the async worktree:

- **Array-of-enum element teardown**: `Destructors.elementDestroy`/`elementClone`
  (backend_capi_destructors.zig) got an enum branch routing RAW_PTR-tagged enum
  elements to the typed `kira_destroy_enum_<T>`/clone pair (was: tag-safe
  closure no-op → whole element + payload leaked). Guard: kik harness
  `EmxArrayEnumStringPayloadFree` churn test (memory_validation pins it).
- **Enum payloads that own heap**: `backend_capi_enum_dtors.zig` extends typed
  destroy/clone beyond string payloads to `.ffi_struct` (free/clone via the
  struct's typed pair) and `.construct_any` (destroy via
  `kira_capi_dynamic_destroy`; the CLONE arm TRAPS — a contains-any enum is
  move-only per KIR002, so a clone is unreachable and must stay loud). The
  shared `payloadOwnsHeap` filter drives destroy, clone, and the `needs_typed`
  gate so pairing stays sound. Fixed `field_override_enum_payload_defaults`
  and `enum_kind_split_cache_parity`.
- **@FFI.Array struct fields are INLINE `[count x element]` C storage** (see
  fieldStorageType): the old store path fed the inline bytes to
  `kira_array_store_release` as a (null) array handle — a silently lost store
  that orphaned the cloned element shell. Real fix: FFI-array fields yield
  their ADDRESS (lower_from_hir_places `isFfiFixedArrayType`), and
  `lowerFfiFixedArraySet`/`Get` (backend_capi_aggregate.zig) GEP into the
  inline storage, release-replacing old element contents and cloning in
  (value semantics; no escape). `backend_capi_struct_dtors.zig`
  (`ffiArrayElement`) SKIPS these fields in release/clone — nothing
  array-shaped to free, and the closure fallback must not read element bytes
  as a pointer.
- **Rejected array stores**: `kira_array_store_release` on a null/inactive
  array or out-of-range index dropped the OWNED incoming element on the floor;
  it now releases it through the same typed paths (native only). This was the
  last leak in `ffi_nested_fixed_array_assignment` (store into a zero-init
  @FFI.Array field).
- **Native task runtime** (runtime_helpers.c): every spawned `KiraTask` leaked
  permanently (calloc'd, never freed — joined/detached/cancelled alike), and
  the ready-queue array was never freed. Now: `kira_task_registry` owns every
  spawn, atexit teardown frees survivors + unrun ctx/frames + queue storage,
  preserving the tasks-alive-until-exit duplicate-join trap semantics. Same
  fix on the (currently uncalled) Zig `kira_async_*` surface
  (async_runtime.zig live-task registry + executor deinit). Guard corpus:
  `task_spawn_lifecycle_leak_parity` (joined/cancelled/detached/dropped).
- Destructor body builders split out per Core Law #5:
  `backend_capi_struct_dtors.zig` (was inside backend_capi_destructors.zig).
- **Nested arrays (`[[T]]`)**: elements are RAW_PTR-tagged inner KiraArray*
  that fell through to the closure no-op. `backend_capi_array_dtors.zig`
  generates typed wrapper pairs `kira_destroy_arr_<K>`/`kira_clone_arr_<K>`
  per bracketed element name (collected transitively at build(), declare-only
  aware, folded into cgu_hash), dispatched from elementDestroy/elementClone.
  Plus: `lowerArraySet` overwrite dtor now derives from the ARRAY's type (not
  the source element's), and `move obj.field` on an array field tags the read
  `.moved` (was a double-free once inner arrays actually freed). Guard: kik
  `ColxNestedArrayFree`.
- **Enum `.array` payloads** (`Result<[Int], E>.Ok`): moved-in KiraArray*
  released via `kira_array_release` + typed element dtor in
  `kira_destroy_enum_<T>`, deep-copied via `kira_array_clone` in the clone —
  `payloadOwnsHeap`/`needs_typed` extended to `.array`. Was the kik-harness
  genRange class (22 leaks). Guard: kik `EmxArrayPayloadEnumFree`.

Sibling repos, same session: ui-foundation `NativeLibs/Text/kira_text.c` got
an engine/face registry + atexit sweep (faces before engines; explicit destroy
unlinks) — the class #5 FreeType tree is gone (95 leaks/156 KB → 0 on the
font repro). kira-graphics released transient Metal descriptors/compile
options/functions at creation and completed `metalContextFree` (pipelines,
libraries, samplers, depth, command queue, registry block; device singleton
deliberately NOT released) — metal_triangle 63/18 KB → 0/0, 9/9 self-tests.

The last 48 B (the font-path string clone, initially misread as a by-design
state-store leak) was an **extern-call escape bug**: `lowerExternCall`
(backend_capi_ffi.zig) escaped EVERY argument, including a String marshalled
to a `CString` parameter — but the C side only ever sees the transient NUL
dup (freed after the call), never the Kira buffer, so escaping the string
orphaned one read-clone per extern call with a string arg. The escape loop
now skips string→CString args; the caller's string_buf slot frees the clone
at scope exit. Guard corpus: `ffi_extern_cstring_arg_leak_regression`
(hybrid+llvm, check_leaks, 100×3 extern probes).

Dev-loop gotcha discovered on the way: `.kira-build` case caches do NOT
invalidate when the dev toolchain snapshot is rebuilt under the SAME version
(2026.07.2) — a post-`zig build` `kirac build` can hand back a binary from
the OLD compiler. `rm -rf <case>/.kira-build` before measuring a compiler
change through kirac directly (corpus `zig build test-*` is unaffected).

End-of-session measurements: forced corpus sweep **2370/0**, kik harness
llvm binary **0 leaks / 0 B** (1162/0 tests, vm/llvm/hybrid checksums
identical), ui-foundation leak-harness 0/0, project-matter editor
**0 leaks / 0 B** (offscreen 120 frames). No known remaining native leaks
anywhere in the stack.

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
3. **Type-erased (Any/construct) values — MOVE-FIRST model** (final form
   2026-07-06 night; authoritative spec: `.codex/KIRA_MEMORY_MODEL.md`). The first
   attempt (eac1445) made Any values full deep values — typed
   `kira_capi_dynamic_destroy`/`kira_capi_dynamic_clone` at every edge. The
   destroys were fine; the CLONES deep-copied whole widget trees on every
   borrowed store/return/struct copy — a measured multi-GB-per-click memory
   explosion in the editor. ROLLED BACK and replaced with move-first:
   - Any values MOVE (escape) into struct fields, `[Any]` elements, enum
     payloads, native-state slots, and owned call args; borrows alias.
     `kira_capi_dynamic_clone` has NO call sites (memory_validation forbids
     them per file).
   - Runtime-typed destroy runs ONLY at single-owner points: `.struct_ptr`
     slot drops (construct-family virtual-call results — recorded exactly
     once in the vcall postlude, NOT in lowerCall — and owned Any params) and
     `kira_capi_state_interior_release` for owning state-slot kinds
     (string/array/struct/closure; enum/Any slots skipped).
   - Any struct fields / elements / state slots are never freed: documented
     conservative leaks (bounded per tree node per rebuild) until the checker
     enforces move-only Any flows (`.codex/KIRA_MEMORY_MODEL.md` roadmap 1).
   TRAPS PINNED: double-record of vcall results (dropPriorOccupant destroyed
   the just-stored result — widget-dispatch use-after-free); state-set of Any
   must ESCAPE the owned source (frame-exit free would dangle the state).
   The remaining 19–33 GB add-entity blow-up was traced to sibling
   `kira-graphics` / `project-matter` code, not to this Any model; only the
   post-fix residual leak counts still need a fresh `leaks --atExit` pass.
4. ~~Enum payload boxes~~ — RESOLVED 2026-07-06 for string payloads; extended
   2026-07-10 to struct + construct_any payloads and array-of-enum elements.
   **Typed enum teardown** (`backend_capi_enum_dtors.zig`): per-enum generated
   `kira_destroy_enum_<T>` / `kira_clone_enum_<T>` switch on the tag and
   free/deep-copy owning payloads — string box + buffer, nested enum block,
   struct shell + contents (`kira_destroy_<T>`/`kira_clone_<T>`), and
   construct_any trees (`kira_capi_dynamic_destroy`; that variant's CLONE arm
   TRAPS — contains-any enums are move-only per KIR002, so no clone site can
   reach it). The `payloadOwnsHeap` filter is shared by destroy, clone, and
   the `needs_typed` gate. Arrays of enums tear down/clone typed too:
   `Destructors.elementDestroy/elementClone` resolve enum element types
   (`arrayEnumElement`, native only — RAW_PTR-tagged enum elements previously
   fell through to the tag-safe closure no-op and leaked block + payload).
   Sound because every destroy AND clone site dispatches typed-or-generic
   through the same `Destructors.enum_map` (`enumDestroyFn`/`enumCloneFn`) —
   a type is deep-cloned everywhere iff deep-destroyed everywhere, so the box
   is never shared into a typed free. Native only (hybrid map empty → shallow
   pair). Guards: corpus `ownership_enum_string_payload_free_parity` +
   `enum_kind_split_cache_parity` (check_leaks); kik harness
   `EmxArrayEnumStringPayloadFree` / `EmxStructPayloadEnumDefaultsFree` /
   `EmxConstructAnyPayloadEnumChurn` Tests + enumsSection churn.
   Related 2026-07-10 fix: `@FFI.Array` fields are INLINE fixed C storage —
   element get/set now lower to real inline accesses
   (`lowerFfiFixedArraySet/Get` in backend_capi_aggregate.zig; place lowering
   returns the field ADDRESS via `isFfiFixedArrayType`). The old path fed the
   inline bytes to `kira_array_store_release` as a bogus array handle: silent
   lost store + orphaned element clone (the ffi_nested_fixed_array_assignment
   leak). Guards: that corpus case (check_leaks + read-back stdout) and kik
   ffi-harness `FfaInlineArrayStoreReadback`/`FfaInlineArrayChurn`.
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
- `kira ffi autobind` regenerates bindings for the current project
  SNAPSHOT, not the repo — copy changed files back to `foundation/bindings/`.
- `KIRA_CAPI_DUMP=1` did not produce module dumps through the `kira` launcher
  in testing; disassemble the built binary instead (below).

Running UI apps headless and deterministic:

```sh
KIRA_METAL_OFFSCREEN=1 KIRA_METAL_OFFSCREEN_FRAMES=120 ./.kira-build/<app>
# scripted input: KIRA_UI_CLICK_SCRIPT="f@x,y;..." KIRA_UI_DRAG_SCRIPT / KIRA_UI_KEY_SCRIPT / KIRA_UI_SCROLL_SCRIPT
```

Leak measurement (macOS):

```sh
leaks --atExit -- ./.kira-build/<app>                      # rc=1 when leaks found — not a crash
MallocStackLogging=1 leaks --atExit -- ./.kira-build/<app> # adds allocation stacks
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
DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib ./.kira-build/<app>

# 3. Under lldb, scope env to the TARGET (inserting gmalloc into lldb itself
#    makes it crawl for minutes):
lldb -b -o "settings set target.env-vars DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib KIRA_METAL_OFFSCREEN=1 KIRA_METAL_OFFSCREEN_FRAMES=10" \
     -o run -o "bt 30" ./.kira-build/<app>

# 4. Frame-pointer chains are often 3 frames deep (tail calls). Disassemble
#    around the crash offset instead:
objdump -d --disassemble-symbols='_kira_fn_<id>_<Name>' .kira-build/<app>
# call profile of a function:
objdump -d --disassemble-symbols='_kira_fn_...' .kira-build/<app> | grep -E "bl\s" | awk '{print $NF}' | sort | uniq -c | sort -rn
```

Guard malloc (deterministic double-free aborts, per project-matter AGENTS.md):
`MallocGuardEdges=1 MallocScribble=1 MallocErrorAbort=1` — but see xzone
caveat above; gmalloc is what actually worked.

## Reproduction targets

```sh
K=<kira-or-copy>
# near-zero baseline, fast, no GPU — first thing to run after a drop change:
$K build --backend llvm ../ui-foundation/Examples/leak-harness
(cd ../ui-foundation/Examples/leak-harness && leaks --atExit -- ./.kira-build/leak-harness)  # expect: 80000, 0 leaks/0 B (2026-07-06 evening: was 2/224 before enum-call-result tracking)

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
(`zig build test-full` — and since 2026-07-06 the stronger gate
`KIRA_CORPUS_CHECK_LEAKS=1 zig build test-full` is fully green: 2247/0),
`verify-memory` green, leak-harness at 0 leaks/0 B, the targeted app's
residual reduced and frame-count-flat, and a corpus case +
`memory_validation.zig` guard pinning the new rule.

## 2026-07-06 evening status

Every corpus-visible native leak class is destroyed; the forced leak sweep is
green across all 2247 cases. Landed (uncommitted worktree): enum call-result
tracking + nested enum typed destroy; native-state token registry + atexit
teardown, owned enum state slots, direct (unboxed) struct slot stores;
fresh-Any return analysis for plain-call widget-tree results; Rust-parity
partial moves (bytecode KBCA `moved` flag, VM void + LLVM null, KSEM107/KIR003
relaxed for array/enum/Any fields); enum struct-field drop-before-overwrite;
moved heap-shell free. See `.codex/KIRA_MEMORY_MODEL.md` (§5 state boxes, §3
fresh-Any, §9 roadmap).

NEXT: construct `body` must consume self so `{ content }` captures are partial
moves — KIR002 currently rejects wrapper-widget bodies (kira_ui EdFlex), which
blocks `(cd ../project-matter && kira build apps/editor)`. Design decision:
extension-method self is an owned existential, type-method/body self is
`borrow`; render(borrow self) must be able to invoke body with ownership.
Sibling fix already applied: kira_ui/WidgetModel.kira `loweredChildren`
widgets param is now `borrow [any Widget]`, and KiraUI.kira's
`let root = app.content` compiles via partial moves.

## 2026-07-06 late: body-consumes-self (consuming receivers) landed

`@Consuming` construct-family methods + implicitly-consuming `body` accessors
take self OWNED; implementations inherit; dispatch transfers the receiver on
every backend (VM needed zero changes — fillTransferredArgs/bindArguments
already implement owned params; LLVM needed the moveOrCloneToHeap
`.struct_ptr → MOVE` case, else each dispatch deep-cloned the tree). Body
content channels (`{ content }`) partial-move out of owned self
(applyConstructAnyFieldMove tags the read `.moved`; note construct literals
have TWO field loops in lower_exprs_calls.zig — call_args AND
literal_fields). Wrapper-widget pattern now leak-free by construction:
tests/pass/run/consuming_body_wrapper_parity (0 leaks). Borrowed contains-any
receivers → KSEM157 (+ KIR002 mid-IR backstop). Full corpus green under
KIRA_CORPUS_CHECK_LEAKS=1.

NEXT for the editor: owned-array element drain — `widgets[index].lower(ctx)`
on an owned `[any Widget]` must move the element out (array_get `moved`,
VOID-tombstoned slot on both backends) and owned-array args must be feedable
by partial-moving a field out of owned self; then flip kira_ui `lower` to
`@Consuming` and drop the `borrow [any Widget]` workaround in
loweredChildren. Consuming-mode decision lives in methodConsumesSelf
(lower_shared_construct_queries.zig) and MUST stay identical across the four
registration/lowering sites (two header registrars, node-bridge accessors,
lowerMethodFunction).
