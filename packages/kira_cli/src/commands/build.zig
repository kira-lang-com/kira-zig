const std = @import("std");
const build_pkg = @import("kira_build");
const build_def = @import("kira_build_definition");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    const parsed = try parseArgs(args);

    try std.fs.cwd().makePath("generated");
    const output_path = try defaultOutputPath(allocator, parsed);

    var system = build_pkg.BuildSystem.init(allocator);
    const result = try system.build(.{
        .source_path = parsed.source_path,
        .output_path = output_path,
        .target = .{ .execution = parsed.backend },
    });
    for (result.artifacts) |artifact| {
        try stdout.print("wrote {s}\n", .{artifact.path});
    }
}

const ParsedArgs = struct {
    backend: build_def.ExecutionTarget,
    source_path: []const u8,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var backend: build_def.ExecutionTarget = .vm;
    var source_path: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            backend = parseBackend(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (source_path != null) return error.InvalidArguments;
        source_path = arg;
    }

    return .{
        .backend = backend,
        .source_path = source_path orelse return error.InvalidArguments,
    };
}

fn parseBackend(arg: []const u8) ?build_def.ExecutionTarget {
    if (std.mem.eql(u8, arg, "vm")) return .vm;
    if (std.mem.eql(u8, arg, "llvm")) return .llvm_native;
    if (std.mem.eql(u8, arg, "hybrid")) return .hybrid;
    return null;
}

fn defaultOutputPath(allocator: std.mem.Allocator, parsed: ParsedArgs) ![]const u8 {
    const stem = std.fs.path.stem(parsed.source_path);
    return switch (parsed.backend) {
        .vm => std.fmt.allocPrint(allocator, "generated/{s}.kbc", .{stem}),
        .llvm_native => std.fmt.allocPrint(allocator, "generated/{s}{s}", .{ stem, build_pkg.executableExtension() }),
        .hybrid => std.fmt.allocPrint(allocator, "generated/{s}.khm", .{stem}),
    };
}
