# Shaders / KSL

Internal orientation for the dedicated shader language pipeline.

## Packages

- `packages/kira_ksl_syntax_model`
- `packages/kira_ksl_parser`
- `packages/kira_ksl_semantics`
- `packages/kira_shader_model`
- `packages/kira_shader_ir`
- `packages/kira_glsl_backend`
- integration points in `packages/kira_build/src/shader/pipeline.zig`

## Current pipeline

1. `kira_source` loads `.ksl` text.
2. `kira_ksl_parser` tokenizes/parses.
3. `kira_ksl_semantics` resolves imports, resources, stages, and layout rules.
4. `kira_shader_ir` preserves typed shader meaning.
5. `kira_glsl_backend` lowers graphics shaders to GLSL 330 and reflection.
6. `kira_build` / `kira_cli` expose `kira shader check|ast|build`.

## Surface summary

KSL is a sibling language, not “normal Kira with shader annotations.”

Implemented concepts include:

- `shader` declarations
- `type` declarations
- helper `function`s
- resource `group`s
- `option`s
- `vertex` / `fragment` / `compute` stages
- stage IO types, builtins, interpolation, and reflection

See `docs/ksl.md` for the broader design rules.

## Backend behavior

- Current concrete backend is GLSL 330 graphics output.
- Compute shaders are present in the language and semantic model, but `kira shader build` intentionally rejects them on the GLSL 330 backend.
- Reflection is emitted as JSON alongside GLSL output.

## File locations to remember

- Parser: `packages/kira_ksl_parser/src/parser.zig`
- Semantics: `packages/kira_ksl_semantics/src/analyzer.zig`
- Shader model: `packages/kira_shader_model/src/{types,module,reflection}.zig`
- IR: `packages/kira_shader_ir/src/ir.zig`
- GLSL lowering: `packages/kira_glsl_backend/src/glsl.zig`

## Test/docs touch points

- `tests/shaders/README.md`
- `tests/shaders/pass/graphics/*`
- `tests/shaders/fail/*`
- `docs/ksl.md`
