# CI runners

Kira can run the same GitHub Actions workflows on GitHub-hosted or Blacksmith
runners. GitHub-hosted runners are the default when the repository variable
`KIRA_CI_RUNNER` is absent or set to `github`.

To enable Blacksmith:

1. Install the Blacksmith GitHub app for the `kira-lang-com/kira` repository
   from <https://app.blacksmith.sh>. Blacksmith only supports organization
   repositories and jobs will queue indefinitely if the app cannot access the
   repository.
2. Run `zig build devflow -- blacksmith enable` from this repository.
3. Push or re-run a workflow. Tests use 4-vCPU Ubuntu 24.04 and Windows 2025
   runners plus a 6-vCPU Apple Silicon macOS 15 runner. LLVM toolchain builds
   use larger runners.

`zig build devflow -- rerun-ci <pr>` reruns completed workflows for a PR's
exact current head after changing providers. The Test workflow also supports a
manual dispatch from GitHub Actions.

Inspect the active provider with `zig build devflow -- blacksmith status`.
Return every workflow to GitHub-hosted runners with
`zig build devflow -- blacksmith disable`.
