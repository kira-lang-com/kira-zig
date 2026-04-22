const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const package_manager = @import("kira_package_manager");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    const input = try support.resolveCheckInput(allocator, parsed.input_path);

    const project_root = switch (input) {
        .application => |app| app.project_root,
        .library => |library| library.root_path,
    };
    if (project_root) |root| {
        try syncProject(allocator, root, parsed, stderr);
    }

    const result = switch (input) {
        .application => |app| blk: {
            try support.logFrontendStarted(stderr, "check", app.source_path);
            break :blk try build.checkFile(allocator, app.source_path);
        },
        .library => |library| blk: {
            try support.logFrontendStarted(stderr, "check", library.source_root);
            break :blk try build.checkPackageRoot(allocator, library.source_root);
        },
    };
    if (!diagnostics.hasErrors(result.diagnostics)) {
        try stdout.writeAll("check passed\n");
        return;
    }
    const display_path = switch (input) {
        .application => |app| app.source_path,
        .library => |library| library.source_root,
    };
    try support.logFrontendFailed(stderr, result.failure_stage, display_path, result.diagnostics.len);
    try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
    return error.CommandFailed;
}

fn syncProject(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    parsed: ParsedArgs,
    stderr: anytype,
) !void {
    var package_diagnostics = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    _ = package_manager.syncProject(allocator, project_root, support.versionString(), .{
        .offline = parsed.offline,
        .locked = parsed.locked,
    }, &package_diagnostics) catch |err| {
        if (err == error.DiagnosticsEmitted) {
            try support.renderStandaloneDiagnostics(stderr, package_diagnostics.items);
            return error.CommandFailed;
        }
        return err;
    };
}

const ParsedArgs = struct {
    offline: bool = false,
    locked: bool = false,
    input_path: []const u8,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var offline = false;
    var locked = false;
    var input_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--offline")) {
            offline = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--locked")) {
            locked = true;
            continue;
        }
        if (input_path != null) return error.InvalidArguments;
        input_path = arg;
    }

    return .{
        .offline = offline,
        .locked = locked,
        .input_path = input_path orelse support.defaultCommandInputPath(),
    };
}
