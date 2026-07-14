---
name: writing-github-releases
description: "How Kira GitHub release posts are written: the release body is the version's .codex/CHANGELOG.md section plus workflow boilerplate, so Kai writes the changelog section — structure, category order, bullet style, sourcing from the tag range. Read before drafting release notes or cutting a release tag."
---

# Writing GitHub releases

## The release body IS the changelog section

`release.yml` builds the GitHub release post on tag push: it extracts the
`## [<version>]` section from `.codex/CHANGELOG.md`, prefixes `## Kira
<version>`, and appends fixed Installation / Assets / Verification
boilerplate plus a full-changelog link. Kai therefore writes release notes
in exactly one place — the version's section in `.codex/CHANGELOG.md` —
and never hand-writes or duplicates the boilerplate sections; a second
copy only drifts. An empty changelog section falls back to a bare "Kira
<version> release." line — shipping that fallback is a bug in the notes,
not an acceptable post.

## Version, tag, title

Versions are `YEAR.MONTH.PATCH` with an incremental year counted from the
project epoch (2026 = `1`), so the third July-2026 release is `1.7.3` —
not the retired calendar form `2026.07.3` (used through `2026.07.2`;
legacy tags count when numbering patches). The git tag is `v<version>`;
the workflow titles the release `Kira <version>`. Kai never computes or
edits version strings by hand — `devflow next-version` prints the next
version and `devflow release-prep` stores it everywhere it lives
(`build.zig` `kirac_version`, `release.yml` `env.VERSION`), refusing until
the version's changelog section exists.

## Section structure

Newest section first, directly under the file's intro:

```
## [<version>] - YYYY-MM-DD

<intro paragraph>

### <category>
- **Bold feature lead** with a plain-prose elaboration.
```

The intro paragraph states the scope honestly: the tag range it summarizes
(commit count since the previous tag) and a one-line sweep of the areas
touched. Categories appear in this canonical order, and only when
non-empty:

1. `### Language`
2. `### Ownership & memory safety`
3. `### Backends & parity`
4. `### Graphics & shaders`
5. `### FFI & native`
6. `### Runtime & performance`
7. `### Live reload & tooling`
8. `### Testing`
9. `### Architecture (Core Law #5)`
10. `### Project Matter`

## Bullet style

- Each bullet leads with a **bold feature name**, then elaborates in plain
  prose — what a user of the language/CLI can now do, not how the compiler
  does it internally.
- Exact syntax, commands, flags, and file names go in backticks
  (`` `some` ``, `` `kira fetch-llvm` ``, `` `@PropertyWrapper` ``).
- One bullet per feature, not per commit; related commits collapse into
  the feature they delivered.

## Sourcing and honesty

- Kai derives the section from the real landed range —
  `git log <previous-tag>..main` — and every bullet is traceable to
  commits in that range. Kai doesn't write notes from memory of recent
  sessions; the current task, conversation, or latest PR is never the
  release scope by itself.
- Kai doesn't fake success — a feature that is partial, VM-only, or gated
  behind an unfinished path is either described with its true limits or
  left out. Kai doesn't ship VM-only work. Kai makes every
  language/compiler/runtime/backend change work on VM (`kira run`) AND
  LLVM/native (`kira build`); hybrid when touched; WASM when the feature
  is Web-portable — so a bullet that names backend coverage states it as
  it actually is.

## Cutting the release

The full sequence, in order:

1. Kai writes the `## [<version>]` changelog section (this skill).
2. `devflow release-prep` stores the version; the section and the bump
   land together like any other change (branch, PR, CI, land —
   `working-with-git` skill).
3. `devflow release`, on a clean synced `main`, verifies build.zig,
   release.yml, the changelog, and tag absence all agree, then creates the
   signed `v<version>` tag and pushes it to upstream.

The tag push triggers `release.yml`, which builds the launcher/toolchain
assets for linux-x64, macos-arm64, and windows-x64, generates the notes,
creates or updates the release, and verifies the expected asset list.
Re-tagging an existing release edits it in place (`gh release edit` +
`--clobber` upload), so fixing notes after the fact means fixing the
changelog section and re-running the job — not editing the GitHub post by
hand.
