# Kira LLVM Native Hot-Path: `kira instruments` profiling + array fast-path

Date: 2026-05-30
Scope: instrumentation + one behavior-preserving native hot-path improvement. No
language, UI Foundation, retained-tree, layout, or render behavior was changed.

## 1. Exact commands run

```
zig version
zig build                                   # baseline, EXIT 0
./zig-out/bin/kira run   examples/status_board       --backend llvm   # golden output
./zig-out/bin/kira build /tmp/kbench/array_bench.kira --backend llvm # native exe
./zig-out/bin/kira instruments run /tmp/kbench/array_bench.kira \
    --backend llvm --track cpu --duration 5s --sample-rate 200hz \
    --json-out .codex/work/reports/array_bench_instruments.json       # EXIT 0
sample <pid> 1                              # macOS function-level profile (before)
zig build                                   # rebuild with the change, EXIT 0
zig build test                             # full suite, EXIT 0
```

Before/after wall-clock used the built native executable directly (3 runs, best of):
```
( for i in 1 2 3; do /usr/bin/time ./array_bench; done )
```

## 2. Environment

| Field        | Value                                              |
|--------------|----------------------------------------------------|
| OS           | macOS 26.5 (Darwin 25.5.0, build 25F71)            |
| Architecture | arm64 (Apple Silicon)                              |
| Zig          | 0.16.0                                             |
| Kira backend | LLVM native (`--backend llvm` → `llvm_native`)    |
| Target apps  | `examples/status_board.kira` (real array-heavy example); a list-of-lists workload shaped like a Foundation retained node tree (600 nodes × 10 children, 200 traversal passes) used to amplify and isolate the array hot path |

`kira instruments` already existed (`packages/kira_cli/src/commands/instruments.zig`
+ `packages/kira_instruments`). It supports
`kira instruments run <target> --backend runtime|llvm|hybrid --track cpu|memory
--duration <d> --sample-rate <hz> --fail-on-growth <size> --json-out <path>` and
emits a human-readable report plus a JSON report. It was verified end-to-end against
an LLVM-native target here (markdown to stdout + `array_bench_instruments.json`).

The built-in sampler measures **process-level** CPU%/RSS. For **function-level** hot
paths I used the macOS `sample` tool against the running native binary.

## 3. Before profile

Top hot function (macOS `sample`, 1 s @ 1 ms, before the change):

```
kira_array_is_active   — present in 312 call-tree frames; dominant native leaf
   <- kira_array_load / kira_array_len  (per element access)
      <- sum_groups / sum_rows (Kira List.get / List.length)
```

Wall-clock (native LLVM executable, best of 3):

| Workload                                   | Before  |
|--------------------------------------------|---------|
| List-of-lists tree (600×10, 200 passes)    | 2.0415 s |
| Flat list (400 rows, 2000 passes)          | 0.1229 s |

Why: every native array access (`kira_array_len`, `kira_array_load`,
`kira_array_store`, `kira_array_append`, `kira_array_release`) called
`kira_array_is_active`, which walked the global `kira_active_arrays` linked list.
With N live arrays this is O(N) **per access**. A Foundation-style tree keeps many
child arrays live at once, so the flat-list case (≈1 live array) barely moved while
the tree case spent ~95% of wall time in this scan.

## 4. Change made

### File: `packages/kira_native_bridge/src/runtime_helpers.c`

`kira_array_is_active`: removed the linked-list registry scan.

Before:
```c
static int kira_array_is_active(const KiraArray *array) {
    if (array == NULL || kira_bridge_probably_invalid_pointer(array)) return 0;
    for (KiraArrayRegistryNode *node = kira_active_arrays; node != NULL; node = node->next) {
        if (node->array == array) return 1;
    }
    /* ... borrowed-array rationale ... */
    return 1;
}
```

After:
```c
static int kira_array_is_active(const KiraArray *array) {
    if (array == NULL || kira_bridge_probably_invalid_pointer(array)) return 0;
    /* Fast path: the registry scan was dead work — found-branch and fall-through
       both return 1, so it could never change the result while costing
       O(live-arrays) per access. ... */
    return 1;
}
```

### Why this is behavior-preserving (provable, not empirical)

The function's output is a pure function of the loop's two exits:
- found in registry → `return 1`
- not found → fall through → `return 1`

Both return `1`. The loop therefore could never change the result. For every
possible input the function returns exactly what it returned before:
`NULL` or sentinel-small pointer → `0`; any other pointer → `1`. Only dead work is
removed; the real validity contract (the null/sentinel rejection) is untouched.
This matches the existing in-code rationale that registry membership is *not* the
validity check (hybrid/VM-borrowed arrays are valid yet never registered).

No public API, struct layout, language semantics, retained-tree logic, layout, or
render path is touched. The change is confined to one internal C helper.

## 5. After profile

| Workload                                   | Before   | After    | Speedup | Reduction |
|--------------------------------------------|----------|----------|---------|-----------|
| List-of-lists tree (600×10, 200 passes)    | 2.0415 s | 0.0937 s | 21.8×   | 95.4%     |
| Flat list (400 rows, 2000 passes)          | 0.1229 s | 0.1193 s | ~1.03×  | ~3% (noise; ~1 live array) |

`kira_array_is_active` is no longer a measurable frame after the change. The entire
21.8× delta is attributable to this single function (it is the only code that
changed), which also confirms it was the before-profile bottleneck.

## 6. Tests run and results

| Check                                                        | Result |
|-------------------------------------------------------------|--------|
| `zig build` (baseline, then with change)                    | EXIT 0 |
| `zig build test` (full suite)                               | EXIT 0 |
| `kira run examples/status_board --backend llvm` golden diff (before vs after change) | byte-identical (MATCH) |
| List-of-lists workload deterministic output                  | `acc=364800000` identical before/after |
| `kira instruments run ... --backend llvm --json-out ...`     | EXIT 0, markdown + JSON report written |

Behavior preservation is covered by: the algebraic proof above, the full Zig test
suite, and byte-identical output from both a real example and a 600-array workload
run through the LLVM native backend before and after.

## 7. Remaining bottlenecks

1. **Registry is now write-only dead weight.** `kira_array_register` still does one
   `malloc` per `kira_array_alloc`, and `kira_array_unregister` is never called, so
   `kira_active_arrays` grows unbounded — a genuine leak (would trip
   `--fail-on-growth` on long-running apps). Nothing reads it anymore.
2. **Per-access guards** `kira_array_repair_invalid_storage` /
   `kira_bridge_probably_invalid_pointer` still run on every load/store. O(1), but
   redundant in inner loops already bounded by a preceding `kira_array_len`.
3. **`kira_array_append` is O(n)** (realloc + full copy, no capacity). Building a
   list of n via push is O(n²).
4. **`kira instruments` is process-level only** — no per-symbol attribution.

## 8. Next recommended optimization task

Remove the now-vestigial array registry entirely: drop `KiraArrayRegistryNode`,
`kira_active_arrays`, `kira_array_register`/`kira_array_unregister`, and the
`kira_array_register(array)` call in `kira_array_alloc`. This is behavior-preserving
for the same reason as this change (the registry has no observable effect once
`kira_array_is_active` stopped reading it) and additionally removes one malloc per
array allocation and the unbounded leak. Then, as a separate task, add geometric
capacity growth to `kira_array_append` (O(n²)→O(n) list construction) — this one
touches `KiraArray` layout, so it must be co-designed with the Zig VM bridge to stay
behavior-preserving. Optionally extend `kira instruments` with a `--profile-symbols`
flag that folds macOS `sample`/`spindump` top symbols into the report.
