const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const hybrid_runtime = @import("kira_hybrid_runtime");
const vm_runtime = @import("kira_vm_runtime");
const diagnostics = @import("kira_diagnostics");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);

    var system = build.BuildSystem.init(allocator);
    switch (parsed.backend) {
        .vm => {
            const result = system.compileVm(parsed.source_path) catch |err| {
                try stderr.print("run failed: {s}\n", .{@errorName(err)});
                return err;
            };
            if (result.diagnostics.len > 0) {
                try diagnostics.renderer.renderAll(stderr, &result.source, result.diagnostics);
            }
            var vm = vm_runtime.Vm.init(allocator);
            try vm.runMain(&result.bytecode_module, stdout);
        },
        .llvm_native => {
            try std.fs.cwd().makePath("generated");
            const executable_path = try std.fmt.allocPrint(
                allocator,
                "generated/{s}.run{s}",
                .{ std.fs.path.stem(parsed.source_path), build.executableExtension() },
            );
            const result = try system.buildNativeArtifact(.{
                .source_path = parsed.source_path,
                .output_path = executable_path,
                .target = .{ .execution = .llvm_native },
            });
            const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
            try runExecutable(allocator, executable.path);
        },
        .hybrid => {
            try std.fs.cwd().makePath("generated");
            const manifest_path = try std.fmt.allocPrint(
                allocator,
                "generated/{s}.run.khm",
                .{std.fs.path.stem(parsed.source_path)},
            );
            _ = try system.buildHybridArtifact(.{
                .source_path = parsed.source_path,
                .output_path = manifest_path,
                .target = .{ .execution = .hybrid },
            });
            const manifest = try hybrid_runtime.loadHybridModule(allocator, manifest_path);
            var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
            defer runtime.deinit();
            try runtime.run();
        },
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

fn findExecutable(artifacts: []const build_def.Artifact) ?build_def.Artifact {
    for (artifacts) |artifact| {
        if (artifact.kind == .executable) return artifact;
    }
    return null;
}

fn runExecutable(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{path}, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.NativeRunFailed;
}
