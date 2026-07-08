# VM crash surfaced by kik-corpus migration: `@memcpy arguments alias` in vm_values addValues

Discovered 2026-07-08 while migrating tests/pass/run/ownership_enum_string_payload_free_parity
into the kik harness (Test-construct form); now at
tests-kik/harness/app/runparity/OwyTests.kira.

## Symptom
Panic `@memcpy arguments alias` in `packages/.../vm_values.zig` `addValues`.

## Trigger (minimal shape)
A struct whose field is an enum carrying a String payload, when the struct is
**freshly declared inside a `while` loop body** (`var envelope = Envelope { ... }`)
and then matched / its String payload concatenated, in the SAME loop iteration.

## Path-specific
Reproduces ONLY through the `kira test` comptime-Test execution driver
(`executeViaDriver` / `pure_test` path in `packages/kira_main/src/developer.zig`),
NOT through normal `kira run` / `kira build`. So it is a bug in the Test-driver
execution path, not general VM codegen.

## Current workaround in the migrated test
Declare the struct once OUTSIDE the loop and mutate it inside instead — same
enum-payload free/reassign coverage, avoids the aliasing memcpy. See
tests-kik/harness/app/runparity/OwyTests.kira.

## TODO (real fix, not yet done)
- Reduce to a standalone repro under tests-kik/harness/known-bugs/.
- Fix the aliasing in addValues (source/dest overlap) on the pure_test driver path.
- Add a negative/regression Test that would crash again if reintroduced.

---

## UPDATE 2026-07-08: two blockers on the "fail-harness via kira test" idea fixed

The idea: a `Test` calls `Foundation.checkPackage(path, backend)` (the in-process
compiler driver) to compile a *separate* package of fail cases and asserts the
pass/fail outcome — so `fail/` diagnostics become `kira test`-runnable. Two real
compiler bugs blocked it; both now fixed:

1. **Infinite recursion in IR type lowering** (`packages/kira_ir/src/lower_from_hir_types.zig`).
   The autobound `@FFI.Alias { target: KiraDeveloper } struct KiraDeveloper {}`
   (self-referential; same for KiraRuntime) had no cycle guard, so
   `lowerNamedType`->`lowerResolvedType`->`lowerNamedType` looped forever and
   crashed `check`/`run`/`build`/`test` on any code touching `KiraDeveloper_ptr`.
   Fix: thread a `VisitedNames` set; on revisit, lower opaque (`raw_ptr` for
   `*_ptr`, else `ffi_struct`).

2. **`NativeLibraryUnavailable` for the driver lib** (`packages/kira_dynamic_ffi/src/dynamic_library.zig`
   + `packages/kira_vm_runtime/src/vm_ffi.zig`). `kira_main` is statically linked
   into the `kira` binary (libkira_main.a) and ships no standalone `.dylib`
   (`dynamic_lib = ""`), so the VM-FFI dispatcher's `dlopen("kira_main")` failed.
   Fix: `DynamicLibrary.openProcess()` resolves symbols from the current process
   image (dlsym(RTLD_DEFAULT) / GetModuleHandle(null)); `vm_ffi.openLibrary`
   falls back to it when a name has no non-empty registered path.

Verified: fail-Test prototype passes (`checkPackage(badPkg).success == false`,
`checkPackage(goodPkg).success == true`) under `kira test`. Full `zig build test`
0 failed; harness 981/0; all corpus packages green.

Still open: the memcpy-alias crash above (separate bug), and migrating the 124
`fail/` cases into a driver-backed kik package.
