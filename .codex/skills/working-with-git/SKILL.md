---
name: working-with-git
description: "Git and PR workflow for this repo: commit/push/PR/review/land/sync via the devflow tool, signed commits, single-stage upstream landing with squash-with-merge-subject, SSH workaround for workflow-scope pushes. Read before any git/PR/merge operation."
---

# Working with git

Never destructive git: no `reset --hard`, `restore`, `checkout -- <file>`,
`stash drop`; worktrees may carry uncommitted WIP that those commands would
discard irreversibly.

## Use `devflow`, NEVER raw git/gh

```sh
zig build devflow -- status              # default + active-branch content diff
zig build devflow -- commit [-m "..."]   # stage all + signed commit
zig build devflow -- push                # push branch to fork over SSH
zig build devflow -- pr-scope            # inspect complete-branch PR metadata
zig build devflow -- open-fork-pr        # open/refresh ONE PR against upstream
zig build devflow -- request-reviews N [--codex]
zig build devflow -- wait-ci N                      # exact-head CI gate
zig build devflow -- ci-failures N                  # exact-head failed job logs
zig build devflow -- blacksmith [enable|disable|status]
zig build devflow -- review-findings N [--codex]   # exact-head inline findings
zig build devflow -- wait-reviews N [--codex]      # blocks until resolved
zig build devflow -- land N              # squash-merge, mirror fork, resync local
zig build devflow -- sync                # resync local main if drifted
```

Branch off `upstream/main`. `open-fork-pr` opens directly on upstream
(single-stage — owner is a maintainer, no fork→upstream double-landing).
Before opening or refreshing a PR, Kai runs `pr-scope` and checks that its title
and body describe the complete `upstream/main...HEAD` diff and branch commit
history. The current Codex task, conversation, session, and latest commit are
never the PR scope. `open-fork-pr` regenerates both fields from the full branch
and also replaces stale metadata on an already-open PR.
`land` squash-merges with subject `Merge pull request #N from <owner>/<branch>`,
then force-mirrors fork `main` to `upstream/main`.

Never trust ahead/behind counts (squash/merge rewrite or add SHAs) — `devflow
status` reports actual content diff instead, trust that. Always resync local
`main` after any merge, same session (`devflow land`/`sync` does this).

`wait-reviews` and `land` only accept submitted reviews attached to the current
PR head; a stale review from an earlier push never satisfies the gate.
`wait-ci` reports and blocks on checks attached to that exact head, and `land`
applies the same green-CI gate itself. Use `review-findings` instead of raw
GitHub commands to read current-head bot comments, and `ci-failures` for failed
workflow logs.
CodeRabbit's successful head check counts as its response when it explicitly
skips an oversized PR. `land` refuses with `ReviewsPending` or
`UnresolvedReviews` if CI isn't green or a requested review (CodeRabbit always,
Codex if pinged) isn't resolved — that's the gate working, not a bug; don't
bypass it by merging manually.

## Guardrails

- Never force-push a shared branch or rewrite published `main`.
- Never bypass commit signing (`--no-gpg-sign` etc.) — fix signing or stop
  with the exact blocker.
- `origin` is always the fork — mirror/branch-host only, never a landing
  target.
