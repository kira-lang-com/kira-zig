# 002 - Real macOS Apple Runner Report

Status: complete

## Summary

Implemented and validated the real repo-local macOS live runner path with the Sokol graphics example.

The generated macOS `.app` now links only the live runner support archive into the host executable. App/native graphics code remains in the Kira live bundle dylib and is loaded by the Kira hybrid runtime, preventing the host executable from owning or duplicating Sokol/AppKit graphics classes.

The Sokol examples now emit `live.frame.presented` from Kira app code only after the actual `sokol.sg_commit()` frame submission path has run.

## Changes

- Updated `packages/kira_live/src/supervisor.zig`
  - macOS generated Xcode `OTHER_LDFLAGS` now excludes the app native object and native graphics libraries.
  - iOS keeps the existing embedded-native link shape.
  - Added a unit test proving the macOS generated project includes the runner support archive but not the Kira app object.
- Updated `examples/sokol_runtime_entry/app/main.kira`
  - Fixed explicit ownership transfers for Sokol descriptors.
  - Emits live frame evidence after `sg_commit()`.
- Updated `examples/sokol_triangle/app/main.kira`
  - Emits live frame evidence after `sg_commit()`.

## Real Runner Validation

Command:

```text
zig-out/bin/kira live macos examples/sokol_runtime_entry --run-for 2s
```

Result: passed.

Observed evidence:

```text
event: live.server.started host=127.0.0.1 port=42111 runner=macos
event: live.runner.launched pid=28527
event: live.client.connected target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_runtime_entry
live.bundle.graph.received
live.client.bundle.received
live.bundle.loaded
live.bundle.linked
live.entrypoint.started
live.frame.presented
event: live.session.ready target=/Users/priamc/Coding/kira-projects/kira-zig/examples/sokol_runtime_entry
event: live.shutdown.finished reason=quit-after
```

The successful frame marker was emitted by the Kira app after Sokol `sg_commit()`, not by host launch, Xcode build, bundle transfer, or entrypoint startup.

Generated project check:

```text
OTHER_LDFLAGS = (.../libkira_live_runner_support_xcode.a)
```

The generated macOS runner project did not include `com.kira.sokol_runtime_entry.o` or `libsokol.a` in the host executable link flags.

## Additional Validation

```text
zig-out/bin/kira check --backend hybrid examples/sokol_runtime_entry
```

Result: passed.

```text
zig-out/bin/kira build --backend hybrid examples/sokol_runtime_entry
```

Result: passed and wrote `.kbc`, `.khm`, `.o`, and `.dylib` artifacts.

```text
zig build test
```

Result: passed. Corpus summary: `1017 passed, 0 failed`.

```text
zig build
```

Result: passed and refreshed the dev Kira toolchain.

```text
zig build repo-truth
```

Result: passed.

## Notes

- `basic-foundation-app` was not used because this run was restricted to local work in the `kira-zig` repo. The strongest repo-local real rendering target was `examples/sokol_runtime_entry`.
- CI files and CI configuration were intentionally untouched per explicit user instruction.
- `packages/kira_live/src/supervisor.zig` remains a pre-existing oversized Zig file. This task avoided adding new runner ownership to the host executable and added a focused regression test, but the full supervisor decomposition remains required architectural follow-up under Core Law #5.
