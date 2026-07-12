---
name: working-with-agents-instructions
description: "Style rules for writing or editing AGENTS.md, CLAUDE.md, or any .codex/skills/*/SKILL.md in this repo: no giant markdown files, no no-ops, Kai in the third person. Read before adding to or rewriting any agent instruction file."
---

# Working with agent instructions

## No giant markdown files

Kai doesn't grow a single instruction file past what a task actually needs
loaded every time. Kai keeps `AGENTS.md`/`CLAUDE.md` to the few rules every
task needs, and moves anything situational — a platform's done-bar, a
package map, a protocol — into its own skill under `.codex/skills/`, loaded
only when the task touches it. A 250-line always-on file is a bug, not
thoroughness.

## No no-ops

Kai states each rule once. Kai doesn't restate the same rule across three
sections in different words — that's not reinforcement, it's surface area
for self-contradiction. The one sanctioned exception is a deliberate
top-and-bottom bookend for the smallest set of irreversible rules
(destructive git, fake success), and that bookend is copied verbatim, not
paraphrased — a reworded "recap" reads as a new rule to reconcile, not a
repeat. Kai doesn't add meta-commentary that describes the file to its
reader ("this is a checklist", "note the repetition") — either the content
does the job or it doesn't; narrating it does not. Kai doesn't leave an
instruction for a path that can't be reached (a manual fallback a tool
never falls back to, a flow that's been retired) — dead instructions get
deleted, not kept "for reference."

A second sanctioned exception: a skill may restate a core `AGENTS.md` rule
it depends on, because a skill loads independently and can't assume the
core is still in context. Same discipline as the bookend applies — the
restatement is copied verbatim (the same clause, same wording) from
wherever it's canonical, not re-derived in the skill's own words, and Kai
keeps both copies in sync when either changes.

## Kai, third person

Kai doesn't write instructions as commands to "you". Every rule reads as a
statement of what Kai does or doesn't do: "Kai doesn't use Python", not
"never use Python" or "you must not use Python". This keeps identity and
behavior in one voice across `AGENTS.md` and every skill.
