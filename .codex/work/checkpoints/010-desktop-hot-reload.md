# Checkpoint 010 — Desktop live hot-reload (the hang / beachball / KCL039 timeout)

Status: **DESIGN + HANDOFF ONLY. No code changes made for hot-reload yet.**
Date: 2026-06-09
Author context: continuation of the `kira live` hybrid-crash session (checkpoint
context in memory `hybrid-enum-bridge-crash`). The malloc double-free crash is
**already fixed and committed-worthy** (corpus 1131/0, verify-leaks green). This
document is ONLY about the *next* problem: desktop live reload doesn't work.

---

## 1. The problem (what the user reported)

After the crash fix, `kira live` on UI Foundation:
- app renders, then **visually hangs / rainbow beachball**, doesn't update,
- **live reload fails** with `error[KCL039]: live reload timed out` after ~20s.

This is a **pre-existing, incomplete WIP** in the live-reload code, NOT caused by
the crash fix. The reload path used the same blocking model before the ownership
changes.

## 2. Root cause (confirmed by reading the code + reproducing)

The desktop runner blocks the whole thread inside the sokol event loop and never
reads the reload bundle:

- `packages/kira_live/src/runner_support.zig`
  - `runLiveFromManifest` (~line 34) is a `while (true)` loop:
    1. `receiveBundleSet(...)` — **blocks** reading socket frames until a
       `replace_bundle` for the main bundle arrives, returns `.bundle_ready`.
    2. `runBundle(...)` (~line 180) — loads the hybrid runtime and calls
       `runtime.run()` (line 221) which enters sokol's `sapp_run` and **blocks
       until the window closes / `sapp_request_quit` is called**.
    3. loop back to step 1.
  - So while the app runs (step 2), **nobody reads the socket**. A reload bundle
    the supervisor sends mid-run sits unread.
- `packages/kira_live/src/supervisor.zig`
  - On a detected source change, `rebuildAndSend` (~line 292) rebuilds, calls
    `connection.sendGraphAndBundles()` (sends the new `replace_bundle` frame),
    then `connection.waitForReloadMarkers(stdout, 20 * ns_per_s)` (line 312).
  - The runner never reads the frame → markers never arrive → **20s timeout →
    `KCL039` (`liveReloadTimedOut`)**. That 20s blocking wait is the beachball
    window the user sees.

The only existing way the loop ever breaks out of `runtime.run()` is the
`--run-for` quit timer: `startNativeQuitTimer` (runner_support.zig ~line 236)
spawns a background thread that sleeps then calls the native `sapp_request_quit`
symbol looked up from the loaded library. **This proves the mechanism we need
already works**: a background thread calling `sapp_request_quit` cleanly unwinds
`runtime.run()`.

### Marker-ordering bug (also blocks reload even once the bundle is read)
`supervisor_shared.zig` `waitForReloadMarkers` (line 150) succeeds only when it
sees BOTH `live.hot_restart.finished` (seen[2]) AND `live.entrypoint.restarted`
(seen[3]). But in `runBundle`, `live.hot_restart.finished` is emitted **after
`runtime.run()` returns** (i.e. after the *reloaded* window also closes). So even
if the bundle were read, the supervisor could never confirm the reload until the
new window is closed. **`live.hot_restart.finished` must be emitted when the
reloaded run presents its FIRST FRAME, not when it ends.**

## 3. How kira-swift genuinely solved this (the model to copy)

Repo: `../kira-swift`. Key files:
- `Sources/KiraVM/EmbeddedPatchClient.swift`
- `Sources/KiraVM/DebugHostBridge.swift` (the important one)
- `Sources/KiraCompiler/HotReload/{HotReloadManager,PatchServer,FileWatcher}.swift`

The genuinely-working design has three principles:

1. **The patch/reload listener runs on a separate background queue/thread.** It
   reads patches over the socket while the app's event loop keeps running. It
   never blocks the render loop. (`EmbeddedPatchClient` uses a background
   `DispatchQueue` + async `connection.receive`.)

2. **Reloads are applied BETWEEN frames, never mid-execution, via a single
   serialized queue.** Every VM operation — boot, each frame/event callback, and
   the patch apply — runs on one serial queue (`KiraBytecodeHostBridge.queue`).
   When a patch arrives mid-frame, it is stashed as `pendingBundle` and applied
   in `runCallback`'s `defer` once the in-flight callback finishes
   (`applyPendingPatchIfSafe`, guarded by `isExecutingCallback`). This guarantees
   the module is only swapped when the VM is idle — no use-after-free, no
   re-entrancy.

3. **Two reload tiers from a compatibility evaluator** (`KiraPatchCompatibility…`):
   - **hotPatch / softReboot** → swap the bytecode module *in place*, keeping the
     SAME window. `loadRuntime` builds a fresh `VirtualMachine`, runs
     `__kira_init_globals` + entry, optionally snapshots/restores "reload-stable"
     state (`__kira_debug_snapshot_state` / `__kira_debug_restore_state`) and
     calls `graphics_on_reload`, then `vm = loadedVM`. The window/host is never
     torn down.
   - **fullRelaunchRequired** → reject, signal the host to relaunch the process.

   kira-swift can swap in place because on-device it is **pure-VM (bytecode
   only)** — no dlopen'd native code to reload.

## 4. The kira-zig adaptation (what to actually build)

kira-zig `live` is **hybrid**: a dlopen'd native dylib (`@Native` Kira code) +
VM (`@Runtime` Kira code), all driven by sokol `sapp_run` inside `runtime.run()`.
Two regimes:

- **VM-only change** (only `@Runtime`/bytecode changed): could swap the bytecode
  module in place like kira-swift → true same-window hot-patch.
- **Native change** (`@Native` code → dylib rebuilt): the dylib must be reloaded;
  sokol holds function pointers into it, so an in-place swap is unsafe → must do
  a **soft reboot** (tear down sokol, recreate). New window, but reload WORKS.

### Recommended phased plan

**PHASE 1 — make reload work at all (soft reboot via background listener).**
This directly kills the hang + KCL039 and reuses the existing `restart_count`
loop. Lowest risk, highest user value. Do this first.

1. In `runner_support.zig`, add a **background reload-listener thread** spawned
   right before `runtime.run()` in `runBundle` (model it on `startNativeQuitTimer`).
   The thread loops on `client.readFrame`:
   - on `replace_bundle` for the main bundle → `storeBundlePayload` to disk, set a
     shared `pending_reload = true`, then call the looked-up `sapp_request_quit`
     to unwind `runtime.run()`.
   - on `shutdown` → set `pending_shutdown = true`, send `shutdown_ack`, quit.
   Use an atomic/guarded flag struct shared with the main loop. NOTE the socket
   reader (`RunnerClient.reader`) is currently single-threaded; either move ALL
   socket reads to this one listener thread (preferred — then `receiveBundleSet`
   for the *initial* bundle also goes through it), or guard with a mutex. Cleanest:
   make the listener the sole socket reader for the whole session.
2. `runLiveFromManifest` loop: after `runtime.run()` returns, if `pending_reload`,
   skip the blocking `receiveBundleSet` (bundle already on disk), bump
   `restart_count`, and re-`runBundle`. If `pending_shutdown`, return.
3. **Fix the marker ordering**: emit `live.hot_restart.finished` from the
   first-frame hook on a reloaded run (when `restart_count != 0`), not after
   `runtime.run()` returns. The first-frame hook is `kiraLiveFirstFrameHook`
   (runner_support.zig ~line 305) — it already gates on `first_frame_sent`. Add a
   restart-aware path so the reloaded run emits `live.entrypoint.restarted`
   (already at runBundle start) + `live.hot_restart.finished` (on first frame).
   Cross-check the exact marker set in `supervisor_shared.zig`
   `waitForReloadMarkers` (line 150): needs `live.hot_restart.finished` (seen[2])
   AND `live.entrypoint.restarted` (seen[3]).
4. **RISK to validate first**: can sokol `sapp_run` be called twice in one
   process on macOS Cocoa? The existing loop *assumes* yes (it's already shaped
   for restarts) but it has likely never executed twice in practice. WRITE A
   SMALL TEST: run `kira live desktop --run-for 30s`, edit `app/main.kira`
   mid-session, confirm the window reopens and renders (capture a screenshot per
   Apple Platform Laws). If double-`sapp_run` crashes/hangs on macOS, Phase 1
   must instead keep sokol alive and go straight to Phase 2's in-place reload, OR
   relaunch the runner process per reload (supervisor respawns child).

**PHASE 2 — same-window in-place reload for VM-only changes (kira-swift hotPatch).**
Optional polish once Phase 1 works.
- Add a compatibility check: if only bytecode/`@Runtime` changed (native dylib
  hash unchanged), do an in-place VM module swap instead of soft reboot.
- Needs a hook point in the frame loop where the VM is idle. sokol calls back
  into Kira each frame via the bridge; between frames control is in native code.
  So register a **native frame callback** (in the graphics host / sokol setup)
  that, when a `pending_reload` flag is set and no Kira callback is in flight,
  swaps `runtime.vm`'s loaded `bytecode.Module` (mirror kira-swift
  `applyPendingPatchIfSafe` + `loadRuntime`). Keep the dlopen'd library.
- Mirror kira-swift's reload-stable-state snapshot/restore + `graphics_on_reload`
  hooks if state continuity is wanted.
- This is a deeper change touching `kira_hybrid_runtime` and the graphics host
  (`../kira-graphics`). Scope it separately.

## 5. Key files & line anchors (as of this checkpoint)

- `packages/kira_live/src/runner_support.zig`
  - `runLiveFromManifest` ~34 (the restart loop), `runBundle` ~180,
    `runtime.run()` ~221, `startNativeQuitTimer` ~236 (COPY THIS PATTERN),
    `receiveBundleSet` ~254, `storeBundlePayload` ~294,
    `kiraLiveFirstFrameHook` ~305, `RunnerClient` ~369.
- `packages/kira_live/src/supervisor.zig`
  - `runDesktop` ~142, the no-`run-for` watch loop ~245, `rebuildAndSend` ~292
    (sends bundle + `waitForReloadMarkers` 20s @312).
- `packages/kira_live/src/supervisor_shared.zig`
  - `sendGraphAndBundles` ~97, `waitForHealthMarkers` ~125,
    `waitForReloadMarkers` ~150 (FIX THE MARKER SET / ORDERING ASSUMPTION).
- `packages/kira_live/src/protocol.zig` — frame wire format, `LiveMessageKind`,
  `readFrame` (already hardened against desynced frames this session).
- `packages/kira_hybrid_runtime/src/runtime.zig`
  - `HybridRuntime.run` ~54 → `runWithWriter` ~58; `bridge` field; `deinit` ~46.
    `bridge.library.lookup(RequestQuitFn, "sapp_request_quit")` is how the quit
    timer gets the symbol — reuse for the listener thread.
- kira-swift reference: `../kira-swift/Sources/KiraVM/DebugHostBridge.swift`
  (`KiraBytecodeHostBridge`, `applyPendingPatchIfSafe`, `loadRuntime`,
  `runCallback` deferred-apply), `../kira-swift/Sources/KiraVM/EmbeddedPatchClient.swift`
  (background listener).

## 6. Definition of done (per repo Agents.md / Core Laws)

- Live reload completes WITHOUT KCL039 and WITHOUT a beachball; app updates.
- Capture a screenshot of the reloaded `basic-foundation-app` rendering (Apple
  Platform Laws — launch/window/timeout are not success; Kira-rendered content is).
- Add a regression test for the runner-side listener (e.g. a fake socket feeding
  a `replace_bundle` mid-run sets `pending_reload` and triggers quit). The
  `--run-for` + edit flow is the integration check.
- Backend parity: this is runner/live plumbing; no VM/LLVM/WASM semantics change.
  Keep the crash-fix invariants from `hybrid-enum-bridge-crash` intact.
- File-size (Core Law #5): `runner_support.zig` is ~429 lines; adding the listener
  may push it over 600. If so, EXTRACT the reload-listener + RunnerClient into a
  focused module (e.g. `reload_listener.zig` / `runner_client.zig`).

## 7. How to reproduce the current failure

```
# from repo root
zig build                      # refresh the kira dev snapshot
kira live desktop examples/...basic-foundation-app   # or the UI Foundation app
# in another shell, edit app/main.kira while it runs
# observe: beachball, then "error[KCL039]: live reload timed out" after ~20s
```
Headless/automatable variant: `kira live desktop <app> --run-for 16s`, edit a
`.kira` under the app's `app/` dir mid-run; supervisor prints the
source.changed → rebuild.started → rebuild.finished → reload.notified → (timeout)
sequence. `git checkout` the edited file afterward.

## 8. macOS reproduction caveat
Synthetic mouse-event injection is blocked by TCC from a terminal, so the
*interactive* beachball can't be driven headlessly. The reload timeout IS
reproducible headlessly (file edit). Validate the interactive path manually with
a real window + screenshot.
