// wasm32-emscripten support for the corpus runner: detect the emcc/node
// toolchain once (so missing tooling SKIPs the opt-in wasm matrix instead of
// failing) and run the emitted `.js` loader under node. The build/run machinery
// mirrors packages/kira_build/src/wasm_emscripten_tests.zig and reuses the exact
// emscripten availability check from kira_llvm_backend rather than re-deriving it.
const builtin = @import("builtin");
const std = @import("std");
const build_def = @import("kira_build_definition");
const llvm_backend = @import("kira_llvm_backend");
const support = @import("execute_support.zig");

pub const ToolingStatus = enum {
    // Default: not yet probed. Skip-safe — any caller that has not run `detect`
    // treats wasm as unavailable rather than blindly invoking emcc.
    unknown,
    available,
    missing_emcc,
    missing_node,
};

pub const Tooling = struct {
    status: ToolingStatus = .unknown,

    pub fn available(self: Tooling) bool {
        return self.status == .available;
    }

    pub fn note(self: Tooling) []const u8 {
        return switch (self.status) {
            .available => "wasm tooling available",
            .unknown => "SKIP wasm: toolchain not probed",
            .missing_emcc => "SKIP wasm: emcc (emscripten) unavailable — set EMSDK/EMCC or install emscripten",
            .missing_node => "SKIP wasm: node unavailable — install Node.js to run the emitted wasm loader",
        };
    }
};

// Detect the wasm toolchain once. Any failure resolving/running emcc is treated
// as "emscripten unavailable" (skip, do not fail); likewise for node. Callers
// only invoke this when the wasm backend is actually selected.
pub fn detect(allocator: std.mem.Allocator) Tooling {
    llvm_backend.emscripten.validateAvailable(allocator) catch {
        return .{ .status = .missing_emcc };
    };
    validateNodeAvailable(allocator) catch {
        return .{ .status = .missing_node };
    };
    return .{ .status = .available };
}

fn validateNodeAvailable(allocator: std.mem.Allocator) !void {
    const process_environ = support.inheritedProcessEnviron();
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

// A packaged app names its artifacts after the package, so locate the emitted
// JS loader by extension rather than assuming a fixed `main.js`.
pub fn firstArtifactWithExtension(artifacts: []const build_def.Artifact, extension: []const u8) ?[]const u8 {
    for (artifacts) |artifact| {
        if (std.mem.endsWith(u8, artifact.path, extension)) return artifact.path;
    }
    return null;
}

pub const NodeRun = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

// Execute `node <js_path>` in the case's runtime cwd. The emitted emscripten
// loader boots the wasm module and invokes the real Kira entrypoint, writing
// Kira `print` output to stdout.
pub fn runNode(allocator: std.mem.Allocator, js_path: []const u8, run_cwd: []const u8) !NodeRun {
    const process_environ = support.inheritedProcessEnviron();
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ "node", js_path },
        .expand_arg0 = .expand,
        .cwd = .{ .path = run_cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    return .{ .term = child.term, .stdout = child.stdout, .stderr = child.stderr };
}
