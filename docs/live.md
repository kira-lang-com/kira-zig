# Live

Kira Live is a networked server/client system. The desktop runner path is the current complete implementation.

Flow:

```text
kira live <runner> <target?>
  -> resolve runner, target, profile, output roots
  -> start live server
  -> build target into .klbundle artifacts
  -> expose bundle graph over TCP
  -> runner client connects over TCP
  -> client downloads bundles
  -> client loads, links, and starts the entrypoint
  -> client reports ready/frame events
  -> source change rebuilds a new full bundle set
  -> supervisor attempts an in-place hot patch, falling back to relaunch
```

## File watching

The supervisor polls every file-system input of the bundle build, for the main
target and each dependency package: all files under `app/` (Kira sources,
`.ksl` shaders, assets), all native-library sources under `NativeLibs/`, and
each package's `kira.toml`. Editor/OS noise (dotfiles, `*~`, `*.swp`, `*.tmp`)
and build outputs (`generated/`, `exports/`, `zig-out/`, dot-directories like
`.kira-build/`) are ignored so rebuilds cannot re-trigger themselves. Any real
change rebuilds the bundles and enters the reload flow below — the tier is
chosen by what actually changed.

## Desktop reload tiers

**Tier 1 — hot patch (`mode=hotpatch`).** When the rebuilt bundle's native
library is byte-identical to the loaded one (a `@Runtime`/bytecode-only edit),
the running process swaps the bytecode module in place between frames: same
process, same window, VM heap untouched — app state survives the reload. The
runner's background reload listener (`reload_listener.zig`) stages the rebuilt
module; the sokol main thread applies it at the next native→VM callback
boundary when the VM is idle (`kira_hybrid_runtime/src/hot_swap.zig`). Live
closures are remapped to the recompiled function ids; retired modules stay
allocated because live values borrow their memory.

A hot patch is rejected — reported over `reload_failed` / `restart_required`
frames — when the edit changed something live values depend on:

- the native library changed (`restart_required`; sokol holds pointers into
  the loaded dylib),
- a struct/enum layout changed,
- a function referenced by a live closure was removed or changed signature.

`KIRA_LIVE_NO_HOTPATCH=1` disables tier 1 entirely (relaunch-only reloads).

**Tier 2 — relaunch (`mode=relaunch`).** The supervisor kills the runner and
spawns a fresh process with the rebuilt bundles, re-verifying the full
health-marker handshake. Required for native-code changes: sokol's macOS
backend enters `[NSApp run]`, which never returns, so native reloads cannot
restart in-process. App state does not survive.

Observed events include:

```text
live.server.started
live.bundle.built
live.bundle.served
live.client.connected
live.bundle.requested
live.bundle.sent
live.bundle.received
live.bundle.loaded
live.bundle.linked
live.entrypoint.started
live.frame.presented
live.session.ready
live.source.changed
live.bundle.rebuilt
live.reload.notified            (mode=hotpatch first, then mode=relaunch on fallback)
live.reload.staged              (runner: rebuilt module loaded, swap pending)
live.reload.applied             (runner: swap committed at a frame boundary)
live.reload.completed           (mode=hotpatch: first post-swap callback finished)
live.reload.deferred            (runner: async tasks busy, retried next frame)
live.reload.rejected            (runner: incompatible edit, falling back)
live.reload.restart_required    (native library changed, falling back)
live.runner.relaunched          (tier 2 generation spawned)
live.shutdown.started
live.shutdown.finished
```

The `.klbundle` directory is the runner artifact boundary. Runners consume bundle manifests, graph metadata, bytecode/hybrid payloads, assets/resources, diagnostics summaries, hashes, and platform/surface metadata instead of reaching into compiler internals. Hot-patch generations are staged into `<bundle>.klbundle.gen<N>` directories — the canonical bundle directory is never overwritten while its dylib is mapped.

## Apple runners (macOS app, iOS simulator, physical iPhone)

Apple live sessions run the SAME watch/hot-patch loop as desktop
(`apple_session.zig`). Apple runners embed the Kira runtime and native code in
one signed app, so every source rebuild is applied as an in-place VM hot patch
over the live connection — the app keeps its window and state. A
swap-incompatible edit reports `live.reload.reinstall_required` (a signed app
cannot be silently respawned; rerun `kira live` to rebuild + reinstall).

**Physical iPhone** (`kira live ios`): by default the supervisor detects this
machine's LAN IP (`ipconfig getifaddr en0`/`en1`), bakes `http://<lan-ip>:<port>`
into the app's `KiraRunner.toml` BEFORE the device build (so it is code-signed
into the bundle), binds the live server on `0.0.0.0`, installs and launches via
`xcrun devicectl`, and serves the session — the phone connects back with no
flags and VM hot reload works exactly like desktop. Override with `--host`,
`--port`, or `--server-url`. The iPhone must be unlocked, on the same network,
and trusting the development profile. `localhost` endpoints are rejected for
physical devices.
