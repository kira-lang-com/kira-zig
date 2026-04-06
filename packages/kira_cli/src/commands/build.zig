const std = @import("std");
const build_pkg = @import("kira_build");
const build_def = @import("kira_build_definition");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    const input = try support.resolveCommandInput(allocator, parsed.input_path);
    const backend = parsed.backend orelse input.default_backend orelse .vm;

    try support.logFrontendStarted(stderr, "build", input.source_path);
    const output_root = try support.outputRoot(allocator, input.project_root);
    defer allocator.free(output_root);
    try support.ensurePath(output_root);
    const output_path = try defaultOutputPath(
        allocator,
        output_root,
        input.project_name orelse std.fs.path.stem(input.source_path),
        backend,
    );

    var system = build_pkg.BuildSystem.init(allocator);
    const result = try system.build(.{
        .source_path = input.source_path,
        .output_path = output_path,
        .target = .{ .execution = backend },
    });
    if (result.failed()) {
        try support.logBuildAborted(stderr, "build", result.failure_kind.?, input.source_path);
        if (result.source) |source| {
            try support.renderDiagnostics(stderr, &source, result.diagnostics);
        }
        return error.CommandFailed;
    }

    for (result.artifacts) |artifact| {
        try stdout.print("wrote {s}\n", .{artifact.path});
    }
}

const ParsedArgs = struct {
    backend: ?build_def.ExecutionTarget = null,
    input_path: []const u8,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var backend: ?build_def.ExecutionTarget = null;
    var input_path: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            backend = parseBackend(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (input_path != null) return error.InvalidArguments;
        input_path = arg;
    }

    return .{
        .backend = backend,
        .input_path = input_path orelse return error.InvalidArguments,
    };
}

fn parseBackend(arg: []const u8) ?build_def.ExecutionTarget {
    if (std.mem.eql(u8, arg, "vm")) return .vm;
    if (std.mem.eql(u8, arg, "llvm")) return .llvm_native;
    if (std.mem.eql(u8, arg, "hybrid")) return .hybrid;
    return null;
}

fn defaultOutputPath(allocator: std.mem.Allocator, output_root: []const u8, stem: []const u8, backend: build_def.ExecutionTarget) ![]const u8 {
    return switch (backend) {
        .vm => std.fmt.allocPrint(allocator, "{s}/{s}.kbc", .{ output_root, stem }),
        .llvm_native => std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ output_root, stem, build_pkg.executableExtension() }),
        .hybrid => std.fmt.allocPrint(allocator, "{s}/{s}.khm", .{ output_root, stem }),
    };
}
