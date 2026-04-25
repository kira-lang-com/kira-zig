# Testing

Internal memory for corpus and verification workflow.

## Corpus layout

- `tests/pass/run/` — runnable success cases.
- `tests/pass/check/` — parse/semantics success without execution.
- `tests/fail/` — expected failures.
- `tests/shaders/pass/` / `tests/shaders/fail/` — dedicated KSL coverage.

## Conventions

- Corpus cases usually use `main.kira` or `main.ksl` plus `expect.toml`.
- Runnable cases typically declare a backend matrix explicitly in `expect.toml`.
- Failure cases should name the diagnostic code/title and stage when relevant.

## Practical backend guidance

- Use backend matrices to keep VM / LLVM / hybrid parity visible.
- If behavior is backend-specific, keep that explicit in `expect.toml` rather than relying on implicit defaults.
- If LLVM or hybrid behavior changes, ensure the case still exercises those paths.

## Example cases to inspect

- `tests/pass/run/basic`
- `tests/pass/run/struct_state_parity`
- `tests/pass/run/callback_value_parity`
- `tests/pass/run/ffi_struct_zero_init`
- `tests/pass/run/hybrid_roundtrip`
- `tests/pass/run/native_runtime_struct_bridge`
- `tests/pass/run/runtime_native_struct_bridge`
- `tests/pass/run/ffi_sokol_triangle_native`
- `tests/pass/check/callback_syntax_and_function_types`
- `tests/fail/semantics/direct_ffi_requires_native`
- `tests/fail/semantics/trailing_callback_parameter_mismatch`
- `tests/shaders/pass/graphics/basic_triangle`
- `tests/shaders/fail/lowering/compute_glsl`

## Unit tests vs corpus

- Put local invariants and small helpers in unit tests next to the package.
- Put user-visible compiler/runtime behavior in corpus cases.
- For shader work, keep the dedicated shader corpus authoritative.

## Verification commands

- `zig build test` for repo-wide package tests and corpus harness.
- `zig build` when build/install/toolchain wiring changed.
- `kira run ...`, `kira build ...`, `kira check ...`, `kira shader ...` when command behavior or generated output changed.
