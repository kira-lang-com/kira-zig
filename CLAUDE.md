@AGENTS.md

## Agent workspace: ALWAYS `.codex/`, NEVER `.claude/`

This repo is shared by more than one agent runtime — you are not the only one who
works here. `.codex/` is the single, shared agent workspace: scratch, notes,
repros, one-off scripts, skills, friction logs, and throwaway output all live
there (`.codex/tmp/` for disposable files, `.codex/work/` for longer-lived notes,
`.codex/skills/` for skills). Read what is already in `.codex/` before starting —
another agent may have left context.

NEVER create or write under `.claude/` in this repo, and never scatter scratch
into a Claude-specific job/temp directory when `.codex/tmp/` exists. Do not assume
a Claude-only convention; if you catch yourself reaching for `.claude/` or a
`$CLAUDE_*` path, redirect to `.codex/`. This applies to every file an agent
creates for its own use.

## Do only what was asked — no scope creep

Do exactly what the user asked, then stop. When the user names a specific action
("commit", "push", "fix this file"), perform that action and report — do NOT
chain into further outward-facing or hard-to-reverse steps they did not request
(opening/merging PRs, requesting reviews, landing, force-pushing, deleting).
"Commit" means commit; it is not permission to push or open a PR. If a follow-up
step seems useful, propose it and wait for an explicit go-ahead rather than
doing it. Approval for one step is not approval for the next.

## Use the `devflow` tool for git/PR flow, not raw git plumbing

Drive the fork/upstream branch → push → PR → review → land → sync flow through
`zig build devflow -- <verb>` (`status`, `commit`, `push`, `open-fork-pr`,
`request-reviews`, `wait-reviews`, `land`, `sync`), not hand-rolled `git`
commands. It encodes the signed-commit, single-stage-PR, squash-land, and
fork-mirror rules and the SSH push workaround. Never run `git reset --hard` or
any operation that discards uncommitted work; do not force-push shared branches.

## Commit conventions

Do NOT add `Co-Authored-By: Claude ...` trailers or any AI/tooling promotional lines to commit messages. Commits are authored solely by the human author.