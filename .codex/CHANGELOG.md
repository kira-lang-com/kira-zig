# Changelog

All notable changes to Kira are documented here. Kira is a dual-mode language:
every feature is expected to work across the VM (`kira run`), LLVM/native
(`kira build`), hybrid, and — where portable — the `wasm32-emscripten` target.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com).

## [1.7.3] - 2026-07-14

First release under the incremental-year versioning scheme (2026 = year 1;
`1.7.3` continues the retired calendar form's `2026.07.2`). This release
summarizes the complete history since `0.1.0` — roughly 200 commits on main,
many of them squash-landed feature branches — spanning the ownership model,
the LLVM/native and hybrid runtimes, the construct UI surface, shaders, FFI,
the source-level debugger, declaration manifests, live reload, the test
harness, and release tooling. It subsumes the `2026.07.2` section below.

### Language

- **`function` declarations and execution annotations**: function
  declarations use `function` (was `func`); `@Main` marks entry points and
  `@Runtime` / `@Native` control execution mode with cross-execution calls
  between them.
- **SwiftUI-style construct surface**: `@Required` construct members,
  `@Content` fields with trailing-block routing (single, list, and named
  fills), computed `let node: T { ... }` bridge accessors with the
  terminal-node rule, and fluent `extend C { .padding(...) }` modifier
  chains — all executing as real runtime values, not frontend-only checks.
- **Construct any-dispatch**: concrete declarations coerce to `any Family`,
  heterogeneous widget arrays unify to `[any Family]`, and accessor/method
  dispatch executes across vm/llvm/hybrid.
- **`some` existential qualifier** for dynamic-dispatch construct families,
  freeing `any` for a future monomorphized-generic meaning.
- **`@PropertyWrapper`** attribute macro with projected-value diagnostics,
  plus the generic macro machinery (wrapper-kind macros, trigger/replace
  attribute macros, `Syntax` reflection) that lets property wrappers be
  written entirely in Kira.
- **Range-`for` loops and the declarative/procedural comptime macro system**.
- **Numeric casts**: `Int(x)` / `Float(x)` across all backends (truncate
  toward zero, saturating out-of-range/NaN behavior matched between VM and
  LLVM), plus `floatToBits(...)` / `bitsToFloat(...)` bit reinterpretation.
- **String operations**: `+` concatenation and executable `==` / `!=`
  equality on every backend.
- **Opaque native callback state**: `nativeState` / `nativeUserData` /
  `nativeRecover` (and `nativeStateFree`) let callbacks box and recover
  persistent native state across the FFI boundary.
- **`attempt`/`handle` fixes**: payload-less failure variants no longer
  produce spurious `KSEM105` errors, and compiler diagnostics now carry
  `--> path:line:col` source locations with snippets.
- **Parser and analysis robustness**: empty control-flow bodies no longer
  misparse as struct literals; pathologically deep expressions report clean
  `KPAR014` / `KSEM155` diagnostics instead of overflowing the stack; a call
  ending a condition no longer swallows the following block's brace.
- **Enum equality** compares discriminants rather than instance identity.
- **Bare-callee resolution** prefers type construction over functions
  consistently in every package, not just the root.

### Ownership & memory safety

- **Affine ownership model**: VM refcounting (ref_count/pin_count) removed
  in favor of Rust-style move semantics with drop/transfer; deep-copy is the
  default value semantics for pure-Kira structs (FFI structs stay shallow).
- **Mid IR ownership checker**: a dedicated pass after HIR lowering enforces
  move/borrow soundness at compile time — reuse-after-move (`KIR002`),
  incomplete-move drops (`KIR003`) — across vm/llvm/hybrid.
- **Compile-time aliasing rules**: owned array/enum aliasing is rejected
  (`KSEM107`, `KSEM118`), and a partial move of a struct field must be
  restored before scope exit (`KSEM107`), closing use-after-free classes
  that previously crashed at runtime.
- **Move-only `Any` model**: type-erased values move rather than clone
  through consuming dispatch; `@Consuming` receivers take `self` by
  ownership with partial-move semantics (`KSEM157` on borrowed receivers),
  including nested consuming field receivers.
- **Deep-owned native values**: strings, closure captures, enum string
  payloads, `Any`/construct trees, and native-state interiors are fully
  ownership-tracked on the native backend with typed destroy/clone —
  measured leak reduction from ~1 GB per 60 frames to near zero across the
  editor and example apps, with the corpus green under
  `KIRA_CORPUS_CHECK_LEAKS=1`.
- **Reborrow semantics**: `var r = t` over a `borrow mut` aliases the
  original storage (shared borrows still value-copy), fixing mutation loss
  in layout engines.
- **Array element write-backs**: `arr[i].field = v`, deep nested places
  (`arr[i].a.b`, `arr[i].xs[j]`, `arr[i].xs.append(v)`), and `borrow mut`
  of array elements now read-modify-write-back on every backend instead of
  mutating a transient copy.
- **Loop-body drop elaboration**: owned values are dropped every loop
  iteration, not just at function exit; struct field move-out no longer
  double-frees.
- **Closure fixes**: `.copy` captures clone instead of transferring
  ownership; each exported native closure gets a fresh native block, fixing
  distinct closures misdispatching after pointer reuse; virtual dispatch
  (`call_virtual`) transfers consumed-receiver ownership like direct calls,
  fixing chained widget-modifier double-frees.
- **Hybrid boundary hardening**: a long campaign of VM↔native fixes —
  aggregate double-frees, enum fields cloned across the boundary, callback
  return values dropped/moved immediately instead of retained forever,
  call-value argument escapes, native-state deep-cloning with dangling
  pointer guards, error-path double-free prevention — landing example apps
  and the kira_ui demo at zero leaks on hybrid.
- **Foundation C-helper leak fixes** across FS, ArgumentParser, and
  DynamicFfi, verified by leak-gated regression tests.
- **Ownership diagnostics**: `KIRA_LEAK_HEAP`, `KIRA_LEAK_RESULTS`,
  `KIRA_RESULT_VM_FREE`, `KIRA_SKIP_STATE_DESTROY`, and `KIRA_DBG` tracing
  environment variables.

### Backends & parity

- **Real LLVM backend**: `kira_llvm_backend` is a true LLVM C API backend —
  toolchain discovery, exhaustive IR opcode lowering, in-process object
  emission, and host linking — and is now the sole native backend (the
  textual-IR writer is retired). wasm32-emscripten builds go through the
  same path.
- **True hybrid execution**: hybrid manifests/contracts, native trampolines,
  and runtime callbacks give working mixed native↔runtime calls, verified
  across `kira run` and `kira build` workflows.
- **Incremental native codegen**: per-function LLVM codegen units cached by
  content hash, default-on for native executable links
  (`KIRA_INCREMENTAL=0` opts out); warm one-function rebuilds dropped from
  ~12 s to under 5 s on the editor project.
- **Native-bodied closure export**: native closures cross
  native→runtime→native calls via manifest capture types.
- **Numeric parity**: runtime shift amounts masked mod 64 before native
  lowering; saturating Float→Int casts; sub-64-bit unsigned FFI returns
  zero-extended; VM `%` truncates toward zero matching `/` and LLVM.
- **Native miscompilation fixes**: reassigned enum locals freed before use,
  virtual-call argument cloning violating LLVM dominance, and `.string_len`
  projections on call temporaries failing to lower (`KIR001`).
- **Build-cache correctness**: executable cache keys fingerprint the full
  linked native library set (including imports and C++ sources), so native
  edits trigger relinks instead of silently reusing stale binaries; wasm
  builds fingerprint with the Emscripten selector.
- **Windows and cross-target support**: native env/pid/socket polling and
  linker paths fixed; cross-compilation target selectors threaded through
  the build pipeline and FFI; managed Clang gained a Darwin driver helper
  for macOS SDK-correct invocations.
- **Hybrid stdout correctness**: `kira run --backend hybrid DIR > file`
  streams complete, byte-identical output.

### Graphics & shaders

- **Four new shader backends**: WGSL, HLSL, MSL, and SPIR-V join GLSL, with
  KSL intrinsics supported across all of them and stable name emission.
- **KSL compute shaders**: MSL/HLSL/GLSL compute lowering with `ksl!` macro
  plumbing, integer textures (`Texture2dUint`/`texelFetch`), while loops,
  and vertex-stage buffer-slot fixes for instance pulling.
- **`atomicAdd` intrinsic** with per-backend lowering and validation: target
  must be a `read_write [UInt]` storage resource; HLSL rejects it with
  `KSL072`; mixed atomic/plain buffer use is rejected with `KSL073`.
- **GLSL compute correctness**: `main()` synthesizes and passes the input
  struct (populating builtins like `gl_GlobalInvocationID`) and emits real
  declared SSBOs instead of silently emitting invalid GLSL.
- **WebGPU surface support**: surface detection and canvas creation for web
  exports.
- **Case-sensitive shader import paths** resolve on Linux, not just
  macOS/Windows.

### FFI & native

- **Dynamic FFI via libffi**: the VM invokes native functions directly
  through a new `kira_dynamic_ffi` package — no precompiled native backend
  required — with a managed, pinned libffi fetch step.
- **Autobind improvements**: deterministic generated output (sorted keys),
  `ffi autobind --backend` selection, and generation during `kira check` /
  `kira test` so clean checkouts build their own bindings under
  `app/bindings/<module>.kira`.
- **C++ native libraries**: `.cc`/`.cpp`/`.cxx`/`.mm` translation units
  compile with `-std=c++17` (e.g. HarfBuzz).
- **Framework-only libraries and shared C symbols**: native libraries can
  contribute only system frameworks/libs, and multiple `@FFI.Extern`
  declarations can bind the same C symbol with different signatures (e.g.
  `objc_msgSend`), enabling direct Objective-C/Metal calls without shims.
- **ABI correctness**: large struct returns use the sret convention on
  SysV/AAPCS64/Windows; callback bridge payloads stay alive for their full
  lifetime; in-process library mode resolves symbols when no shared library
  exists.
- **Foundation file APIs**: binary-safe `fs_write_bytes` / ranged
  `fs_read_range` reads, plus recursive `removePath` and `renamePath`.
- **Import resolution**: sibling source-directory imports restored while
  preserving package-root qualification rules.

### Runtime & performance

- **VM interpreter overhaul**: hot dispatch split into focused modules with
  fused compare/branch/arith superinstructions; `-Dvm-debug` and a safety
  test module let hot VM code run ReleaseFast inside Debug builds.
- **Native optimization defaults**: native binaries now actually run
  optimized LLVM codegen (previously unoptimized); `KIRA_NATIVE_OPT`
  (default `-O2`) and `KIRA_KEEP_IR` env vars control it.
- **Hybrid frame-time work**: payload-less enum variants interned as shared
  blocks, pointer-keyed enum declaration caches, and getenv memoization
  took example-app frame time from ~140 ms to ~95 ms and tree_build up
  ~2.7×; array-element borrow-elision restored a resize benchmark from
  33 fps to 75 fps.
- **Bounded recursion**: deep VM recursion raises a clean `RuntimeFailure`
  instead of crashing around 315 frames.
- **Benchmark harness**: `zig build bench` covers six cost classes.

### Live reload & tooling

- **Source-level debugger**: `kira debug` opens an interactive source-level
  REPL, and `kira debug --dap` serves the Debug Adapter Protocol over stdio
  for editors — conditional breakpoints, step/next/continue, and
  launch-after-`configurationDone` semantics on both `--backend vm` and
  `--backend llvm`, backed by a new `kira_debug` package and KBCD line
  tables (hybrid debugging is rejected up front for now).
- **Live reload**: new `kira_live` package and `kira live` command with
  supervisor/protocol/bundle-builder for desktop, macOS, and iOS; desktop
  hot reload runs a reload-generation loop that re-verifies health markers
  each generation.
- **Real platform runners**: macOS and iOS Simulator live runners demand
  real bundle/link/entrypoint/frame evidence, and a wasm32-emscripten
  backend executes real Kira entrypoints via emcc + Node.
- **`kira export`**: platform project/export scaffolds for
  apple/web/windows/android/linux, typed runner/platform ids, the
  `.klbundle` live protocol, and merged Xcode workspace export.
- **Bounded smoke tests**: `--quit-after <duration>` and `--headless` on
  run/live commands.
- **`kira build --timings`** honored correctly.

### Testing

- **`kira test` backend parity**: identical pass/fail verdicts across
  `--backend vm|hybrid|llvm` (llvm additionally proves the LLVM executable
  phase gate); `@Native` test suites route through the real hybrid bridge.
- **Pure-Kira test driver is the default runner**: expect/trap verdicts are
  computed in Kira itself (`KIRA_LEGACY_TEST=1` restores the Zig runner);
  trap tests verify the expected failure message, not just any abort, and
  PASS/FAIL/KTRAP markers are NUL-prefixed so program output can't be
  miscounted.
- **Kira-native suites**: a 949-test language-surface harness, a 224-case
  FFI bridge suite (which surfaced the FF1 closure-dispatch bug), and the
  migrated runnable corpus all run through `kira test`, with per-leaf
  `Tests { backends, phase }` matrices honored for corpus roots and the
  recursive `kira test tests-kik` surface wired into CI.
- **Corpus infrastructure**: check/build phases parallelized behind a
  reader-writer lock (~1.6× faster), `-Dstable-tests` /
  `KIRA_CORPUS_STABLE` for flaky native builds, and rotted cases repaired.
- **Memory verification**: `zig build verify-memory` / `verify-leaks`
  targets wired into the build, with ownership-parity, leak-repro, and
  closure-capture regression corpora.
- **CI**: Emscripten 4.0.21 setup for WASM coverage; shader golden files
  update via `KIRA_UPDATE_SHADER_GOLDENS=1`.

### Architecture (Core Law #5)

- **Verified executable IR**: a `verify(caps)` phase makes it structurally
  impossible for a backend to consume merely-typechecked IR; `kira check`
  runs the same executable-obligation verifier, so a passing check
  guarantees build/run won't hit a later lowering gap.
- **Bytecode container KBC7**: new opcodes append to the serialized range
  (old tags preserved), with the reader accepting older containers.
- **Package extractions and file-size splits**: structured CLI diagnostics
  moved to `kira_diagnostic_messages`; managed LLVM/libffi install wiring
  moved to `build_support/managed_install.zig`; oversized VM, semantics,
  and autobind files split into focused sub-1000-line modules.
- **ABI drift guards**: a comptime assertion pins `NativeStateBox`'s layout
  to the C `KiraNativeState` prefix.
- **Test discovery repairs**: dormant VM execution/native-bridge suites and
  the devflow unit tests were wired into their runners (exposing and fixing
  14 pre-existing native-bridge failures); the memory-validation artifact
  is now actually executed by `zig build test`.

### Project Matter

- **Declaration manifests**: `package.kira` (a `Package` declaration with
  plain structs and array literals) replaces TOML as the project manifest
  across run/check/build/test/live/package commands, with `KMAN` schema
  diagnostics, `kira migrate-manifest` for legacy `kira.toml` /
  `NativeLibs/*.toml` (globs, git dependencies, link flags, autobind
  profiles, and Kira versions all preserved), and `kira new` templates
  emitting sanitized declaration manifests.
- **`devflow` automation**: a repo-native Zig tool drives the whole
  fork→PR→review→land→sync flow (content-diff status, signed commits,
  fork-SSH pushes, exact-head CI and review gates, squash-with-merge-subject
  landings) — and now the release flow too: `next-version`, `release-prep`,
  and `release` compute the incremental-year version, store it, and cut a
  signed release tag only when build.zig, the release workflow, the
  changelog section, and tag state all agree.
- **Versioning scheme**: switched from calendar `2026.07.x` to
  incremental-year `1.7.x` (2026 = year 1); patch numbering continues
  across the schemes.
- **Release infrastructure**: metadata-driven LLVM toolchain bundle releases
  from `llvm-metadata.toml`; the release workflow provisions LLVM/libffi
  and generates GitHub release notes from this changelog's matching
  section.
- **Project layout**: examples/templates migrated to a project-root layout;
  the CLI renamed from `kira-bootstrapper` to `kira`; docs site updated for
  the CLI, folder examples, and toolchain setup.
- **No Python**: repo tooling (including the `kira live web` file server)
  is pure Zig/Kira.
- **Native memory model documented** in `KIRA_MEMORY_MODEL.md`.

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
