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
zig build devflow -- push                # push the branch to the fork over SSH
zig build devflow -- open-fork-pr [t]    # open ONE PR against upstream (single-stage)
zig build devflow -- request-reviews N [--codex]   # on the upstream PR
zig build devflow -- wait-reviews N [--codex]      # blocks until threads resolved
zig build devflow -- land N              # squash-merge upstream PR w/ "Merge pull request #N from..." subject, mirror fork, resync local
zig build devflow -- sync                # resync local main if it drifted
```

Single-stage: `open-fork-pr` opens the PR **on upstream** (the owner is a
maintainer), `land` merges it there and then force-mirrors the fork's `main` to
`upstream/main` so the fork never diverges. Branch off `upstream/main` before
starting.

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

## Default for this repo: single-stage squash-with-merge-subject

The owner is a **maintainer of `kira-lang-com/kira`**, so there is exactly ONE landing,
directly on upstream — no fork→upstream double-landing (that manufactured parallel SHAs
and permanent ahead/behind divergence). Land the single upstream PR as a **squash merge
whose subject is set to `Merge pull request #N from <owner>/<branch>`** (PR title as body):

```sh
gh pr merge <n> --repo kira-lang-com/kira --squash \
  --subject "Merge pull request #<n> from <owner>/<branch>" --body "<PR title>"
```

Squash is the ONLY method that gives a single flat-list entry per PR. Do NOT use
`--merge` (a real merge commit re-exposes every child commit in the flat list — verified)
and do NOT use `--rebase` (flattens all children onto the line). The fork's `main` is a
**mirror**: after the upstream merge, reset it to `upstream/main` so it stays 0/0.

## Procedure

1. **Branch off `upstream/main` and curate BEFORE review.** Create the feature branch
   from `upstream/main`. Squash fixup/WIP commits into coherent logical commits with
   imperative messages. Push (to the fork as a branch host, or directly to upstream if
   you have write access) and open ONE PR against `upstream` `main`. Curate first so CI
   and reviews apply to the SHAs that land; if you rewrite the branch after review,
   re-request review and re-check CI before merging.

2. **Preconditions.** The PR is green and reviewed:
   - CI passing: `gh pr checks <n> --repo kira-lang-com/kira`.
   - Every requested review resolved: CodeRabbit always; Codex when it was pinged.
     Never land with a requested review still pending or an unresolved finding.
   - If a review never appeared, the review App is likely not installed — surface that,
     do not land unreviewed.

3. **Merge once — squash with merge subject.** With the branch curated (step 1) and
   green (step 2):
   ```sh
   gh pr merge <n> --repo kira-lang-com/kira --squash \
     --subject "Merge pull request #<n> from <owner>/<branch>" --body "<PR title>" \
     --delete-branch
   ```
   One flat-list entry reading `Merge pull request #N from <owner>/<branch>`, no children.

4. **Mirror the fork.** After the merge, reset the fork's `main` to `upstream/main` so it
   never diverges: `git push git@github.com:<owner>/kira.git upstream/main:main --force`
   (SSH; fork `main` is unprotected). Resync local `main` to `upstream/main` too. `devflow`
   automates steps 3–4.

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
