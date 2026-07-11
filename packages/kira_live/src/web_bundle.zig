const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const llvm_backend = @import("kira_llvm_backend");
const manifest = @import("kira_manifest");
const shared = @import("supervisor_shared.zig");

/// Inputs for compiling a Kira project to a real wasm32-emscripten web bundle.
///
/// The bundle is the honest path: the project entrypoint is compiled through the
/// real frontend + IR + LLVM + emcc pipeline (the same machinery `kira build
/// --backend wasm32-emscripten` uses), producing `main.js` + `main.wasm` that run
/// the actual Kira `main()` in a browser or under node. No hand-assembled probe
/// module is involved.
pub const BundleOptions = struct {
    source_path: []const u8,
    project_root: ?[]const u8,
    project_name: []const u8,
    surface: manifest.WebSurface,
    /// Directory the served/exported files land in (index.html, main.js, main.wasm, ...).
    web_root: []const u8,
    /// Scratch directory for the emcc build (object files stay out of `web_root`).
    build_dir: []const u8,
};

pub const BundleResult = struct {
    index_path: []const u8,
    ffi_path: []const u8,
    manifest_path: []const u8,
    js_path: []const u8,
    wasm_path: []const u8,
};

pub const BundleError = error{
    WebAppBuildFailed,
    MissingWasmJsArtifact,
    MissingWasmBinaryArtifact,
};

/// Compile `options.source_path` to a real wasm32-emscripten bundle and write the
/// served/exported directory. On a frontend/backend/toolchain failure the build
/// diagnostics are rendered to `stderr` and `error.WebAppBuildFailed` is returned.
pub fn buildWebApp(
    allocator: std.mem.Allocator,
    options: BundleOptions,
    stderr: anytype,
) !BundleResult {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, options.build_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, options.web_root);

    const build_js_path = try std.fs.path.join(allocator, &.{ options.build_dir, "main.js" });

    var system = build.BuildSystem.init(allocator);
    const result = try system.build(.{
        .source_path = options.source_path,
        .output_path = build_js_path,
        .target = .{ .execution = .wasm32_emscripten },
    });
    if (result.failed()) {
        try renderBuildDiagnostics(stderr, result.diagnostics);
        return BundleError.WebAppBuildFailed;
    }

    const built_js = findArtifactWithSuffix(result.artifacts, ".js") orelse return BundleError.MissingWasmJsArtifact;
    const built_wasm = findArtifactWithSuffix(result.artifacts, ".wasm") orelse return BundleError.MissingWasmBinaryArtifact;

    const js_path = try std.fs.path.join(allocator, &.{ options.web_root, "main.js" });
    const wasm_path = try std.fs.path.join(allocator, &.{ options.web_root, "main.wasm" });
    try copyFile(allocator, built_js, js_path);
    try copyFile(allocator, built_wasm, wasm_path);
    // The emcc-generated JS locates the wasm binary by the basename baked in at
    // link time (the project artifact name, e.g. `my-app.wasm`). Keep that name
    // available next to the canonical `main.wasm` so the loader resolves it for
    // project builds whose artifact is not literally `main.*`.
    const built_wasm_name = std.fs.path.basename(built_wasm);
    if (!std.mem.eql(u8, built_wasm_name, "main.wasm")) {
        const original_name_path = try std.fs.path.join(allocator, &.{ options.web_root, built_wasm_name });
        try copyFile(allocator, built_wasm, original_name_path);
    }
    // When the project declared `assets`, emcc emits a `--preload-file` data
    // package next to the `.js`, named after the linked output basename and
    // fetched at runtime by the generated loader. Copy it into the served root
    // under the canonical `main.data` and, when the built basename differs, its
    // original name too (mirroring the `.wasm` copy above) so the loader —
    // whichever name it baked in — resolves the package.
    if (dataSidecarPath(allocator, built_js)) |built_data| {
        if (fileExists(built_data)) {
            const main_data = try std.fs.path.join(allocator, &.{ options.web_root, "main.data" });
            try copyFile(allocator, built_data, main_data);
            const built_data_name = std.fs.path.basename(built_data);
            if (!std.mem.eql(u8, built_data_name, "main.data")) {
                const original_data_path = try std.fs.path.join(allocator, &.{ options.web_root, built_data_name });
                try copyFile(allocator, built_data, original_data_path);
            }
        }
    } else |_| {}

    const index_path = try std.fs.path.join(allocator, &.{ options.web_root, "index.html" });
    const ffi_path = try std.fs.path.join(allocator, &.{ options.web_root, "kira-browser-ffi.generated.js" });
    const manifest_path = try std.fs.path.join(allocator, &.{ options.web_root, "manifest.json" });
    try shared.writeFile(index_path, try webIndex(allocator, options.project_name, options.surface));
    try shared.writeFile(ffi_path, webGeneratedFfiJs());
    try shared.writeFile(manifest_path, try webManifestJson(allocator, options.project_name, manifest.webSurfaceRequirements(options.surface)));

    return .{
        .index_path = index_path,
        .ffi_path = ffi_path,
        .manifest_path = manifest_path,
        .js_path = js_path,
        .wasm_path = wasm_path,
    };
}

pub const NodeRunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_ok: bool,
};

/// Execute the emcc-generated `main.js` under node — the headless proof that the
/// real Kira entrypoint runs (a browserless environment cannot host a page, so
/// node executes the same artifact the browser would load). The caller owns the
/// returned stdout/stderr slices.
pub fn runNodeApp(
    allocator: std.mem.Allocator,
    js_path: []const u8,
    cwd: ?[]const u8,
) !NodeRunResult {
    const process_environ = shared.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .cwd = if (cwd) |root| .{ .path = root } else .inherit,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_ok = result.term == .exited and result.term.exited == 0,
    };
}

fn renderBuildDiagnostics(stderr: anytype, items: []const diagnostics.Diagnostic) !void {
    for (items) |diag| try shared.renderStandaloneDiagnostic(stderr, diag);
}

fn findArtifactWithSuffix(artifacts: []const build_def.Artifact, suffix: []const u8) ?[]const u8 {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable and std.mem.endsWith(u8, artifact.path, suffix)) return artifact.path;
    }
    return null;
}

/// The emcc data-package sidecar path for a linked `.js` loader: `foo.js` ->
/// `foo.data`. Returns an error when the loader path has no `.js` suffix.
fn dataSidecarPath(allocator: std.mem.Allocator, js_path: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, js_path, ".js")) return error.NotAJsPath;
    return std.fmt.allocPrint(allocator, "{s}.data", .{js_path[0 .. js_path.len - ".js".len]});
}

fn copyFile(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, from, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    try shared.writeRawBytes(to, bytes);
}

/// The browser shell. It pre-defines the emscripten `Module` so it can capture the
/// real app stdout into the page/console and emit Kira-owned progression events
/// only from the genuine emscripten lifecycle callbacks: `onRuntimeInitialized`
/// fires when the wasm module is instantiated and the runtime is ready (right
/// before `main()` runs), and `postRun` fires after `main()` returns. No event is
/// emitted unless the corresponding real milestone happened.
pub fn webIndex(allocator: std.mem.Allocator, project_name: []const u8, surface: manifest.WebSurface) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>{s}</title></head>
        \\<body data-kira-runner="web" data-kira-surface="{s}" data-kira-artifact="main.wasm">
        \\<h1>{s}</h1>
        \\<pre id="kira-stdout" aria-label="Kira application output"></pre>
        \\<script src="./kira-browser-ffi.generated.js"></script>
        \\<script>
        \\(() => {{
        \\  const sink = document.getElementById("kira-stdout");
        \\  const emit = (line) => {{ if (sink) sink.textContent += line + "\n"; console.log(line); }};
        \\  const appOut = (text) => {{ if (sink) sink.textContent += text + "\n"; console.log(text); }};
        \\  globalThis.KiraWasmApp = {{ moduleLoaded: false, runtimeStarted: false, mainReturned: false, stdout: [] }};
        \\  globalThis.Module = {{
        \\    print: (text) => {{ globalThis.KiraWasmApp.stdout.push(text); appOut(text); }},
        \\    printErr: (text) => {{ console.error(text); }},
        \\    onRuntimeInitialized: () => {{
        \\      globalThis.KiraWasmApp.moduleLoaded = true;
        \\      globalThis.KiraWasmApp.runtimeStarted = true;
        \\      emit("kira.wasm.module_loaded");
        \\      emit("kira.runtime.started");
        \\    }},
        \\    postRun: [() => {{
        \\      globalThis.KiraWasmApp.mainReturned = true;
        \\      emit("kira.app.main_returned");
        \\    }}],
        \\  }};
        \\}})();
        \\</script>
        \\<script src="./main.js"></script>
        \\</body></html>
        \\
    , .{ project_name, surface.label(), project_name });
}

/// Foundation.Web FFI binding glue. This is real binding surface (callback
/// registry, DOM/console/navigator handles, timers, event hooks) that Kira code
/// can drive; it is not a success marker and emits nothing on its own.
pub fn webGeneratedFfiJs() []const u8 {
    return
    \\// generated by Kira Foundation.Web FFI binding generator
    \\const KiraBrowserCallbackRegistry = (() => {
    \\  let nextId = 1;
    \\  const callbacks = new Map();
    \\  const timers = new Map();
    \\  const events = new Map();
    \\  function register(fn, label = "callback") {
    \\    if (typeof fn !== "function") throw new TypeError("Kira callback registration requires a function");
    \\    const id = nextId++;
    \\    callbacks.set(id, { fn, label });
    \\    return id;
    \\  }
    \\  function invoke(id, ...args) {
    \\    const record = callbacks.get(id);
    \\    if (!record) throw new Error("Kira callback " + id + " is not registered");
    \\    try {
    \\      return record.fn(...args);
    \\    } catch (error) {
    \\      console.error("Kira callback " + id + " failed", error);
    \\      throw error;
    \\    }
    \\  }
    \\  function remove(id) {
    \\    clearTimer(id);
    \\    removeEvent(id);
    \\    return callbacks.delete(id);
    \\  }
    \\  function setTimer(fnOrId, ms) {
    \\    const id = typeof fnOrId === "function" ? register(fnOrId, "timer") : fnOrId;
    \\    const timer = globalThis.setTimeout(() => {
    \\      try {
    \\        invoke(id);
    \\      } finally {
    \\        timers.delete(id);
    \\        callbacks.delete(id);
    \\      }
    \\    }, ms);
    \\    timers.set(id, timer);
    \\    return id;
    \\  }
    \\  function clearTimer(id) {
    \\    if (!timers.has(id)) return false;
    \\    globalThis.clearTimeout(timers.get(id));
    \\    timers.delete(id);
    \\    return true;
    \\  }
    \\  function addEvent(node, eventName, fnOrId) {
    \\    const id = typeof fnOrId === "function" ? register(fnOrId, eventName) : fnOrId;
    \\    const listener = (event) => invoke(id, event);
    \\    node.addEventListener(eventName, listener);
    \\    events.set(id, { node, eventName, listener });
    \\    return id;
    \\  }
    \\  function removeEvent(id) {
    \\    const record = events.get(id);
    \\    if (!record) return false;
    \\    record.node.removeEventListener(record.eventName, record.listener);
    \\    events.delete(id);
    \\    return true;
    \\  }
    \\  function clearAll() {
    \\    for (const id of Array.from(timers.keys())) clearTimer(id);
    \\    for (const id of Array.from(events.keys())) removeEvent(id);
    \\    callbacks.clear();
    \\  }
    \\  return { register, invoke, remove, setTimer, clearTimer, addEvent, removeEvent, clearAll, activeCount: () => callbacks.size };
    \\})();
    \\
    \\globalThis.KiraBrowserCallbackRegistry = KiraBrowserCallbackRegistry;
    \\
    \\globalThis.KiraBrowserFFI = {
    \\  documentBody: () => document.body,
    \\  createElement: (tag) => document.createElement(tag),
    \\  setText: (node, text) => { node.textContent = text; },
    \\  appendChild: (parent, child) => parent.appendChild(child),
    \\  setAttribute: (node, name, value) => node.setAttribute(name, value),
    \\  setStyle: (node, name, value) => { node.style[name] = value; },
    \\  addClass: (node, name) => node.classList.add(name),
    \\  removeClass: (node, name) => node.classList.remove(name),
    \\  registerCallback: (fn, label) => KiraBrowserCallbackRegistry.register(fn, label),
    \\  invokeCallback: (id, ...args) => KiraBrowserCallbackRegistry.invoke(id, ...args),
    \\  removeCallback: (id) => KiraBrowserCallbackRegistry.remove(id),
    \\  clearCallbacks: () => KiraBrowserCallbackRegistry.clearAll(),
    \\  activeCallbackCount: () => KiraBrowserCallbackRegistry.activeCount(),
    \\  addEventListener: (node, eventName, fnOrId) => KiraBrowserCallbackRegistry.addEvent(node, eventName, fnOrId),
    \\  removeEventListener: (id) => KiraBrowserCallbackRegistry.removeEvent(id),
    \\  onClick: (node, fnOrId) => KiraBrowserCallbackRegistry.addEvent(node, "click", fnOrId),
    \\  consoleLog: (text) => console.log(text),
    \\  userAgent: () => navigator.userAgent,
    \\  href: () => location.href,
    \\  setTimeout: (fnOrId, ms) => KiraBrowserCallbackRegistry.setTimer(fnOrId, ms),
    \\  clearTimeout: (id) => KiraBrowserCallbackRegistry.clearTimer(id),
    \\  createCanvas: () => document.createElement("canvas"),
    \\  detectWebGPU: async () => ({ available: !!navigator.gpu, adapter: navigator.gpu ? await navigator.gpu.requestAdapter() : null }),
    \\};
    \\
    ;
}

pub fn webManifestJson(allocator: std.mem.Allocator, project_name: []const u8, requirements: manifest.WebSurfaceRequirements) ![]const u8 {
    const capability = if (requirements.graphics_capability) |capability_value| capability_value.label() else "none";
    return std.fmt.allocPrint(
        allocator,
        "{{\"runner\":\"web\",\"runtime\":\"kira-wasm\",\"artifact\":\"main.wasm\",\"loader\":\"main.js\",\"artifact_kind\":\"emscripten-compiled-app\",\"placeholder\":false,\"surface\":\"{s}\",\"rendering_model\":\"{s}\",\"graphics_capability\":\"{s}\",\"requires_canvas\":{},\"requires_browser_detection\":{},\"app\":\"{s}\"}}\n",
        .{
            requirements.surface.label(),
            requirements.rendering_model.label(),
            capability,
            requirements.requires_canvas,
            requirements.requires_browser_detection,
            project_name,
        },
    );
}

test "web bundle index loads the compiled emcc loader, not a probe module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try webIndex(arena.allocator(), "KiraApp", .dom);
    try std.testing.expect(std.mem.indexOf(u8, html, "./main.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "onRuntimeInitialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "postRun") != null);
    // The retired probe artifact must never be referenced by the app shell.
    try std.testing.expect(std.mem.indexOf(u8, html, "kira-app.wasm") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "kira-wasm.js") == null);
    // No fake host-surface markers baked into the shell.
    try std.testing.expect(std.mem.indexOf(u8, html, "HOST_") == null);
}

test "web bundle manifest describes the compiled emcc artifact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try webManifestJson(arena.allocator(), "KiraApp", manifest.webSurfaceRequirements(.webgpu));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifact\":\"main.wasm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"artifact_kind\":\"emscripten-compiled-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surface\":\"webgpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_canvas\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "generated-runtime-module") == null);
}

test "web bundle FFI glue exposes stable callback handles" {
    const js = webGeneratedFfiJs();
    try std.testing.expect(std.mem.indexOf(u8, js, "KiraBrowserCallbackRegistry") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "registerCallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "removeCallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clearCallbacks") != null);
    // FFI glue is binding surface only; it must not emit success markers.
    try std.testing.expect(std.mem.indexOf(u8, js, "HOST_") == null);
}

test "web bundle compiles a real wasm app and node runs the entrypoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const process_allocator = std.heap.smp_allocator;
    // Skip when the emscripten toolchain or node is not available in this env.
    llvm_backend.emscripten.validateAvailable(process_allocator) catch |err| switch (err) {
        error.EmscriptenUnavailable => return error.SkipZigTest,
        else => return err,
    };
    if (!nodeAvailable(process_allocator)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "web");
    try tmp.dir.createDirPath(std.testing.io, "build");
    // A named project (artifact `webproj.js`, not `main.js`) covers the loader's
    // baked-in wasm basename: the bundle must keep that name resolvable.
    try tmp.dir.createDirPath(std.testing.io, "proj/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "proj/kira.toml",
        .data =
        \\[package]
        \\name = "webproj"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "proj/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    print("web-bundle-node-ok");
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "proj/app/main.kira", allocator);
    const web_root = try tmp.dir.realPathFileAlloc(std.testing.io, "web", allocator);
    const build_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "build", allocator);

    var stderr_buffer: std.Io.Writer.Allocating = .init(allocator);
    const bundle = try buildWebApp(allocator, .{
        .source_path = source_path,
        .project_root = null,
        .project_name = "solo",
        .surface = .dom,
        .web_root = web_root,
        .build_dir = build_dir,
    }, &stderr_buffer.writer);

    // Real emcc artifacts land in the served root; the retired probe does not.
    try std.testing.expect(fileExists(bundle.js_path));
    try std.testing.expect(fileExists(bundle.wasm_path));
    // The loader resolves the wasm by its baked-in project basename, so the
    // bundle must keep `webproj.wasm` alongside the canonical `main.wasm`.
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ web_root, "webproj.wasm" })));
    try std.testing.expect(!fileExists(try std.fs.path.join(allocator, &.{ web_root, "kira-app.wasm" })));

    const html = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, bundle.index_path, allocator, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, html, "./main.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "kira-app.wasm") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "HOST_") == null);

    // Node executes the very artifact a browser would load and prints real output.
    const node_run = try runNodeApp(process_allocator, bundle.js_path, null);
    defer process_allocator.free(node_run.stdout);
    defer process_allocator.free(node_run.stderr);
    try std.testing.expect(node_run.exit_ok);
    try std.testing.expect(std.mem.indexOf(u8, node_run.stdout, "web-bundle-node-ok") != null);
}

fn fileExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn nodeAvailable(allocator: std.mem.Allocator) bool {
    const process_environ = shared.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ "node", "--version" },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}
