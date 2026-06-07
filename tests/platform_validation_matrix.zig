const std = @import("std");

const Evidence = struct {
    path: []const u8,
    token: []const u8,
};

const MatrixRow = struct {
    name: []const u8,
    evidence: []const Evidence,
};

const rows = [_]MatrixRow{
    .{
        .name = "repo purity rejects Python, root Zig clutter, and fake markers",
        .evidence = &.{
            .{ .path = "tests/repository_truth.zig", .token = "checkPythonFile" },
            .{ .path = "tests/repository_truth.zig", .token = "checkRootZig" },
            .{ .path = "tests/repository_truth.zig", .token = "checkFakeMarkers" },
            .{ .path = "tests/repository_truth.zig", .token = "live supervisor must not translate Kira visible-content markers into host frame success" },
        },
    },
    .{
        .name = "VM, LLVM, and hybrid corpus paths remain wired through zig build test",
        .evidence = &.{
            .{ .path = "build.zig", .token = "kira-corpus-tests" },
            .{ .path = "tests/discovery.zig", .token = "Backend.hybrid" },
            .{ .path = "tests/discovery.zig", .token = "Backend.vm" },
            .{ .path = "tests/execute.zig", .token = ".llvm" },
        },
    },
    .{
        .name = "wasm32-emscripten executes a real Kira entrypoint",
        .evidence = &.{
            .{ .path = "packages/kira_build/src/wasm_emscripten_tests.zig", .token = "wasm-entrypoint-ok" },
            .{ .path = "packages/kira_build/src/wasm_emscripten_tests.zig", .token = "\".wasm\"" },
            .{ .path = "packages/kira_build/src/wasm_emscripten_tests.zig", .token = "node" },
            .{ .path = "packages/kira_build/src/wasm_emscripten_tests.zig", .token = "KTC003" },
        },
    },
    .{
        .name = "live supervision preserves marker-layer ordering",
        .evidence = &.{
            .{ .path = "packages/kira_live/src/supervisor_shared.zig", .token = "live.bundle.loaded" },
            .{ .path = "packages/kira_live/src/supervisor_shared.zig", .token = "live.bundle.linked" },
            .{ .path = "packages/kira_live/src/supervisor_shared.zig", .token = "live.entrypoint.started" },
            .{ .path = "packages/kira_live/src/supervisor_shared.zig", .token = "live.frame.presented" },
        },
    },
    .{
        .name = "macOS runner keeps Kira graphics code in the loaded bundle",
        .evidence = &.{
            .{ .path = "packages/kira_live/src/apple_runner.zig", .token = "macOS live runner project leaves app graphics code in the loaded Kira bundle" },
            .{ .path = "packages/kira_live/src/apple_runner.zig", .token = "libkira_live_runner_support_xcode.a" },
            .{ .path = "packages/kira_live/src/apple_runner.zig", .token = "com.kira.sokol_triangle.o" },
        },
    },
    .{
        .name = "iOS Simulator runner installs, launches, and captures simulator logs",
        .evidence = &.{
            .{ .path = "packages/kira_live/src/apple_runner.zig", .token = "iPhone 17 Pro" },
            .{ .path = "packages/kira_live/src/ios_live.zig", .token = "simctl" },
            .{ .path = "packages/kira_live/src/ios_live.zig", .token = "live.ios.simulator.install.succeeded" },
            .{ .path = "packages/kira_live/src/ios_live.zig", .token = "live.ios.simulator.launch.succeeded" },
            .{ .path = "packages/kira_live/src/ios_live.zig", .token = "live.ios.simulator.logs.captured" },
        },
    },
    .{
        .name = "web live validation uses served localhost output, not file URLs",
        .evidence = &.{
            .{ .path = "packages/kira_live/src/web_live.zig", .token = "live.server.started" },
            .{ .path = "packages/kira_live/src/web_live.zig", .token = "http://127.0.0.1" },
            .{ .path = "tests/repository_truth.zig", .token = "checkFakeMarkers" },
        },
    },
    .{
        .name = "kira export apple and kira live emit one unified KiraApp workspace with the shared runner entry",
        .evidence = &.{
            .{ .path = "packages/kira_cli/src/commands/export.zig", .token = "apple_workspace.generate" },
            .{ .path = "packages/kira_live/src/apple_app_sources.zig", .token = "extern int kira_live_runner_entry" },
            .{ .path = "packages/kira_live/src/apple_pbxproj.zig", .token = "OTHER_LDFLAGS[sdk=" },
            .{ .path = "packages/kira_live/src/apple_live.zig", .token = "workspace.generate" },
            .{ .path = "packages/kira_live/src/runner_support.zig", .token = "runStandaloneFromManifest" },
            .{ .path = "packages/kira_live/src/runner_support.zig", .token = "live.runtime.mode=standalone" },
            .{ .path = "packages/kira_live/src/model.zig", .token = "RunnerManifest round-trips standalone export mode" },
        },
    },
    .{
        .name = "tvOS and visionOS are real backend targets (triples + sokol), not placeholders",
        .evidence = &.{
            .{ .path = "packages/kira_llvm_backend/src/clang_driver.zig", .token = "arm64-apple-tvos15.0" },
            .{ .path = "packages/kira_llvm_backend/src/clang_driver.zig", .token = "arm64-apple-xros1.0" },
            .{ .path = "packages/kira_llvm_backend/src/clang_driver.zig", .token = ".appletvos" },
            .{ .path = "packages/kira_llvm_backend/src/clang_driver.zig", .token = ".xros" },
            .{ .path = "packages/kira_live/src/apple_workspace.zig", .token = "aarch64-visionos-none" },
            .{ .path = "packages/kira_live/src/apple_workspace.zig", .token = "visionOS" },
        },
    },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try validate(arena.allocator(), true);
}

test "platform validation matrix evidence is wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try validate(arena.allocator(), false);
}

fn validate(allocator: std.mem.Allocator, print_success: bool) !void {
    var failures = std.array_list.Managed([]const u8).init(allocator);
    for (rows) |row| {
        for (row.evidence) |item| {
            const contents = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, item.path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
                try failures.append(try std.fmt.allocPrint(allocator, "matrix row `{s}` cannot read {s}: {s}", .{ row.name, item.path, @errorName(err) }));
                continue;
            };
            if (std.mem.indexOf(u8, contents, item.token) == null) {
                try failures.append(try std.fmt.allocPrint(allocator, "matrix row `{s}` missing `{s}` in {s}", .{ row.name, item.token, item.path }));
            }
        }
    }

    if (failures.items.len != 0) {
        for (failures.items) |failure| std.debug.print("{s}\n", .{failure});
        return error.PlatformValidationMatrixFailed;
    }

    if (print_success) {
        for (rows) |row| std.debug.print("matrix row ok: {s}\n", .{row.name});
        std.debug.print("platform validation matrix checks passed\n", .{});
    }
}
