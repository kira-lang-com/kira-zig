# Shader Tests

This directory holds `.ksl` shader coverage for the dedicated KSL pipeline.

Current layout:

- `pass/graphics/`
- `pass/compute/`
- `fail/parser/`
- `fail/semantics/`
- `fail/lowering/`

Each case contains:

- `main.ksl`
- `expect.toml`
- optional generated-output expectations checked by package tests such as `expected.vert.glsl`, `expected.frag.glsl`, and `expected.reflection.json`

The current KSL test coverage exercises:

- valid graphics shader parsing and lowering
- import loading for helper modules
- parser failures
- semantic failures
- reflection emission
- explicit compute-backend rejection for the GLSL 330 backend
