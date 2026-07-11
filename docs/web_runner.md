# Kira Wasm Web Runner

The `web` runner id maps to Kira Wasm, the web runner/runtime backend. Kira Wasm is not Kira Web.

- Foundation provides low-level platform APIs, including `Foundation.Web`.
- Kira Wasm is the runner/runtime backend for browsers.
- Kira Web is reserved for a future React-alternative framework.
- Kira UI/UI Foundation/Kira Graphics are separate from Kira Web.

Web surfaces are typed:

- `dom`
- `webgpu`
- `hybrid`

## Real build path (no probe module)

`kira export web`, `kira live web`, and `kira run web` compile the project's real
entrypoint through the actual backend pipeline — the same machinery
`kira build --backend wasm32-emscripten` uses:

```
Kira source -> typecheck -> Kira IR -> LLVM backend -> wasm32-emscripten -> emcc link -> main.js + main.wasm
```

The emcc-generated `main.js` (loader) and `main.wasm` (compiled module) are written
into the served/exported directory alongside an `index.html` shell that loads
`main.js`. The default emcc output supports both `web` and `node` environments, so
one artifact serves the browser and headless node without a per-invocation link
flag change. Executable links pass `-sALLOW_MEMORY_GROWTH=1` (real apps exceed
emscripten's 16MB default heap; the first oversized allocation would otherwise
abort the module) together with `-sGROWABLE_ARRAYBUFFERS=0`, because a growable
memory otherwise surfaces as a resizable `ArrayBuffer` that `TextDecoder.decode`
rejects, breaking every `UTF8ToString` at runtime. Object files from the link
step stay in a sibling `web-build/` scratch directory, out of the served output. The hand-assembled probe module
(`kira-app.wasm` / `kira-wasm.js`) is gone from the app path; nothing masquerades
as the app.

### Honest progression events

The `index.html` shell pre-defines the emscripten `Module` object and emits
Kira-owned events only from genuine emscripten lifecycle callbacks:

- `onRuntimeInitialized` fires once the wasm module is instantiated and the runtime
  is ready (right before `main()` runs) → logs `kira.wasm.module_loaded` and
  `kira.runtime.started`.
- The app's real stdout is captured through `Module.print` into the page (`<pre
  id="kira-stdout">`) and the console.
- `postRun` fires after `main()` returns → logs `kira.app.main_returned`.

No event is emitted unless the corresponding real milestone happened. There are no
`HOST_*` capability markers in the app shell.

### Headless `kira run web`

A browserless environment cannot host a page, so `kira run web` (which drives
`kira live web --headless`) compiles the real wasm bundle and then executes the
generated `main.js` under `node` — the same artifact a browser would load. The
app's real stdout is streamed through and the node exit status decides success
(`web.run.node_executed` on success, `web.run.node_failed` otherwise).

### Interactive `kira live web`

Non-headless `kira live web` compiles the bundle and serves it over HTTP so a real
browser can load `main.js`/`main.wasm` and run the Kira entrypoint. The host only
serves files; the page reports the genuine emscripten lifecycle events above.

### Surfaces and requirements

Web surfaces remain typed (`dom`, `webgpu`, `hybrid`). `manifest.json` records the
surface, rendering model, and graphics capability for the compiled app
(`artifact_kind: emscripten-compiled-app`). `hybrid` is still rejected with a
precise diagnostic until it has a browser VM/native boundary runner.

Foundation.Web browser APIs are FFI-backed. `kira-browser-ffi.generated.js` ships
the binding glue (DOM node handles, console logging, navigator/location access,
attributes/styles/classes, stable callback registration/invocation/removal, DOM
event hooks, timers, callback cleanup, WebGPU capability detection). It is binding
surface only and emits no success markers.

### Bundling runtime assets (`assets` manifest key)

Emscripten has no host filesystem, so an app that reads files at runtime (shader
sources, fonts, data tables) finds nothing on wasm unless those files are packaged
into the module. Declare them in `kira.toml` with a project-root-relative
`assets` list:

```toml
[package]
name = "triangle"
assets = ["generated/Shaders", "fonts"]
```

Each entry must exist at build time; a missing entry fails the build with a
`KPK025` diagnostic (surfaced on every target, not just wasm) instead of silently
shipping an incomplete package. Generate build-time assets first — e.g.
`kira shader build Shaders/Name.ksl --target wgsl --out-dir generated/Shaders`.

For a `wasm32-emscripten` build the linker passes each entry to `emcc` as
`--preload-file <abs>@/<project-relative-path>`, mounting the directory at its
project-relative location inside the browser MEMFS. Because the app's working
directory on MEMFS is `/`, a runtime-relative open (`fopen("generated/Shaders/…")`)
resolves against the mounted tree exactly as it does on a host build reading from
disk. emcc emits a `.data` side-package next to `main.js`; `kira live/run web`
copies it into the served/exported web root (as `main.data`, plus the linked
basename when they differ) so the generated loader fetches it.

On every non-wasm target the `assets` key is accepted and validated but otherwise
inert: host and native builds read the same paths straight from disk, so nothing
is packaged and no `.data` file is produced.

### Requirements and current limitations

`emcc` and `node` must be on `PATH` (or discoverable via `EMSDK`/`EMCC`). App
packages that link a host-only native library with no `wasm32-emscripten` target
fail with a precise `KTC003` diagnostic instead of a faked success — the real,
honest outcome for a target that cannot yet lower to wasm.

#### wasm32 bridge-value element representation

The runtime `KiraBridgeValue` (array elements, native-state slots, dispatch args)
has a target-width payload: on 64-bit a string `{ptr,len}` uses two 8-byte words
(payload field 2 = ptr, extra field 3 = len); on wasm32 a pointer and `size_t`
are 32-bit, so the whole struct is 16 bytes and both halves pack into the single
8-byte payload word (ptr@8, len@12). The backend emits this packed layout on
wasm32 (`backend_capi_bridge_string.zig`), so strings stored in arrays/native
state round-trip correctly across the C runtime helpers (which memcpy
`sizeof(KiraBridgeValue)` = 16 bytes per element). Writing the length to field 3
placed it past the 16-byte C struct and the runtime read length 0 — the
`ownership_string_deep_value_parity` empty-string regression, now fixed and
covered on the `wasm` backend.

Known caveat — closure **deep clone / element release** of closures stored *as
array elements* on wasm32. A closure value is a Kira i64 carrying a bit-63 tag
plus a 32-bit heap pointer; the full tagged word round-trips through the element
payload (store/load/invoke of closures-in-arrays works — verified on wasm and
native), but `kira_array_clone`/`kira_array_release` read the element through the
C `payload.raw_ptr` union member (`uintptr_t` = 32-bit on wasm32) and hand it to
a `void*`-typed per-element callback, both of which drop bit-63. The clone/release
then treats the block as an untagged plain pointer and conservatively no-ops
(leak, never a double free). This is a *distinct* representation issue from the
string layout bug above: the closure value is stored losslessly and only truncates
at the C `raw_ptr` dereference + `void*` callback boundary, which a fix would have
to widen to an i64-typed tagged-element callback ABI (not just a storage-layout
change).

Commands:

```bash
kira export web <app-or-source> --surface dom
kira export web <app-or-source> --surface webgpu
kira run web <app> --quit-after 2s
kira live web <app> --surface dom --quit-after 10s
```
