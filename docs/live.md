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
  -> client hot-restarts the entrypoint in the same runner process
```

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
live.reload.notified
live.bundle.update.received
live.hot_restart.started
live.hot_restart.finished
live.entrypoint.restarted
live.shutdown.started
live.shutdown.finished
```

The `.klbundle` directory is the runner artifact boundary. Runners consume bundle manifests, graph metadata, bytecode/hybrid payloads, assets/resources, diagnostics summaries, hashes, and platform/surface metadata instead of reaching into compiler internals.

Hot restart is currently honest full-bundle reload with `mode=full-bundle`. Incremental patching is not claimed yet; the bundle layout leaves room for it.

iOS physical live must use a device-reachable endpoint such as `--host 0.0.0.0 --port 42111` plus a LAN URL/token handoff. `localhost` is only valid for local desktop tests.
