# Checkpoint - 008 Native Performance Regression

Task: Kira had a ~20x perf win that regressed after the ownership/drop/leak rework. Find
and fix it WITHOUT undoing the Rust-like ownership model or reintroducing leaks. Build a
real benchmark harness; back every claim with measurements.

Status: two native-path regressions found and fixed; ownership model preserved; corpus
1128/0; 0 leaks; benchmark harness added (`zig build bench`).

## Trigger / evidence

User CPU profile (iOS, cycles) of basic-foundation-app: 99.7% under `GSEventRunModal` (the
UIKit run loop — coarse) but the one Kira-attributed leaf was `kira_fn_1142_Row → mfm_alloc`,
i.e. widget construction spending its time in malloc. Pointed the hunt at per-frame
allocation churn + runtime-helper overhead.

## Regression 1 — per-iteration scratch `alloca` in loops (CRASH + waste)

A `benchmarks/struct_array` workload (array of structs built per frame) **segfaulted on
native** at ~32k+ iterations (EXC_BAD_ACCESS, write, on a stack address; `str w9,[sp,...]`).
Root cause: the C-API backend `alloca`'d its reusable scratch slots (array
append/get/set bridge slots, hybrid runtime-call arg/result arrays, FFI cret slots) **at the
current builder insertion point**. An `alloca` outside the entry block is a *dynamic* stack
allocation that LLVM does not reclaim until function return — so each loop iteration lowered
`sp` permanently (`mov sp, x1` inside the loop, restored only at function exit) → unbounded
stack growth → overflow. Also pure per-iteration waste even below the crash threshold.

Fix: `FunctionCodegen.entryAlloca(ty, name)` (backend_capi_codegen.zig) emits the alloca in
the function entry block (before its terminator) regardless of the current position, then
restores the builder. Routed every loop-reachable scratch site through it:
- backend_capi_aggregate.zig: array.get/set/append slots
- backend_capi_calls.zig: rt.args / rt.result (hybrid runtime call)
- backend_capi_ffi.zig: cret.struct.slot / cret.sret.slot
(dispatch trampolines are straight-line — no loop — left as-is.)
Added LLVM-C bindings `LLVMGetEntryBasicBlock`, `LLVMPositionBuilderBefore` (llvm_c.zig).

Result: struct_array native 0.07s/100k frames, no crash. New corpus regression test
`tests/pass/run/array_append_loop_no_stack_growth` (60k-iteration array append in one
function — above the old crash threshold) passes vm/llvm/hybrid.

## Regression 2 — `getenv` per runtime operation (the ~20x slowdown)

Profiling `benchmarks/tree_build` (nested struct/array/string tree built+dropped per frame)
showed `kira_array_release` spending the bulk of its self time in
`kira_trace_log → kira_trace_enabled → getenv` (290 of 777 samples in one stack). The trace
gate (`runtime_helpers.c::kira_trace_enabled`) only cached its decision when the explicit
setter `kira_set_execution_trace_enabled` was called; a native build never calls it, so the
static stayed -1 and **every** trace check ran a fresh `getenv("KIRA_TRACE_EXECUTION")` (a
locked, linear env scan). `kira_trace_log` runs on every array release / print / bridge op.

Fix: memoize the env lookup once into the static on first call (still overridable by the
setter). Trace functionality unchanged; the disabled-path check is now a single int read.

Measured before/after (native, same binary, only the trace fix toggled):
- tree_build (200k frames): 0.560s → 0.208s  (**2.7x**)
- string_ops (1M create/move): 0.014s → 0.007s (**2.0x**)
- leak-harness, the REAL KiraUIFoundation per-frame pipeline (10k frames):
  0.84s → 0.63s (**1.34x**); `getenv`/`kira_trace_enabled` gone from the hot profile.
(int_loop/calls have no heap release → unaffected, as expected.)

## Benchmark harness (Phase 1)

`benchmarks/` — one Kira project per cost class (int_loop, calls, string_ops, closures,
struct_array, tree_build) + `benchmark_runner.zig` (repo-native, Zig). `zig build bench`
runs each across vm/llvm (hybrid via KIRA_BENCH_HYBRID=1), executes the real program,
requires a clean exit, and prints a min-wall-time table. `benchmarks/README.md` documents it.

Representative table (`zig build bench`, after fixes):

| benchmark | vm | llvm | vm/llvm |
|---|---|---|---|
| int_loop (5M) | 1344 ms | 7.2 ms | 187x |
| calls (2M) | 2187 ms | 6.7 ms | 326x |
| string_ops (1M) | 2353 ms | 4.6 ms | 514x |
| closures (1M) | 4398 ms | 25.3 ms | 174x |
| struct_array (200k) | 9197 ms | 120 ms | 76x |
| tree_build (200k) | 10674 ms | 207 ms | 51x |

## Files changed

- packages/kira_llvm_backend/src/llvm_c.zig (2 new bindings)
- packages/kira_llvm_backend/src/backend_capi_codegen.zig (entryAlloca)
- packages/kira_llvm_backend/src/backend_capi_aggregate.zig (3 sites)
- packages/kira_llvm_backend/src/backend_capi_calls.zig (2 sites)
- packages/kira_llvm_backend/src/backend_capi_ffi.zig (2 sites)
- packages/kira_native_bridge/src/runtime_helpers.c (trace memoize)
- benchmarks/** (new harness: 6 projects + runner + README)
- build.zig (`bench` step)
- tests/pass/run/array_append_loop_no_stack_growth/** (new regression test)
- tests/memory_validation.zig (new test + 3 source-invariant guards)

## Validation

- `zig build`: ok. `zig fmt --check` all touched Zig files: clean.
- `zig build test -Dstable-tests`: 1128 passed, 0 failed (vm/llvm/hybrid).
- `zig build verify-memory`: memory validation checks passed; 0 leaks
  (tree_build `leaks --atExit`: 0 leaks / 0 bytes).
- `zig build repo-truth` / platform matrix: passed.
- Ownership preserved: moves still transfer (no clone functions in the hot profile),
  drops still free recursively, KIRA_ARRAY_OWNERSHIP_FREE on, no refcount/Arc reintroduced.

## Remaining / out of scope

- The VM remains 50–500x slower than native on these loops — inherent to a tree-walking
  bytecode interpreter; not a regression. The user already flagged "Kira is slow, fix later."
- Per-frame UI allocation churn (build+drop the whole retained tree each frame) is
  algorithmic in UI Foundation, not a compiler regression; the after-fix profile is genuine
  malloc/free, not overhead.
- The deferred native-state per-frame leak (checkpoint 007) is unchanged.
