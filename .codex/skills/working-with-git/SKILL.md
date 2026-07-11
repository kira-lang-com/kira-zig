---
name: working-with-git
description: "Git and PR workflow for this repo: commit/push/PR/review/land/sync via the devflow tool, signed commits, single-stage upstream landing with squash-with-merge-subject, SSH workaround for workflow-scope pushes. Read before any git/PR/merge operation."
---

# Working with git

Never destructive git: no `reset --hard`, `restore`, `checkout -- <file>`,
`stash drop`. Worktrees carry uncommitted WIP; those discard it irreversibly.

## Use `devflow`, NEVER raw git/gh

```sh
zig build devflow -- status              # content diff, not ahead/behind counts
zig build devflow -- commit [-m "..."]   # stage all + signed commit
zig build devflow -- push                # push branch to fork over SSH
zig build devflow -- open-fork-pr [t]    # open ONE PR against upstream
zig build devflow -- request-reviews N [--codex]
zig build devflow -- wait-reviews N [--codex]      # blocks until resolved
zig build devflow -- land N              # squash-merge, mirror fork, resync local
zig build devflow -- sync                # resync local main if drifted
```

Branch off `upstream/main`. `open-fork-pr` opens directly on upstream
(single-stage — owner is a maintainer, no fork→upstream double-landing).
`land` squash-merges with subject `Merge pull request #N from <owner>/<branch>`,
then force-mirrors fork `main` to `upstream/main`.

Never trust ahead/behind counts (squash/merge rewrite or add SHAs) — `devflow
status` reports actual content diff instead, trust that. Always resync local
`main` after any merge, same session (`devflow land`/`sync` does this).

`land` refuses with `ReviewsPending` or `UnresolvedReviews` if CI isn't green
or a requested review (CodeRabbit always, Codex if pinged) isn't resolved —
that's the gate working, not a bug; don't bypass it by merging manually.

## Guardrails

- Never force-push a shared branch or rewrite published `main`.
- Never bypass commit signing (`--no-gpg-sign` etc.) — fix signing or stop
  with the exact blocker.
- `origin` is always the fork — mirror/branch-host only, never a landing
  target.
