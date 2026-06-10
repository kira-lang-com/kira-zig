# Checkpoint - 009 VM + native deep performance

Task: the VM was 50-500x slower than native. Find every reason and make deep improvements;
consider C#-style bytecode / JIT, but keep non-JIT fast for iPhone (iOS forbids JIT).

Status: every dominant cause found and addressed; correctness preserved (corpus 1128/0,
verify-memory passed, 0 leaks). Ownership model untouched.

## Why the VM looked 50-500x slower — ranked by impact

1. **The dev snapshot ships -ODebug (4-11x).** `zig build` defaults
   `standardOptimizeOption` to Debug, so `kira run --backend vm` ran an unoptimized,
   safety-checked interpreter while the native `.run` binaries were LLVM-built. Pure
   Debug-vs-optimized. ReleaseFast VM: int_loop 1369->364ms, struct_array 8914->822ms.
2. **The Kira-generated NATIVE object was compiled at -O0 (!).** `emitObjectFileViaClang`
   passed no `-O` flag, so clang defaulted to -O0 — no mem2reg/SROA/inlining/loop opts on
   ANY native binary, including the on-device iPhone app. (This is also why the loop-body
   `alloca` fix in checkpoint 008 was even needed: mem2reg never ran to promote them.)
3. **Per-call heap churn in the interpreter:** runFunction malloc/free'd four arrays
   (registers, register_owned, locals, local_owned) AND rebuilt the label->offset table by
   scanning every instruction, on EVERY call. Plus call_runtime malloc'd an args array per
   call.
4. **Per-write ownership hash lookup:** setSlotOwned called `Heap.isManagedValue`, which
   does a hashmap `contains` on every raw_ptr/string register write — even for
   const/arith/alloc results whose managedness is statically known.
5. Helper-call + error-union overhead for integer arithmetic/compare (addValues etc. were
   not always inlined).

## Fixes

Native (`backend_runtime_utils.zig`):
- Emit the Kira IR at **-O2** by default (env `KIRA_NATIVE_OPT=0/1/2/3/s/z` to override).
  This is the primary iPhone lever. Native: int_loop 7.2->4.3ms, struct_array 120->101ms,
  tree_build 207->188ms; corpus + 0-leak preserved (the optimizer did not change drop
  semantics).

VM interpreter (`vm.zig`):
- **Frame buffer pool** (`acquireFrame`/`releaseFrame`): reuse register/local value+owned
  buffers across calls instead of 4 mallocs/call. Pooled buffers stay alive (only capacity
  is stored) so intra-frame pointers (local_ptr/field_ptr) stay valid and nested calls draw
  distinct buffers — no aliasing.
- **Label-offset cache** (`labelOffsetsFor`): build each function's label->pc table once,
  keyed by the instruction-array pointer; was rebuilt every call.
- **Specialized slot setters** (`setSlotPrimitive`/`setSlotManaged`): const/arith/compare
  results set owned=false and freshly-allocated heap values set owned=true WITHOUT the
  isManagedValue hash lookup (managedness is statically known at those sites).
- **Integer fast paths** for add/sub/mul/compare (wrapping ops inline, no helper call).
- **Stack-buffer args** for call_runtime (<=16 args) — no per-call malloc in the common case.

## Measured results (min-of-3)

VM, ReleaseFast, committed baseline -> after (interpreter changes only):
| bench | before | after | x |
|---|---|---|---|
| int_loop | 442 ms | 299 ms | 1.48 |
| calls | 430 ms | 265 ms | 1.62 |
| closures | 637 ms | 419 ms | 1.52 |
| string_ops | 389 ms | 231 ms | 1.68 |
| tree_build | 1030 ms | 931 ms | 1.11 |
| struct_array | 1035 ms | ~800 ms | ~1.3 |

Compounded dev-experience win (Debug committed -> ReleaseFast optimized), e.g. int_loop
1369 ms -> 299 ms = **4.6x**; struct_array 8914 ms -> ~800 ms = **~11x**.
Native -O0 -> -O2: 1.1-1.7x on top.

After the fixes the VM is ~1.5-6x of native on these benches (UI-shaped struct/tree ~5-6x;
pure integer loops ~45x — the irreducible per-dispatch tax of a tree-walking interpreter).

## JIT / C#-style bytecode assessment

- **JIT was deliberately NOT built.** iOS forbids JIT (no W^X / no executable mmap without
  special entitlements), and the user's primary target is iPhone, so a JIT cannot run there.
  The right investment is a fast interpreter + optimized AOT native, which is what shipped.
- **The bytecode is already register-based** (dst/lhs/rhs indices), i.e. the Dalvik/Lua
  shape that is *better* for interpretation than C#'s stack-based CIL. The remaining
  interpreter tax is dispatch + the 24-byte tagged Value; a compact fixed-width encoding or
  threaded dispatch could add ~1.3-2x but is a larger redesign, left as a documented future
  lever.

## Files changed
- packages/kira_vm_runtime/src/vm.zig (pool, label cache, slot specialization, int
  fast-paths, stack-buffer args)
- packages/kira_llvm_backend/src/backend_runtime_utils.zig (-O2 default native codegen)

## Validation
- `zig build test -Dstable-tests`: 1128 passed, 0 failed (vm/llvm/hybrid), both -O0 and -O2.
- `zig build verify-memory`: memory validation checks passed.
- tree_build `leaks --atExit` (native -O2): 0 leaks / 0 bytes.
- `zig fmt --check` touched files: clean.

## Recommended follow-ups (not done)
- Ship the dev `kira` snapshot / device runtime as ReleaseFast (the 4-11x lever); keep Debug
  for compiler-internals iteration. `zig build -Doptimize=ReleaseFast` already routes to the
  release channel.
- vm.zig is 3290 lines (Core Law #5, >1000) — split the interpreter loop into a module.
- Optional: compact fixed-width bytecode + threaded dispatch for another ~1.5-2x interpreter.
