# Skipped cases (semantics dirs 41-80 slice)

> RESOLVED 2026-07-13: `invalid_callback_signature` is now MIGRATED via FailTest
> fixture mode. `app/FsbFailTests.kira` declares `FsbInvalidCallbackSignature`
> whose `source { fixture("fixtures/invalid_callback_signature") }` compiles the
> real multi-file package (import + FFI callback binding) through the per-backend
> check path, asserting KSEM045. Historical rationale retained below.

## invalid_callback_signature (tests/fail/semantics/invalid_callback_signature)

Reason: multi-file case with a native FFI support library — cannot be inlined
into a single `FailTest` `source { }` block, which models a single compilation
unit.

Files that make it multi-file:
- `app/main.kira` — `import callbacks as callbacks`; calls
  `callbacks.kira_invoke_callback(bad_callback, 0, 5)`.
- `app/callbacks.kira` — imported support module.
- `callbacks.kira` — second support module (repo root of the case).
- `NativeLibs/callbacks.c`, `NativeLibs/callbacks.h`, `NativeLibs/callbacks.toml`
  — native C library backing the import.
- `project.toml` — legacy multi-file project manifest (not a single `main.kira`).

Expected diagnostic (from `app/expect.toml`): `KSEM045`
("invalid callback signature"), backends `["hybrid", "vm"]`.
