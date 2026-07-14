# CI runners

Kira's GitHub Actions workflows run only on Blacksmith. There is no
GitHub-hosted fallback.

To enable Blacksmith:

1. Install the Blacksmith GitHub app for the `kira-lang-com/kira` repository
   from <https://app.blacksmith.sh>. Blacksmith only supports organization
   repositories and jobs will queue indefinitely if the app cannot access the
   repository.
2. Push or re-run a workflow. Tests use 4-vCPU Ubuntu 24.04 and Windows 2025
   runners plus a 6-vCPU Apple Silicon macOS 15 runner. LLVM toolchain builds
   use larger runners.

Each Test matrix job runs both `zig build test` (package unit tests and
repository policy) and every Kira-native suite under `tests-kik` through the
recursive `kira test tests-kik` runner.
The latter uses the manifest's VM/LLVM/hybrid backend matrix and enables stdout
parity checks.

`zig build devflow -- rerun-ci <pr>` reruns completed workflows for a PR's
exact current head after changing providers. The Test workflow also supports a
manual dispatch from GitHub Actions. Use
`zig build devflow -- ci-runners <pr>` to report the actual runner identity,
runner group, and labels assigned to every exact-head job.
