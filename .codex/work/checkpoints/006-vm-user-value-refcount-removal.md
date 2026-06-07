# Checkpoint - 006 VM User-Value Refcount Removal

Task: Complete the VM user-value memory migration away from refcounted ownership.

Status: complete

## Ownership Model Implemented

Linear (Rust-style affine) ownership for all Kira user values. The compiler is the
source of truth for ownership and lifetime safety; the runtime heap performs only
deterministic, single-owner drops.

- Kira owns by default; plain parameters consume named non-trivial values.
- `borrow Type` / `borrow mut Type` are non-consuming borrows that never own or destroy.
- `move expr` performs explicit ownership transfer; use-after-move is rejected at compile time.
- Trivial/Copy values (`Int`, `Float`, `Bool`, `CString`, `RawPtr`, callbacks) pass by value.
- Closure captures carry an explicit capture ownership mode; non-Copy owned captures are
  rejected before backend lowering (KSEM117).
- Overwrites drop the replaced owned value; borrows are never dropped through the owner.

## Removed Refcounted Paths

`packages/kira_vm_runtime/src/ownership.zig` (the hard-stop file) had every Arc-style
mechanism removed in the prior run; this checkpoint verified the removal and finished the
naming/truthfulness cleanup:

- Removed `ObjectRecord.ref_count` and `ObjectRecord.pin_count` fields.
- Removed `retainValue` / `releaseValue` / `retainPtr` / `releasePtr` / `unpinPtr`.
- Renamed `assignOwned` -> `assignTransferred`, `releaseSlots` -> `dropSlots`,
  `releasePtr` -> `dropPtr`, `releaseValue` -> `dropValue`.
- Boundary pin scopes are now non-owning (visited-set tracking only; no refcount/pin holds).
- Renamed the runtime drop wrapper `Vm.releaseManagedValue` -> `Vm.dropManagedValue`
  (hybrid runtime + all VM self-tests) so no user-value path is named after the retired
  Arc model. The hybrid "Retain them ... releases them" comment was reworded to
  "Keep them alive ... drops them."

Proof:
- `grep -niE 'ref_count|refcount|retain|release|arc|pin_count' ownership.zig` -> no matches.
- `grep -rniE 'retainValue|releaseValue|retainPtr|releasePtr|assignOwned|releaseSlots|releaseManagedValue|ref_count|pin_count'`
  across `kira_vm_runtime` and `kira_hybrid_runtime` -> no matches.

## Diagnostics

- `KSEM117` "closure capture requires explicit ownership" — rejects non-Copy closure
  captures before backend lowering, with primary/secondary spans and a help line steering
  toward borrow params / explicit move / Copy-only capture.
- `KSEM094` mutable callback capture rejection preserved.
- Use-after-move / move-from-borrow diagnostics preserved.

## Tests Added / Changed

- `tests/fail/semantics/ownership_closure_capture_noncopy/` — non-Copy struct capture rejected (KSEM117), vm/llvm/hybrid.
- `tests/fail/semantics/ownership_closure_capture_array_noncopy/` — non-Copy array capture rejected (KSEM117), vm/llvm/hybrid.
- `tests/pass/run/ownership_closure_capture_copy_parity/` — Copy capture passes, vm/llvm/hybrid.
- `tests/memory_validation.zig` (+ `zig build verify-memory` / `verify-leaks`) — asserts backend
  matrices, heap cleanup assertions, and hybrid drop wiring; updated to require `dropManagedValue`.
- `packages/kira_vm_runtime/src/ownership.zig` unit tests rewritten to assert non-owning pin
  scopes and zero-count cleanup (no refcount assertions remain).

## Validation

- `zig fmt --check` on touched files: clean.
- `zig build`: passed.
- `zig build test`: passed.
- `zig build test -Dstable-tests`: corpus `1065 passed, 0 failed` (vm/llvm/hybrid).
- `zig build verify-memory`: `memory validation checks passed`.
- `zig build verify-leaks`: `memory validation checks passed`.

Note: one transient LLVM-build flake surfaced once under `verify-memory` and cleared on
re-run (a known flaky native build, not an ownership regression); the stable runner exists
for exactly this reason.

## Backend Parity

VM, LLVM/native, and hybrid agree across the corpus; closure-capture ownership rejection is
identical across all three backends (the fail tests declare `["hybrid","vm","llvm"]`). WASM
parity preserved through the existing wasm32-emscripten path for portable features.

## Remaining Limitations

- Non-trivial `copy expr` clone semantics remain reserved/unimplemented (pre-existing; out of
  scope for this task) and are documented in `docs/ownership.md`.
- Returned-borrow lifetime validation is still pending (pre-existing limit noted in docs).

## Hard-Stop Conditions

None triggered: `ownership.zig` is refcount-free; no backend divergence without diagnostic;
no leaks hidden by keeping allocations alive; no crash converted to fake success; no tests
weakened; ownership enforcement is cross-backend, not VM-only.
