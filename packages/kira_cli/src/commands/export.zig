const std = @import("std");
const apple_export = @import("apple_export.zig");
const android_export = @import("android_export.zig");
const diag_messages = @import("kira_diagnostic_messages");
const manifest = @import("kira_manifest");
const kira_project = @import("kira_project");
const kira_toolchain = @import("kira_toolchain");
const kira_live = @import("kira_live");
const support = @import("../support.zig");
const diagnostics = @import("kira_diagnostics");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    if (parsed.xcode_rebuild_platform) |platform_name| {
        return apple_export.xcodeRebuild(allocator, stdout, stderr, parsed.input_path, platform_name);
    }
    var manifest_diagnostics = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    defer manifest_diagnostics.deinit();
    const target = kira_project.resolveTargetFromPathWithDiagnostics(allocator, parsed.input_path, &manifest_diagnostics) catch |err| switch (err) {
        error.InvalidProjectPath => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.invalidProjectPath(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        error.ProjectManifestNotFound => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.PackageMessages.missingProjectManifest(allocator, parsed.input_path));
            return error.CommandFailed;
        },
        error.DiagnosticsEmitted => {
            try support.renderStandaloneDiagnostics(stderr, manifest_diagnostics.items);
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
        .apple, .macos, .ios, .tvos, .visionos => try apple_export.run(allocator, stdout, stderr, parsed.family, exports_root, parsed.input_path),
        .windows => try exportWindows(allocator, stdout, stderr, exports_root, project_name),
        .android => try exportAndroid(allocator, stdout, stderr, exports_root, project_name, selected_app_path),
        .web => try exportWeb(allocator, stdout, stderr, exports_root, project_name, parsed.surface, target.source_path, root),
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
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "java", "com", "kira", "app", "MainActivity.java" }), android_export.mainSource());
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "assets", "KiraRunner.toml" }), try runnerConfigToml(allocator, "android", project_name, selected_app_path));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "res", "values", "styles.xml" }), "<resources><style name=\"AppTheme\" parent=\"android:style/Theme.Material.Light.NoActionBar\"/></resources>\n");
    try stdout.print("exported Android Gradle runner project at {s}\n", .{root});
    if (!commandExists(allocator, "sdkmanager") and !commandExists(allocator, "adb")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "Android Studio installation is intentionally not automated."));
    }
}

fn exportWeb(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    exports_root: []const u8,
    project_name: []const u8,
    surface: manifest.WebSurface,
    source_path: ?[]const u8,
    project_root: []const u8,
) !void {
    if (surface == .hybrid) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, surface.label(), "The hybrid web surface is modeled, but it still needs a browser VM/native boundary runner."));
        return error.CommandFailed;
    }
    const entrypoint = source_path orelse {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, surface.label(), "The web export target requires an app or example entrypoint to compile to wasm32-emscripten."));
        return error.CommandFailed;
    };
    const root = try std.fs.path.join(allocator, &.{ exports_root, "web" });
    const build_dir = try std.fs.path.join(allocator, &.{ exports_root, "web-build" });
    const bundle = kira_live.web_bundle.buildWebApp(allocator, .{
        .source_path = entrypoint,
        .project_root = project_root,
        .project_name = project_name,
        .surface = surface,
        .web_root = root,
        .build_dir = build_dir,
    }, stderr) catch |err| switch (err) {
        error.WebAppBuildFailed => return error.CommandFailed,
        else => return err,
    };
    try stdout.print("exported Kira Wasm {s} app at {s} (loader {s}, module {s})\n", .{ surface.label(), root, bundle.js_path, bundle.wasm_path });
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

fn writeTextFile(path: []const u8, data: []const u8) !void {
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

test "Android application ids are valid without manual replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("com.kira.kira_app", try androidApplicationId(arena.allocator(), "Kira App"));
    try std.testing.expectEqualStrings("com.kira.app_123_demo", try androidApplicationId(arena.allocator(), "123 Demo"));
}
