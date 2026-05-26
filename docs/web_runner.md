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

The current implemented proof is `dom`. `webgpu` and `hybrid` are modeled and rejected with precise diagnostics until they have real host support.

Foundation.Web browser APIs are FFI-backed. The generated binding surface includes DOM node handles, console logging, navigator/location access, attributes/styles/classes, click/event hooks, and timers. Generated JS glue lives in web exports as `kira-browser-ffi.generated.js`.

`examples/web_dom` demonstrates:

- creating DOM elements
- setting text
- appending children
- logging `Kira browser API call succeeded`
- showing location/user-agent data
- updating text to `Kira DOM updated`

Commands:

```bash
kira check examples/web_dom
kira run web examples/web_dom --quit-after 1s
kira live web examples/web_dom --surface dom --quit-after 10s
kira export web examples/web_dom --surface dom
```

Emscripten is detected through `emcc --version`. If it is missing and cannot be set up non-interactively, Kira reports `KTC030`/`KTC031` instead of claiming a compiled Wasm build.
