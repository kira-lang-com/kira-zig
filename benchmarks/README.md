# Kira performance benchmarks

Repo-native performance harness. Each subdirectory is a real Kira project (`project.toml`
+ `app/main.kira`) exercising one cost class. The runner compiles and **executes** every
program through the real compiler/runtime on each backend and reports wall-clock time —
there are no synthetic markers; a crash or non-zero exit fails the run.

## Running

```sh
zig build bench
```

Prints a table comparing, per benchmark:

- **vm** — `kira run --backend vm` (frontend + bytecode interpretation)
- **llvm** — the generated native executable run directly (compile time excluded, so the
  number is pure Kira-generated machine code)
- **vm/llvm** — speedup of native over the VM

Options (environment variables):

- `KIRA_BENCH_HYBRID=1` — also measure the hybrid backend (off by default; hybrid bridges
  every call through the VM and is slow on hot loops).
- `KIRA_BENCH_REPEATS=N` — repetitions per measurement; the minimum is kept (default 3).

## Benchmarks

| dir | cost class |
|---|---|
| `int_loop` | pure integer hot loop (no heap) |
| `calls` | function calls with primitive args |
| `string_ops` | string create / move / pass / return / destroy |
| `closures` | closure create / capture / call / destroy |
| `struct_array` | per-frame array of structs: build, borrow-read, drop |
| `tree_build` | nested struct/array/string tree built and dropped per frame (UI-shape proxy) |

`struct_array` and `tree_build` are the closest proxies for the UI Foundation per-frame
build/update/render-command pipeline; they are deliberately allocation- and
drop-heavy.

## Performance regressions found via this harness

Two regressions in the native path were found and fixed (ownership model preserved, no
leaks reintroduced):

1. **Per-iteration scratch `alloca` in loops** (`backend_capi_*` → `FunctionCodegen.entryAlloca`).
   Array-op / runtime-call / FFI bridge scratch slots were `alloca`'d at the current
   insertion point. An `alloca` outside the entry block is a *dynamic* stack allocation
   that LLVM never reclaims until function return, so every loop iteration grew the stack —
   a hard **stack-overflow crash** past ~32k iterations plus per-iteration waste. Fixed by
   hoisting these reusable scratch allocas to the entry block (the standard LLVM idiom).

2. **`getenv` per runtime operation** (`runtime_helpers.c::kira_trace_enabled`). The trace
   gate ran a fresh `getenv("KIRA_TRACE_EXECUTION")` on every array release / print / bridge
   op when the trace setter was never called (the native default). Memoizing the lookup once
   removed it from the hot path: **2.7× on `tree_build`, 2.0× on `string_ops`**, and ~1.34×
   on the real `KiraUIFoundation` per-frame pipeline (leak-harness).
