const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const manifest = @import("kira_manifest");
const kira_project = @import("kira_project");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
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
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, exports_root);

    switch (parsed.family) {
        .apple => try exportApple(allocator, stdout, exports_root, project_name, null),
        .macos => try exportApple(allocator, stdout, exports_root, project_name, .macos),
        .ios => try exportApple(allocator, stdout, exports_root, project_name, .ios),
        .tvos => try exportApple(allocator, stdout, exports_root, project_name, .tvos),
        .visionos => try exportApple(allocator, stdout, exports_root, project_name, .visionos),
        .windows => try exportWindows(allocator, stdout, stderr, exports_root, project_name),
        .android => try exportAndroid(allocator, stdout, stderr, exports_root, project_name),
        .web => try exportWeb(allocator, stdout, stderr, exports_root, project_name, parsed.surface),
        .linux => try exportLinux(allocator, stdout, stderr, exports_root, project_name),
    }
}

const ParsedArgs = struct {
    family: manifest.ExportFamily,
    input_path: []const u8 = ".",
    profile: manifest.BuildProfile = .debug,
    surface: manifest.WebSurface = .dom,
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
    exports_root: []const u8,
    project_name: []const u8,
    focus: ?manifest.ApplePlatform,
) !void {
    const apple_root = try std.fs.path.join(allocator, &.{ exports_root, "apple" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, apple_root);
    const workspace = try std.fs.path.join(allocator, &.{ apple_root, "KiraApp.xcworkspace" });
    const project = try std.fs.path.join(allocator, &.{ apple_root, "KiraApp.xcodeproj" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, workspace);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, project);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraRuntime" }));
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraLiveClient" }));
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraBundleLoader" }));
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ apple_root, "Shared", "Assets.xcassets" }));

    try writeTextFile(try std.fs.path.join(allocator, &.{ workspace, "contents.xcworkspacedata" }),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Workspace version="1.0">
        \\  <FileRef location="group:KiraApp.xcodeproj"></FileRef>
        \\</Workspace>
        \\
    );
    try writeTextFile(try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraRuntime", "main.m" }), appleMainSource());
    try writeTextFile(try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraLiveClient", "KiraLiveClient.swift" }), appleSwiftSource());
    try writeTextFile(try std.fs.path.join(allocator, &.{ apple_root, "Shared", "KiraBundleLoader", "KiraBundleLoader.swift" }), appleBundleLoaderSource());

    const platforms = [_]manifest.ApplePlatform{ .macos, .ios, .tvos, .visionos };
    for (platforms) |platform| {
        const dir_name = applePlatformDir(platform);
        const platform_dir = try std.fs.path.join(allocator, &.{ apple_root, dir_name });
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, platform_dir);
        try writeTextFile(try std.fs.path.join(allocator, &.{ platform_dir, "Info.plist" }), try appleInfoPlist(allocator, platform, project_name));
        try writeTextFile(try std.fs.path.join(allocator, &.{ platform_dir, "Entitlements.plist" }), entitlementsPlist());
    }
    try writeTextFile(try std.fs.path.join(allocator, &.{ project, "project.pbxproj" }), try applePbxproj(allocator, project_name));
    try writeAppleSchemes(allocator, apple_root);
    if (focus) |platform| {
        try stdout.print("exported {s} Apple target at {s}\n", .{ platform.label(), apple_root });
    } else {
        try stdout.print("exported merged Apple workspace at {s}\n", .{apple_root});
    }
}

fn exportWindows(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "windows" });
    try writeCmakeScaffold(allocator, root, project_name, "windows");
    try stdout.print("exported Windows Visual Studio/CMake scaffold at {s}\n", .{root});
    if (!commandExists(allocator, "cmake")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingVisualStudioTools(allocator, "`cmake` was not found on PATH in this environment."));
    }
}

fn exportLinux(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "linux" });
    try writeCmakeScaffold(allocator, root, project_name, "linux");
    try stdout.print("exported Linux CMake/Ninja scaffold at {s}\n", .{root});
    if (!commandExists(allocator, "cmake") or !commandExists(allocator, "ninja")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingLinuxBuildTools(allocator, "`cmake` and `ninja` should both be available for a full local Linux export build."));
    }
}

fn exportAndroid(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8) !void {
    const root = try std.fs.path.join(allocator, &.{ exports_root, "android" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "java", "com", "kira", "app" }));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "settings.gradle" }), "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }\nrootProject.name = 'KiraApp'\ninclude ':app'\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "build.gradle" }), "plugins {\n    id 'com.android.application' version '8.7.3' apply false\n}\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "build.gradle" }), try std.fmt.allocPrint(allocator, "plugins {{ id 'com.android.application' }}\n\nandroid {{ namespace 'com.kira.app'; compileSdk 35\n    defaultConfig {{ applicationId 'com.kira.{s}'; minSdk 26; targetSdk 35; versionCode 1; versionName '0.1.0' }}\n}}\n", .{safeIdentifier(allocator, project_name) catch "app"}));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "AndroidManifest.xml" }), "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:theme=\"@style/AppTheme\" android:label=\"KiraApp\"><activity android:name=\".MainActivity\" android:exported=\"true\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n");
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "app", "src", "main", "java", "com", "kira", "app", "MainActivity.java" }), "package com.kira.app;\n\nimport android.app.Activity;\nimport android.os.Bundle;\n\npublic final class MainActivity extends Activity {\n  public void onCreate(Bundle state) { super.onCreate(state); }\n}\n");
    try stdout.print("exported Android Gradle scaffold at {s}\n", .{root});
    if (!commandExists(allocator, "sdkmanager") and !commandExists(allocator, "adb")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingAndroidSdk(allocator, "Android Studio installation is intentionally not automated."));
    }
}

fn exportWeb(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype, exports_root: []const u8, project_name: []const u8, surface: manifest.WebSurface) !void {
    if (surface != .dom) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(allocator, surface.label(), "Only the DOM web surface is scaffolded in this milestone."));
        return error.CommandFailed;
    }
    const root = try std.fs.path.join(allocator, &.{ exports_root, "web" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, root);
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "index.html" }), try webIndex(allocator, project_name));
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "kira-browser-ffi.generated.js" }), webGeneratedFfiJs());
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "kira-wasm.js" }), webRuntimeJs());
    try writeBytesFile(try std.fs.path.join(allocator, &.{ root, "kira-app.wasm" }), &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "manifest.json" }), try std.fmt.allocPrint(allocator, "{{\"runner\":\"web\",\"runtime\":\"kira-wasm\",\"surface\":\"dom\",\"app\":\"{s}\"}}\n", .{project_name}));
    try stdout.print("exported Kira Wasm DOM scaffold at {s}\n", .{root});
    if (!commandExists(allocator, "emcc")) {
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.ToolchainMessages.missingEmscripten(allocator, "`emcc --version` is not available; generated DOM artifacts are static scaffold output, not a native Emscripten build."));
    }
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
    try writeTextFile(try std.fs.path.join(allocator, &.{ root, "src", "main.c" }), "#include <stdio.h>\nint main(void) { puts(\"Kira platform export scaffold\"); return 0; }\n");
}

fn writeAppleSchemes(allocator: std.mem.Allocator, apple_root: []const u8) !void {
    const schemes_root = try std.fs.path.join(allocator, &.{ apple_root, "KiraApp.xcodeproj", "xcshareddata", "xcschemes" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, schemes_root);
    const platforms = [_][]const u8{ "macOS", "iOS", "tvOS", "visionOS" };
    const profiles = [_][]const u8{ "Debug", "Profiler", "Release" };
    for (platforms) |platform| {
        for (profiles) |profile| {
            const name = try std.fmt.allocPrint(allocator, "KiraApp-{s}-{s}", .{ platform, profile });
            try writeTextFile(try std.fs.path.join(allocator, &.{ schemes_root, try std.fmt.allocPrint(allocator, "{s}.xcscheme", .{name}) }), try schemeXml(allocator, name, profile));
        }
    }
}

fn schemeXml(allocator: std.mem.Allocator, name: []const u8, profile: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Scheme LastUpgradeVersion="1600" version="1.7">
        \\  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        \\    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{s}" BuildableName="{s}.app" BlueprintName="{s}" ReferencedContainer="container:KiraApp.xcodeproj"></BuildableReference></BuildActionEntry></BuildActionEntries>
        \\  </BuildAction>
        \\  <LaunchAction buildConfiguration="{s}"></LaunchAction>
        \\</Scheme>
        \\
    , .{ name, name, name, profile });
}

fn applePbxproj(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return std.fmt.allocPrint(allocator,
        \\// !$*UTF8*$!
        \\{{
        \\archiveVersion = 1;
        \\classes = {{}};
        \\objectVersion = 56;
        \\objects = {{
        \\A1 = {{isa = PBXProject; buildConfigurationList = C0; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A2; productRefGroup = A3; projectDirPath = ""; projectRoot = ""; targets = (TmacDebug, TiosDebug, TtvosDebug, TvisionDebug, ); }};
        \\A2 = {{isa = PBXGroup; children = (A3, FMain, ); sourceTree = "<group>"; }};
        \\A3 = {{isa = PBXGroup; children = (); name = Products; sourceTree = "<group>"; }};
        \\FMain = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = Shared/KiraRuntime/main.m; sourceTree = "<group>"; }};
        \\BFMac = {{isa = PBXBuildFile; fileRef = FMain; }};
        \\BFIos = {{isa = PBXBuildFile; fileRef = FMain; }};
        \\BFTvos = {{isa = PBXBuildFile; fileRef = FMain; }};
        \\BFVision = {{isa = PBXBuildFile; fileRef = FMain; }};
        \\SMac = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFMac, ); runOnlyForDeploymentPostprocessing = 0; }};
        \\SIos = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFIos, ); runOnlyForDeploymentPostprocessing = 0; }};
        \\STvos = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFTvos, ); runOnlyForDeploymentPostprocessing = 0; }};
        \\SVision = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFVision, ); runOnlyForDeploymentPostprocessing = 0; }};
        \\TmacDebug = {{isa = PBXNativeTarget; buildConfigurationList = C1; buildPhases = (SMac, ); buildRules = (); dependencies = (); name = "KiraApp-macOS-Debug"; productName = "KiraApp-macOS-Debug"; productType = "com.apple.product-type.application"; }};
        \\TiosDebug = {{isa = PBXNativeTarget; buildConfigurationList = C2; buildPhases = (SIos, ); buildRules = (); dependencies = (); name = "KiraApp-iOS-Debug"; productName = "KiraApp-iOS-Debug"; productType = "com.apple.product-type.application"; }};
        \\TtvosDebug = {{isa = PBXNativeTarget; buildConfigurationList = C3; buildPhases = (STvos, ); buildRules = (); dependencies = (); name = "KiraApp-tvOS-Debug"; productName = "KiraApp-tvOS-Debug"; productType = "com.apple.product-type.application"; }};
        \\TvisionDebug = {{isa = PBXNativeTarget; buildConfigurationList = C4; buildPhases = (SVision, ); buildRules = (); dependencies = (); name = "KiraApp-visionOS-Debug"; productName = "KiraApp-visionOS-Debug"; productType = "com.apple.product-type.application"; }};
        \\C0 = {{isa = XCConfigurationList; buildConfigurations = (PDebug, PProfiler, PRelease, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
        \\C1 = {{isa = XCConfigurationList; buildConfigurations = (MDebug, MProfiler, MRelease, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
        \\C2 = {{isa = XCConfigurationList; buildConfigurations = (IDebug, IProfiler, IRelease, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
        \\C3 = {{isa = XCConfigurationList; buildConfigurations = (TDebug, TProfiler, TRelease, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
        \\C4 = {{isa = XCConfigurationList; buildConfigurations = (VDebug, VProfiler, VRelease, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
        \\PDebug = {{isa = XCBuildConfiguration; buildSettings = {{}}; name = Debug; }};
        \\PProfiler = {{isa = XCBuildConfiguration; buildSettings = {{}}; name = Profiler; }};
        \\PRelease = {{isa = XCBuildConfiguration; buildSettings = {{}}; name = Release; }};
        \\MDebug = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-macOS-Debug"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.macos.debug"; SDKROOT = macosx; INFOPLIST_FILE = macOS/Info.plist; CODE_SIGNING_ALLOWED = NO;}}; name = Debug; }};
        \\MProfiler = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-macOS-Profiler"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.macos.profiler"; SDKROOT = macosx; INFOPLIST_FILE = macOS/Info.plist; CODE_SIGNING_ALLOWED = NO;}}; name = Profiler; }};
        \\MRelease = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-macOS-Release"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.macos.release"; SDKROOT = macosx; INFOPLIST_FILE = macOS/Info.plist; CODE_SIGNING_ALLOWED = NO;}}; name = Release; }};
        \\IDebug = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-iOS-Debug"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.ios.debug"; SDKROOT = iphoneos; INFOPLIST_FILE = iOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Debug; }};
        \\IProfiler = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-iOS-Profiler"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.ios.profiler"; SDKROOT = iphoneos; INFOPLIST_FILE = iOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Profiler; }};
        \\IRelease = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-iOS-Release"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.ios.release"; SDKROOT = iphoneos; INFOPLIST_FILE = iOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Release; }};
        \\TDebug = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-tvOS-Debug"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.tvos.debug"; SDKROOT = appletvos; INFOPLIST_FILE = tvOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Debug; }};
        \\TProfiler = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-tvOS-Profiler"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.tvos.profiler"; SDKROOT = appletvos; INFOPLIST_FILE = tvOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Profiler; }};
        \\TRelease = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-tvOS-Release"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.tvos.release"; SDKROOT = appletvos; INFOPLIST_FILE = tvOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Release; }};
        \\VDebug = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-visionOS-Debug"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.visionos.debug"; SDKROOT = xros; INFOPLIST_FILE = visionOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Debug; }};
        \\VProfiler = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-visionOS-Profiler"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.visionos.profiler"; SDKROOT = xros; INFOPLIST_FILE = visionOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Profiler; }};
        \\VRelease = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = "KiraApp-visionOS-Release"; PRODUCT_BUNDLE_IDENTIFIER = "com.kira.app.visionos.release"; SDKROOT = xros; INFOPLIST_FILE = visionOS/Info.plist; CODE_SIGNING_ALLOWED = YES;}}; name = Release; }};
        \\}};
        \\rootObject = A1;
        \\}}
        \\
    , .{});
}

fn appleMainSource() []const u8 {
    return "#import <Foundation/Foundation.h>\nint main(int argc, char **argv) { @autoreleasepool { NSLog(@\"Kira Apple runner scaffold\"); } return 0; }\n";
}

fn appleSwiftSource() []const u8 {
    return "import Foundation\n\npublic struct KiraLiveClient { public let serverURL: URL }\n";
}

fn appleBundleLoaderSource() []const u8 {
    return "import Foundation\n\npublic struct KiraBundleLoader { public let bundleRoot: URL }\n";
}

fn applePlatformDir(platform: manifest.ApplePlatform) []const u8 {
    return switch (platform) {
        .macos => "macOS",
        .ios => "iOS",
        .tvos => "tvOS",
        .visionos => "visionOS",
    };
}

fn appleInfoPlist(allocator: std.mem.Allocator, platform: manifest.ApplePlatform, project_name: []const u8) ![]const u8 {
    const requires_ios = if (platform == .ios or platform == .tvos or platform == .visionos) "<key>LSRequiresIPhoneOS</key><true/>" else "";
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict><key>CFBundleName</key><string>{s}</string><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1.0</string>{s}</dict></plist>
        \\
    , .{ project_name, requires_ios });
}

fn entitlementsPlist() []const u8 {
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict/></plist>\n";
}

fn webIndex(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>{s}</title></head>
        \\<body><script src="./kira-browser-ffi.generated.js"></script><script src="./kira-wasm.js"></script></body></html>
        \\
    , .{project_name});
}

fn webGeneratedFfiJs() []const u8 {
    return
    \\// generated by Kira Foundation.Web FFI binding generator
    \\globalThis.KiraBrowserFFI = {
    \\  documentBody: () => document.body,
    \\  createElement: (tag) => document.createElement(tag),
    \\  setText: (node, text) => { node.textContent = text; },
    \\  appendChild: (parent, child) => parent.appendChild(child),
    \\  setAttribute: (node, name, value) => node.setAttribute(name, value),
    \\  setStyle: (node, name, value) => { node.style[name] = value; },
    \\  addClass: (node, name) => node.classList.add(name),
    \\  removeClass: (node, name) => node.classList.remove(name),
    \\  onClick: (node, fn) => node.addEventListener("click", fn),
    \\  consoleLog: (text) => console.log(text),
    \\  userAgent: () => navigator.userAgent,
    \\  href: () => location.href,
    \\  setTimeout: (fn, ms) => setTimeout(fn, ms),
    \\};
    \\
    ;
}

fn webRuntimeJs() []const u8 {
    return
    \\const ffi = globalThis.KiraBrowserFFI;
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
    \\ffi.onClick(button, () => ffi.setText(status, "Kira DOM updated"));
    \\ffi.setTimeout(() => ffi.setText(status, "Kira DOM updated"), 250);
    \\ffi.consoleLog("Kira browser API call succeeded");
    \\
    ;
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

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const candidates = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" };
    for (candidates) |dir| {
        const path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(path);
        var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch continue;
        file.close(std.Options.debug_io);
        return true;
    }
    return false;
}
