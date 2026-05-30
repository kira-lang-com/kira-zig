# Immediate Work

This file is the controller for the sequential Kira milestone queue.

Do not put full task bodies here. Each real task lives in its own Markdown file under:

    .codex/work/tasks/

The agent must read this file first, then execute every incomplete task file in sorted filename order.



## Source Of Truth

The source of truth is, in order:

1. `AGENTS.md`
2. `.codex/work/ImmediateWork.md`
3. The current task file under `.codex/work/tasks/`
4. The latest checkpoint under `.codex/work/checkpoints/`, if any
5. Repo-local code, tests, docs, and build configuration

Do not create or rely on Codex `/goal` state.

Do not replace this queue with a self-authored goal.

Do not treat a precise blocker report as completion.

Do not treat smoke tests, placeholder runners, fake markers, or host-only rendering as success.



## Current Queue

Execute these tasks in sorted order:

1. `000-repository-truth-cleanup.md`
2. `001-wasm32-emscripten-backend.md`
3. `002-macos-apple-runner.md`
4. `003-ios-simulator-apple-runner.md`
5. `004-ios17pro-basic-foundation-app.md`
6. `005-full-platform-validation-matrix.md`

Do not add new milestone tasks unless explicitly instructed by the user.

Do not skip a task because a later task looks more interesting.

Do not combine tasks unless the current task explicitly requires touching the next task’s infrastructure.



## Execution Model

Work sequentially and autonomously.

For each task:

1. Read `AGENTS.md`.
2. Read this file.
3. Read the latest checkpoint under `.codex/work/checkpoints/`, if any.
4. Find the first incomplete task in `.codex/work/tasks/`.
5. Read that task file completely.
6. Execute only that task.
7. Fix failures instead of accepting them.
8. Add or update tests before claiming completion.
9. Run the required validation for the task.
10. Write a report under `.codex/work/reports/`.
11. Write a checkpoint under `.codex/work/checkpoints/`.
12. Mark the task complete inside its own Markdown file only when its completion criteria are truly satisfied.
13. Move to the next sorted incomplete task.

Do not parallelize milestone tasks in the same branch.

Do not stop because a task becomes difficult.

Do not downgrade a failed requirement into an accepted limitation.

Every error is a failure until fixed, or until it is proven to be an external blocker outside the repo and outside this machine's control.



## External Blockers

External blockers are not success states.

A blocker is acceptable only when it is truly external to the repository and impossible to solve in the current environment, such as:

- missing physical hardware
- unavailable credentials
- revoked signing access
- inaccessible external service
- unavailable platform runtime that cannot be installed or simulated locally

Before reporting a blocker, exhaust repo-local paths:

- inspect existing architecture
- search for related implementation
- add missing lowering/runtime/backend support
- add diagnostics for unsupported cases
- add negative tests
- remove fake success paths
- run targeted validation
- run repo-wide validation when practical

If a blocker remains, mark the current task as incomplete/blocking with evidence, write a report and checkpoint, then continue to the next independent task if useful work remains.



## Required Report Format

Each task report under `.codex/work/reports/` must include:

- task filename
- status: complete, incomplete, or blocked
- files changed
- behavior implemented
- smoke/fake success paths removed
- tests added or updated
- commands run
- command results
- remaining failures, if any
- blocker evidence, if any
- exact reason completion criteria are or are not satisfied



## Required Checkpoint Format

Each checkpoint under `.codex/work/checkpoints/` must include:

- timestamp
- current task filename
- status
- last successful command
- last failing command, if any
- important files changed
- next recommended action
- whether VM/LLVM/hybrid/WASM parity was preserved or explicitly rejected
- whether AGENTS.md core laws were followed



## Global Non-Negotiables

The agent must follow `AGENTS.md` at all times.

In particular:

- no Python anywhere
- no smoke surfaces
- no fake markers
- no host-rendered content counted as Kira output
- no unexpected root-level Zig files
- no VM-only completion when LLVM/native should work
- no WASM build-only completion when WASM execution should work
- no simulator-launch-only completion when app rendering is required
- no oversized Zig file ignored when Core Law #5 applies
- no weakening tests to make incomplete work pass

If ambiguity exists, assume the stricter interpretation.

When unsure whether a result proves Kira behavior or host behavior, treat it as host behavior until proven otherwise.

## Hard Task Order Gate

Task order is mandatory.

Before executing any task, the agent must verify that every lower-numbered task file has:

    Status: complete

If any lower-numbered task is still incomplete, blocked, or missing a report/checkpoint, the agent must stop work on the current task and return to the lowest-numbered incomplete task.

A later task file is not permission to start that task.

Reading a later task for context is allowed only after the current task explicitly requires it. Editing code for a later task is forbidden until all previous tasks are complete.

If the agent accidentally starts a later task out of order, it must revert only its own out-of-order changes, write a checkpoint explaining the violation, and resume the earliest incomplete task.