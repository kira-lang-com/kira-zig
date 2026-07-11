# Checkpoint 011 — Full VM hot reload (in-place module swap, not hot restart)

Status: **IMPLEMENTED + unit/integration tested. Visual E2E pending (machine
was at the lock screen during the session — see §6).**
Date: 2026-07-11

## 1. What was built

True hot reload for the Kira VM in desktop live mode: a `@Runtime`-only edit is
swapped INTO the running process between frames — same process, same window,
same VM heap. App state survives because Kira has no module-level globals: all
persistent state lives in native-state boxes and closure captures in the VM
heap, which the swap never touches. This supersedes (but keeps, as fallback)
the process-relaunch reload from checkpoint 010 / commit 62fb039.

Two tiers (supervisor tries 1, falls back to 2):
1. **hotpatch** — native dylib byte-identical: stage rebuilt module + manifest,
   swap at a frame boundary, remap live closure fn ids.
2. **relaunch** — native changed / incompatible edit / runner silent: existing
   kill-and-respawn generation loop.

## 2. Key design facts (why this works)

- **Vm does not own the module**; every entrypoint takes `*const Module`.
  Module-derived caches (PreparedModule, type caches) are keyed by module
  pointer — but the hybrid runtime holds the module BY VALUE, so an in-place
  swap keeps the address: `Vm.invalidateModuleCaches()` (vm.zig) invalidates
  explicitly. The old PreparedModule is RETIRED into `vm.retired_prepared`,
  not freed: the app entrypoint's interpreter frame is parked inside native
  `sapp_run` for the whole session and resumes old prepared code at quit.
- **Old modules are retired, never freed** (`HybridRuntime.reload.retired_*`):
  heap struct/enum records and constant strings borrow name/byte slices from
  module memory for as long as the value lives.
- **Function ids are module-relative**: recompiles reassign them. Live
  references = heap `ClosureObject.function_id` + exported native closure
  blocks (`[u64 fn_id, u64 cap_count, ...]` — native reads word 0 every
  callback). `vm_reload.remapLiveFunctionIds` rewrites both (verify pass, then
  commit). The in-flight callback's id was read by native BEFORE the remap, so
  `hot_swap.enterCallback` translates that one id by hand.
- **The callback boundary is the runtimeInvoke HOOK, not invokeRuntime**: the
  entry invocation never returns (parked in `sapp_run`), so depth counting
  must only count hook-driven callbacks. Swap applies at hook depth 0→1 with
  `vm_reload.tasksIdle` (queued VmTasks capture prepared-function indices).
- **NativeStateBox** embeds `module: *const Module` (same address, fine) and a
  type-name slice into old module memory → `repointNativeStateBoxes` re-points
  at the new module's identical TypeDecl.
- **Bridge trampolines** are keyed by function id → `NativeBridge.rebind()`
  re-resolves the id→symbol map from the new manifest against the
  ALREADY-OPEN dylib (never re-dlopens).
- **Compat evaluator** (`hot_swap.evaluate`): all old struct/enum layouts must
  be identical in the new module; every live closure's function must exist
  (unique name) with identical signature. Function BODIES change freely.
- **Staging dirs**: rebuilt bundles land in `<bundle>.klbundle.gen<N>` — the
  canonical dir is never overwritten while its signed dylib is mapped
  (macOS kills the process on mapped-file rewrite).

## 3. Files

New:
- `packages/kira_vm_runtime/src/vm_reload.zig` — remap/repoint/tasksIdle + tests
- `packages/kira_hybrid_runtime/src/hot_swap.zig` — StagedSwap, ReloadState,
  evaluate/commit, enterCallback/exitCallback + tests (incl. full swap drive)
- `packages/kira_live/src/runner_client.zig` — extracted RunnerClient, write mutex
- `packages/kira_live/src/reload_listener.zig` — background sole-reader thread,
  staging, native-lib byte compare, restart_required/reload_failed frames
- `packages/kira_live/src/supervisor_reload.zig` — attemptHotReload outcome wait

Modified:
- `packages/kira_vm_runtime/src/vm.zig` — invalidateModuleCaches, retired_prepared
- `packages/kira_vm_runtime/src/root.zig` — export `reload`
- `packages/kira_native_bridge/src/bridge.zig` — `rebind()`
- `packages/kira_hybrid_runtime/src/runtime.zig` — `reload` state field,
  boundary hooks in runtimeInvoke, pub buildRuntimeDescriptors
- `packages/kira_hybrid_runtime/src/root.zig` — export hot_swap + tests
- `packages/kira_live/src/runner_support.zig` — listener spawn, reload markers,
  `KIRA_LIVE_NO_HOTPATCH` kill-switch
- `packages/kira_live/src/supervisor.zig` — hotpatch-first reload branch
- `packages/kira_live/src/protocol.zig` — comment fix + outcome-frame test
- `build.zig` — kira_bytecode import for live modules
- `docs/live.md` — rewritten reload tiers + marker list

## 3b. File watching (added same session)

`source_watcher.zig` rewritten from ".kira under app/ only" to ALL bundle-build
inputs per package (main + deps): every watchable file under `app/` (sources,
.ksl shaders, assets) and `NativeLibs/`, plus `kira.toml` via new addFile().
Noise filtered (dotfiles, `*~`, `*.swp/.swx`, `*.tmp`); output dirs ignored
(dot-dirs, generated/, exports/, zig-out/) so rebuilds can't self-trigger.
Bindings/ deliberately NOT watched (autobind output). Net effect: native-source
edits in kira-graphics/ui-foundation now trigger rebuild → dylib byte compare →
relaunch tier automatically; shader/asset/manifest edits trigger hotpatch tier.
supervisor.zig `watchPackageInputs`. Tests: inputs matrix + noise-ignore.

## 3c. Apple runners + physical iPhone (added same session)

`apple_session.zig` — shared watch/hot-patch session loop for macOS app, iOS
simulator, and physical iPhone (apple_live.zig's old driveSession sent bundles
once and shut down; now all Apple runners live-reload). Apple runners self-bind
native (`__kira_live_self__`) → every rebuild is hotpatch-eligible on device;
swap-incompatible edits emit `live.reload.reinstall_required` (no silent
respawn of a signed app).

`ios_live.zig` physical-device flow completed: LAN IP auto-detect (existing)
→ endpoint baked into KiraRunner.toml BEFORE the device build (code-signed in)
→ LiveServer binds 0.0.0.0 → `devicectl device install app` + `device process
launch --terminate-existing` → 60s accept → apple_session loop. The old
"devicectl-install-loop-not-implemented" wall is gone. NOT validated on real
hardware this session (no unlocked iPhone/GUI available); simulator/macos paths
compile+unit-test green, device path needs a phone: `kira live ios <app>`,
watch live.ios.install/launch.succeeded → live.session.ready → edit →
live.reload.completed mode=hotpatch runner=ios-device.

## 3d. Live diagnostics + editor init-hang (investigated, unresolved)

Env kill-switches / tracers added:
- `KIRA_LIVE_NO_HOTPATCH=1` — runner skips the reload listener (relaunch-only).
- `KIRA_HOTSWAP_DISABLE=1` — hybrid runtime skips enterCallback/exitCallback
  boundary hooks entirely (neutralizes the swap path even mid-callback).
- `KIRA_LIVE_DEBUG=1` — runner emits ordered CLIENT markers (reliable, unlike
  buffered stderr) through runBundle: live.debug.run_bundle.start →
  manifests_read → runtime_init.start → runtime_init.done → hooks_installed →
  entrypoint.invoking. Use to pinpoint where a runner stalls.

Findings from a diagnosis session (screen unlocked):
- `kira live` KCL038 (frame not presented) reproduces with BOTH kill-switches
  set → PRE-EXISTING, not caused by the hot-reload work (neutralized A/B is
  byte-identical). basic-foundation-app reaches live.ui_foundation.app.started
  but no frame — in the agent sandbox this is expected (no WindowServer; a
  screenshot shows only the terminal, no sokol window). Needs a real-display
  run to confirm frame presentation.
- project-matter editor (`kira live` in apps/editor): hangs INSIDE
  HybridRuntime.init — markers stop at runtime_init.start, never
  runtime_init.done, no error/KIC001, no crash trace. Main bundle is tiny
  (9446B bytecode, `__kira_live_self__`) so it is not a deserialize hang; it is
  in bindCurrentProcess self-symbol resolution. This path (native_bridge
  bind/bindCurrentProcess) was NOT touched by the hot-reload work — the only
  bridge.zig change is a purely-additive `rebind`. `kira check` on the editor
  passes. Hypothesis: the plain `kirac __live-runner` desktop host cannot dlsym
  the editor's @Native symbols (world/math_x) from itself. Left unresolved —
  needs process-level observation the sandbox blocks.

## 3e. Metal desktop-live rendering — ROOT-CAUSED AND FIXED

`kira live desktop` (macOS) rendered nothing (KCL038) because the app runs the
**Metal** backend (`graphicsDefaultBackend` → Metal on Apple; Sokol is the
portable/WASM fallback), and three separate defects stacked up. All fixed;
basic-foundation-app now renders its real dashboard live on Metal (screenshot
captured, 60 FPS), reaching `live.frame.presented` + `live.session.ready`,
rc=0, and hot reload runs end to end.

Root causes + fixes:
1. **Metal never emitted the live frame markers.** `kira_live_emit_first_frame`
   / `live.frame.presented` existed only in `sokol_impl.c`. Added
   `kiraGraphicsLiveFramePresented()` (KG SokolBackend.kira) — emits
   `live.kira_graphics.frame.submitted` + `kira_live_emit_first_frame()` — and
   call it from the Metal on-screen loop after the first real present
   (MetalApplication.kira). (This was "#1".)
2. **The runner could not connect to the WindowServer** →
   `MTLCreateSystemDefaultDevice` (and `[NSApplication sharedApplication]`)
   HUNG, whole process effectively suspended. Cause: the supervisor spawned the
   runner with **stdin redirected to /dev/null**, detaching it from the
   controlling terminal / GUI session. Fix: spawn the runner with
   **`posix_spawn` inheriting stdin/stdout/stderr** (supervisor_shared.zig
   `posixSpawnRunner`), replacing `std.process.spawn`'s fork()+exec(). `kira
   run` worked precisely because the bootstrapper spawns it with inherited
   stdin.
3. **RunnerClient dangling-buffer crash.** `RunnerClient.connect` initialized
   `reader`/`writer` with pointers into the struct's own inline buffers and its
   embedded `io_impl`, then **returned the struct by value** — the copy's
   pointers dangled into the connect-local's freed stack. Worked for the first
   few log lines, then the stack was reused → EXC_BAD_ACCESS in
   `sendText`→`Writer.write` (crash addr `0x164657265` = ASCII "ered"). Masked
   by the WindowServer hang; surfaced once #2 was fixed. Fix: **heap-allocate
   RunnerClient** so its address (and all interior pointers) stay stable;
   `connect` now returns `*RunnerClient`.
Also: `metalActivateApp()` (KG MetalWindow.kira) becomes a foreground GUI app
before device creation, hoisted ahead of `metalContextAlloc`.

Diagnosis note: the agent sandbox puts spawned processes in a PID namespace
invisible to `ps`/`sample`, so the hang was localized by (a) socket-marker
bisection through the KG Metal path, (b) an in-process SIGUSR1 watchdog that
FP-walked + `dladdr`-symbolicated the main thread to a dump file, and (c) the
macOS crash report for the SIGABRT. All that scaffolding has been removed; the
useful `live.runner.exited/signaled/alive_at_timeout` supervisor reporting
stays.

## 4. Markers / protocol

Runner→supervisor: `live.reload.staged`, `live.reload.applied`,
`live.reload.completed mode=hotpatch` (log_line); `restart_required`,
`reload_failed` (previously-unwired frame kinds, now used).
Supervisor: `live.reload.notified mode=hotpatch` → on completed
`live.reload.completed mode=hotpatch count=N`; on fallback
`live.reload.notified mode=relaunch reason=<outcome>` then generation loop.

## 5. Validation done

- `zig build test` fully green (incl. new: vm_reload remap/reject tests,
  hot_swap evaluator tests, full stage→enterCallback→commit→exitCallback drive
  with notify-event assertions, protocol outcome-frame round-trip).
- `zig build` green; snapshot refreshed.

## 6. Pending — visual E2E (environment blocker)

`kira live desktop ../ui-foundation/Examples/basic-foundation-app --run-for …`
reported KCL038 (frame not presented) in BOTH hotpatch and
`KIRA_LIVE_NO_HOTPATCH=1` baseline runs — NOT a regression from this work.
Screenshot probe showed the Mac at the LOCK SCREEN: no Metal drawables → sokol
frame callbacks never fire → no `live.frame.presented`, and no frame boundary
to apply a swap at. Once unlocked, run:

```
kira live desktop ../ui-foundation/Examples/basic-foundation-app --run-for 90s
# mid-run: edit Examples/basic-foundation-app/app/main.kira (e.g. a Text label)
# expect: live.reload.notified mode=hotpatch → live.reload.staged →
#         live.reload.applied → live.reload.completed mode=hotpatch
# verify: same runner PID, window stays open, label visibly changed; screenshot.
# also: edit a @Native file (kira-graphics/ui-foundation native lib) →
#         restart_required → mode=relaunch fallback works.
```

## 7. Known dev-mode tradeoffs (documented, bounded)

- Retired modules/prepared programs/manifests accumulate per reload (freed at
  exit). Rapid-save replaced stagings leak a Module (no Module.deinit exists).
- Post-quit entrypoint epilogue runs OLD code (parked frame, retired prepared).
- Anonymous-lambda name matching: remap is by function name — synthesized
  lambda names could theoretically pair an old closure with a different
  same-named, same-signature new lambda after heavy edits; worst case is stale
  behavior until relaunch, never memory unsafety.
