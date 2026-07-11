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

## Commit conventions

Do NOT add `Co-Authored-By: Claude ...` trailers or any AI/tooling promotional lines to commit messages. Commits are authored solely by the human author.