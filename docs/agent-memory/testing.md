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

## Opt-in wasm backend

- `backends` accepts a fourth value, `"wasm"`, alongside `"vm"`, `"llvm"`, and
  `"hybrid"`. It is opt-in per case (e.g. `backends = ["hybrid", "vm", "llvm", "wasm"]`)
  and must accompany `hybrid` — it never stands alone.
- A `wasm` entry builds the case through the real `wasm32-emscripten` pipeline
  (the same `BuildSystem` the CLI uses), executes the emitted `.js` loader under
  `node`, and compares stdout/exit exactly like the other backends.
- When `emcc` or `node` is missing, the runner SKIPs the wasm entry for that case
  (it never fails and never silently pretends it ran): the summary prints a
  `<n> skipped` count plus a per-case note (`SKIP wasm: emcc ... unavailable`, or
  the equivalent for node). Set `EMSDK`/`EMCC` or install emscripten + Node.js to
  run wasm locally.
- `"wasm"` is part of the `all` backend selection, so `zig build test-backends`
  and `zig build test-full` exercise opted-in wasm cases automatically (skipping
  cleanly when the toolchain is absent). `zig build test` stays VM-only.
- Only add `"wasm"` to a case after confirming it passes on wasm
  (`KIRA_CORPUS_FILTER=<case> zig build test-backends`, with emcc + node present).
  A case that diverges on wasm is a real backend gap — leave it off the wasm
  matrix rather than papering over the mismatch.

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
- `zig build test` runs the VM run corpus. `zig build test-backends` runs the run corpus across VM, LLVM, hybrid, and (for opted-in cases) wasm. `zig build test-full` runs check, build, and run corpus coverage across all backends. Missing emcc/node makes wasm entries skip (with a per-case note) rather than fail.

## Verification commands

- `zig build test` for repo-wide package tests and corpus harness.
- `zig build` when build/install/toolchain wiring changed.
- `kira run ...`, `kira build ...`, `kira check ...`, `kira shader ...` when command behavior or generated output changed.
