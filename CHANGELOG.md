# Changelog

All notable changes to Kira are documented here. Kira is a dual-mode language:
every feature is expected to work across the VM (`kira run`), LLVM/native
(`kira build`), hybrid, and — where portable — the `wasm32-emscripten` target.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com).

## [2026.07.2] - 2026-07-07

First tagged release since `0.1.0`. Summarizes 179 commits spanning the
ownership model, hybrid/native runtime, backend parity, the UI construct
surface, shaders, FFI, live reload, and the test harness.

### Language

- **Move-only `Any` model** with consuming receivers, including nested
  consuming field receivers and runtime-typed teardown for type-erased values
  and native-state interiors.
- **`some` existential qualifier**; migrated existential `any` uses and tagged
  `extend`-modifier `self` as existential.
- **SwiftUI-style construct UI surface**: `@Required` / `@Content` sections, the
  Widget→Node bridge with computed-property accessors, trailing content blocks
  routed into `@Content` fields, heterogeneous widget-array unification, and
  concrete-widget coercion to any-construct types.
- **`@PropertyWrapper` attribute macro** with backend parity, plus wrapper-kind
  macros and `Syntax` rewriting for pure-Kira property wrappers.
- **`Int()` / `Float()` numeric casts** across all backends, with saturating
  `Float`→`Int` conversion and zero-extended unsigned FFI returns.
- Executable `String` content equality (`==` / `!=`) across IR, VM, and LLVM.
- `range-for`, macros, and the full kira-zig language layer restored.
- Enum equality tag comparisons fixed; enum arguments materialized to hybrid
  native callbacks.

### Ownership & memory safety

- **Mid IR ownership checker** with Rust by-value move semantics; reports the
  first ownership error only. Split into focused modules.
- Reject array/enum aliasing at `check` (`KSEM107` moves, `KSEM118` array
  fields) and reject unrestored partial field moves at scope exit.
- Loop-body drop elaboration; fixed field move-out use-after-free.
- **Removed VM refcounting**; fixed native leaks and the associated perf
  regression.
- **Native strings, closures, and enum string payloads are now deep values** —
  tracked, cloned, and freed — with harness leak checks.
- Extensive hybrid/native lifetime fixes: closure copy captures, callback-bridge
  payload liveness, single-owner VM↔native aggregate return/arg ownership, enum
  field cloning across the native boundary, and multiple double-free /
  use-after-free repairs.
- Foundation C-helper memory leaks fixed (FS, ArgumentParser, DynamicFfi);
  memory validation wired into build steps.

### Backends & parity

- **LLVM C-API backend is now the sole native backend**; the text-IR writer was
  retired. Fixed compare-predicate typing and masked shift counts before LLVM
  shift lowering.
- **WASM**: Emscripten-backed WASM tests enabled; Kira Wasm web runner,
  multi-platform exports, `Foundation.Web` bin, and a validation matrix.
- **Hybrid** backend hardened across ownership, native-state handling, stdout
  streaming, and error paths.
- `kira check` is now the executable-validity contract; backends are gated
  behind verified IR.
- Per-local cleanup slots for owned enum locals; VM modulo truncates toward zero
  to match the LLVM backend.

### Graphics & shaders

- Shader backends and callback registry; KSL `atomicAdd` intrinsic across
  backends with target/mixed-buffer validation.
- Complete GLSL compute input lowering; shader parity and golden tests locked
  down. Fixed shader import path casing for case-sensitive filesystems.

### FFI & native

- **libffi-backed dynamic FFI VM path**; framework-only native libs and
  multi-signature C symbols supported.
- Deterministic FFI autobind emission; linked native libraries included in the
  executable cache key / build fingerprint.
- `nativeStateFree` builtin for releasing native-state boxes; documented and
  enforced the `NativeStateBox` / `KiraNativeState` shared ABI prefix.
- C++ native-library sources compiled with an explicit standard.

### Runtime & performance

- VM interpreter split; hot-reload generations and native opt flags.
- Corpus validation parallelized with a reader-writer lock (~1.6× faster).
- Perf: pointer-keyed enum decl lookups, `KIRA_LEAK_HEAP` memoized out of the
  per-drop hot path, array-element borrow-elision restored.
- Bounded interpreter/parser recursion depth with clean runtime errors instead
  of segfaults.

### Live reload & tooling

- `kira_live` package and `kira live` command for hot-reload workflows; real
  live server/client sessions with desktop, Apple, and web runners.
- `kira_diagnostic_messages` package for structured CLI diagnostics;
  `--quit-after` flag for bounded CLI smoke tests.
- Diagnostics render labels on synthetic spans instead of crashing.

### Testing

- `tests-kik` cross-backend stress harness with a foldered `app/<purpose>/`
  layout; a 949-test suite across the language surface plus an FFI catch-all
  suite as `Test` constructs.
- `kira test` runs on VM, hybrid, and LLVM with full parity, a pure-Kira test
  driver (now the default), trap-message verification, and native-FFI suites on
  `--backend llvm`.

### Architecture (Core Law #5)

- Split oversized files across `kira_vm_runtime`, `kira_ir`, `kira_semantics`,
  the VM interpreter, the Mid IR ownership checker, and HIR lowering into
  focused modules while preserving public APIs.

### Project Matter

- Added engine-driven language and runtime capabilities (Project Matter).

## [0.1.0] - 2026-05-17

- Bootstrap release launcher from toolchain archives; first published Kira
  toolchain across Linux x64, macOS arm64, and Windows x64.

[2026.07.2]: https://github.com/iPriam/kira/releases/tag/v2026.07.2
[0.1.0]: https://github.com/iPriam/kira/releases/tag/v0.1.0
