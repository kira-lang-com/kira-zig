# Glyph atlas for sokol path — working notes

GOAL: eliminate per-frame text/icon per-pixel coverage-quad blit on the sokol
(wasm WebGPU + desktop GL) path. Build an A8 glyph atlas; text/icon draws become
ONE textured quad per glyph sampling the atlas, tinted by vertex color.

## Repos / key files
- ui-foundation/NativeLibs/Text/kira_text.c — FreeType text. draw_run() @741-807
  rasterizes each glyph EVERY FRAME (kira_text_face_render_glyph) then calls
  kg_ui_blit_coverage per glyph. WIP-heavy (multi-session) — extend only.
- ui-foundation/NativeLibs/Icon/kira_icon_draw.c — icon coverage cache (64 LRU,
  keyed hash+px) @44; kira_icon_draw_run @77 blits via kg_ui_blit_coverage.
- kira-graphics/NativeLibs/Sokol/sokol_impl.c — THE backend. Key symbols:
  - kg_ui_blit_coverage @1549 — per-pixel-run coverage -> quads into solid batch.
    "a texture atlas is a later optimization" (the note to kill).
  - kg_ui_draw_vertices @1326 / kg_ui_flush_batch @1308 — solid batch (kg_ui_vertex
    {x,y,r,g,b,a}), ONE append+draw per flush. KG_UI_BATCH_CAPACITY 65536.
  - kg_ui_draw_texture @1426 — existing textured pipeline (kg_ui_tex_vertex
    {x,y,u,v,alpha}); RGBA8 sample * alpha. Study target for glyph pipeline.
  - kg_ui_tex_ensure_pipeline @~1150-1295 — texture shader (WGSL @1180 / GLSL330
    @1189) + pipeline + sampler. Model for glyph pipeline.
  - kg_ui_push_clip@1363/pop_clip@1379 flush solid batch at clip boundary.
  - kg_ui_ndc_x/y — points -> NDC. kg_ui_logical_scale = dpi backing scale.
  - kg_ui_dpi_scale @625 (weak-linked, read by kira_text.c backing_scale).
  - SG_PIXELFORMAT via _sglue_to_sgpixelformat / helper @1660.

## Plan (separate atlas pipeline+batch, additive, low risk)
1. kira-graphics: A8 CPU atlas (2048^2=4MB) + shelf packer + int64-keyed slot
   table. New R8 pipeline (cov=tex.r; out=rgb, a*cov). New glyph vertex batch.
   New API: kg_ui_draw_glyph_coverage(int64 key, x,y,w,rows,pitch,cov, r,g,b,a):
   pack once on first key, thereafter just emit 1 textured quad. Reuses the
   physical-pixel-grid placement math from kg_ui_blit_coverage (crisp/1:1 nearest).
2. Ordering: glyph batch flushed cross-wise vs solid batch to preserve painter
   order (append-time cross flush; boundary flush both). At most one non-empty
   at any clip/pass boundary.
3. Upload timing: sg_update_image is ONCE-PER-FRAME-PER-IMAGE in sokol. Keep CPU
   atlas + g_atlas_cpu_dirty + g_atlas_uploaded_this_frame (reset at FRAME
   boundary = sg_commit, NOT per pass). glyph_flush: if dirty && !uploaded ->
   update whole atlas, mark uploaded. Glyphs packed AFTER this-frame upload draw
   via legacy blit fallback (correct, resident next frame). Atlas-full ->
   fallback this glyph + defer full reset to next frame begin (no mid-frame
   corruption). LOG on reset.
4. ui-foundation: kira_text.c draw_run + kira_icon_draw.c call
   kg_ui_draw_glyph_coverage with a stable key instead of kg_ui_blit_coverage.
   text key = mix(face-id, glyph_index, phys_px_q); icon key = mix(hash, px).
5. Host parity: WGSL + GLSL330 shader variants both. Metal path is separate
   (UiBatch atlas) — DO NOT touch. MSL variant only if tex pipeline has one.

## Open Qs to resolve while reading
- Where is sg_commit / frame boundary to reset uploaded_this_frame? (2 passes:
  editor 3D scene + UI — must reset per FRAME not per pass.)
- kg_ui_vertex + kg_ui_tex_vertex struct defs, kg_ui_ndc, kg_ui_logical_scale.
- Does R8 sampleable image work on WebGPU sokol here? (R8 universal - yes.)

## CONFIRMED FACTS (from reading)
- sg_update_image: mid-pass safe (validation only checks immutable + once-per-
  frame). Limit resets on sg_commit (_sg.frame_index++ @sokol_gfx.h:25666 inside
  sg_commit). So "frame" = sg_commit cycle.
- Frame boundary = kg_end_pass_and_commit @4021 (sg_end_pass@4031, sg_commit@4032).
  Reset g_atlas_uploaded_this_frame + process reset_pending AFTER sg_commit here.
  Each render pass calls this (end+commit per pass). Aligns perfectly.
- Texture binding uses sg_view: sg_view_desc.texture.image=img; sg_make_view;
  bindings.views[0].id = view.id (pattern @2523-2526, used @1478).
- kg_ui_vertex {x,y,r,g,b,a}@587; kg_ui_tex_vertex {x,y,u,v,a}@1102.
- ndc: kg_ui_ndc_x/y@608/615; scale kg_ui_logical_scale@239 (clamped>=1 in blit).
- Shader guards: SOKOL_METAL / SOKOL_WGPU(wasm) / #else GLSL330(SOKOL_GLCORE).
- Pass stale-guard resets kg_ui_batch_count @3656 and @4024 — add glyph reset.
- Boundaries to also flush glyph batch: push_clip@1369, pop_clip@1381,
  draw_texture@1442, end_pass_and_commit@4030.
- kg_ui_draw_vertices@1326 cross-flush glyph; glyph emit cross-flush solid.

## IMPLEMENTED
- sokol_impl.c: glyph atlas module inserted after kg_ui_tex_ensure_pipeline
  (~1295). ATLAS 2048^2 R8. Shelf packer. int64-keyed open-addr slot table.
  New public: kg_ui_draw_glyph_coverage(key,x,y,w,rows,pitch,cov,r,g,b,a).
- kira_text.c draw_run: key=mix(face,glyph,phys_px_q) -> kg_ui_draw_glyph_coverage.
- kira_icon_draw.c: key=mix(hash,px) -> kg_ui_draw_glyph_coverage.

## Build fixes
- sg_image_data uses .mip_levels[0].ptr/.size (NOT .subimage[][]) in this sokol.
- FPS printed to stderr as "KiraGraphics: fps=%.1f frames=%d" (console.warn kira:).
- Chrome: --headless=new --no-sandbox --enable-unsafe-webgpu --use-angle=metal
  --force-device-scale-factor=2 --window-size=1400,900 --enable-logging=stderr
  URL .../interact.html?stage=orbit (or omit for idle). serve.js <dir> <port>.

## MEASUREMENT METHOD (resolved)
- FPS instrument = the editor's OWN on-screen "NN FPS" badge (bottom-left), read
  from a --screenshot. The C stderr "KiraGraphics: fps=" counter does NOT surface
  reliably in headless (only prints on sustained frames; badge is authoritative
  and is what the dpi agent used: "FPS badge value").
- Headless Chrome only drives frames (rAF/BeginFrame) while a --screenshot is
  PENDING. So: launch with --screenshot + long --timeout; the /slow?ms=16000 img
  keeps load pending so the badge stabilizes before capture. No-screenshot runs
  stall the loop after init (that's why earlier fps runs were 0).
- Editor renders continuously via editorEngineFrame per-frame hook (main.kira).

## CORRECTNESS (verified @2x, pointer-key build)
- shot-idle2x.png: ALL text crisp+correct at 2x retina, icons correct, dragon
  renders, no corruption/missing glyphs. Badge showed "30 FPS" (baseline 19 idle).
  -> atlas path visually correct, no regression.

## RESULTS (badge, QUIET machine — MUST kill all chromes between runs; contention
## crushes numbers, e.g. idle2x read 28 with 4 chromes alive, 60 when alone)
- idle @1x: 60 (base) -> 57  (no regression; noise)
- idle @2x: 19 (base) -> 60  *** GOAL: 60fps @retina idle achieved ***
- orbit@2x: 29 (base) -> 30  (3D-scene-fill-bound; text was never the orbit
  bottleneck, so atlas can't help here — remaining ceiling = the scene pass)
- orbit@1x: ~60 (base) -> 60 (no regression)
- resets=0 everywhere with font_path key. Text/icons crisp, no regression.
- Vsync uncap flag = --disable-gpu-vsync only (--disable-frame-rate-limit and
  --run-all-compositor-stages break --timeout/screenshot; don't use).
- cap.sh in this dir does one capture. Badge cropped from bottom-left.

## FINAL STATUS — COMPLETE
Files changed:
- kira-graphics/NativeLibs/Sokol/sokol_impl.c (+~830): glyph atlas module
  (R8 2048^2, shelf packer, int64 open-addr slot table, R8-sampling pipeline in
  MSL/WGSL/GLSL330, glyph vertex batch, cross-flush vs solid batch, once-per-
  commit upload, deferred atlas-full reset) + boundary/frame-reset wiring.
- ui-foundation/NativeLibs/Text/kira_text.c: kira_text_glyph_key(font_path,
  glyph, phys_px) + draw_run routes to kg_ui_draw_glyph_coverage (weak, falls
  back to kg_ui_blit_coverage).
- ui-foundation/NativeLibs/Icon/kira_icon_draw.c (untracked, prior session):
  kira_icon_glyph_key(hash, px) + same routing.

Verified:
- Editor wasm 2x retina: text+icons crisp (matches dpi-after baseline), dragon
  renders, idle 19->60 FPS, orbit 29->30 (scene-bound), resets=0.
- Editor wasm 1x: idle 60->57, orbit 60 (no regression).
- basic-foundation-app wasm 2x: all text crisp incl accents (Épurée), resets=0.
- basic_triangle wasm: renders (non-text sokol path unaffected).
- text-engine-smoke + state-store-smoke: green under node.
- Host mac build (SOKOL_GLCORE / GLSL330 — the real desktop-GL path): compiles +
  links (exit 0). WGSL runtime-verified; GLSL330 compile-verified (identical
  logic). MSL variant = iOS-only, mirrors working tex shader.
- Metal UiBatch compositor (KiraGraphicsFoundationBackend) = separate source,
  untouched.

Remaining ceiling: orbit@2x = 30fps is 3D-scene-fill-bound (dragon mesh + grid +
gizmos at 4x pixels), NOT text — the atlas fully removed the text/icon cost
(idle 19->60 proves it). Item #3 (separate scene depth attachment) is a
scene-pass concern outside the text-atlas mandate; documented, not done.
editor wasm --force-device-scale-factor=2, 1400x900 headless chrome:
  BEFORE: 19 idle / 29 orbit @2x (was 60 @1x).
Build: cd project-matter/apps/editor && <wasm-drive>/kira build --target wasm32-emscripten .
Serve: node <wasm-drive>/serve.js <dir> <port 8160+>
Compare crispness vs .codex/tmp/wasm-drive/dpi-after-select.png
