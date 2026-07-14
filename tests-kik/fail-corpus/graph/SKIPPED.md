# Graph fail-corpus — skipped cases

> RESOLVED 2026-07-13: `outside_app_import` is now MIGRATED via FailTest fixture
> mode. `app/FgrFailTests.kira` declares `FgrOutsideAppImport` whose
> `source { fixture("fixtures/outside_app_import") }` compiles the real on-disk
> package directory (`fixtures/outside_app_import/`, with `support.kira` kept
> physically outside `app/`) through the same per-backend check path, asserting
> KSEM032. The historical rationale below is retained for context.

## outside_app_import — import-graph case, not single-file expressible
Legacy layout (import-graph shape):

    tests/fail/graph/outside_app_import/
      app/main.kira      # import support as Support; Support.hello()
      app/expect.toml    # KSEM032 "unresolved import" (semantics), backends ["hybrid","vm"]
      support.kira       # a module physically OUTSIDE the app/ directory

The declared diagnostic `KSEM032` "unresolved import" is produced precisely because
`support.kira` lives **outside the app root**, so the module-resolution / import graph
cannot reach it. The failure is a property of the on-disk directory layout and the
import graph spanning two files — not of any single source text.

A `FailTest` `source` block is one in-memory compilation unit with no surrounding
directory structure and no second module, so this cross-file, layout-dependent import
resolution failure cannot be reproduced inside a `FailTest`. There is no single-file
form (block or raw-string tier) that expresses it. `SKIPPED`.

This package is created (kira.toml + app/main.kira) to hold this record, per the
migration instruction to create the graph package even when it only holds SKIPPED.md.
