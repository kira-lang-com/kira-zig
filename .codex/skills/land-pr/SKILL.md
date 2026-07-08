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
zig build devflow -- land N              # squash w/ "Merge pull request #N from..." subject + resync
zig build devflow -- sync                # resync local main if it drifted
zig build devflow -- open-upstream-pr [t]
```

Two rules the tool enforces that must never be broken by hand either:

1. **Never trust ahead/behind commit counts.** After a PR merges (a squash rewrites
   SHAs; a merge commit or cross-fork cherry-pick adds new ones), "N ahead" lies;
   only `git diff <a> <b>` (empty = identical) tells the truth. `devflow status`
   uses exactly this.
2. **After any merge, resync the local default branch to the merged remote in the
   same session.** Skipping this strands local `main` on the pre-merge commits and
   makes the next session think the fork diverged. `devflow land` does it
   automatically (with a backup ref); use `devflow sync` if a land happened elsewhere.

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

The owner wants BOTH: the flat list must show **exactly one entry per PR** (no child
commits) AND each entry must read `Merge pull request #N from <owner>/<branch>` — the
`apple/swift` look. The table shows these two wants collide for a real `--merge`: it
re-exposes children. **Only squash gives one line per PR.** So the resolution is a
**squash merge with the subject forced to the merge line** — one commit per PR, no
children, but reading exactly like a GitHub merge.

## Default for this repo: squash-with-merge-subject BOTH stages

The repo owner's standing rule: land every PR — fork AND upstream — as a **squash
merge whose subject is set to `Merge pull request #N from <owner>/<branch>`** (PR title
as body):

```sh
gh pr merge <n> --repo <slug> --squash \
  --subject "Merge pull request #<n> from <owner>/<branch>" --body "<PR title>"
```

This is the ONLY way to get a single flat-list entry per PR that reads like a merge.
Do NOT use `--merge` (a real merge commit re-exposes every child commit in the flat
list — verified) and do NOT use `--rebase` (flattens all children onto the line).
Curating the branch to clean commits is still good practice (the body/review read
better), but it is not what keeps the list clean — the squash is.

## Procedure

1. **Curate the branch BEFORE review.** Rebase onto the latest base and squash
   fixup/WIP commits into coherent logical commits with imperative messages (one per
   logical change; a large PR may keep a handful of independently-reviewable ones).
   Do this first, then push and request review — so CI and the reviews apply to the
   commits that will actually land. If you rewrite the branch AFTER review, the green
   CI and submitted reviews now point at stale SHAs: re-request review and re-check CI
   before merging, never merge a rewritten head on the strength of a pre-rewrite review.

2. **Preconditions.** The PR is green and reviewed:
   - CI passing: `gh pr checks <n> --repo <owner/repo>`.
   - Every requested review resolved: CodeRabbit always; Codex when it was pinged.
     Never land with a requested review still pending or an unresolved finding.
   - If a review never appeared, the review App is likely not installed on the
     fork — surface that, do not land unreviewed.

3. **Fork-internal PR — squash with merge subject.** With the branch curated (step 1)
   and green (step 2):
   ```sh
   gh pr merge <n> --repo <fork> --squash \
     --subject "Merge pull request #<n> from <owner>/<branch>" --body "<PR title>" \
     --delete-branch
   ```
   One flat-list entry reading `Merge pull request #N from <owner>/<branch>`, no
   children. `--delete-branch` is safe here — the head is a throwaway feature branch.
   Confirm: `git log --oneline <base> -3` shows one entry for the PR.

4. **Upstream PR — also squash with merge subject.** After the fork PR merges into fork
   `main`, open the upstream PR from a **dedicated branch** (cherry-pick the landed
   change onto a branch off `upstream/main`) — not from fork `main` directly. Land it
   the same way, but WITHOUT `--delete-branch` (never risk deleting a shared branch):
   ```sh
   gh pr merge <n> --repo kira-lang-com/kira --squash \
     --subject "Merge pull request #<n> from <owner>/<branch>" --body "<PR title>"
   ```
   Squash with the forced subject (never plain `--merge`, never `--rebase`) so upstream
   `main` also reads as one `Merge pull request #N from …` entry per landed unit.

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
