---
name: land-pr
description: "Land a reviewed PR onto its base with a clean, single-entry-per-PR history. Handles the squash-vs-merge reality of GitHub's UI, the SSH workaround for workflow-scope pushes, and the fork -> upstream two-stage flow."
---

# Land a PR cleanly

Use when a PR is ready to merge and the history must stay readable — one entry
per landed unit, not a wall of individual commits.

## Preferred: the `devflow` tool (guards baked in)

The recurring fork-flow failures (phantom "ahead" counts, stranded local main,
workflow-scope push rejections) are automated away by `packages/kira_devflow`.
Prefer it over hand-run git/gh — the guards are structural, not advisory:

```sh
zig build devflow -- status              # content diff, NOT ahead/behind counts
zig build devflow -- commit [-m "..."]   # stage all + signed commit
zig build devflow -- push                # always via the fork SSH remote
zig build devflow -- open-fork-pr [t]    # fork-internal PR, empty body
zig build devflow -- request-reviews N [--codex]
zig build devflow -- wait-reviews N [--codex]   # blocks until threads resolved
zig build devflow -- land N              # squash-merge + resync local main
zig build devflow -- sync                # resync local main if it drifted
zig build devflow -- open-upstream-pr [t]
```

Two rules the tool enforces that must never be broken by hand either:

1. **Never trust ahead/behind commit counts.** After a squash-merge the SHAs are
   rewritten, so "N ahead" is a lie; only `git diff <a> <b>` (empty = identical)
   tells the truth. `devflow status` uses exactly this.
2. **After any squash-merge, resync the local default branch to the merged
   remote in the same session.** Skipping this is what strands local `main` on
   pre-squash commits and makes the next session think the fork diverged.
   `devflow land` does it automatically (with a backup ref); use `devflow sync`
   if a land happened elsewhere.

The manual procedure below remains the reference for what the tool does and for
cases the tool does not cover.

## The GitHub-UI reality (read first)

There is no merge method that shows *only* merge commits in every GitHub view.

- A PR's **Commits** tab always lists every commit in the PR. Unavoidable.
- GitHub's **`/commits/<branch>` page lists every commit reachable from the
  branch, chronologically** — including a merge's second-parent commits. So a
  no-fast-forward **merge commit** does NOT hide the individual commits there;
  they remain reachable and shown.
- `git log --first-parent` and the network graph are the only views that read as
  merge-commits-only.

So the choice is real:

| Method | GitHub flat commit list | First-parent line | Keeps individual commits |
| --- | --- | --- | --- |
| **Squash and merge** | ONE commit per PR | one commit per PR | no (collapsed to one) |
| **Merge commit (no-ff)** | merge commit **+ all N individuals** | merge commit per PR | yes (in the DAG) |
| Rebase and merge | all N individuals | all N individuals | yes (flattened) |

If the goal is "I only ever see one thing per PR in GitHub," that is **squash and
merge** — it is the only method that collapses a PR to a single flat-list entry.
It is not technically a merge commit and it discards the individual commit
messages, keeping only the squash message.

## Default for this repo: squash-merge BOTH stages

The repo owner's standing rule is **one entry per PR in GitHub's UI, everywhere** —
so **squash and merge every PR, fork AND upstream**. Squash is the only method that
collapses a PR to a single flat-list entry, and the owner wants that for both the
fork-internal PR and the upstream PR. This deliberately overrides the older
"no-fast-forward merge commit for upstream" guidance — record the override in the
PR when you land it. Never `--merge` (a real merge commit re-exposes the individual
commits in GitHub's flat list) and never `--rebase` (flattens all N onto the line).

## Procedure

1. **Preconditions.** The PR is green and reviewed:
   - CI passing: `gh pr checks <n> --repo <owner/repo>`.
   - Every requested review resolved: CodeRabbit always; Codex when it was pinged.
     Never land with a requested review still pending or an unresolved finding.
   - If a review never appeared, the review App is likely not installed on the
     fork — surface that, do not land unreviewed.

2. **Fork-internal PR — squash and merge.** One commit per PR:
   ```sh
   gh pr merge <n> --repo <fork> --squash --delete-branch
   ```
   Edit the squash commit's title/body to a single imperative summary (the PR
   title is a good default). Confirm it landed as one commit:
   `git log --oneline <base> -3`.

3. **Upstream PR — also squash and merge.** After the fork PR is merged into fork
   `main`, open the upstream PR from fork `main` and land it the same way:
   ```sh
   gh pr merge <n> --repo kira-lang-com/kira --squash --delete-branch
   ```
   `--squash` (never `--merge`, never `--rebase`) so upstream `main` also reads as
   one flat-list entry per landed unit.

## Pushing branches that touch `.github/workflows/`

An HTTPS push via an OAuth token without the `workflow` scope is **rejected** for
any commit that adds/edits a workflow file:

```text
refusing to allow an OAuth App to ... workflow ... without `workflow` scope
```

Two fixes:

- **SSH push (no reconfig):** push over the fork's SSH URL, which is not
  scope-gated:
  ```sh
  git push git@github.com:<fork-owner>/kira.git <local-branch>:<remote-branch>
  ```
- **Grant the scope (persistent):** `gh auth refresh -s workflow`.

## Guardrails

- Never force-push a shared branch, never rewrite published `main`. Existing messy
  history (individual commits already on `main` from past landings) cannot be
  cleaned without a forbidden `main` rewrite — leave it, only keep new landings
  clean.
- Never bypass commit signing (`--no-gpg-sign` etc.). If signing fails, fix
  signing or stop with the exact blocker.
- Ensure `origin` is the fork, never the official repo. The two-stage flow is
  fork PR (reviewed + merged) THEN upstream PR — never open upstream while the
  fork PR is unmerged.
