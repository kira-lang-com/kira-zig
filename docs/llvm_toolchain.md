# LLVM Toolchain Releases

Kira ships pinned LLVM bundles so contributors do not need to build LLVM themselves as the default path. The repo records exactly which LLVM version Kira expects, which release tag owns those bundles, and which archive name and checksum belongs to each supported host platform.

## Why Kira ships LLVM bundles

- LLVM is large enough that rebuilding it on every contributor machine is a bad default.
- Kira needs predictable headers, libraries, and tool behavior when the LLVM backend lands.
- GitHub release assets are durable and easy for a future `zig build fetch-llvm` command to download, cache, and verify.
- Workflow artifacts are still useful during CI, but they are temporary debugging outputs rather than the long-term delivery channel.

## Source of truth: `llvm-metadata.toml`

`llvm-metadata.toml` lives at the repo root and is the contract between the repo, CI, and a future downloader. It pins:

- the LLVM source version and source tag to build
- the Kira-controlled Git tag and GitHub release tag that owns the published bundles
- the supported host targets
- the exact archive filename per target
- the expected SHA-256 checksum per target

The workflow never invents release asset names on its own. It reads the metadata, builds that target matrix, and packages archives with names that must match the metadata exactly.

At the time this file was introduced, the repo pin was updated to LLVM `22.1.2`, which was the latest released upstream LLVM version on April 2, 2026.

## Supported host targets

The first version supports host platforms that GitHub-hosted runners can build directly without pretending to support cross-builds that do not exist in CI:

- `x86_64-windows-msvc`
- `x86_64-linux-gnu`
- `aarch64-macos`

`aarch64-macos` is used instead of a second macOS architecture because the workflow is designed around a real native build on the GitHub-hosted runner rather than a guessed cross-build. If Kira later decides to ship another macOS host bundle, add it only when the runner and packaging path are both real and maintainable.

## What each bundle contains

Each release asset is produced from an LLVM install tree, not from the raw build directory. The install tree is packaged directly so Kira can consume a deterministic layout:

- `include/llvm/`
- `include/llvm-c/`
- `lib/`
- `bin/llvm-config` or `bin/llvm-config.exe` when LLVM installs it on that host
- any supporting files installed alongside those directories by LLVM's normal install step

The workflow intentionally avoids building LLVM examples, tests, benchmarks, docs, bindings, and optional compression or XML dependencies. The goal is a usable LLVM integration bundle for Kira, not a full general-purpose LLVM workstation image.

## Release workflow

The main workflow lives at `.github/workflows/release-llvm-toolchains.yml`.

### Dry run

Use `workflow_dispatch` with `publish = false` to build the bundles and upload workflow artifacts for inspection. This is the normal way to generate fresh checksum values when bumping LLVM or changing packaging behavior.

Each matrix job uploads:

- the packaged archive
- the matching `.sha256` file
- a small checksum log

If `llvm-metadata.toml` still has empty checksum fields, the job prints the generated checksum values so a maintainer can update the metadata intentionally in a follow-up commit.

### Publishing

There are two publish paths:

- push a tag that matches `llvm-v*-kira.*`
- run `workflow_dispatch` with `publish = true`

Publish runs are stricter than dry runs:

- the Git tag must match `[llvm].release_tag`
- the generated archive name for each target must match the metadata
- the generated SHA-256 for each target must match the committed `sha256` value in `llvm-metadata.toml`

If checksums are missing or stale, publishing fails on purpose. That keeps the metadata file as the source of truth instead of letting CI silently rewrite repo state.

When publishing succeeds, the workflow creates or updates the GitHub release for `[llvm].release_tag` and uploads:

- each packaged LLVM archive
- each archive's `.sha256` file

## Expected asset naming

Asset names are deterministic and versioned:

- `llvm-22.1.2-x86_64-windows-msvc.zip`
- `llvm-22.1.2-x86_64-linux-gnu.tar.xz`
- `llvm-22.1.2-aarch64-macos.tar.xz`

Each archive also has a sibling checksum asset:

- `llvm-22.1.2-x86_64-linux-gnu.tar.xz.sha256`

That naming convention is enforced by `scripts/llvm/llvm_release.py`, which validates that the metadata and workflow stay in sync.

## Future Kira consumer

A future `zig build fetch-llvm` command should read `llvm-metadata.toml`, pick the current host key, download the matching release asset from `[llvm].release_tag`, verify the SHA-256, and install the unpacked tree into Kira's cache. That future command should not need hard-coded LLVM versions or ad hoc asset naming logic because the repo metadata already records the contract.
