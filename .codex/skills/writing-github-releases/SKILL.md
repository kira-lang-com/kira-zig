---
name: writing-github-releases
description: "How Kira GitHub release posts are written: notes are drafted in an untracked file and published by `devflow release --notes` — never checked into git. Structure, category order, bullet style, user-facing-only content rules, sourcing from the tag range. Read before drafting release notes or cutting a release."
---

# Writing GitHub releases

## Notes live on the release, never in git

Kai doesn't check a changelog into the repository — no `CHANGELOG.md`
anywhere, tracked or generated. Release notes exist in exactly one place:
the GitHub release body. Kai drafts them in an untracked file (e.g.
`.codex/tmp/release-notes-<version>.md`) and `devflow release --notes
<file>` publishes them when it creates the release. The asset-build
workflow (`release.yml`) only uploads archives into that release; it never
writes or edits the body.

## User-facing content only

Release notes describe what a user of the language, runtime, and CLI can
see. Kai doesn't put internal material in them: development workflow and
process (PR/landing policy, review tooling, devflow internals), agent
instructions or skills, internal documents, repo hygiene (file splits,
test-runner wiring), or anything describing how the team works. When in
doubt, ask whether a Kira user running `kira` could observe the change —
if not, it stays out.

## Version, tag, title

Versions are `YEAR.MONTH.PATCH` with an incremental year counted from the
project epoch (2026 = `1`), so the third July-2026 release is `1.7.3` —
not the retired calendar form `2026.07.3` (used through `2026.07.2`;
legacy tags count when numbering patches). The git tag is `v<version>`;
the release title is `Kira <version>`. Kai never computes or edits version
strings by hand — `devflow next-version` prints the next version and
`devflow release-prep` stores it everywhere it lives (`build.zig`
`kirac_version`, `release.yml` `env.VERSION`).

## Notes structure

```
<intro paragraph>

### <category>
- **Bold feature lead** with a plain-prose elaboration.
```

The intro paragraph states the scope honestly: the tag range it summarizes
and a one-line sweep of the areas touched. Categories appear in this
canonical order, and only when non-empty:

1. `### Language`
2. `### Ownership & memory safety`
3. `### Backends & parity`
4. `### Graphics & shaders`
5. `### FFI & native`
6. `### Runtime & performance`
7. `### Live reload & tooling`
8. `### Testing`
9. `### Compiler guarantees`

## Bullet style

- Each bullet leads with a **bold feature name**, then elaborates in plain
  prose — what a user of the language/CLI can now do, not how the compiler
  does it internally.
- Exact syntax, commands, flags, and file names go in backticks
  (`` `some` ``, `` `kira fetch-llvm` ``, `` `@PropertyWrapper` ``).
- One bullet per feature, not per commit; related commits collapse into
  the feature they delivered.

## Sourcing and honesty

- Kai derives the notes from the real landed range —
  `git log <previous-tag>..main` plus merged-PR metadata for squashed
  branches — and every bullet is traceable to commits in that range. Kai
  doesn't write notes from memory of recent sessions; the current task,
  conversation, or latest PR is never the release scope by itself.
- Kai doesn't fake success — a feature that is partial, VM-only, or gated
  behind an unfinished path is either described with its true limits or
  left out. Kai doesn't ship VM-only work. Kai makes every
  language/compiler/runtime/backend change work on VM (`kira run`) AND
  LLVM/native (`kira build`); hybrid when touched; WASM when the feature
  is Web-portable — so a bullet that names backend coverage states it as
  it actually is.

## Cutting the release

The full sequence, in order:

1. `devflow release-prep` stores the version; the bump lands like any
   other change (branch, PR, CI, land — `working-with-git` skill).
2. Kai drafts the notes in an untracked file per this skill.
3. `devflow release --notes <file>`, on a clean synced `main`, verifies
   build.zig, release.yml, the notes draft, and tag absence all agree,
   then creates the signed `v<version>` tag, pushes it, and publishes the
   GitHub release with those notes.

The tag push triggers `release.yml`, which builds the launcher/toolchain
assets for linux-x64, macos-arm64, and windows-x64 and uploads them into
the already-published release. Fixing notes after the fact means editing
the release body through `gh release edit` with a corrected draft — the
repo carries nothing to update.
