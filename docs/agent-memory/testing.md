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

## Corpus reporting

- Passing corpus runs print only `<n> passed` and `0 failed`.
- Runs with five or fewer failures print every failure with its full trace.
- Runs with more than five failures group failures by stable diagnostic/runtime signatures, show occurrence counts and representative cases, and print one full trace per group.
- The corpus runner writes `.kira/test-report.json` on every run so agents can inspect totals, grouped failures, representative cases, diagnostic metadata, and full group traces without re-running tests just to recover output.
- `zig build test` runs the VM run corpus. `zig build test-backends` runs the run corpus across VM, LLVM, and hybrid. `zig build test-full` runs check, build, and run corpus coverage across all backends.

## Verification commands

- `zig build test` for repo-wide package tests and corpus harness.
- `zig build` when build/install/toolchain wiring changed.
- `kira run ...`, `kira build ...`, `kira check ...`, `kira shader ...` when command behavior or generated output changed.
