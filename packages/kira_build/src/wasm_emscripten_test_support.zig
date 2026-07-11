//! Shared test infrastructure for the wasm32-emscripten build/run regression
//! tests (wasm_emscripten_tests.zig). Extracted to keep that file focused on the
//! test cases themselves (Core Law #5): artifact lookup, host-tooling
//! availability gating (emscripten + node, skip when absent), and the inherited
//! process environment plumbing node inherits so it resolves on PATH.
const std = @import("std");
const builtin = @import("builtin");
const build_def = @import("kira_build_definition");
const llvm_backend = @import("kira_llvm_backend");

pub fn firstArtifactWithExtension(artifacts: []const build_def.Artifact, extension: []const u8) ?[]const u8 {
    for (artifacts) |artifact| {
        if (std.mem.endsWith(u8, artifact.path, extension)) return artifact.path;
    }
    return null;
}

pub fn hasArtifact(artifacts: []const build_def.Artifact, path: []const u8) bool {
    for (artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.path, path)) return true;
    }
    return false;
}

pub fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, extension });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - ext.len], extension });
}

/// Skip the calling test (error.SkipZigTest) unless both emscripten and node are
/// present: these tests compile through emcc and execute the loader under node.
pub fn ensureRuntimeToolingAvailable(allocator: std.mem.Allocator) !void {
    llvm_backend.emscripten.validateAvailable(allocator) catch |err| switch (err) {
        error.EmscriptenUnavailable => return error.SkipZigTest,
        else => return err,
    };
    validateNodeAvailable(allocator) catch |err| switch (err) {
        error.NodeUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

fn validateNodeAvailable(allocator: std.mem.Allocator) !void {
    const process_environ = inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const result = std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ "node", "--version" },
        .expand_arg0 = .expand,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.NodeUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    return error.NodeUnavailable;
}

pub fn inheritedProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = currentPosixEnvironBlock() } },
    };
}

fn currentPosixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};

    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}
