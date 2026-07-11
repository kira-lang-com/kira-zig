---
name: wasm-target
description: "WASM/Web backend definition of done for Kira: the real frontend->IR->LLVM->wasm32-emscripten->Emscripten->runtime path, the 8-point completion bar, and forbidden smoke shortcuts. Read before claiming any wasm32-emscripten or Web target work is complete."
---

# WASM / Web target

Real path only: `Kira source -> typecheck -> Kira IR -> LLVM -> wasm32-emscripten
-> Emscripten link -> browser host bindings -> Kira runtime -> Kira UI/Graphics`.
Browser hosts may load wasm, provide imports, forward events — never render
placeholder content or emit Kira success themselves.

## Done means all 8, on the affected Kira code

1. Compiles through the real frontend + IR.
2. Lowers through LLVM for `wasm32-emscripten`.
3. Links through Emscripten.
4. Starts the real Kira runtime.
5. Invokes the real app/test entrypoint.
6. Executes real assertions/app behavior.
7. Reports results to the harness without smoke markers.
8. Preserves backend parity for portable features.

A browser opening, a canvas existing, or one example building is not on this
list — none of those are done.

## Excluding a test from WASM

Only when genuinely impossible/unsupported in the browser sandbox, and only
with the exact reason plus diagnostics or explicit target metadata. Never an
imprecise "skip on wasm".

Forbidden as proof: JS-rendered test output, browser capability checks, WASM
build success as execution success, host page load as runtime success.
