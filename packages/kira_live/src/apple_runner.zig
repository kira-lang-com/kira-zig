const std = @import("std");
const builtin = @import("builtin");
const live = @import("root.zig");
const live_build_options = @import("kira_live_build_options");
const manifest_config = @import("kira_manifest");
const model = @import("model.zig");
const native = @import("kira_native_lib_definition");
const shared = @import("supervisor_shared.zig");
const live_args = @import("live_args.zig");

pub const PreparedRunner = struct {
    runner_dir: []const u8,
    manifest_path: []const u8,
    executable_path: ?[]const u8 = null,
    subcommand: ?[]const u8 = null,
};

pub fn generateRunnerArtifacts(
    allocator: std.mem.Allocator,
    kind: live.RunnerKind,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
    parsed: live_args.ParsedArgs,
    stderr: anytype,
) !PreparedRunner {
    const runners_root = try std.fs.path.join(allocator, &.{ target.output_root, "runners" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, runners_root);
    const runner_dir = try std.fs.path.join(allocator, &.{ runners_root, kind.deterministicDirectoryName() });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, runner_dir);
    const cache_rel = switch (kind) {
        .desktop_dynamic_host => "cache",
        .xcode_macos, .xcode_ios, .xcode_tvos, .xcode_visionos => "app-support/KiraLive",
        else => "cache",
    };
    const manifest_path = try std.fs.path.join(allocator, &.{ runner_dir, "KiraRunner.toml" });
    const ios_simulator = kind == .xcode_ios and live_args.isIosSimulatorRequest(parsed);
    const runner_manifest = model.RunnerManifest{
        .kind = kind,
        .name = target.runner_display_name,
        .bundle_id = try runnerBundleId(allocator, target, kind),
        .version = "0.1.0",
        .target_path = target.target_root,
        .package_name = target.target_package_name,
        .validation_app_path = target.validation_app_root,
        .bundles_path = try std.fs.path.join(allocator, &.{ target.output_root, "bundles" }),
        .local_cache_path = cache_rel,
        .main_bundle_id = bundles.graph.main_bundle_id,
        .server_host = switch (kind) {
            .xcode_ios => if (ios_simulator) "127.0.0.1" else "0.0.0.0",
            else => "127.0.0.1",
        },
        .server_port = 0,
        .native_contract_hash = bundles.native_contract_hash,
        .runtime_mode = .live,
        .embedded_bundles_path = null,
    };
    try shared.writeTomlFile(manifest_path, runner_manifest);

    switch (kind) {
        .desktop_dynamic_host => {
            _ = stderr;
            const runner_exe = try std.process.executablePathAlloc(std.Options.debug_io, allocator);
            return .{
                .runner_dir = runner_dir,
                .manifest_path = manifest_path,
                .executable_path = runner_exe,
                .subcommand = "__live-runner",
            };
        },
        .xcode_macos => try generateXcodeProject(allocator, .macos, runner_dir, target, bundles),
        .xcode_ios => try generateXcodeProject(allocator, if (ios_simulator) .ios_simulator else .ios, runner_dir, target, bundles),
        .xcode_tvos,
        .xcode_visionos,
        .windows_visual_studio,
        .android_gradle,
        .web_kira_wasm,
        .linux_cmake,
        => {},
    }
    return .{
        .runner_dir = runner_dir,
        .manifest_path = manifest_path,
    };
}

pub const XcodePlatform = enum { macos, ios, ios_simulator };

fn appleSdkName(platform: XcodePlatform) []const u8 {
    return switch (platform) {
        .macos => "macosx",
        .ios => "iphoneos",
        .ios_simulator => "iphonesimulator",
    };
}

fn appleSupportTarget(allocator: std.mem.Allocator, platform: XcodePlatform) ![]const u8 {
    return switch (platform) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "aarch64-macos-none"),
            .x86_64 => allocator.dupe(u8, "x86_64-macos-none"),
            else => error.UnsupportedTarget,
        },
        .ios => allocator.dupe(u8, "aarch64-ios-none"),
        .ios_simulator => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "aarch64-ios-simulator"),
            else => error.UnsupportedTarget,
        },
    };
}

fn generateXcodeProject(
    allocator: std.mem.Allocator,
    platform: XcodePlatform,
    runner_dir: []const u8,
    target: live.ResolvedLiveTarget,
    bundles: live.BundleBuildArtifacts,
) !void {
    const sources_dir = try std.fs.path.join(allocator, &.{ runner_dir, "Sources" });
    const resources_dir = try std.fs.path.join(allocator, &.{ runner_dir, "Resources" });
    const project_dir = try std.fs.path.join(allocator, &.{ runner_dir, try std.fmt.allocPrint(allocator, "{s}.xcodeproj", .{target.runner_display_name}) });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, sources_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, resources_dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, project_dir);

    const main_m = try std.fs.path.join(allocator, &.{ sources_dir, "main.m" });
    try shared.writeFile(main_m, try std.fmt.allocPrint(
        allocator,
        \\#import <Foundation/Foundation.h>
        \\extern int kira_live_runner_entry(const char *manifest_path);
        \\int main(int argc, char **argv) {{
        \\    @autoreleasepool {{
        \\        NSString *path = [[NSBundle mainBundle] pathForResource:@"KiraRunner" ofType:@"toml"];
        \\        return kira_live_runner_entry([path UTF8String]);
        \\    }}
        \\}}
    ,
        .{},
    ));

    const bundle_id = try runnerBundleId(allocator, target, if (platform == .macos) .xcode_macos else .xcode_ios);
    const plist_path = try std.fs.path.join(allocator, &.{ resources_dir, "Info.plist" });
    try shared.writeFile(plist_path, try infoPlist(allocator, platform, target.runner_display_name, bundle_id));
    const runner_manifest_path = try std.fs.path.join(allocator, &.{ runner_dir, "KiraRunner.toml" });
    const runner_manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, runner_manifest_path, allocator, .limited(1024 * 1024));
    const runner_resource_path = try std.fs.path.join(allocator, &.{ resources_dir, "KiraRunner.toml" });
    try shared.writeFile(runner_resource_path, runner_manifest_text);

    const project_path = try std.fs.path.join(allocator, &.{ project_dir, "project.pbxproj" });
    const runner_build_root = try shared.resolveLiveRunnerBuildRoot(allocator);
    if (platform == .ios or platform == .ios_simulator) {
        const sdk_name = appleSdkName(platform);
        const sdk_capture = try shared.runToolCapture(allocator, &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" });
        defer allocator.free(sdk_capture);
        const sdk_path = std.mem.trim(u8, sdk_capture, " \t\r\n");
        try shared.runToolInCwd(allocator, runner_build_root, &.{ live_build_options.zig_exe, "build", "live-runner-support", "-Doptimize=ReleaseFast", try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{try appleSupportTarget(allocator, platform)}), try std.fmt.allocPrint(allocator, "-Dapple-sdk={s}", .{sdk_path}) });
    } else {
        try shared.runToolInCwd(allocator, runner_build_root, &.{ live_build_options.zig_exe, "build", "live-runner-support", "-Doptimize=ReleaseFast" });
    }
    const support_library_source = try std.fs.path.join(allocator, &.{ runner_build_root, "zig-out", "lib", "libkira_live_runner_support.a" });
    const support_library_path = try repackSupportArchiveForXcode(allocator, support_library_source, runner_dir);
    try shared.writeFile(project_path, try pbxproj(
        allocator,
        platform,
        target.runner_display_name,
        bundle_id,
        "Resources/Info.plist",
        support_library_path,
        bundles.main_native_object_path,
        bundles.main_native_libraries,
    ));
}

fn repackSupportArchiveForXcode(allocator: std.mem.Allocator, source_archive: []const u8, runner_dir: []const u8) ![]const u8 {
    const build_dir = try std.fs.path.join(allocator, &.{ runner_dir, "build" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, build_dir);
    const dest_archive = try std.fs.path.join(allocator, &.{ build_dir, "libkira_live_runner_support_xcode.a" });
    const object_dir = try std.fs.path.join(allocator, &.{ build_dir, "support-objects" });
    _ = std.Io.Dir.cwd().deleteTree(std.Options.debug_io, object_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, object_dir);
    try shared.runToolInCwd(allocator, object_dir, &.{ "/usr/bin/ar", "-x", source_archive });

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ "/usr/bin/libtool", "-static", "-o", dest_archive });
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, object_dir, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".o")) continue;
        const object_path = try std.fs.path.join(allocator, &.{ object_dir, entry.name });
        try shared.runTool(allocator, &.{ "/bin/chmod", "0644", object_path });
        try argv.append(object_path);
    }
    if (argv.items.len == 4) return error.ExternalCommandFailed;
    try shared.runTool(allocator, argv.items);
    return dest_archive;
}

pub fn runnerSelector(allocator: std.mem.Allocator, kind: live.RunnerKind) !?native.TargetSelector {
    return switch (kind) {
        .desktop_dynamic_host, .xcode_macos => try native.TargetSelector.parse(allocator, switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-macos-none",
            .x86_64 => "x86_64-macos-none",
            else => return error.UnsupportedTarget,
        }),
        .xcode_ios => try native.TargetSelector.parse(allocator, "aarch64-ios-none"),
        .xcode_tvos,
        .xcode_visionos,
        .windows_visual_studio,
        .android_gradle,
        .web_kira_wasm,
        .linux_cmake,
        => null,
    };
}

pub fn iosSimulatorSelector(allocator: std.mem.Allocator) !native.TargetSelector {
    return native.TargetSelector.parse(allocator, switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-ios-simulator",
        else => return error.UnsupportedTarget,
    });
}

pub fn validateAppleRunnerProject(
    allocator: std.mem.Allocator,
    developer_dir: []const u8,
    platform: XcodePlatform,
    runner: PreparedRunner,
    product_name: []const u8,
) !void {
    const project_name = try std.fmt.allocPrint(allocator, "{s}.xcodeproj", .{product_name});
    const project_path = try std.fs.path.join(allocator, &.{ runner.runner_dir, project_name });
    const derived_data_path = try std.fs.path.join(allocator, &.{ runner.runner_dir, "DerivedData" });
    try shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{ "xcodebuild", "-list", "-project", project_path });
    try shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{ "xcodebuild", "-showBuildSettings", "-project", project_path });
    switch (platform) {
        .macos => try shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{
            "xcodebuild",
            "-project",
            project_path,
            "-scheme",
            product_name,
            "-configuration",
            "Debug",
            "-derivedDataPath",
            derived_data_path,
            "-sdk",
            "macosx",
            "build",
            "CODE_SIGNING_ALLOWED=NO",
        }),
        .ios => try shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{
            "xcodebuild",
            "-project",
            project_path,
            "-scheme",
            product_name,
            "-configuration",
            "Debug",
            "-derivedDataPath",
            derived_data_path,
            "-sdk",
            "iphoneos",
            "-destination",
            "generic/platform=iOS",
            "build",
            "CODE_SIGNING_ALLOWED=NO",
        }),
        .ios_simulator => try shared.runToolWithDeveloperDir(allocator, developer_dir, null, &.{
            "xcodebuild",
            "-project",
            project_path,
            "-scheme",
            product_name,
            "-configuration",
            "Debug",
            "-derivedDataPath",
            derived_data_path,
            "-sdk",
            "iphonesimulator",
            "-destination",
            "platform=iOS Simulator,name=iPhone 17 Pro",
            "build",
            "CODE_SIGNING_ALLOWED=NO",
        }),
    }
}

fn infoPlist(allocator: std.mem.Allocator, platform: XcodePlatform, name: []const u8, bundle_id: []const u8) ![]const u8 {
    return switch (platform) {
        .macos => std.fmt.allocPrint(
            allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
            \\  <key>CFBundleExecutable</key><string>{s}</string>
            \\  <key>CFBundleIdentifier</key><string>{s}</string>
            \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            \\  <key>CFBundleName</key><string>{s}</string>
            \\  <key>CFBundlePackageType</key><string>APPL</string>
            \\  <key>CFBundleShortVersionString</key><string>0.1.0</string>
            \\  <key>CFBundleVersion</key><string>1</string>
            \\  <key>NSHighResolutionCapable</key><true/>
            \\</dict>
            \\</plist>
        ,
            .{ name, bundle_id, name },
        ),
        .ios, .ios_simulator => std.fmt.allocPrint(
            allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
            \\  <key>CFBundleExecutable</key><string>{s}</string>
            \\  <key>CFBundleIdentifier</key><string>{s}</string>
            \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            \\  <key>CFBundleName</key><string>{s}</string>
            \\  <key>CFBundlePackageType</key><string>APPL</string>
            \\  <key>CFBundleShortVersionString</key><string>0.1.0</string>
            \\  <key>CFBundleVersion</key><string>1</string>
            \\  <key>LSRequiresIPhoneOS</key><true/>
            \\  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
            \\</dict>
            \\</plist>
        ,
            .{ name, bundle_id, name },
        ),
    };
}

fn pbxproj(
    allocator: std.mem.Allocator,
    platform: XcodePlatform,
    product_name: []const u8,
    bundle_id: []const u8,
    info_plist_path: []const u8,
    support_library_path: []const u8,
    main_native_object_path: []const u8,
    native_libraries: []const native.ResolvedNativeLibrary,
) ![]const u8 {
    var ldflags = std.array_list.Managed(u8).init(allocator);
    try ldflags.appendSlice("\"");
    try ldflags.appendSlice(support_library_path);
    try ldflags.appendSlice("\"");
    if (platform == .ios or platform == .ios_simulator) {
        try ldflags.appendSlice(", ");
        try ldflags.appendSlice("\"");
        try ldflags.appendSlice(main_native_object_path);
        try ldflags.appendSlice("\"");
        for (native_libraries) |library| {
            try ldflags.appendSlice(", \"");
            try ldflags.appendSlice(library.artifact_path);
            try ldflags.appendSlice("\"");
            for (library.link.frameworks) |framework| {
                try ldflags.appendSlice(", \"-framework\", \"");
                try ldflags.appendSlice(framework);
                try ldflags.appendSlice("\"");
            }
        }
        try ldflags.appendSlice(", \"-Wl,-export_dynamic\"");
    }

    const sdkroot = appleSdkName(platform);
    const supported_platforms = switch (platform) {
        .macos => "macosx",
        .ios => "iphoneos",
        .ios_simulator => "iphonesimulator",
    };
    const deploy_key = if (platform == .macos) "MACOSX_DEPLOYMENT_TARGET" else "IPHONEOS_DEPLOYMENT_TARGET";
    const deploy_value = if (platform == .macos) "13.0" else "17.0";
    const code_sign_style = if (platform == .ios) "Automatic" else "";
    const code_sign_allowed = if (platform == .ios) "YES" else "NO";

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();
    const w = &buffer.writer;
    try w.writeAll("// !$*UTF8*$!\n");
    try w.writeAll("{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n");
    try w.writeAll("A1 /* Project object */ = {isa = PBXProject; buildConfigurationList = A30; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A2; productRefGroup = A3; projectDirPath = \"\"; projectRoot = \"\"; targets = (A4, ); };\n");
    try w.writeAll("A2 = {isa = PBXGroup; children = (A5, A6, A3, ); sourceTree = \"<group>\"; };\n");
    try w.writeAll("A3 = {isa = PBXGroup; children = (A7, ); name = Products; sourceTree = \"<group>\"; };\n");
    try w.writeAll("A5 = {isa = PBXGroup; path = Sources; sourceTree = \"<group>\"; children = (A8, ); };\n");
    try w.writeAll("A6 = {isa = PBXGroup; path = Resources; sourceTree = \"<group>\"; children = (A9, A17, ); };\n");
    try w.print("A7 = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = \"{s}.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};\n", .{product_name});
    try w.writeAll("A8 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = \"<group>\"; };\n");
    try w.writeAll("A9 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };\n");
    try w.writeAll("A17 = {isa = PBXFileReference; lastKnownFileType = text; path = KiraRunner.toml; sourceTree = \"<group>\"; };\n");
    try w.print("A4 = {{isa = PBXNativeTarget; buildConfigurationList = A31; buildPhases = (A11, A12, A13, ); buildRules = (); dependencies = (); name = \"{s}\"; productName = \"{s}\"; productReference = A7; productType = \"com.apple.product-type.application\"; }};\n", .{ product_name, product_name });
    try w.writeAll("A11 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A14, ); runOnlyForDeploymentPostprocessing = 0; };\n");
    try w.writeAll("A12 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };\n");
    try w.writeAll("A13 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (A16, ); runOnlyForDeploymentPostprocessing = 0; };\n");
    try w.writeAll("A14 = {isa = PBXBuildFile; fileRef = A8; };\n");
    try w.writeAll("A15 = {isa = PBXBuildFile; fileRef = A9; };\n");
    try w.writeAll("A16 = {isa = PBXBuildFile; fileRef = A17; };\n");
    try w.writeAll("A30 = {isa = XCConfigurationList; buildConfigurations = (A32, A33, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n");
    try w.writeAll("A31 = {isa = XCConfigurationList; buildConfigurations = (A34, A35, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n");
    try w.print("A32 = {{isa = XCBuildConfiguration; buildSettings = {{ PRODUCT_NAME = \"{s}\"; PRODUCT_BUNDLE_IDENTIFIER = \"{s}\"; SDKROOT = {s}; SUPPORTED_PLATFORMS = \"{s}\"; {s} = {s}; WRAPPER_EXTENSION = app; PRODUCT_BUNDLE_PACKAGE_TYPE = APPL; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \"{s}\"; CODE_SIGN_STYLE = \"{s}\"; CODE_SIGNING_ALLOWED = {s}; }}; name = Debug; }};\n", .{ product_name, bundle_id, sdkroot, supported_platforms, deploy_key, deploy_value, info_plist_path, code_sign_style, code_sign_allowed });
    try w.print("A33 = {{isa = XCBuildConfiguration; buildSettings = {{ PRODUCT_NAME = \"{s}\"; PRODUCT_BUNDLE_IDENTIFIER = \"{s}\"; SDKROOT = {s}; SUPPORTED_PLATFORMS = \"{s}\"; {s} = {s}; WRAPPER_EXTENSION = app; PRODUCT_BUNDLE_PACKAGE_TYPE = APPL; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \"{s}\"; CODE_SIGN_STYLE = \"{s}\"; CODE_SIGNING_ALLOWED = {s}; }}; name = Release; }};\n", .{ product_name, bundle_id, sdkroot, supported_platforms, deploy_key, deploy_value, info_plist_path, code_sign_style, code_sign_allowed });
    try w.print("A34 = {{isa = XCBuildConfiguration; buildSettings = {{ PRODUCT_NAME = \"{s}\"; PRODUCT_BUNDLE_IDENTIFIER = \"{s}\"; SDKROOT = {s}; SUPPORTED_PLATFORMS = \"{s}\"; {s} = {s}; WRAPPER_EXTENSION = app; PRODUCT_BUNDLE_PACKAGE_TYPE = APPL; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \"{s}\"; GCC_PRECOMPILE_PREFIX_HEADER = NO; CLANG_ENABLE_MODULES = YES; DEAD_CODE_STRIPPING = NO; OTHER_LDFLAGS = ({s}); CODE_SIGN_STYLE = \"{s}\"; CODE_SIGNING_ALLOWED = {s}; }}; name = Debug; }};\n", .{ product_name, bundle_id, sdkroot, supported_platforms, deploy_key, deploy_value, info_plist_path, ldflags.items, code_sign_style, code_sign_allowed });
    try w.print("A35 = {{isa = XCBuildConfiguration; buildSettings = {{ PRODUCT_NAME = \"{s}\"; PRODUCT_BUNDLE_IDENTIFIER = \"{s}\"; SDKROOT = {s}; SUPPORTED_PLATFORMS = \"{s}\"; {s} = {s}; WRAPPER_EXTENSION = app; PRODUCT_BUNDLE_PACKAGE_TYPE = APPL; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \"{s}\"; GCC_PRECOMPILE_PREFIX_HEADER = NO; CLANG_ENABLE_MODULES = YES; DEAD_CODE_STRIPPING = NO; OTHER_LDFLAGS = ({s}); CODE_SIGN_STYLE = \"{s}\"; CODE_SIGNING_ALLOWED = {s}; }}; name = Release; }};\n", .{ product_name, bundle_id, sdkroot, supported_platforms, deploy_key, deploy_value, info_plist_path, ldflags.items, code_sign_style, code_sign_allowed });
    try w.writeAll("};\nrootObject = A1;\n}\n");
    return buffer.toOwnedSlice();
}

fn expectedBundleIdForValidationApp(allocator: std.mem.Allocator, validation_manifest_path: []const u8) ![]const u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, validation_manifest_path, allocator, .limited(1024 * 1024));
    const parsed = try @import("kira_manifest").parseProjectManifest(allocator, text);
    return bundleIdForName(allocator, parsed.name);
}

pub fn bundleIdForName(allocator: std.mem.Allocator, package_name: []const u8) ![]const u8 {
    const raw = if (std.mem.startsWith(u8, package_name, "Kira") and package_name.len > 4) package_name[4..] else package_name;
    var builder = std.array_list.Managed(u8).init(allocator);
    try builder.appendSlice("com.kira.");
    for (raw, 0..) |ch, index| {
        if (ch == '-' or ch == '.' or ch == ' ') {
            try builder.append('_');
            continue;
        }
        if (std.ascii.isUpper(ch)) {
            if (index != 0) try builder.append('_');
            try builder.append(std.ascii.toLower(ch));
            continue;
        }
        try builder.append(std.ascii.toLower(ch));
    }
    return builder.toOwnedSlice();
}

pub fn runnerBundleId(allocator: std.mem.Allocator, target: live.ResolvedLiveTarget, kind: live.RunnerKind) ![]const u8 {
    if (kind == .xcode_ios) return allocator.dupe(u8, "com.kira.live.dev");
    const base = std.fs.path.basename(target.target_root);
    const suffix = switch (kind) {
        .desktop_dynamic_host => "desktop",
        .xcode_macos => "macos",
        .xcode_ios => "ios",
        .xcode_tvos => "tvos",
        .xcode_visionos => "visionos",
        .windows_visual_studio => "windows",
        .android_gradle => "android",
        .web_kira_wasm => "web",
        .linux_cmake => "linux",
    };
    var builder = std.array_list.Managed(u8).init(allocator);
    try builder.appendSlice("com.kira.live.");
    for (base) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try builder.append(std.ascii.toLower(ch));
        } else {
            try builder.append('-');
        }
    }
    try builder.append('.');
    try builder.appendSlice(suffix);
    return builder.toOwnedSlice();
}

test "iOS runner Info.plist opts into ProMotion (>60 Hz) and macOS does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = "CADisableMinimumFrameDurationOnPhone";
    const ios = try infoPlist(arena.allocator(), .ios, "Demo", "com.kira.demo");
    try std.testing.expect(std.mem.indexOf(u8, ios, key) != null);
    const sim = try infoPlist(arena.allocator(), .ios_simulator, "Demo", "com.kira.demo");
    try std.testing.expect(std.mem.indexOf(u8, sim, key) != null);
    const mac = try infoPlist(arena.allocator(), .macos, "Demo", "com.kira.demo");
    try std.testing.expect(std.mem.indexOf(u8, mac, key) == null);
}

test "iOS live runner uses stable reusable development bundle identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const target = live.ResolvedLiveTarget{
        .target_root = "/tmp/ui-foundation",
        .target_manifest_path = "/tmp/ui-foundation/kira.toml",
        .target_package_name = "KiraUIFoundation",
        .target_kind = .executable,
        .validation_app_root = "/tmp/ui-foundation/Examples/basic-foundation-app",
        .validation_manifest_path = "/tmp/ui-foundation/Examples/basic-foundation-app/kira.toml",
        .validation_entrypoint_path = "/tmp/ui-foundation/Examples/basic-foundation-app/app/main.kira",
        .output_root = "/tmp/ui-foundation/Examples/basic-foundation-app/.kira-build/live",
        .runner_display_name = "UIFoundationLiveRunner",
    };
    const bundle_id = try runnerBundleId(arena.allocator(), target, .xcode_ios);
    try std.testing.expectEqualStrings("com.kira.live.dev", bundle_id);
}

test "macOS live runner project leaves app graphics code in the loaded Kira bundle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const project = try pbxproj(
        arena.allocator(),
        .macos,
        "SokolLiveRunner",
        "com.kira.live.sokol.macos",
        "Resources/Info.plist",
        "/tmp/libkira_live_runner_support_xcode.a",
        "/tmp/com.kira.sokol_triangle.o",
        &.{},
    );
    try std.testing.expect(std.mem.indexOf(u8, project, "libkira_live_runner_support_xcode.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "com.kira.sokol_triangle.o") == null);
}
