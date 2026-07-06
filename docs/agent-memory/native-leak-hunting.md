# Native Leak Hunting

Internal memory for diagnosing and fixing native (LLVM backend) memory leaks.
State as of 2026-07-06, after array-ownership free became unconditional
(commits `88db4a1`, `a0b2b08`; history in
`.codex/work/reports/array-registry-leak-and-promotion.md`).

## Current state

`kira_array_release` frees owned arrays unconditionally on the pure-native
path (hybrid defers to the VM's destructors). The old
`KIRA_ARRAY_OWNERSHIP_FREE` gate and its `KIRA_ARRAY_OWNERSHIP_FREE_DEV` env
hook are GONE — do not reintroduce them. The ownership model is Rust-like
move/drop elaboration, NO refcounts: one release per owned value at its drop
point, moves transfer, borrows never dropped, borrow→owned promotions
deep-clone.

Measured baselines (`leaks --atExit`, offscreen frames):

| Program | Residual | Notes |
|---|---|---|
| ui-foundation `Examples/leak-harness` (10k frames) | 2 leaks / 224 B | effectively clean |
| ui-foundation `Examples/liquid-glass-app` (120 and 600 frames) | 628 leaks / ~360 KB | identical at both frame counts → one-time setup only |
| ui-foundation `Examples/basic-foundation-app` (120 frames) | 1,951 leaks / ~470 KB | `ft_add_renderer` (font engine) visible in stacks |
| project-matter `apps/editor` (60 frames) | 10,968 leaks / ~1.25 MB | was 1.0 GB before the free path |

A residual that does NOT grow with `KIRA_METAL_OFFSCREEN_FRAMES` is one-time
setup; only frame-scaling leaks are per-frame bugs.

## Remaining leak classes (the actual TODO)

1. **Native String drop gap** — `c_string_to_string` lowers to
   `strlen+malloc+memcpy` (`backend_capi_calls.zig:lowerCStringToString`) but
   no drop is ever emitted for owned Strings. Every CString→String coercion
   leaks its copy. `leaks` shows them as ROOT LEAKs with `malloc in kira_fn_*`
   frames whose content is readable string data. Fix belongs in drop
   elaboration (track string registers like arrays), not in C.
2. **Closure capture leaks** — `kira_destroy_closure`
   (`runtime_helpers.c`) deliberately does not free captured heap values (no
   per-capture type info; conservative leak instead of double-free).
3. **Native-state interior teardown** — `kira_native_state_free` frees the
   payload buffer and token only; interior arrays/structs/enums the box owns
   are not destroyed. Fine for app-lifetime ambient state, a leak for
   short-lived boxes. The VM's `freeNativeState` destroys interiors — parity
   gap.
4. **Font-engine setup** (`ft_add_renderer` etc.) in ui-foundation — one-time,
   low priority.
5. **`[U8]` storage amplification** (perf, not a leak): every byte element is a
   24-byte `KiraBridgeValue`, so `readFileRange` on a 32 MB file allocates
   768 MB transiently. Needs a packed byte-array representation.

Triage rule: a leak stack rooted in `kira_fn_<id>_<KiraName>` = backend drop
gap (fix in `kira_llvm_backend`). A stack rooted in a C helper
(`fs_*`, `kap_*`, `kira_dynamic_*`) = helper or call-site bug (those were all
fixed 2026-07-05; regressions are corpus-guarded).

## Where the machinery lives

- `packages/kira_llvm_backend/src/backend_capi_drop.zig` — drop slots,
  owned-register tracking (`setup` pre-scan, `onAlloc`/`onEscape`,
  `emitExitCleanup`, `moveOrCloneToHeap`, `prepareStructReturn`).
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
