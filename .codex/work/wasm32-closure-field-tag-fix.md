# wasm32 closure-field tag truncation — root cause + fix (2026-07-10)

Both wasm32-only graphics-app bugs (method-installed handlers "lost"; borrow
value-struct handler invoke trapping `unreachable`) were ONE root cause:

A Kira closure value is an i64 with **bit 63 tagging a heap closure block**.
Struct fields of closure type were stored at POINTER width
(`fieldStorageType -> ptr_ty` = 4 bytes on wasm32), so storing a CAPTURING
closure into a struct field truncated the tag. The untagged block address then
hit the call_value dispatcher, whose `is_direct` test (`value <= u32 max`) is
degenerate on wasm32 (loads are zext'd). Two symptoms:

1. Dispatcher `default: unreachable` let LLVM assume the loaded id must equal a
   known case and FOLD the handler call to the default handler — the
   `app.onFrame{}` / `app.onEvent{}` setter "loss" (silent, no trap).
2. When the value stayed runtime-opaque (nativeState -> C -> @Native callback),
   the switch executed and trapped `RuntimeError: unreachable` on handler
   invoke — the kira-graphics event-dispatch trap.

Non-capturing closures never reproduced it (plain fn id fits 32 bits).

## Fix

Closure-typed fields (IR kind `.raw_ptr` with name = signature text, starts
with `'('` — see `backend_utils.isClosureValueType`) are now FULL i64 slots.
Layout-identical on 64-bit; only pure-Kira structs can carry such fields, so C
layout is unaffected. Width-consistent load/store at:

- packages/kira_llvm_backend/src/backend_utils.zig (`isClosureValueType`)
- backend_capi.zig (`fieldStorageType`)
- backend_capi_value_repr.zig (`loadConverted`)
- backend_capi_aggregate.zig (`lowerStoreIndirect`, both closure paths)
- backend_capi_struct_dtors.zig (release/clone contents)

Regression tests: packages/kira_build/src/wasm_emscripten_closure_width_tests.zig
(registered in kira_build root.zig test block; skip w/o emcc+node).

## Validation (all green)

- zig build test: 78/78 steps, 288/288 tests
- KIRA_CORPUS_BACKENDS=wasm zig build test-backends: 524/0
- host corpus filters vm+llvm+hybrid: closure 50/0, ownership 107/0,
  method 9/0, callback 38/0, struct 91/0
- .codex/tmp/wasm-drive repros: minA, gfxrepro, gfxreproB green on
  vm/llvm/hybrid/wasm32
- input-probe rebuilt with `app.onEvent(move ...)`/`app.onFrame(move ...)`
  METHOD installation: headless-Chrome DOM injection shows all handler markers
  (key/char/pointer/scroll) + visible input-reactive clear color.

## Still open (NOT this fix)

- input agent's bug #2: double `nativeStateFree` aborts on wasm
  (emscripten_builtin_free) — separate issue, repro in nstest/README.
- Any (`construct_any`) fields keep ptr-width slots (K8 semantics); if a
  tagged closure can ever legally flow into an Any field, wasm32 would have
  the same truncation there.
