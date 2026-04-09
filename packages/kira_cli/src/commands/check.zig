const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const package_manager = @import("kira_package_manager");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    const input = try support.resolveCommandInput(allocator, parsed.input_path);

    if (input.project_root) |project_root| {
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

    try support.logFrontendStarted(stderr, "check", input.source_path);
    const result = try build.checkFile(allocator, input.source_path);
    if (!diagnostics.hasErrors(result.diagnostics)) {
        try stdout.writeAll("check passed\n");
        return;
    }
    try support.logFrontendFailed(stderr, result.failure_stage, input.source_path, result.diagnostics.len);
    try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
    return error.CommandFailed;
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
