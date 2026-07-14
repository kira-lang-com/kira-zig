---
name: kira-build
description: >-
  Hard-won build/run/debug gotchas for the Kira language ecosystem
  (kira-zig compiler, ui-foundation, project-matter, any repo with
  .kira/.ksl files). Use for building/running/debugging Kira binaries or
  .kira apps, `kira ffi autobind`, fork-CI failures on iPriam/kira, editing
  .kira/.ksl, or resize/segfault/VM crashes.
license: MIT
---

# Kira Build & Debug Gotchas

- Never `cp` a binary or reference `zig-out/` paths. Build with `zig build`,
  then run the raw `kira` binary directly.
- `kira ffi autobind` writes to the toolchain snapshot, not the repo — copy
  output into `foundation/bindings/` manually.
- VM `@memcpy alias` crash is scoped to the `kira test` comptime-Test
  driver, not the general VM.
- `rebuildOnResize: false` (or any widget-tree caching across frames) →
  dangling-capture segfault on resize: Kira closures don't survive repeated
  `nativeState` extraction. `MetalWindow.kira` intentionally skips
  rendering from the resize delegate — no live drag-reflow is by design.
- Python is banned repo-wide, no exceptions for one-off scripts (AGENTS.md
  Tooling rule).
- Example apps build per-directory: `cd Examples/<app-name>/ && kira build`.
- Visual-fidelity work (shader porting, pixel matching): confirm direction
  with one cheap pass before fanning out many agents at it.
