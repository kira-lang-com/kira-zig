const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const kira_log = @import("kira_log");
const source_pkg = @import("kira_source");
const kira_toolchain = @import("kira_toolchain");
const build_options = @import("kira_cli_build_options");

pub fn binaryName() []const u8 {
    return build_options.binary_name;
}

pub fn versionString() []const u8 {
    return build_options.version;
}

pub fn channel() kira_toolchain.Channel {
    return kira_toolchain.Channel.parse(build_options.channel).?;
}

pub fn primaryExecutableName() []const u8 {
    return build_options.primary_executable;
}

pub fn resolveManagedToolchainRoot(allocator: std.mem.Allocator) ![]u8 {
    if (try kira_toolchain.toolchainRootFromSelfExecutable(allocator)) |toolchain_root| {
        return toolchain_root;
    }
    return kira_toolchain.managedToolchainRoot(allocator, channel(), versionString());
}

pub fn resolveResourceRoot(allocator: std.mem.Allocator) ![]u8 {
    if (try kira_toolchain.toolchainRootFromSelfExecutable(allocator)) |toolchain_root| {
        return toolchain_root;
    }

    if (try findRepoRootFromCwd(allocator)) |repo_root| return repo_root;
    if (try findRepoRootFromSelfExe(allocator)) |repo_root| return repo_root;

    const toolchain_root = try resolveManagedToolchainRoot(allocator);
    if (hasManagedResources(toolchain_root)) return toolchain_root;
    allocator.free(toolchain_root);
    return error.ResourceRootNotFound;
}

pub fn renderDiagnostics(stderr: anytype, source: *const source_pkg.SourceFile, items: []const diagnostics.Diagnostic) !void {
    if (items.len == 0) return;
    try diagnostics.renderer.renderAll(stderr, source, items);
}

pub fn logFrontendStarted(stderr: anytype, command: []const u8, path: []const u8) !void {
    try kira_log.write(stderr, .{
        .level = .info,
        .scope = "frontend",
        .event = "started",
        .message = "Frontend compilation started.",
        .fields = &.{
            .{ .key = "command", .value = command },
            .{ .key = "path", .value = path },
        },
    });
}

pub fn logFrontendFailed(stderr: anytype, stage: ?build.FrontendStage, path: []const u8, diagnostics_len: usize) !void {
    var diagnostics_buffer: [32]u8 = undefined;
    const diagnostics_text = try std.fmt.bufPrint(&diagnostics_buffer, "{d}", .{diagnostics_len});
    try kira_log.write(stderr, .{
        .level = .@"error",
        .scope = "frontend",
        .event = "failed",
        .message = "Frontend compilation stopped because Kira emitted diagnostics.",
        .fields = &.{
            .{ .key = "stage", .value = frontendStageName(stage) },
            .{ .key = "path", .value = path },
            .{ .key = "diagnostics", .value = diagnostics_text },
        },
    });
}

pub fn logBuildAborted(stderr: anytype, command: []const u8, kind: build.BuildFailureKind, path: []const u8) !void {
    try kira_log.write(stderr, .{
        .level = .@"error",
        .scope = "build",
        .event = "aborted",
        .message = "Build stopped before producing artifacts.",
        .fields = &.{
            .{ .key = "command", .value = command },
            .{ .key = "reason", .value = buildFailureName(kind) },
            .{ .key = "path", .value = path },
        },
    });
}

pub fn logInternalCompilerError(stderr: anytype, err_name: []const u8) !void {
    try kira_log.write(stderr, .{
        .level = .@"error",
        .scope = "compiler",
        .event = "internal_boundary",
        .message = "The internal compiler error boundary handled an unexpected failure.",
        .fields = &.{
            .{ .key = "error", .value = err_name },
        },
    });
}

pub fn renderInternalCompilerError(stderr: anytype, err_name: []const u8) !void {
    try stderr.writeAll("error[KICE001]: internal compiler error\n");
    try stderr.writeAll("  Kira hit an unexpected internal failure and stopped before it could finish the command.\n");
    try stderr.print("  note: internal error = {s}\n", .{err_name});
    try stderr.writeAll("  help: Please report this bug with the command you ran and the source file that triggered it.\n");
}

fn frontendStageName(stage: ?build.FrontendStage) []const u8 {
    return switch (stage orelse .ir) {
        .lexer => "lexer",
        .parser => "parser",
        .semantics => "semantics",
        .ir => "ir",
    };
}

fn buildFailureName(kind: build.BuildFailureKind) []const u8 {
    return switch (kind) {
        .frontend => "frontend_diagnostics",
        .build => "build_diagnostics",
        .toolchain => "toolchain_diagnostics",
    };
}

fn findRepoRootFromCwd(allocator: std.mem.Allocator) !?[]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return findRepoRootFromPath(allocator, cwd);
}

fn findRepoRootFromSelfExe(allocator: std.mem.Allocator) !?[]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    return findRepoRootFromPath(allocator, exe_dir);
}

fn findRepoRootFromPath(allocator: std.mem.Allocator, start_path: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start_path);
    errdefer allocator.free(current);

    while (true) {
        if (isRepoRoot(current)) return current;

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }

    allocator.free(current);
    return null;
}

fn isRepoRoot(path: []const u8) bool {
    const metadata_path = std.fs.path.join(std.heap.page_allocator, &.{ path, "llvm-metadata.toml" }) catch return false;
    defer std.heap.page_allocator.free(metadata_path);
    if (!fileExists(metadata_path)) return false;

    const build_path = std.fs.path.join(std.heap.page_allocator, &.{ path, "build.zig" }) catch return false;
    defer std.heap.page_allocator.free(build_path);
    return fileExists(build_path);
}

fn hasManagedResources(path: []const u8) bool {
    const metadata_path = std.fs.path.join(std.heap.page_allocator, &.{ path, "llvm-metadata.toml" }) catch return false;
    defer std.heap.page_allocator.free(metadata_path);
    if (!fileExists(metadata_path)) return false;

    const templates_path = std.fs.path.join(std.heap.page_allocator, &.{ path, "templates" }) catch return false;
    defer std.heap.page_allocator.free(templates_path);
    var dir = std.fs.openDirAbsolute(templates_path, .{}) catch std.fs.cwd().openDir(templates_path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}
