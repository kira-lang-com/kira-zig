---
name: llvm-toolchain
description: "LLVM discovery order and toolchain/launcher caution for Kira: where LLVM is found, when to fetch it, and why zig build refreshes the dev kira snapshot. Read before touching launcher/build/toolchain code or when local LLVM tests need setup."
---

# LLVM / toolchain

Discovery order: `KIRA_LLVM_HOME` -> Kira-managed installs under
`~/.kira/toolchains/llvm/...` -> older repo-managed fallback paths.

`zig build` refreshes the `~/.kira/toolchains/dev` snapshot `kira` runs
from — be careful changing launcher/build/toolchain behavior, it affects
every subsequent `kira` invocation in the session.

Missing local LLVM is not a reason to skip LLVM validation — run
`kira fetch-llvm` / `zig build fetch-llvm` or help install it first. Don't
add tests/diagnostics that would only validate in some other intended
environment; always prefer real testing here.
