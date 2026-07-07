const std = @import("std");
const diag_messages = @import("kira_diagnostic_messages");
const manifest = @import("kira_manifest");
const kira_live = @import("kira_live");
const support = @import("../support.zig");

const ApplePlatform = kira_live.apple_workspace.Platform;

pub fn run(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    family: manifest.ExportFamily,
    exports_root: []const u8,
    input_path: []const u8,
) !void {
    const apple_root = try std.fs.path.join(allocator, &.{ exports_root, "apple" });
    const base_target = resolveAppleTarget(allocator, stderr, input_path, family.label()) catch return error.CommandFailed;
    const platforms = platformsForFamily(family);

    const generated = kira_live.apple_workspace.generate(allocator, base_target, .{
        .apple_root = apple_root,
        .mode = .standalone,
        .platforms = platforms,
    }) catch |err| {
        const detail = try std.fmt.allocPrint(
            allocator,
            "Failed to generate the {s} Apple workspace: {s}.",
            .{ family.label(), @errorName(err) },
        );
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.appleWorkspaceGenerationFailed(allocator, detail));
        return error.CommandFailed;
    };

    try stdout.print("exported {s} Apple workspace at {s}\n", .{ family.label(), generated.apple_root });
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
pub fn xcodeRebuild(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    input_path: []const u8,
    platform_name: []const u8,
) !void {
    const base_target = resolveAppleTarget(allocator, stderr, input_path, "apple") catch return error.CommandFailed;
    const apple_root = try std.fs.path.join(allocator, &.{ base_target.target_root, "exports", "apple" });
    kira_live.apple_workspace.rebuildPlatform(allocator, base_target, apple_root, platform_name) catch |err| {
        const detail = try std.fmt.allocPrint(
            allocator,
            "Failed to rebuild Kira artifacts for SDK platform `{s}`: {s}.",
            .{ platform_name, @errorName(err) },
        );
        try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.appleWorkspaceGenerationFailed(allocator, detail));
        return error.CommandFailed;
    };
    try stdout.print("rebuilt Kira artifacts for {s}\n", .{platform_name});
}

fn resolveAppleTarget(
    allocator: std.mem.Allocator,
    stderr: anytype,
    input_path: []const u8,
    family_label: []const u8,
) !kira_live.ResolvedLiveTarget {
    return kira_live.resolveLiveTarget(allocator, input_path) catch |err| switch (err) {
        error.LibraryTargetCannotBeStartedInLiveMode => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
                allocator,
                family_label,
                "Apple exports need an executable Kira project (app/example) to embed in the KiraApp workspace.",
            ));
            return error.CommandFailed;
        },
        error.TargetNotLiveCapable => {
            try support.renderStandaloneDiagnostic(stderr, try diag_messages.CliMessages.exportNotImplemented(
                allocator,
                family_label,
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
}

fn platformsForFamily(family: manifest.ExportFamily) []const ApplePlatform {
    return switch (family) {
        .apple => &.{ .macos, .ios, .tvos, .visionos },
        .macos => &.{.macos},
        .ios => &.{.ios},
        .tvos => &.{.tvos},
        .visionos => &.{.visionos},
        else => &.{ .macos, .ios, .tvos, .visionos },
    };
}

test "individual Apple export families select one platform" {
    try std.testing.expectEqual(@as(usize, 1), platformsForFamily(.macos).len);
    try std.testing.expectEqual(ApplePlatform.macos, platformsForFamily(.macos)[0]);
    try std.testing.expectEqual(ApplePlatform.ios, platformsForFamily(.ios)[0]);
    try std.testing.expectEqual(ApplePlatform.tvos, platformsForFamily(.tvos)[0]);
    try std.testing.expectEqual(ApplePlatform.visionos, platformsForFamily(.visionos)[0]);
}

test "unified Apple export keeps every Apple platform" {
    const platforms = platformsForFamily(.apple);
    try std.testing.expectEqual(@as(usize, 4), platforms.len);
    try std.testing.expectEqual(ApplePlatform.macos, platforms[0]);
    try std.testing.expectEqual(ApplePlatform.ios, platforms[1]);
    try std.testing.expectEqual(ApplePlatform.tvos, platforms[2]);
    try std.testing.expectEqual(ApplePlatform.visionos, platforms[3]);
}
