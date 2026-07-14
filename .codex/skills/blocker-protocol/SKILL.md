---
name: blocker-protocol
description: "What counts as a valid blocker in this repo and the exhaustion bar before reporting one, including compileError handling and dirty-worktree expectations. Read before reporting any blocker, especially a compileError."
---

# Blocker protocol

A blocker is valid ONLY when the remaining obstacle is genuinely external:
missing physical hardware, unavailable credentials, revoked signing access,
inaccessible external service. A precise blocker report without prior
investigation is a failure, not a result.

## Exhaustion bar (minimum, before reporting)

Inspect architecture, search related implementations, add missing
lowering/runtime/backend support, add diagnostics for genuinely unsupported
cases, write/update tests, run targeted then repo-wide validation, remove
fake success paths touched, preserve VM/LLVM/hybrid/WASM parity.

A path is reasonable if architecture, standard practice, or docs support it —
difficulty, tedium, or unfamiliarity don't make it unreasonable. Dismiss a
path only on concrete evidence it leads nowhere or the capability is
genuinely unavailable.

## `compileError` blockers specifically

Validate sibling projects, report exact results, remove the blocker,
continue. Stopping after reporting is allowed only when continuation is
genuinely infeasible — never because the report itself was precise.

## Odds and ends

- Dirty worktree with unrelated changes already present: expected, don't
  revert unless unambiguously asked.
- A deliberate `comptime { @compileError(...) }` is an explicit user message,
  not corruption — don't remove it merely to pass a build unless removal is
  allowed.
