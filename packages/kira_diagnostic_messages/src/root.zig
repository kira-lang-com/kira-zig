const std = @import("std");

pub const DiagnosticCode = @import("DiagnosticCode.zig").DiagnosticCode;
pub const DiagnosticDomain = @import("DiagnosticDomain.zig").DiagnosticDomain;
pub const CompilerPhase = @import("CompilerPhase.zig").CompilerPhase;
pub const build = @import("DiagnosticMessage.zig").build;
pub const CliMessages = @import("CliMessages.zig");
pub const PackageMessages = @import("PackageMessages.zig");
pub const ToolchainMessages = @import("ToolchainMessages.zig");
pub const CompilerBugMessages = @import("CompilerBugMessages.zig");
pub const BackendMessages = @import("BackendMessages.zig");

test "KIC001 is only used in approved fallback locations" {
    const approved = [_][]const u8{
        "packages/kira_diagnostic_messages/src/DiagnosticCode.zig",
        "packages/kira_diagnostic_messages/src/CompilerBugMessages.zig",
        "packages/kira_diagnostic_messages/src/root.zig",
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var offending = std.array_list.Managed([]const u8).init(arena.allocator());
    try scanDirForFallbackUses(arena.allocator(), &offending, &approved, "packages");
    try scanFlatDirForFallbackUses(arena.allocator(), &offending, &approved, "tests");
    try scanFileForFallbackUses(arena.allocator(), &offending, &approved, "build.zig");

    if (offending.items.len != 0) {
        std.debug.print(
            "Use a specific diagnostic code or the approved legacy fallback helper. Offending files:\\n",
            .{},
        );
        for (offending.items) |path| std.debug.print("  {s}\\n", .{path});
        return error.TestUnexpectedResult;
    }
}

fn scanDirForFallbackUses(
    allocator: std.mem.Allocator,
    offending: *std.array_list.Managed([]const u8),
    approved: []const []const u8,
    dir_path: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);

        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(path)) continue;
                try scanDirForFallbackUses(allocator, offending, approved, path);
            },
            .file => {
                if (!std.mem.endsWith(u8, path, ".zig")) continue;
                try scanFileForFallbackUses(allocator, offending, approved, path);
            },
            else => {},
        }
    }
}

fn scanFlatDirForFallbackUses(
    allocator: std.mem.Allocator,
    offending: *std.array_list.Managed([]const u8),
    approved: []const []const u8,
    dir_path: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        try scanFileForFallbackUses(allocator, offending, approved, path);
    }
}

fn scanFileForFallbackUses(
    allocator: std.mem.Allocator,
    offending: *std.array_list.Managed([]const u8),
    approved: []const []const u8,
    path: []const u8,
) !void {
    if (isApproved(path, approved)) return;

    const text = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    if (std.mem.indexOf(u8, text, "KIC001") != null or std.mem.indexOf(u8, text, "KICE001") != null) {
        try offending.append(try allocator.dupe(u8, path));
    }
}

fn shouldSkipDir(path: []const u8) bool {
    return pathsEqual(path, ".git") or
        pathsEqual(path, ".zig-cache") or
        pathsEqual(path, "zig-out") or
        pathsEqual(path, "generated") or
        pathsEqual(path, "third_party") or
        pathsEqual(path, "zig-pkg") or
        pathsEqual(path, ".codex") or
        pathsEqual(path, ".github") or
        pathsEqual(path, ".opencode");
}

fn isApproved(path: []const u8, approved: []const []const u8) bool {
    for (approved) |candidate| {
        if (pathsEqual(path, candidate)) return true;
    }
    return false;
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (normalizePathChar(lhs) != normalizePathChar(rhs)) return false;
    }
    return true;
}

fn normalizePathChar(char: u8) u8 {
    return if (char == '\\') '/' else char;
}
