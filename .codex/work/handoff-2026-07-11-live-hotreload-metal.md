# Handoff — Desktop live hot reload + Metal rendering (2026-07-11)

Branch: `flow/kik-driver-and-corpus`. PR: **#27** on `kira-lang-com/kira`
(3 signed commits this session). Sibling repo `../kira-graphics` has 1 signed
commit (`d49bbbc`, ssh-signed — I set KG's local `gpg.format=ssh` since gpg
isn't installed; matches kira-zig).

Full design record: `.codex/work/checkpoints/011-vm-hot-reload.md` (§3a–§3e).
This file is the fast "what's next" summary.

---

## TL;DR

Desktop `kira live` now **renders on Metal and hot-reloads end to end** for
apps with a proper native dylib (verified on `../ui-foundation/Examples/
basic-foundation-app` — real dashboard, 60 FPS, screenshot captured). The user's
`project-matter/apps/editor` now **loads and runs** (was hanging in init) but
hits ONE remaining pre-existing multi-bundle limitation (below). `kira run` on
the editor works fine, so the editor's own code is correct.

Everything green: `zig build`, `zig build test` (full suite), corpus 527/0
(from earlier in session).

---

## What shipped (all on PR #27)

1. **VM in-place hot reload** (`e2f5c0d` bundles this with the Metal work):
   swap the executing bytecode module between frames, same process/window,
   VM heap + app state preserved. Retire (don't free) old modules; remap live
   closure function ids; re-point native-state boxes; rebind native trampolines.
   Falls back to relaunch when the native dylib changed or the edit is
   swap-incompatible. Files: `kira_vm_runtime/src/vm_reload.zig`,
   `kira_hybrid_runtime/src/hot_swap.zig` + `hot_swap_compat.zig`,
   `kira_live/src/reload_listener.zig`, `supervisor_reload.zig`,
   `kira_native_bridge/src/bridge.zig` (`rebind`), `vm.zig`
   (`invalidateModuleCaches`, `retired_prepared`).

2. **Metal desktop-live rendering — 3 stacked defects, all fixed**:
   - Metal never emitted `live.frame.presented` → added
     `kiraGraphicsLiveFramePresented()` (KG `SokolBackend.kira`), called from the
     Metal on-screen loop (`MetalApplication.kira`). Plus `metalActivateApp()`
     (KG `MetalWindow.kira`) becomes a foreground app before device creation.
   - Runner couldn't reach the WindowServer (`MTLCreateSystemDefaultDevice` /
     `[NSApplication sharedApplication]` HUNG) → the supervisor spawned it with
     **stdin=/dev/null**, detaching the GUI session. Fixed by
     `posixSpawnRunner` (`supervisor_shared.zig`) — `posix_spawn` **inheriting
     stdin/stdout/stderr** instead of `std.process.spawn`'s fork()+exec().
   - `RunnerClient` returned by value while `reader`/`writer`/`io_impl` held
     pointers into its own stack → dangling → `EXC_BAD_ACCESS` in `sendText`.
     Fixed by **heap-allocating** `RunnerClient` (`runner_client.zig`,
     `connect` now returns `*RunnerClient`).

3. **Editor init-hang fix** (`1cb17fa`): the app's own package can appear in its
   dependency graph, so the live build rebuilt the main bundle as a dependency
   and **overwrote its manifest** with `__kira_live_self__` (deps emit no shared
   lib) → runner self-bound against kirac (no app symbols) → hung in
   `HybridRuntime.init`. Fixed: skip the app's own package in the dep loop
   (`bundle_builder.zig`, `if (dep_bundle_id == app_bundle_id) continue`).

Also this session (earlier): full file-system watcher (`source_watcher.zig` +
`watch_inputs.zig` — watches app/ sources+shaders+assets, NativeLibs/,
kira.toml; ignores editor/OS noise + build outputs), Apple live sessions +
physical-iPhone hot reload (`apple_session.zig`, `apple_live.zig`, `ios_live.zig`
— bakes the Mac's LAN URL into the signed app), `docs/live.md` rewrite.
Plus `b153675` float32/f64 width coercion (separate, unrelated, already on #27).

Useful diagnostics kept (gated): supervisor reports
`live.runner.exited/signaled/alive_at_timeout` when health markers fail
(`supervisor.zig`); `KIRA_LIVE_NO_HOTPATCH=1` and `KIRA_HOTSWAP_DISABLE=1`
kill-switches.

---

## UPDATE 2026-07-11 (later session)

- **Windows CI was RED** on #27: `vm_tasks.zig:86 sleepNs` used
  `std.c.timespec`/`std.c.nanosleep` — POSIX-only; the timespec fields are
  `void` on windows-msvc so the corpus test exe failed to compile. Fixed by
  switching to the repo-native portable idiom
  `std.Options.debug_io.sleep(.fromNanoseconds(ns), .awake)` (commit `802f564`,
  pushed). `zig build` + `zig build test` (161/0) green locally.
- **Decision (user): land PR #27 FIRST.** The editor cross-bundle closure crash
  is pre-existing and unrelated to the hot-reload/Metal work → its own PR later.
- **Correction to the Option A recommendation below:** the live main bundle is
  ALREADY compiled whole-program — `buildProjectBundle` calls the SAME
  `compileFileForBackendWithSelector(entrypoint, .hybrid)` that `kira run` uses,
  and that lowers the full program graph. So "make the main bundle whole-program"
  is probably a no-op. The real mismatch is almost certainly a **function-id
  space** disagreement between the per-package **native dylib** (compiled from the
  dependency bundle) and the **whole-program VM module** loaded by the runner:
  `exportRuntimeClosureToNative` gets `fn=4846` from the native side and
  `module.findFunctionById` on the VM module can't resolve it. That's Option-B
  territory (unify/remap ids across bundles), NOT Option A. Investigate the id
  origin of the failing fn before writing code.

### Second follow-up: macOS in-process FFI symbol export (KTC007)

`kira test --backend hybrid tests-kik/harness` fails on macOS with KTC007: the
synthesized hybrid test-driver object (`main.test.o`) has **undefined
`_kira_developer_destroy` / `_kira_developer_last_error` / `_kira_developer_report`**
at link time. Those come from `kira_main`'s in-process developer API, registered
with `dynamic_lib = ""` (foundation/NativeLibs/KiraApi.toml). Commit `6b5d04e`
exported these for **Linux** (`-rdynamic`), but the **macOS** link of the driver
still can't see them (needs `-Wl,-export_dynamic` / the symbols made visible to
the test-driver link). Pre-existing, NOT run in CI (`zig build test` never
invokes `kira test tests-kik/harness`), and unrelated to the hot-reload/Metal or
Windows-CI work. This is exactly Codex's PR-#27 P1 (`dynamic_library.zig:69`)
but on macOS. Fix in its own change when picking up the FFI thread. `kira check
tests-kik/harness` passes (analysis clean); only the native hybrid link fails.

---

## THE OPEN ITEM — editor cross-bundle closure resolution

Repro: `cd ../project-matter/apps/editor && kira live` → reaches
`live.entrypoint.started`, then SIGABRT:

```
hybrid runtime failure in fn=4846: runtime closure function could not be resolved
  vm_native_bridge.zig:440  exportRuntimeClosureToNative  (findFunctionById fails)
  native_calls.zig:52       callNative exports a closure arg to native
  runtime.zig:476/235       native->runtime callback fn=4846
```

Root cause: `kira live` compiles **each package into its own bundle module**
(separate function-id spaces) and the runner loads only the **main** bundle's
module into the VM. A closure created in the main module over a function that
lives in a **dependency package's** bundle can't be resolved
(`module.findFunctionById(closure.function_id)` returns null). `kira run`
compiles **whole-program into one module**, so it resolves — and `kira run` on
the editor renders fine (`live.kira_graphics.frame.submitted`), proving the
editor code is correct. basic-foundation-app works in live only because it has
no cross-package closures.

**Recommended fix — Option A (smaller):** compile the main live bundle
**whole-program** — include all reachable `@Runtime` functions from every
package in the main VM module (matching `kira run`), while keeping per-package
native dylibs for hot-reload granularity. Look at `bundle_builder.zig`
`buildProjectBundle` → `compileFileForBackendWithSelector(entrypoint, .hybrid)`:
confirm whether it already pulls in imports whole-program (the editor's main
`.kirbc` is only ~9.4KB, so it looks SCOPED, not whole-program). If scoped, the
fix is to make the app-entry compile include all imported packages' runtime
functions in the emitted module. Then dep bundles carry native + are still
reload units, but the VM has every function.

Option B (bigger): load + link ALL bundle modules in the runner with a unified
id space (cross-module resolution + id remapping). More faithful to per-bundle
reload but a large change to module loading and the hot-swap id logic. Not
recommended first.

This is pre-existing (my dylib fix just got the editor far enough to hit it) and
NOT related to the hot-reload/Metal work. Waiting on the user's go for Option A.

---

## Gotchas learned (save yourself time)

- **Agent sandbox hides spawned processes**: `ps -A` / `sample` / `pgrep`
  CANNOT see the `kira live` runner (separate PID namespace), even with bypass
  perms. Don't waste time trying to attach a profiler. Diagnose live hangs with
  (a) socket-marker bisection through the app path, or (b) an in-process
  SIGUSR1 watchdog that FP-walks + `dladdr`-symbolicates the main thread to a
  file (the scaffolding was removed but the pattern is in git history around
  the middle of this session), or (c) macOS crash reports in
  `~/Library/Logs/DiagnosticReports/kirac-*.ips` for SIGABRT/SIGSEGV (parse the
  2nd JSON line with `jq`, not python).
- **Runner stderr does NOT reliably reach the supervisor log.** The socket
  (log_line frames) is reliable; raw `fd 2` writes get lost. If you need runner
  output, route it through `client.sendText(.log_line, ...)` or dup2 fd 2 to a
  file.
- **Screen must be UNLOCKED** — a locked Mac has no Metal drawables → no frame
  → KCL038 on any app. Auto-lock will bite during long `--run-for` runs.
- **Stale `.kira-build/live`**: always `rm -rf .kira-build/live` before a fresh
  live run when testing bundle-build changes; the KHM/dylib can be stale and
  mislead you (I read a stale KHM and chased a phantom).
- **KG signing**: `../kira-graphics` needs `git config gpg.format ssh` +
  `user.signingkey /Users/priamc/.ssh/github_ssh.pub` locally (done) or commits
  fail (gpg not installed).

---

## How to test

```
cd ~/Code/kira-projects/kira-zig && zig build      # refresh snapshot
cd ~/Code/kira-projects/ui-foundation/Examples/basic-foundation-app
kira live                                            # window renders (Metal), session.ready
# edit app/main.kira (change a Text label), save -> live.source.changed -> reload
```
UI edits are `@Native` → relaunch tier (new window, correct). A pure `@Runtime`
edit hot-patches in place (same window, state preserved).

Editor: `cd ../project-matter/apps/editor && kira live` → currently SIGABRTs on
the cross-bundle closure (open item above). `kira run` there works.

---

## PR state
Not landed. 3 commits on #27, CodeRabbit auto-reviews the pushes, Codex review
requested. Don't land until reviews clear + user go-ahead. KG PR not opened yet
(its `main` also carries the user's unrelated WIP) — open one for just `d49bbbc`
when asked.
