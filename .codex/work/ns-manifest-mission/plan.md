# Mission: file-scoped imports + package.kira everywhere (2026-07-14)

## Workstream B — package.kira migration (first; mechanical)
Batches (from inventory agent):
1. benchmarks/ — 6 project.toml, no native libs (trivial, kira migrate-manifest)
2. examples non-native — 10 simple project.toml
3. examples native — callbacks, callbacks_chain, sokol_ios_runtime_entry, sokol_runtime_entry, sokol_triangle (NativeLibs inlining via migrate-manifest)
4. foundation/ — kira.toml + 4 NativeLibs + CODE: kira_package_manager/src/manager.zig:722,753 + kira_cli/src/support.zig:466 hardcode foundation/kira.toml
5. dual cleanup — rm legacy kira.toml in tests-kik/corpus/sokol{,-triangle}, examples/hello/project.toml
6. code modernization — kira_live (web_bundle.zig:389, watch_inputs.zig:4,35, apple_runner.zig:478,482, bundle_builder.zig:286, source_watcher.zig) watch/write package.kira; ffi_autobind_cache.zig:138,207 add package.kira; app.zig legacy-first tests; wasm_emscripten_*/pipeline_tests fixtures → package.kira coverage (keep some legacy-compat coverage!)
7. docs — docs/native_libraries.md, docs/agent-memory/cli-build-toolchain.md; PackageMessages.zig:15,63 + CliMessages.zig:90 wording
8. root Kira.toml = workspace manifest (special) — decide separately
Keep legacy loader compat paths intact (declared policy: package.kira first, legacy still loads).
Gates: kira test tests-kik (clean bindings), zig build test, examples smoke (kira check each migrated dir).

## Workstream A — file-scoped imports (after B)
Waiting on import-system map. Goal: `import` in file A must not make module names visible in file B of same app/package. Design doc TBD here.
Models: impl = Opus 4.8 high agents; mass edits = Sonnet 5 low agents.

## Workstream A design (from import-system map)
Leak mechanism: program graph merges all package files into one Program; semantics builds ONE global header-map set; imported-package decls register under scoped `Pkg.name` AND bare fallback → visible to every file. Import alias binding already file-scoped via importVisibleToContext (lower_shared_symbols.zig:91-101, source_path).
Fix: build per-file import index (source_path → imported module set) in lowerProgramWithOptions; gate bare-name fallback lookups (findFunctionHeader + type/construct/enum/alias/annotation equivalents in lower_shared.zig:159-167 family) and qualified roots by current file's imports (ctx.current_source_path, set per-decl lower_program.zig:499-502 — extend to header/signature phases via decl_origins).
Keep: same-package cross-file visibility, package-wide KSEM003.
Diagnostics: KSEM012/KSEM027 as today + add "defined in package X — add `import X` to this file" note (new code or note on KSEM012).
Tests: corpus imports/ suite updated; new fail-corpus (bare-no-import, qualified-no-import); must-compile per-file-import case. Blast radius: 15 multi-file corpus packages listed by map agent.
Key files: lower_program.zig:171-233,499-545; lower_shared.zig:31-167; lower_shared_symbols.zig:28-101; lower_exprs_core.zig:177-367; lower_exprs_call_resolution.zig; builder.zig:77-240.

## CHECKPOINT 2026-07-14 (paused by user)
Branch: flow/package-kira-migration (NOT committed, NOT pushed). Working tree: 17 M, 47 D, 25 ?? — all intentional.
DONE:
- 22 dirs migrated via kira migrate-manifest (benchmarks×6, examples×15+hello dual, foundation); NativeLibs inlined
- legacy manifests + 13 NativeLibs/*.toml deleted (C sources kept); stale checked-in bindings deleted (foundation/bindings/, examples callbacks/sokol *.kira); dual dirs cleaned
- all migrated dirs pass kira check (incl. foundation, sokol_triangle, corpus sokol dirs)
- Opus agent: code couplings FIXED+verified (manager.zig foundation resolution, support.zig hasManagedResources, kira_live watch/write incl. declaration shim, app.zig fixtures + package.kira-first precedence test, autobind-cache test coverage)
- Sonnet agent: docs+messages DONE (native_libraries.md rewrite, cli-build-toolchain.md, PackageMessages/CliMessages wording; verified zig build)
PARTIAL:
- kira_build test fixtures agent KILLED mid-work: wasm_emscripten_tests/width/closure_width edited, pipeline_tests.zig partially converted (stopped at "test 4 KiraUI/CardExample path-dependency"). Files compile status UNVERIFIED. Resume: re-read 4 files, finish pipeline_tests conversion, ast-check, run targeted tests.
REMAINS:
1. finish fixtures conversion (resume killed agent's work)
2. gates: zig build test (NOTE: docs agent saw 5 wasm32 failures "libkira_runtime.dylib missing" claimed pre-existing/env — VERIFY on main before blaming migration), kira test tests-kik from clean bindings
3. devflow commit/push/PR/CI/land
4. Workstream A (file-scoped imports) — design in this file, not started
5. reminder: upstream ruleset "Main" still disabled (user)

## Follow-ups from PR #32 review (2026-07-15)
- autobind name derivation corrupts _SA_PPPIXELFORMAT_FORCE_U32 (generator bug; snapshots hand-fixed, regen would regress)
- autobind maps C `long` -> I32 in 3 sites (ffi_autobind_kira_types.zig:183, ffi_autobind_sdk_clang_ast.zig:337, ffi_autobind_sdk_model.zig:264) — wrong on LP64 Darwin (pthread opaque layouts); needs target-aware mapping + snapshot regen + tests
