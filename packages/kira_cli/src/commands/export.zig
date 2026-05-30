const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const manifest = @import("kira_manifest");
const kira_live = @import("kira_live");
const kira_project = @import("kira_project");
const kira_toolchain = @import("kira_toolchain");
const kira_wasm_runtime = @import("kira_wasm_runtime");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    if (parsed.xcode_rebuild_platform) |platform_name| {
        return xcodeRebuildApple(allocator, stdout, stderr, parsed.input_path, platform_name);
    }
    const target = kira_project.resolveTargetFromPath(allocator, parsed.input_path) catch |err| switch (err) {
        error.InvalidProjectPath => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidProjectPath(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        error.ProjectManifestNotFound => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingProjectManifest(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        else => return err,
    };
    const root = target.root_path orelse std.fs.path.dirname(target.source_path orelse ".") orelse ".";
    const project_name = target.project_name orelse "KiraApp";
    const exports_root = try std.fs.path.join(allocator, &.{ root, "exports" });
    const selected_app_path = try allocator.dupe(u8, root);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, exports_root);

    switch (parsed.family) {
        .apple, .macos, .ios, .tvos, .visionos => try exportApple(allocator, stdout, stderr, exports_root, parsed.input_path),
        .windows => try exportWindows(allocator, stdout, stderr, exports_root, project_name),
        .android => try exportAndroid(allocator, stdout, stderr, exports_root, project_name, selected_app_path),
        .web => try exportWeb(allocator, stdout, stderr, exports_root, project_name, parsed.surface),
        .linux => try exportLinux(allocator, stdout, stderr, exports_root, project_name),
    }
}

const ParsedArgs = struct {
    family: manifest.ExportFamily,
    input_path: []const u8 = ".",
    profile: manifest.BuildProfile = .debug,
    surface: manifest.WebSurface = .dom,
    xcode_rebuild_platform: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = ParsedArgs{ .family = manifest.ExportFamily.parse(args[0]) orelse return error.InvalidArguments };
    var input_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.profile = manifest.BuildProfile.parse(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--surface")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.surface = manifest.WebSurface.parse(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--xcode-rebuild")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.xcode_rebuild_platform = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (input_path != null) return error.InvalidArguments;
        input_path = arg;
    }
    parsed.input_path = input_path orelse ".";
    return parsed;
}

fn exportApple(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    exports_root: []const u8,
    input_path: []const u8,
) !void {
    const apple_root = try std.fs.path.join(allocator, &.{ exports_root, "apple" });
    const base_target = kira_live.resolveLiveTarget(allocator, input_path) catch |err| switch (err) {
        error.LibraryTargetCannotBeStartedInLiveMode => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
                allocator,
                "apple",
                "`kira export apple` needs an executable Kira project (app/example) to embed in the unified KiraApp workspace.",
            ));
            return error.CommandFailed;
        },
        error.TargetNotLiveCapable => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
                allocator,
                "apple",
                "The Kira project does not declare an Apple-capable runtime.",
            ));
            return error.CommandFailed;
        },
        error.InvalidProjectPath => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidProjectPath(allocator, input_path));
            return error.CommandFailed;
        },
        error.ProjectManifestNotFound => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingProjectManifest(allocator, input_path));
            return error.CommandFailed;
        },
        else => return err,
    };

    const generated = kira_live.apple_workspace.generate(allocator, base_target, .{
        .apple_root = apple_root,
        .mode = .standalone,
    }) catch {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
            allocator,
            "apple",
            "Failed to generate the unified Apple workspace (need the Apple toolchain plus per-platform Kira native builds).",
        ));
        return error.CommandFailed;
    };

    try stdout.print("exported unified Apple workspace at {s}\n", .{generated.apple_root});
    for (generated.scheme_names) |scheme| {
        try stdout.print("  scheme: {s}\n", .{scheme});
    }
    for (generated.unavailable) |status| {
        try stdout.print("  note: {s} target not buildable yet ({s})\n", .{ @tagName(status.platform), status.reason });
    }
    try stdout.print("open `{s}/KiraApp.xcworkspace` in Xcode, pick a platform scheme, and Run on its device or simulator.\n", .{generated.apple_root});
}

// Invoked by the generated Xcode Run Script build phase. Rebuilds only the Kira
// artifacts for the SDK Xcode is building ($PLATFORM_NAME) into the existing
// exports/apple tree, so editing Kira source and pressing Build regenerates the
// native object + embedded bundles for that platform without a full re-export.
fn xcodeRebuildApple(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    input_path: []const u8,
    platform_name: []const u8,
) !void {
    const base_target = kira_live.resolveLiveTarget(allocator, input_path) catch {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
            allocator,
            "apple",
            "`kira export apple --xcode-rebuild` needs the original executable Kira project.",
        ));
        return error.CommandFailed;
    };
    const apple_root = try std.fs.path.join(allocator, &.{ base_target.target_root, "exports", "apple" });
    kira_live.apple_workspace.rebuildPlatform(allocator, base_target, apple_root, platform_name) catch {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
            allocator,
            "apple",
            "Failed to rebuild Kira artifacts for the requested Apple SDK platform.",
        ));
        return error.CommandFailed;
    };
    try stdout.print("rebuilt Kira artifacts for {s}\n", .{platform_name});
}

fn exportWindows(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "windows" });
    try writeCmakeScaffold(allocator, root, project_name, "windows");
    try stdout.print("exported Windows Visual Studio/CMake project at {s}\n", .{root});
    if (!commandExists(allocator, "cmake")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingVisualStudioTools(allocator, "`cmake` was not found on PATH in this environment."));
    }
}

fn exportLinux(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "linux" });
    try writeCmakeScaffold(allocator, root, project_name, "linux");
    try stdout.print("exported Linux CMake/Ninja project at {s}\n", .{root});
    if (!commandExists(allocator, "cmake") or !commandExists(allocator, "ninja")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingLinuxBuildTools(allocator, "`cmake` and `ninja` should both be available for a full local Linux export build."));
    }
}

fn exportAndroid(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8, selected_app_path: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "android" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "java", "com", "kira", "app" }));
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "assets" }));
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "res", "values" }));
    const application_id = try androidApplicationId(allocator, project_name);
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "settings.gradle" }), "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }\nrootProject.name = 'KiraApp'\ninclude ':app'\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "build.gradle" }), "plugins {\n    id 'com.android.application' version '8.7.3' apply false\n}\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "build.gradle" }), try std.fmt.allocPrint(allocator, "plugins {{ id 'com.android.application' }}\n\nandroid {{ namespace 'com.kira.app'; compileSdk 35\n    defaultConfig {{ applicationId '{s}'; minSdk 26; targetSdk 35; versionCode 1; versionName '0.1.0' }}\n    compileOptions {{ sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }}\n}}\n", .{application_id}));
    if (try androidSdkRoot(allocator)) |sdk_root| {
        defer allocator.free(sdk_root);
        try writeTextFile(try std.fs.path.join(allocator, &.{ root, "local.properties" }), try std.fmt.allocPrint(allocator, "sdk.dir={s}\n", .{sdk_root}));
    }
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "AndroidManifest.xml" }), "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:theme=\"@style/AppTheme\" android:label=\"KiraApp\"><activity android:name=\"com.kira.app.MainActivity\" android:exported=\"true\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "java", "com", "kira", "app", "MainActivity.java" }), androidMainSource());
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "assets", "KiraRunner.toml" }), try runnerConfigToml(allocator, "android", project_name, selected_app_path));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "res", "values", "styles.xml" }), "<resources><style name=\"AppTheme\" parent=\"android:style/Theme.Material.Light.NoActionBar\"/></resources>\n");
    try stdout.print("exported Android Gradle runner project at {s}\n", .{root});
    if (!commandExists(allocator, "sdkmanager") and !commandExists(allocator, "adb")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "Android Studio installation is intentionally not automated."));
    }
}

fn exportWeb(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8, surface: manifest.WebSurface) !void {
    if (surface == .hybrid) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, surface.label(), "The hybrid web surface is modeled, but it still needs a browser VM/native boundary runner."));
        return error.CommandFailed;
    }
    const requirements = manifest.webSurfaceRequirements(surface);
    const root = try std.fs.path.join(allocator, &.{ exports_root, "web" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, root);
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "index.html" }), try webIndex(allocator, project_name, surface));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "kira-browser-ffi.generated.js" }), webGeneratedFfiJs());
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "kira-wasm.js" }), webRuntimeJs(surface));
    const wasm = try kira_wasm_runtime.buildModule(allocator, .{ .app_name = project_name, .surface = surface.label() });
    if (!kira_wasm_runtime.validateModule(wasm) or kira_wasm_runtime.isHeaderOnly(wasm)) return error.InvalidWasmArtifact;
    try writeBytesFile(try std.fs.path.join(allocator, &.{ root, "kira-app.wasm" }), wasm);
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "manifest.json" }), try webManifestJson(allocator, project_name, requirements));
    try stdout.print("exported Kira Wasm {s} runtime at {s}\n", .{ surface.label(), root });
}

fn writeCmakeScaffold(allocator: std.mem.Allocator, root: []const u8, project_name: []const u8, platform: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ root, "src" }));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "CMakeLists.txt" }), try std.fmt.allocPrint(allocator,
        \\cmake_minimum_required(VERSION 3.25)
        \\project({s}_kira_{s} C)
        \\add_executable(KiraApp src/main.c)
        \\
    , .{ try safeIdentifier(allocator, project_name), platform }));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "CMakePresets.json" }),
        \\{"version":6,"configurePresets":[{"name":"debug","generator":"Ninja","binaryDir":"build/debug","cacheVariables":{"CMAKE_BUILD_TYPE":"Debug"}},{"name":"release","generator":"Ninja","binaryDir":"build/release","cacheVariables":{"CMAKE_BUILD_TYPE":"Release"}}]}
        \\
    );
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "src", "main.c" }), "#include <stdio.h>\nint main(void) { puts(\"Kira platform export host\"); return 0; }\n");
}

fn androidMainSource() []const u8 {
    return
    \\package com.kira.app;
    \\
    \\import android.app.Activity;
    \\import android.os.Bundle;
    \\import android.util.Log;
    \\import android.widget.TextView;
    \\import java.io.BufferedReader;
    \\import java.io.InputStream;
    \\import java.io.InputStreamReader;
    \\import java.nio.charset.StandardCharsets;
    \\
    \\public final class MainActivity extends Activity {
    \\  private String runnerConfig() {
    \\    StringBuilder builder = new StringBuilder();
    \\    try (InputStream input = getAssets().open("KiraRunner.toml");
    \\         BufferedReader reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))) {
    \\      String line;
    \\      while ((line = reader.readLine()) != null) {
    \\        builder.append(line).append('\n');
    \\      }
    \\      return builder.toString();
    \\    } catch (Exception error) {
    \\      return "KiraRunner.toml unreadable: " + error.getMessage();
    \\    }
    \\  }
    \\
    \\  public void onCreate(Bundle state) {
    \\    super.onCreate(state);
    \\    String config = runnerConfig();
    \\    Log.i("KiraRunner", "Kira Android runner host launched");
    \\    Log.i("KiraRunner", "Kira runner config loaded: " + config);
    \\    TextView label = new TextView(this);
    \\    label.setText("Kira runtime configured");
    \\    setContentView(label);
    \\  }
    \\}
    \\
    ;
}

fn runnerConfigToml(allocator: std.mem.Allocator, runner: []const u8, project_name: []const u8, selected_app_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\runner = "{s}"
        \\payload_kind = "kira-runtime-config"
        \\app_name = "{s}"
        \\selected_example = "{s}"
        \\bundle_identifier = "com.kira.live.dev"
        \\required_markers = [
        \\  "KIRA_UI_FOUNDATION_APP_STARTED",
        \\  "KIRA_UI_TREE_BUILT",
        \\  "KIRA_UI_RETAINED_TREE_READY",
        \\  "KIRA_UI_LAYOUT_NON_EMPTY",
        \\  "KIRA_UI_DRAW_COMMANDS_SUBMITTED",
        \\  "KIRA_APP_RENDERED_VISIBLE_CONTENT",
        \\]
        \\
    ,
        .{ runner, project_name, selected_app_path },
    );
}

fn webIndex(allocator: std.mem.Allocator, project_name: []const u8, surface: manifest.WebSurface) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>{s}</title></head>
        \\<body data-kira-runner="web" data-kira-surface="{s}"><script src="./kira-browser-ffi.generated.js"></script><script src="./kira-wasm.js"></script></body></html>
        \\
    , .{ project_name, surface.label() });
}

fn webGeneratedFfiJs() []const u8 {
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

fn webRuntimeJs(surface: manifest.WebSurface) []const u8 {
    return switch (surface) {
        .dom => webDomRuntimeJs(),
        .webgpu => webGpuRuntimeJs(),
        .hybrid => webDomRuntimeJs(),
    };
}

fn webDomRuntimeJs() []const u8 {
    return
    \\(async () => {
    \\const ffi = globalThis.KiraBrowserFFI;
    \\const wasmBytes = await fetch("./kira-app.wasm").then((response) => response.arrayBuffer());
    \\const wasm = await WebAssembly.instantiate(wasmBytes, {});
    \\const exports = wasm.instance.exports;
    \\const wasmModuleLoaded = exports.kira_wasm_module_loaded();
    \\const runtimeStarted = exports.kira_runtime_started();
    \\const appEntrypointInvoked = exports.kira_app_entrypoint_invoked();
    \\const appStarted = exports.kira_app_start();
    \\globalThis.KiraWasmRuntime = { exports, wasmModuleLoaded, runtimeStarted, appEntrypointInvoked, appStarted, retainedTreeInitialized: exports.kira_retained_tree_initialized() };
    \\if (wasmModuleLoaded) ffi.consoleLog("KIRA_WASM_MODULE_LOADED");
    \\if (runtimeStarted) ffi.consoleLog("KIRA_RUNTIME_STARTED");
    \\if (appEntrypointInvoked) ffi.consoleLog("KIRA_APP_ENTRYPOINT_INVOKED");
    \\ffi.consoleLog("Kira Wasm runtime instantiated");
    \\const root = ffi.documentBody();
    \\const title = ffi.createElement("h1");
    \\ffi.setText(title, "Hello from Kira Wasm");
    \\ffi.appendChild(root, title);
    \\const details = ffi.createElement("p");
    \\ffi.setText(details, "Location: " + ffi.href() + " | UA: " + ffi.userAgent());
    \\ffi.appendChild(root, details);
    \\const button = ffi.createElement("button");
    \\ffi.setText(button, "Click me");
    \\ffi.appendChild(root, button);
    \\const status = ffi.createElement("p");
    \\ffi.setText(status, "Waiting for DOM update");
    \\ffi.appendChild(root, status);
    \\const clickId = ffi.registerCallback(() => ffi.setText(status, "Kira DOM updated"), "button.click");
    \\const clickHandle = ffi.onClick(button, clickId);
    \\const timerId = ffi.registerCallback(() => ffi.setText(status, "Kira DOM updated"), "timer.status");
    \\ffi.setTimeout(timerId, 250);
    \\globalThis.KiraWebHostProbe = { clickHandle, timerId, teardown: () => ffi.clearCallbacks(), activeCallbacks: () => ffi.activeCallbackCount() };
    \\ffi.consoleLog("HOST_BROWSER_API_CALL_SUCCEEDED");
    \\})();
    \\
    ;
}

fn webGpuRuntimeJs() []const u8 {
    return
    \\(async () => {
    \\const ffi = globalThis.KiraBrowserFFI;
    \\const wasmBytes = await fetch("./kira-app.wasm").then((response) => response.arrayBuffer());
    \\const wasm = await WebAssembly.instantiate(wasmBytes, {});
    \\const exports = wasm.instance.exports;
    \\const wasmModuleLoaded = exports.kira_wasm_module_loaded();
    \\const runtimeStarted = exports.kira_runtime_started();
    \\const appEntrypointInvoked = exports.kira_app_entrypoint_invoked();
    \\const uiFoundationStarted = exports.kira_ui_foundation_app_started();
    \\const uiTreeBuilt = exports.kira_ui_tree_built();
    \\const uiRetainedTreeReady = exports.kira_ui_retained_tree_ready();
    \\const uiLayoutNonEmpty = exports.kira_ui_layout_non_empty();
    \\const uiDrawCommandsSubmitted = exports.kira_ui_draw_commands_submitted();
    \\const graphicsWebgpuInitialized = exports.kira_graphics_webgpu_initialized();
    \\const appStarted = exports.kira_app_start();
    \\const retainedTreeInitialized = exports.kira_retained_tree_initialized();
    \\const layoutRan = exports.kira_layout_ran();
    \\const renderCommandsGenerated = exports.kira_render_commands_generated();
    \\globalThis.KiraWasmRuntime = { exports, wasmModuleLoaded, runtimeStarted, appEntrypointInvoked, uiFoundationStarted, uiTreeBuilt, uiRetainedTreeReady, uiLayoutNonEmpty, uiDrawCommandsSubmitted, graphicsWebgpuInitialized, appStarted, retainedTreeInitialized, layoutRan, renderCommandsGenerated };
    \\if (wasmModuleLoaded) ffi.consoleLog("KIRA_WASM_MODULE_LOADED");
    \\if (runtimeStarted) ffi.consoleLog("KIRA_RUNTIME_STARTED");
    \\if (appEntrypointInvoked) ffi.consoleLog("KIRA_APP_ENTRYPOINT_INVOKED");
    \\if (uiFoundationStarted) ffi.consoleLog("KIRA_UI_FOUNDATION_APP_STARTED");
    \\if (uiTreeBuilt) ffi.consoleLog("KIRA_UI_TREE_BUILT");
    \\if (uiRetainedTreeReady) ffi.consoleLog("KIRA_UI_RETAINED_TREE_READY");
    \\if (uiLayoutNonEmpty) ffi.consoleLog("KIRA_UI_LAYOUT_NON_EMPTY");
    \\if (uiDrawCommandsSubmitted) ffi.consoleLog("KIRA_UI_DRAW_COMMANDS_SUBMITTED");
    \\if (graphicsWebgpuInitialized) ffi.consoleLog("KIRA_GRAPHICS_WEBGPU_INITIALIZED");
    \\ffi.consoleLog("Kira Wasm runtime instantiated");
    \\if (retainedTreeInitialized) ffi.consoleLog("Kira UI Foundation retained tree initialized");
    \\if (layoutRan) ffi.consoleLog("Kira UI Foundation layout ran");
    \\if (renderCommandsGenerated) ffi.consoleLog("Kira UI Foundation render commands generated");
    \\const root = ffi.documentBody();
    \\const title = ffi.createElement("h1");
    \\ffi.setText(title, "Kira WebGPU surface");
    \\ffi.appendChild(root, title);
    \\const canvas = ffi.createCanvas();
    \\ffi.setAttribute(canvas, "width", "640");
    \\ffi.setAttribute(canvas, "height", "360");
    \\ffi.setStyle(canvas, "border", "1px solid #222");
    \\ffi.appendChild(root, canvas);
    \\const status = ffi.createElement("p");
    \\ffi.setText(status, "Detecting WebGPU");
    \\ffi.appendChild(root, status);
    \\try {
    \\  const info = await ffi.detectWebGPU();
    \\  if (!info.available || !info.adapter) {
    \\    ffi.setText(status, "WebGPU unavailable in this browser");
    \\    return;
    \\  }
    \\  const device = await info.adapter.requestDevice();
    \\  const context = canvas.getContext("webgpu");
    \\  const format = navigator.gpu.getPreferredCanvasFormat();
    \\  context.configure({ device, format, alphaMode: "opaque" });
    \\  const shader = device.createShaderModule({ code: `
    \\    @vertex fn vs_main(@builtin(vertex_index) vertexIndex: u32) -> @builtin(position) vec4f {
    \\      var positions = array<vec2f, 3>(vec2f(0.0, 0.7), vec2f(-0.7, -0.7), vec2f(0.7, -0.7));
    \\      let p = positions[vertexIndex];
    \\      return vec4f(p, 0.0, 1.0);
    \\    }
    \\    @fragment fn fs_main() -> @location(0) vec4f {
    \\      return vec4f(0.16, 0.62, 0.52, 1.0);
    \\    }
    \\  ` });
    \\  const pipeline = device.createRenderPipeline({
    \\    layout: "auto",
    \\    vertex: { module: shader, entryPoint: "vs_main" },
    \\    fragment: { module: shader, entryPoint: "fs_main", targets: [{ format }] },
    \\    primitive: { topology: "triangle-list" },
    \\  });
    \\  const encoder = device.createCommandEncoder();
    \\  const pass = encoder.beginRenderPass({
    \\    colorAttachments: [{ view: context.getCurrentTexture().createView(), clearValue: { r: 0.04, g: 0.05, b: 0.07, a: 1.0 }, loadOp: "clear", storeOp: "store" }],
    \\  });
    \\  pass.setPipeline(pipeline);
    \\  pass.draw(3);
    \\  pass.end();
    \\  device.queue.submit([encoder.finish()]);
    \\  globalThis.KiraWebGpuHostCapability = { device: true, context: true, pipeline: true, frameSubmitted: true };
    \\  ffi.setText(status, "Host WebGPU frame submitted");
    \\  ffi.consoleLog("HOST_WEBGPU_AVAILABLE");
    \\  ffi.consoleLog("HOST_WEBGPU_PIPELINE_CREATED");
    \\  ffi.consoleLog("HOST_WEBGPU_FRAME_SUBMITTED");
    \\} catch (error) {
    \\  ffi.setText(status, "WebGPU detection failed");
    \\  throw error;
    \\}
    \\})();
    \\
    ;
}

fn webManifestJson(allocator: std.mem.Allocator, project_name: []const u8, requirements: manifest.WebSurfaceRequirements) ![]const u8 {
    const capability = if (requirements.graphics_capability) |capability_value| capability_value.label() else "none";
    return std.fmt.allocPrint(
        allocator,
        "{{\"runner\":\"web\",\"runtime\":\"kira-wasm\",\"artifact\":\"kira-app.wasm\",\"artifact_kind\":\"generated-runtime-module\",\"placeholder\":false,\"surface\":\"{s}\",\"rendering_model\":\"{s}\",\"graphics_capability\":\"{s}\",\"requires_canvas\":{},\"requires_browser_detection\":{},\"app\":\"{s}\"}}\n",
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

fn writeTextFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(path) orelse ".");
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

fn writeBytesFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(path) orelse ".");
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

fn safeIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(std.ascii.toLower(ch));
        } else {
            try out.append('_');
        }
    }
    return out.toOwnedSlice();
}

fn androidApplicationId(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    const segment = try safeJavaPackageSegment(allocator, project_name);
    return std.fmt.allocPrint(allocator, "com.kira.{s}", .{segment});
}

fn safeJavaPackageSegment(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(std.ascii.toLower(ch));
        } else {
            try out.append('_');
        }
    }
    if (out.items.len == 0 or !std.ascii.isAlphabetic(out.items[0])) {
        try out.insertSlice(0, "app_");
    }
    return out.toOwnedSlice();
}

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const candidates = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" };
    for (candidates) |dir| {
        const path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(path);
        var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch continue;
        file.close(std.Options.debug_io);
        return true;
    }
    if (androidSdkToolExists(allocator, name)) return true;
    return false;
}

fn androidSdkToolExists(allocator: std.mem.Allocator, name: []const u8) bool {
    if (androidSdkRoot(allocator) catch null) |root| {
        defer allocator.free(root);
        return androidSdkToolExistsUnderRoot(allocator, root, name);
    }
    return false;
}

fn androidSdkRoot(allocator: std.mem.Allocator) !?[]const u8 {
    if (kira_toolchain.envVarOwned(allocator, "ANDROID_HOME")) |root| {
        if (directoryExistsAbsolute(root)) return root;
        allocator.free(root);
    } else |_| {}
    if (kira_toolchain.envVarOwned(allocator, "ANDROID_SDK_ROOT")) |root| {
        if (directoryExistsAbsolute(root)) return root;
        allocator.free(root);
    } else |_| {}
    if (kira_toolchain.envVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const root = try std.fs.path.join(allocator, &.{ home, "Library", "Android", "sdk" });
        if (directoryExistsAbsolute(root)) return root;
        allocator.free(root);
    } else |_| {}
    return null;
}

fn directoryExistsAbsolute(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn androidSdkToolExistsUnderRoot(allocator: std.mem.Allocator, root: []const u8, name: []const u8) bool {
    const candidates = [_][]const u8{
        "platform-tools",
        "cmdline-tools/latest/bin",
        "emulator",
    };
    for (candidates) |relative| {
        const path = std.fs.path.join(allocator, &.{ root, relative, name }) catch continue;
        defer allocator.free(path);
        var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch continue;
        file.close(std.Options.debug_io);
        return true;
    }
    return false;
}

test "web export FFI uses stable tracked callback handles" {
    const js = webGeneratedFfiJs();
    try std.testing.expect(std.mem.indexOf(u8, js, "KiraBrowserCallbackRegistry") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "registerCallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "invokeCallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "removeCallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clearCallbacks") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "activeCallbackCount") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "addEventListener") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "removeEventListener") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clearTimeout") != null);
}

test "web export manifest models WebGPU canvas requirements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const requirements = manifest.webSurfaceRequirements(.webgpu);
    const json = try webManifestJson(arena.allocator(), "KiraApp", requirements);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surface\":\"webgpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rendering_model\":\"graphics-canvas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"graphics_capability\":\"webgpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_canvas\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_browser_detection\":true") != null);
}

test "Android application ids are valid without manual replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("com.kira.kira_app", try androidApplicationId(arena.allocator(), "Kira App"));
    try std.testing.expectEqualStrings("com.kira.app_123_demo", try androidApplicationId(arena.allocator(), "123 Demo"));
}
