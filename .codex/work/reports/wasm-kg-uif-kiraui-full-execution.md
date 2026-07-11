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

## Third wave (2026-07-11): project-matter editor — full win

The editor renders completely in headless Chrome on wasm: full chrome (menu
bar with the Hosami project, hierarchy, import/components/properties panels,
content browser) plus the viewport drawing the lambert-lit dragon mesh (18MB
kmesh streamed from MEMFS) over the perspective grid. Full marker chain incl.
`KIRA_APP_RENDERED_VISIBLE_CONTENT`, zero Dawn errors. Host Metal render
verified identical before/after.

Editor needed (beyond prior machinery): 3 shader conversions to
createShaderFromKslArtifact; backend-agnostic `Graphics.contextWidth/Height`
(was Metal-only → 0 on sokol → 0x0 image abort); auto-managed offscreen
depth-stencil in kg_begin_render_pass (Metal supplies implicitly, sokol
didn't); `-1` texture-format sentinel now resolves to swapchain format in
kg_create_texture_id; REAL textured UI compositing `kg_ui_draw_texture`
(MSL/WGSL/GLSL) replacing ui-foundation's flat-fill TextureView placeholder
(fake-success surface removed); storage-buffer/compute (matter rain)
Metal-gated cleanly pending sokol-WGPU storage support; `assets = ["Assets",
"hosami"]` + hosami symlink (MEMFS clamps `..` to root, so the editor's
`../hosami` probe resolves to the mounted copy).

## Fourth wave (2026-07-11): quality + performance

- Interactive editor proven: entity selection, File menu (Save World/Save
  As/Reload Project), RMB camera look (after platform-gating the Apple-only
  NSCursor call in graphicsShowMouse — was aborting wasm), all via injected
  DOM input in headless Chrome.
- emcc link stage was -O0; now follows KIRA_NATIVE_OPT (default -O2 —
  binaryen wasm-opt + minified loader). link.zig emccLinkOptFlag.
- Measured wasm CPU overhead: ≈1.6× native (same Kira bench, LLVM -O2 both).
- High-DPI done right (kira-graphics + ui-foundation): layout in points,
  native-pixel framebuffer, glyphs rasterized at size×dpi_scale, pointer
  coords normalized; hit-testing verified; Metal host untouched;
  GraphicsApplication.highDpi (default true) is the escape hatch.
- Icons: root cause = drawIconFields had NO non-Metal branch (silent drop).
  Real fallback (kira_icon_draw.c cached rasterize + tinted coverage blit).
- Glyph atlas on the sokol path (sokol_impl.c +830 lines): 2048² R8 skyline
  atlas, path+glyph+px keys, batched single draw, once-per-commit upload,
  deferred reset on full. Editor FPS at 2× retina: idle 19→60, orbit 29→30
  (orbit is 3D-scene fill-bound — scene-pass depth-attachment /
  dynamic-resolution is the remaining lever, documented not implemented).
- Two more genuine kira-zig codegen fixes with corpus tests: closure
  struct-fields ptr-width tag truncation (silent default-handler fold /
  unreachable trap; now i64 slots) and F32-in-f64-context invalid IR
  (float32_width_parity). Suites 161/0; corpus 527/0 host + 527/0 wasm.

## Fifth wave (2026-07-11): pixel-perfect layout

- Cursor-steal + right-click interception fixed: canvas owns contextmenu
  (sokol_impl.c kg_js_own_right_click, emscripten-gated), JS cursor watchdog
  (restore on all-buttons-up / blur / hidden), editor stale-drag guard.
  Adversarially verified (stolen mouseup scenario).
- Retina icon misalignment: icons rasterized at point size while the atlas
  blit divides by dpi — now rasterize at size×dpi like text (kira_icon_draw.c).
- Pixel snapping unified (sokol_impl.c): one rule at the point→pixel seam —
  each rect edge independently round(v*scale); solid quads, texture quads,
  and scissors now agree with the glyph path. Validated at 1×, 1.5×
  (fractional acid test, zero edge drift), 2×, with A/B pixel-diff proof.
- Equal-inset law (user's standing rule: h and v padding MUST be equal):
  11 offenders equalized across the editor chrome (tool button, grips, plus
  button, row eyes, magnifiers, dropdown icons, tab markers, transport pill,
  status icon); law codified in modules/editor Theme.kira; deliberate
  exceptions documented (title-bar runs, alignment columns, centered
  cross-axis). Rule also saved to agent memory (kira-ui-padding-rule).

## Environment notes

- emcc 6.0.2 (brew), node v24, Chrome 150 (brew cask) installed this session.
- Nothing committed; all changes sit in the three worktrees alongside the
  user's pre-existing WIP.
