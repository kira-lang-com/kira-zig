# WASM: full execution of Kira Graphics, UI Foundation, and Kira UI apps

- date: 2026-07-10
- status: complete (layer 11 on all three app families)
- goal: "ensure Wasm Kira can fully execute KG apps, UI Foundation apps and Kira UI apps"

## Result

All three app families compile through the real frontend → IR → LLVM →
wasm32-emscripten → emcc pipeline, start the real Kira runtime in a browser,
and render real Kira-generated content via the Sokol/WebGPU backend:

- kira-graphics `clear_color`: real clear frame (markers + pixel-verified color).
- kira-graphics `basic_triangle`: real geometry from a KSL-compiled WGSL shader
  (blue triangle, pixel-verified), shader assets preloaded into MEMFS.
- ui-foundation `basic-foundation-app`: the full dashboard renders in headless
  Chrome — sidebar, stat cards (12,458 / 342 / 8.2K / 24%), components, activity
  feed, 60 FPS badge, real text shaped by FreeType+HarfBuzz compiled to wasm.
- kira_ui `basic-kira-ui-app`: full widget page renders (AppSurface / VStack /
  HStack / Foundation cards, banner, FPS badge).
- 12+ headless ui-foundation smokes plus kira_ui `state-smoke` execute under
  node with real output (state store, text engine, layout, retained tree,
  leak-harness, ...).
- `kira run web <project>` compiles the real app and node-executes it with
  honest lifecycle events; `kira export web` writes a real emcc bundle
  (index.html + main.js/main.wasm + preload .data), probe module retired.

## kira-zig changes (by area)

Native libs / manifests:
- NativeLibs C/C++ sources compile via emcc + emar for `wasm32-emscripten-unknown`
  (`packages/kira_build/src/native_artifact_build.zig`, split out of
  `ffi_support.zig` per Core Law 5).
- Per-target `compiler_flags` (TargetSpec) and `linker_flags` (LinkExtras),
  parsed by `packages/kira_manifest/src/native_lib_parser.zig` (split from
  `parser.zig`), resolved through `native_lib_resolver.zig` (a dropped-field bug
  there was found and fixed with a resolution-stage test).
- Foundation native libs (FS, ArgumentParser static; DynamicFfi, KiraApi
  pure-empty) declare wasm targets — KTC003 remains for undeclared libs.
- Project manifest `assets = [...]` key → emcc `--preload-file` mounts at
  project-relative paths (wasm only); `KPK025` diagnostic for missing assets.
- Emscripten executable links: `-sALLOW_MEMORY_GROWTH=1 -sGROWABLE_ARRAYBUFFERS=0`.

LLVM backend wasm32 width-family fixes (all with regression tests in
`packages/kira_build/src/wasm_emscripten_tests.zig` / `wasm_emscripten_width_tests.zig`):
1. size_t params (malloc/memcpy/memcmp/strlen/kira_struct_alloc) →
   `Types.usize_ty` + `sizeArg`/`sizeRet` (backend_capi_types.zig).
2. Array element destroy/clone callbacks → C-ABI thunks
   (backend_capi_wasm_cb_adapters.zig).
3. @Native functions passed as C callbacks (sokol sapp_desc etc.) → per-signature
   C-ABI adapters (backend_capi_wasm_native_cb.zig).
4. String bridge packing: wasm32 KiraBridgeValue is 16 bytes, ptr|len share the
   payload word (backend_capi_bridge_string.zig).
5. raw_ptr/construct_any struct fields stored at pointer width but loaded as
   i64 in clone/release_contents + closure field stores → 4-byte loads
   (backend_capi_struct_dtors.zig, backend_capi_aggregate.zig). This was the
   3.9GB-malloc first-frame OOM in UIF apps.

Web runner (real path, probe retired):
- `packages/kira_live/src/web_bundle.zig` (new): real emcc build + bundle +
  node runner; wasm/.data copied under both canonical and baked-in basenames.
- `web_live.zig` / `kira_cli/commands/export.zig` rewritten to use it;
  `kira run web` node-executes with honest `web.run.node_executed` events.
- docs/web_runner.md rewritten truthfully.

Corpus:
- "wasm" backend in the corpus matrix (build via BuildSystem, run node,
  skip-with-note when emcc/node absent). 14 cases opted in, all green.

## Sibling repo changes

- kira-graphics: Sokol.toml wasm target (`--use-port=emdawnwebgpu` compile+link);
  Metal/Vulkan empty wasm sections; `graphicsDefaultBackend()` (Metal on
  macOS/iOS, Sokol otherwise); basic_triangle uses `createShaderFromKsl` +
  `assets` key; sokol_impl.c: WGPU double-swapchain-acquire fix + WGSL branch
  for the immediate-2D UI shader (GLSL was being fed to Dawn → black canvas).
- ui-foundation: Text/StateStore/Icon wasm target sections (FreeType+HarfBuzz
  compile clean under emcc); RunFoundationApp uses `graphicsDefaultBackend()`
  instead of hardcoded Metal (macOS Metal regression-verified by offscreen
  framebuffer dump).
- kira_ui: no changes needed (pure Kira); basic-kira-ui-app got a kira.lock.

## Validation

- `zig build test`: 160/0 across multiple runs; final composite run green.
- Full corpus incl. wasm matrix: 523-524 passed / 0 failed (stable mode).
- Host regression spot-checks per fix: string 26/0, ownership 107/0,
  closure 50/0, struct 91/0, array 67/0, ffi 18/0 on vm+llvm+hybrid.
- macOS Metal UIF dashboard offscreen framebuffer verified post backend-selection
  change.
- Browser evidence: headless Chrome 150 (`--headless=new --no-sandbox
  --enable-unsafe-webgpu --use-angle=metal`), HTTP-served bundles (file:// can't
  fetch wasm; data: has no secure context), screenshots read back and judged.

## Remaining known gaps (documented, not blocking the goal)

1. Closure values stored as array elements: deep clone/release degrades to a
   conservative no-op (leak, never crash) on wasm32 — needs an i64-typed
   tagged-element callback ABI (docs/web_runner.md).
2. clear_color-style draw-less clear passes present no content in headless
   screenshot captures (markers fire; clears WITH draws present fine).
   Pre-existing presentation quirk.
3. `--backend vm` graphics runs fail on `kira_runtime` dynamic lib resolution —
   pre-existing, matches in-flight FFI work on this branch.
4. `fps-overlay-smoke` / `SimpleApp` examples have a manifest-layout resolution
   issue (unrelated to wasm).
5. Font files: UIF text uses the builtin FreeType font on wasm; app-shipped
   .ttf assets can now be packaged via the `assets` key but weren't wired into
   the examples.

## Second wave (same day, follow-up asks)

- Fullscreen: canvas fills the window; sokol tracks element size; Kira layout
  genuinely reflows (verified at 1440x900 — truncated card labels complete).
  Harness: `Examples/basic-foundation-app/generated/fullscreen.html`.
- project-matter on wasm: `ksl!` macro now emits WGSL (vertexWgsl/fragmentWgsl,
  `{Shader}__{stage}__main` entries) + `uniformReflection` (real compiler
  reflection, grammar `name:binding:size:stageMask:members`); KG gained
  `createShaderFromKslArtifact` (backend-aware: MSL/WGSL/GLSL) and
  reflection-driven uniform binding in sokol_impl.c (replaces hardcoded
  scene/object blocks; per-stage visibility fix; Float vertex-format fix).
  cube3d + scene3d render real 3D geometry on wasm. Fleet follow-ups: ~35 apps
  still call `createShader(combinedMsl)` (mechanical conversion), dual-stage
  uniforms unsupported, storage buffers/textures unexercised.
- Input: DOM → sokol → Kira decode proven for all event kinds
  (`.codex/tmp/wasm-drive/INPUT-PROOF-README.md`); full visible loop on
  interactive-input-app (click/type/Enter/scroll all react, 60 FPS;
  `Examples/interactive-input-app/generated/input-demo.html`).
- Two more wasm32 codegen fixes (both with regression tests in
  `wasm_emscripten_closure_width_tests.zig`): closure struct-fields were
  ptr-width slots → bit-63 tag truncated → silent default-handler fold or
  `unreachable` trap; now full i64 slots on every target.
- Still open: double `nativeStateFree` abort on wasm for draw-less frames
  (repro `.codex/tmp/wasm-drive/nstest/`; host silently tolerates the double
  free); Any-field closure truncation flagged
  (`.codex/work/wasm32-closure-field-tag-fix.md`).

## Environment notes

- emcc 6.0.2 (brew), node v24, Chrome 150 (brew cask) installed this session.
- Nothing committed; all changes sit in the three worktrees alongside the
  user's pre-existing WIP.
