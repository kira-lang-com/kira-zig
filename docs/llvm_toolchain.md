# LLVM Toolchain Releases

Kira ships pinned LLVM bundles so contributors do not need to build LLVM themselves as the default path. The repo records exactly which LLVM version Kira expects, which release tag owns those bundles, and which archive name belongs to each supported host platform.

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

Use `workflow_dispatch` with `publish = false` to build the bundles and upload workflow artifacts for inspection.

Each matrix job uploads:

- the packaged archive

### Publishing

There are two publish paths:

- push a tag that matches `llvm-v*-kira.*`
- run `workflow_dispatch` with `publish = true`

Publish runs still keep the release metadata-driven:

- the published release tag is always `[llvm].release_tag`
- the generated archive name for each target must match the metadata

When publishing succeeds, the workflow creates or updates the GitHub release for `[llvm].release_tag` and uploads:

- each packaged LLVM archive

On a tag push, the workflow validates that the pushed tag already matches `[llvm].release_tag`. On `workflow_dispatch` with `publish = true`, the workflow can create that release tag from the current commit automatically if it does not exist yet.

## Expected asset naming

Asset names are deterministic and versioned:

- `llvm-22.1.2-x86_64-windows-msvc.zip`
- `llvm-22.1.2-x86_64-linux-gnu.tar.xz`
- `llvm-22.1.2-aarch64-macos.tar.xz`

That naming convention is enforced by `scripts/llvm/llvm_release.py`, which validates that the metadata and workflow stay in sync.

## Runtime discovery in the repo

The LLVM backend uses an explicit discovery order instead of silently falling back to whatever happens to be on the system:

1. `KIRA_LLVM_HOME`
2. repo-managed install at `.kira/llvm/current`
3. repo-managed versioned install at `.kira/llvm/llvm-<version>-<host-key>`

When `llvm-config` exists inside the selected toolchain, Kira uses it to refine the bin/lib directories. Otherwise Kira falls back to the normal install tree layout.

If discovery fails, the LLVM backend reports the paths it checked and tells the caller to set `KIRA_LLVM_HOME` or install the repo-managed toolchain. The backend does not silently bind to an arbitrary machine-local LLVM install.

The same discovery path is used by the pure LLVM backend and the native half of hybrid mode.

## Future Kira consumer

A future `zig build fetch-llvm` command should read `llvm-metadata.toml`, pick the current host key, download the matching release asset from `[llvm].release_tag`, and install the unpacked tree into Kira's cache. That future command should not need hard-coded LLVM versions or ad hoc asset naming logic because the repo metadata already records the contract.
