# Package Management

Kira package management v1 is official-registry-first, lockfile-backed, and source-only.

## Manifest

Use `package.kira` for new projects — a manifest authored in Kira itself (see
[package-manifest.md](package-manifest.md) for the full schema). Legacy
`kira.toml` and `project.toml` are still discovered for compatibility, and
`package.kira` takes precedence when both are present. Migrate an existing
package with `kira migrate-manifest <project-dir|kira.toml>`.

```kira
Package DemoApp {
    let version = "0.1.0"
    let kind = PackageKind.App
    let defaults = Defaults { executionMode: Backend.Vm, buildTarget: BuildTarget.Host }
    let dependencies = [
        Dependency { name: "FrostUI", version: "0.1.0" },
        Dependency { name: "LocalDemo", path: "../LocalDemo" }
    ]
}
```

The equivalent legacy `kira.toml` form is still supported:

```toml
[package]
name = "DemoApp"
version = "0.1.0"
kind = "app"
kira = "0.1.0"

[defaults]
execution_mode = "vm"
build_target = "host"

[dependencies]
FrostUI = "0.1.0"
LocalDemo = { path = "../LocalDemo" }
GameKit = { git = "https://github.com/Sunlight-Horizon/GameKit.git", rev = "a1b2c3d4" }
```

## Commands

- `kira sync` resolves dependencies, fills the local cache, and updates `kira.lock`
- `kira add <Package>` adds the newest exact registry version
- `kira add --git <url> --rev <commit> <Package>` adds a pinned git dependency
- `kira remove <Package>` removes a dependency and refreshes the lockfile
- `kira update` refreshes registry dependency versions in the manifest, then re-syncs
- `kira new --lib <Name> <destination>` scaffolds a library package with `package.kira`, `moduleRoot`, and `app/<lowercased-name>.kira`
- `kira package pack` writes a validated source-only `.tar` archive into `.kira-build/package/`
- `kira package inspect <archive-or-project-dir>` prints package metadata and contents

## Creating A Library

Use the CLI:

```bash
kira new --lib GraphicsKit .codex/tmp/GraphicsKit
```

That scaffold creates:

- `package.kira`
- `kind = PackageKind.Library`
- `moduleRoot = "GraphicsKit"`
- `app/graphicskit.kira` as the root module file

Imports from consumers then look like:

```kira
import GraphicsKit
```

`kira build`, `kira run`, and `kira check` automatically sync first. Add `--offline` to stay cache-only and `--locked` to require the existing lockfile state.

## Lockfile

`kira.lock` stores:

- root dependency declarations
- resolved package source kind: registry, path, or git
- exact versions for registry packages
- locked commit hashes for git packages
- registry archive URL and SHA-256 checksum
- module root ownership and transitive dependency names

Kira rewrites the lockfile only when the resolved graph changes.

## Security Rules

- no install scripts, postinstall scripts, lifecycle scripts, or arbitrary shell hooks
- registry packages are verified with SHA-256 before extraction
- git dependencies must be pinned and locked to a concrete commit
- packages are extracted from source-only tar archives with path-traversal checks
- metadata mismatches are treated as hard errors

## Intentionally Unsupported In V1

- semver ranges for registry dependencies
- public package publishing
- binary or native prebuilt blobs
- package website and marketplace features
- provenance or signature verification

## Internal Publishing Expectation

V1 assumes Sunlight Horizon maintainers prepare the sparse registry index and publish source archives separately. Public consumers install from the static index and archive host; public self-service upload is not part of this release.
