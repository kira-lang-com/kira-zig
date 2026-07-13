# CLOSED 2026-07-13 — nothing to migrate (phantom case).

The legacy `tests/` tree has been deleted. This case never had sources to begin
with, so there is nothing to transport; it is closed permanently, not deferred.

- widget_imported_constructor_resolution: no source to migrate — the corpus directory `tests/pass/run/widget_imported_constructor_resolution/` contains only `kira.lock` (no `main.kira`, no `expect.toml`, no `app/`); git history confirms only `kira.lock` was ever committed (commit 40874b8 "Expand construct and widget surface support" added just that one file), so the imported-constructor-resolution program itself never landed in the tree.
