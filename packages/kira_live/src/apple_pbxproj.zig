const std = @import("std");

pub const LdflagsBlock = struct {
    // null => unconditional OTHER_LDFLAGS; otherwise OTHER_LDFLAGS[sdk=<condition>]
    sdk_condition: ?[]const u8,
    value: []const u8,
};

pub const TargetSpec = struct {
    product_name: []const u8,
    bundle_id: []const u8,
    info_plist_rel: []const u8,
    sdkroot: []const u8,
    supported_platforms: []const u8,
    deployment_key: []const u8,
    deployment_value: []const u8,
    device_family: ?[]const u8,
    archs: []const u8,
    ldflags_blocks: []const LdflagsBlock,
    development_team: []const u8,
    // unavailable targets are emitted with no link step and a guard define so the
    // project still opens but the platform clearly cannot run yet.
    unavailable_reason: ?[]const u8 = null,
    // optional shell script run as the first build phase (rebuilds Kira artifacts).
    rebuild_script: ?[]const u8 = null,
    // native (llvm) targets link a self-contained native object (with its own `main`)
    // via OTHER_LDFLAGS — no main.m to compile, no KiraRunner.toml/Bundles to copy.
    native_entry: bool = false,
};

const Ids = struct {
    target: []const u8,
    product: []const u8,
    sources_phase: []const u8,
    frameworks_phase: []const u8,
    resources_phase: []const u8,
    config_list: []const u8,
    config_debug: []const u8,
    config_release: []const u8,
    plist_ref: []const u8,
    plist_build: []const u8,
};

fn idsFor(allocator: std.mem.Allocator, index: usize) !Ids {
    const p = try std.fmt.allocPrint(allocator, "T{d}", .{index});
    return .{
        .target = try std.fmt.allocPrint(allocator, "{s}TGT", .{p}),
        .product = try std.fmt.allocPrint(allocator, "{s}PRD", .{p}),
        .sources_phase = try std.fmt.allocPrint(allocator, "{s}SRC", .{p}),
        .frameworks_phase = try std.fmt.allocPrint(allocator, "{s}FRW", .{p}),
        .resources_phase = try std.fmt.allocPrint(allocator, "{s}RES", .{p}),
        .config_list = try std.fmt.allocPrint(allocator, "{s}CLST", .{p}),
        .config_debug = try std.fmt.allocPrint(allocator, "{s}CDBG", .{p}),
        .config_release = try std.fmt.allocPrint(allocator, "{s}CREL", .{p}),
        .plist_ref = try std.fmt.allocPrint(allocator, "{s}PLR", .{p}),
        .plist_build = try std.fmt.allocPrint(allocator, "{s}PLB", .{p}),
    };
}

// Shared file reference IDs.
const FR_MAIN_M = "FRMAINM";
const BF_MAIN_M = "BFMAINM"; // shared build file for main.m (one PBXBuildFile per source-in-target is required; we make per-target below)
const FR_RUNNER_TOML = "FRRTOML";
const FR_BUNDLES = "FRBUNDLES";
// Trivial source compiled by native (llvm) targets so Xcode runs the linker;
// `main` itself is supplied by kira_native_app.o via OTHER_LDFLAGS. Without a
// compiled source, Xcode skips linking and emits an .app with no executable.
const FR_NATIVE_STUB = "FRNSTUB";

pub fn render(allocator: std.mem.Allocator, targets: []const TargetSpec) ![]const u8 {
    var ids_list = try allocator.alloc(Ids, targets.len);
    for (0..targets.len) |i| ids_list[i] = try idsFor(allocator, i);

    // The runner manifest + bytecode bundles only exist for the hybrid path. A
    // native (llvm) export never writes them, so referencing them would show up red
    // (missing file) in Xcode. Only emit those references when a hybrid target exists.
    var has_hybrid = false;
    for (targets) |spec| {
        if (!spec.native_entry) has_hybrid = true;
    }

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();
    const w = &buffer.writer;

    try w.writeAll("// !$*UTF8*$!\n{\n");
    try w.writeAll("archiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n");

    // Project object.
    try w.writeAll("PROJ = {isa = PBXProject; buildConfigurationList = PROJCLST; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = GRPMAIN; productRefGroup = GRPPROD; projectDirPath = \"\"; projectRoot = \"\"; targets = (");
    for (ids_list) |ids| try w.print("{s}, ", .{ids.target});
    try w.writeAll("); };\n");

    // Groups.
    try w.writeAll("GRPMAIN = {isa = PBXGroup; children = (GRPSRC, GRPRES, GRPPROD, ); sourceTree = \"<group>\"; };\n");
    try w.writeAll("GRPSRC = {isa = PBXGroup; path = Sources; sourceTree = \"<group>\"; children = (" ++ FR_MAIN_M ++ ", " ++ FR_NATIVE_STUB ++ ", ); };\n");
    // Resources group lists the real per-target Info.plists (always present), plus the
    // runner manifest + bytecode bundles only when a hybrid target writes them.
    try w.writeAll("GRPRES = {isa = PBXGroup; path = Resources; sourceTree = \"<group>\"; children = (");
    for (ids_list) |ids| try w.print("{s}, ", .{ids.plist_ref});
    if (has_hybrid) try w.writeAll(FR_RUNNER_TOML ++ ", " ++ FR_BUNDLES ++ ", ");
    try w.writeAll("); };\n");
    try w.writeAll("GRPPROD = {isa = PBXGroup; name = Products; sourceTree = \"<group>\"; children = (");
    for (ids_list) |ids| try w.print("{s}, ", .{ids.product});
    try w.writeAll("); };\n");

    // Shared file references.
    try w.writeAll(FR_MAIN_M ++ " = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = \"<group>\"; };\n");
    try w.writeAll(FR_NATIVE_STUB ++ " = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = native_link_stub.c; sourceTree = \"<group>\"; };\n");
    if (has_hybrid) {
        try w.writeAll(FR_RUNNER_TOML ++ " = {isa = PBXFileReference; lastKnownFileType = text; path = KiraRunner.toml; sourceTree = \"<group>\"; };\n");
        try w.writeAll(FR_BUNDLES ++ " = {isa = PBXFileReference; lastKnownFileType = folder; path = Bundles; sourceTree = \"<group>\"; };\n");
    }

    // Per-target product refs, plist refs, build files.
    for (targets, ids_list) |spec, ids| {
        try w.print("{s} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = \"{s}.app\"; includeInIndex = 0; sourceTree = BUILT_PRODUCTS_DIR; }};\n", .{ ids.product, spec.product_name });
        try w.print("{s} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {s}; sourceTree = \"<group>\"; }};\n", .{ ids.plist_ref, std.fs.path.basename(spec.info_plist_rel) });
        // per-target build files referencing shared sources/resources. Native (llvm)
        // targets compile only the link stub; hybrid targets compile main.m and copy
        // the runner manifest + bytecode bundles.
        if (spec.native_entry) {
            try w.print("{s}BFsrc = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ ids.target, FR_NATIVE_STUB });
        } else {
            try w.print("{s}BFsrc = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ ids.target, FR_MAIN_M });
            try w.print("{s}BFtoml = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ ids.target, FR_RUNNER_TOML });
            try w.print("{s}BFbnd = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ ids.target, FR_BUNDLES });
        }
    }

    // Targets and build phases. A rebuild Run Script (when present) runs first so the
    // active SDK's Kira artifacts are regenerated before sources compile and link.
    for (targets, ids_list) |spec, ids| {
        if (spec.rebuild_script) |_| {
            try w.print("{s} = {{isa = PBXNativeTarget; buildConfigurationList = {s}; buildPhases = ({s}SCRIPT, {s}, {s}, {s}, ); buildRules = (); dependencies = (); name = \"{s}\"; productName = \"{s}\"; productReference = {s}; productType = \"com.apple.product-type.application\"; }};\n", .{
                ids.target, ids.config_list, ids.target, ids.sources_phase, ids.frameworks_phase, ids.resources_phase, spec.product_name, spec.product_name, ids.product,
            });
        } else {
            try w.print("{s} = {{isa = PBXNativeTarget; buildConfigurationList = {s}; buildPhases = ({s}, {s}, {s}, ); buildRules = (); dependencies = (); name = \"{s}\"; productName = \"{s}\"; productReference = {s}; productType = \"com.apple.product-type.application\"; }};\n", .{
                ids.target, ids.config_list, ids.sources_phase, ids.frameworks_phase, ids.resources_phase, spec.product_name, spec.product_name, ids.product,
            });
        }
        if (spec.rebuild_script) |script| {
            try w.print("{s}SCRIPT = {{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; name = \"Rebuild Kira ({s})\"; files = (); inputPaths = (); outputPaths = (); alwaysOutOfDate = 1; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = \"{s}\"; }};\n", .{ ids.target, spec.product_name, try escapePbxString(allocator, script) });
        }
        if (spec.native_entry) {
            // Native targets compile only the link stub (so Xcode runs the linker); the
            // real `main` and all code arrive via OTHER_LDFLAGS (kira_native_app.o + libs).
            // No Kira runner resources are copied.
            try w.print("{s} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({s}BFsrc, ); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ ids.sources_phase, ids.target });
            try w.print("{s} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ids.frameworks_phase});
            try w.print("{s} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ids.resources_phase});
        } else {
            try w.print("{s} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({s}BFsrc, ); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ ids.sources_phase, ids.target });
            try w.print("{s} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ids.frameworks_phase});
            try w.print("{s} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({s}BFtoml, {s}BFbnd, ); runOnlyForDeploymentPostprocessing = 0; }};\n", .{ ids.resources_phase, ids.target, ids.target });
        }
    }

    // Project-level config list + configs.
    try w.writeAll("PROJCLST = {isa = XCConfigurationList; buildConfigurations = (PROJCDBG, PROJCREL, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n");
    try w.writeAll("PROJCDBG = {isa = XCBuildConfiguration; buildSettings = { ENABLE_USER_SCRIPT_SANDBOXING = NO; }; name = Debug; };\n");
    try w.writeAll("PROJCREL = {isa = XCBuildConfiguration; buildSettings = { ENABLE_USER_SCRIPT_SANDBOXING = NO; }; name = Release; };\n");

    // Per-target config lists + build configs.
    for (targets, ids_list) |spec, ids| {
        try w.print("{s} = {{isa = XCConfigurationList; buildConfigurations = ({s}, {s}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};\n", .{ ids.config_list, ids.config_debug, ids.config_release });
        try writeBuildConfig(w, ids.config_debug, "Debug", spec);
        try writeBuildConfig(w, ids.config_release, "Release", spec);
    }

    try w.writeAll("};\nrootObject = PROJ;\n}\n");
    return buffer.toOwnedSlice();
}

fn escapePbxString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (value) |c| switch (c) {
        '\\' => try out.appendSlice("\\\\"),
        '"' => try out.appendSlice("\\\""),
        '\n' => try out.appendSlice("\\n"),
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(c),
    };
    return out.toOwnedSlice();
}

fn writeBuildConfig(w: anytype, id: []const u8, name: []const u8, spec: TargetSpec) !void {
    try w.print("{s} = {{isa = XCBuildConfiguration; buildSettings = {{ ", .{id});
    try w.print("PRODUCT_NAME = \"{s}\"; PRODUCT_BUNDLE_IDENTIFIER = \"{s}\"; ", .{ spec.product_name, spec.bundle_id });
    try w.print("SDKROOT = {s}; SUPPORTED_PLATFORMS = \"{s}\"; {s} = {s}; ", .{ spec.sdkroot, spec.supported_platforms, spec.deployment_key, spec.deployment_value });
    if (spec.device_family) |fam| try w.print("TARGETED_DEVICE_FAMILY = \"{s}\"; ", .{fam});
    try w.print("ARCHS = {s}; VALID_ARCHS = {s}; ONLY_ACTIVE_ARCH = YES; ", .{ spec.archs, spec.archs });
    try w.print("WRAPPER_EXTENSION = app; PRODUCT_BUNDLE_PACKAGE_TYPE = APPL; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \"{s}\"; ", .{spec.info_plist_rel});
    try w.writeAll("CLANG_ENABLE_MODULES = YES; DEAD_CODE_STRIPPING = NO; ALWAYS_SEARCH_USER_PATHS = NO; ");

    if (spec.unavailable_reason) |reason| {
        // No link step: the target compiles a stub main but cannot run; surfaced clearly.
        try w.print("GCC_PREPROCESSOR_DEFINITIONS = (\"KIRA_TARGET_UNAVAILABLE=1\", ); CODE_SIGNING_ALLOWED = NO; OTHER_LDFLAGS = (); ", .{});
        _ = reason;
    } else {
        try w.print("CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = {s}; CODE_SIGNING_ALLOWED = YES; ", .{spec.development_team});
        try w.writeAll("\"CODE_SIGNING_REQUIRED[sdk=*simulator*]\" = NO; \"CODE_SIGN_IDENTITY[sdk=iphoneos*]\" = \"Apple Development\"; \"CODE_SIGN_IDENTITY[sdk=appletvos*]\" = \"Apple Development\"; \"CODE_SIGN_IDENTITY[sdk=xros*]\" = \"Apple Development\"; \"CODE_SIGN_IDENTITY[sdk=macosx*]\" = \"-\"; ");
        for (spec.ldflags_blocks) |block| {
            if (block.sdk_condition) |cond| {
                try w.print("\"OTHER_LDFLAGS[sdk={s}]\" = ({s}); ", .{ cond, block.value });
            } else {
                try w.print("OTHER_LDFLAGS = ({s}); ", .{block.value});
            }
        }
    }
    try w.print("}}; name = {s}; }};\n", .{name});
}

pub fn schemeXml(allocator: std.mem.Allocator, product_name: []const u8, target_id_index: usize) ![]const u8 {
    const target_id = try std.fmt.allocPrint(allocator, "T{d}TGT", .{target_id_index});
    // A BuildableReference snippet is needed verbatim in several actions; build it once.
    const ref = try std.fmt.allocPrint(
        allocator,
        "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"{s}\" BuildableName=\"{s}.app\" BlueprintName=\"{s}\" ReferencedContainer=\"container:KiraApp.xcodeproj\"></BuildableReference>",
        .{ target_id, product_name, product_name },
    );
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Scheme LastUpgradeVersion="1600" version="1.7">
        \\  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        \\    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{s}</BuildActionEntry></BuildActionEntries>
        \\  </BuildAction>
        \\  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"></TestAction>
        \\  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{s}</BuildableProductRunnable></LaunchAction>
        \\  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{s}</BuildableProductRunnable></ProfileAction>
        \\  <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
        \\  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
        \\</Scheme>
        \\
    , .{ ref, ref, ref });
}

test "pbxproj renders one target per spec with shared sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const specs = [_]TargetSpec{
        .{
            .product_name = "KiraApp-macOS",
            .bundle_id = "com.kira.app.macos",
            .info_plist_rel = "Resources/macOS-Info.plist",
            .sdkroot = "macosx",
            .supported_platforms = "macosx",
            .deployment_key = "MACOSX_DEPLOYMENT_TARGET",
            .deployment_value = "13.0",
            .device_family = null,
            .archs = "arm64",
            .ldflags_blocks = &.{.{ .sdk_condition = null, .value = "\"/tmp/x.a\"" }},
            .development_team = "F3U5976KWH",
        },
        .{
            .product_name = "KiraApp-iOS",
            .bundle_id = "com.kira.app.ios",
            .info_plist_rel = "Resources/iOS-Info.plist",
            .sdkroot = "iphoneos",
            .supported_platforms = "iphoneos iphonesimulator",
            .deployment_key = "IPHONEOS_DEPLOYMENT_TARGET",
            .deployment_value = "17.0",
            .device_family = "1,2",
            .archs = "arm64",
            .ldflags_blocks = &.{
                .{ .sdk_condition = "iphoneos*", .value = "\"/tmp/dev.a\"" },
                .{ .sdk_condition = "iphonesimulator*", .value = "\"/tmp/sim.a\"" },
            },
            .development_team = "F3U5976KWH",
        },
    };
    const project = try render(arena.allocator(), &specs);
    try std.testing.expect(std.mem.indexOf(u8, project, "path = main.m") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "lastKnownFileType = folder; path = Bundles") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "T0TGT") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "T1TGT") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "\"OTHER_LDFLAGS[sdk=iphonesimulator*]\" = (\"/tmp/sim.a\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "extern int kira_live_runner_entry") == null);
}

test "native_entry target compiles the link stub (so Xcode runs the linker) and copies no runner resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const specs = [_]TargetSpec{
        .{
            .product_name = "KiraApp-iOS",
            .bundle_id = "com.kira.live.dev",
            .info_plist_rel = "Resources/iOS-Info.plist",
            .sdkroot = "iphoneos",
            .supported_platforms = "iphoneos iphonesimulator",
            .deployment_key = "IPHONEOS_DEPLOYMENT_TARGET",
            .deployment_value = "17.0",
            .device_family = "1,2",
            .archs = "arm64",
            .ldflags_blocks = &.{.{ .sdk_condition = "iphonesimulator*", .value = "\"/tmp/kira_native_app.o\"" }},
            .development_team = "F3U5976KWH",
            .native_entry = true,
        },
    };
    const project = try render(arena.allocator(), &specs);
    // The link stub is referenced and compiled in the Sources phase.
    try std.testing.expect(std.mem.indexOf(u8, project, "path = native_link_stub.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "T0BFsrc = {isa = PBXBuildFile; fileRef = " ++ FR_NATIVE_STUB) != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "files = (T0BFsrc, ); runOnlyForDeploymentPostprocessing = 0; }") != null);
    // No runner manifest / bytecode bundle copy for native targets.
    try std.testing.expect(std.mem.indexOf(u8, project, "T0BFtoml") == null);
    try std.testing.expect(std.mem.indexOf(u8, project, "T0BFbnd") == null);
    // No KiraRunner.toml / Bundles file references at all (they'd show red in Xcode
    // since a native export never writes them); the real Info.plist is grouped instead.
    try std.testing.expect(std.mem.indexOf(u8, project, "path = KiraRunner.toml") == null);
    try std.testing.expect(std.mem.indexOf(u8, project, "path = Bundles") == null);
    try std.testing.expect(std.mem.indexOf(u8, project, "path = iOS-Info.plist") != null);
}

test "scheme defines a Profile action with a runnable so Product > Profile works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scheme = try schemeXml(arena.allocator(), "KiraApp-iOS", 1);
    // Profile must be wired to the built app so Instruments has something to launch.
    const profile_open = std.mem.indexOf(u8, scheme, "<ProfileAction") orelse return error.MissingProfileAction;
    const profile_close = std.mem.indexOf(u8, scheme, "</ProfileAction>") orelse return error.MissingProfileAction;
    const profile = scheme[profile_open..profile_close];
    try std.testing.expect(std.mem.indexOf(u8, profile, "BuildableProductRunnable") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "BuildableName=\"KiraApp-iOS.app\"") != null);
    // Build phase still marks the target buildable for profiling.
    try std.testing.expect(std.mem.indexOf(u8, scheme, "buildForProfiling=\"YES\"") != null);
}
