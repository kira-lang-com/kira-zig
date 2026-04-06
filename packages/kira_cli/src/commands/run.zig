const std = @import("std");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const hybrid_runtime = @import("kira_hybrid_runtime");
const vm_runtime = @import("kira_vm_runtime");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    const input = try support.resolveCommandInput(allocator, parsed.input_path);
    const backend = parsed.backend orelse input.default_backend orelse .vm;

    try support.logFrontendStarted(stderr, "run", input.source_path);
    var system = build.BuildSystem.init(allocator);
    switch (backend) {
        .vm => {
            const result = try system.compileVm(input.source_path);
            if (result.failed()) {
                if (result.failure_stage == .ir) {
                    try support.logBuildAborted(stderr, "run", .build, input.source_path);
                } else {
                    try support.logFrontendFailed(stderr, result.failure_stage, input.source_path, result.diagnostics.len);
                }
                try support.renderDiagnostics(stderr, &result.source, result.diagnostics);
                return error.CommandFailed;
            }

            var vm = vm_runtime.Vm.init(allocator);
            const module = result.bytecode_module.?;
            try vm.runMain(&module, stdout);
        },
        .llvm_native => {
            const output_root = try support.outputRoot(allocator, input.project_root);
            defer allocator.free(output_root);
            try support.ensurePath(output_root);
            const stem = input.project_name orelse std.fs.path.stem(input.source_path);
            const executable_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}.run{s}",
                .{ output_root, stem, build.executableExtension() },
            );
            const result = try system.buildNativeArtifact(.{
                .source_path = input.source_path,
                .output_path = executable_path,
                .target = .{ .execution = .llvm_native },
            });
            if (result.failed()) {
                try support.logBuildAborted(stderr, "run", result.failure_kind.?, input.source_path);
                if (result.source) |source| {
                    try support.renderDiagnostics(stderr, &source, result.diagnostics);
                }
                return error.CommandFailed;
            }

            const executable = findExecutable(result.artifacts) orelse return error.MissingExecutableArtifact;
            try runExecutable(allocator, executable.path);
        },
        .hybrid => {
            const output_root = try support.outputRoot(allocator, input.project_root);
            defer allocator.free(output_root);
            try support.ensurePath(output_root);
            const stem = input.project_name orelse std.fs.path.stem(input.source_path);
            const manifest_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}.run.khm",
                .{ output_root, stem },
            );
            const result = try system.buildHybridArtifact(.{
                .source_path = input.source_path,
                .output_path = manifest_path,
                .target = .{ .execution = .hybrid },
            });
            if (result.failed()) {
                try support.logBuildAborted(stderr, "run", result.failure_kind.?, input.source_path);
                if (result.source) |source| {
                    try support.renderDiagnostics(stderr, &source, result.diagnostics);
                }
                return error.CommandFailed;
            }

            const manifest = try hybrid_runtime.loadHybridModule(allocator, manifest_path);
            var runtime = try hybrid_runtime.HybridRuntime.init(allocator, manifest);
            defer runtime.deinit();
            try runtime.run();
        },
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
