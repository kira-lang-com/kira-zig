const std = @import("std");
const build_pkg = @import("kira_build");
const build_def = @import("kira_build_definition");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    if (args.len < 1) return error.InvalidArguments;

    try std.fs.cwd().makePath("generated");
    const stem = std.fs.path.stem(args[0]);
    const output_path = try std.fmt.allocPrint(allocator, "generated/{s}.kbc", .{stem});

    var system = build_pkg.BuildSystem.init(allocator);
    const result = try system.buildBytecodeArtifact(.{
        .source_path = args[0],
        .output_path = output_path,
    });
    try stdout.print("wrote {s}\n", .{result.artifacts[0].path});
}
