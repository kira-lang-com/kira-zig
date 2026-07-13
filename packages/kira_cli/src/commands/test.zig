const std = @import("std");
const builtin = @import("builtin");
const build = @import("kira_build");
const build_def = @import("kira_build_definition");
const kira_main = @import("kira_main");
const manifest = @import("kira_manifest");
const support = @import("../support.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseArgs(args);
    _ = parsed.offline;
    _ = parsed.locked;
    const previous_timings = build.timingsEnabled();
    build.setTimingsEnabled(parsed.timings or timingsEnvEnabled());
    defer build.setTimingsEnabled(previous_timings);
    try support.syncCommandDependencies(allocator, parsed.input_path, parsed.offline, parsed.locked, stderr);
    const path = try allocator.dupeZ(u8, parsed.input_path);
    defer allocator.free(path);
    const developer = kira_main.kira_developer_create() orelse return error.OutOfMemory;
    defer kira_main.kira_developer_destroy(developer);
    const status = kira_main.kira_developer_test(developer, path.ptr, backendArg(selectedBackend(parsed)));
    const report = std.mem.span(kira_main.kira_developer_report(developer) orelse "");
    try writeMachineReport(allocator, parsed.input_path, report);
    if (status == .ok) {
        // Reporting-hole guard: a successful `kira test` MUST end with its
        // combined `test result:` tally line — that line is the last thing the
        // runner emits, so its absence means a backend leg died or the output
        // was truncated mid-run. Such a run must fail loudly, never exit 0 with
        // a silently incomplete report (fake success).
        if (!reportComplete(report)) {
            try stderr.writeAll(report);
            try stderr.writeAll(
                "\nerror[KCLI021]: incomplete test report — the final `test result:` line is missing, " ++
                    "so a backend leg died or its output was truncated. Failing the run.\n",
            );
            return error.CommandFailed;
        }
        if (build.progressActive()) {
            try stdout.writeAll(finalResultLine(report));
        } else {
            try stdout.writeAll(report);
        }
        return;
    }
    build.emitProgress("[kira:control] suspend");
    if (report.len != 0) try stderr.writeAll(report) else try stderr.writeAll(std.mem.span(kira_main.kira_developer_last_error(developer) orelse ""));
    return error.CommandFailed;
}

fn finalResultLine(report: []const u8) []const u8 {
    const marker = "test result:";
    const start = std.mem.lastIndexOf(u8, report, marker) orelse return report;
    const end = std.mem.indexOfScalarPos(u8, report, start, '\n') orelse report.len;
    return report[start..@min(end + 1, report.len)];
}

const ResultTotals = struct {
    passed: usize,
    failed: usize,
    total: usize,
};

fn writeMachineReport(allocator: std.mem.Allocator, input_path: []const u8, report: []const u8) !void {
    const totals = parseResultTotals(report) orelse return;
    const input = support.resolveCliInput(allocator, input_path) catch return;
    const project_root = input.target.root_path orelse std.fs.path.dirname(input.target.displayPath()) orelse ".";
    const build_root = try std.fs.path.join(allocator, &.{ project_root, ".kira-build" });
    defer allocator.free(build_root);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, build_root);
    const report_path = try std.fs.path.join(allocator, &.{ build_root, "test-report.json" });
    defer allocator.free(report_path);
    const file = if (std.fs.path.isAbsolute(report_path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, report_path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, report_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    try writer.interface.print(
        "{{\n  \"total_tests\": {d},\n  \"passed_tests\": {d},\n  \"failed_tests\": {d},\n  \"failure_group_count\": 0,\n  \"failure_groups\": []\n}}\n",
        .{ totals.total, totals.passed, totals.failed },
    );
    try writer.interface.flush();
}

fn parseResultTotals(report: []const u8) ?ResultTotals {
    const line = finalResultLine(report);
    const marker = "test result:";
    if (!std.mem.startsWith(u8, line, marker)) return null;
    var fields = std.mem.tokenizeAny(u8, line[marker.len..], " ;\r\n");
    const passed = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "passed")) return null;
    const failed = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "failed")) return null;
    const total = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "total")) return null;
    return .{ .passed = passed, .failed = failed, .total = total };
}

fn timingsEnvEnabled() bool {
    if (!builtin.link_libc) return false;
    const raw = std.c.getenv("KIRA_TIMINGS") orelse return false;
    const value = std.mem.span(raw);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

/// True when the report carries its terminal combined `test result:` tally
/// line. The runner always emits that line last, so its presence proves the
/// report reached the end intact (every planned backend leg ran to completion).
fn reportComplete(report: []const u8) bool {
    if (std.mem.startsWith(u8, report, "test result:")) return true;
    return std.mem.indexOf(u8, report, "\ntest result:") != null;
}

test "interactive test output keeps only the combined result" {
    const report = "PASS One\ntest result [vm]: 1 passed; 0 failed; 1 total\ntest result: 1 passed; 0 failed; 1 total\n";
    try std.testing.expectEqualStrings("test result: 1 passed; 0 failed; 1 total\n", finalResultLine(report));
}

test "combined test result parses for machine report" {
    const totals = parseResultTotals("PASS One\ntest result: 7 passed; 2 failed; 9 total\n").?;
    try std.testing.expectEqual(@as(usize, 7), totals.passed);
    try std.testing.expectEqual(@as(usize, 2), totals.failed);
    try std.testing.expectEqual(@as(usize, 9), totals.total);
}

const ParsedArgs = struct {
    backend: ?build_def.ExecutionTarget = null,
    profile: ?manifest.BuildProfile = null,
    offline: bool = false,
    locked: bool = false,
    timings: bool = false,
    input_path: []const u8,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var backend: ?build_def.ExecutionTarget = null;
    var profile: ?manifest.BuildProfile = null;
    var offline = false;
    var locked = false;
    var timings = false;
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
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            profile = manifest.BuildProfile.parse(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--offline")) {
            offline = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--locked")) {
            locked = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timings")) {
            timings = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--print-backend-policy")) {
            continue;
        }
        if (input_path != null) return error.InvalidArguments;
        input_path = arg;
    }
    return .{
        .backend = backend,
        .profile = profile,
        .offline = offline,
        .locked = locked,
        .timings = timings,
        .input_path = input_path orelse support.defaultCommandInputPath(),
    };
}

fn selectedBackend(parsed: ParsedArgs) ?build_def.ExecutionTarget {
    if (parsed.backend) |backend| return backend;
    return switch (parsed.profile orelse return null) {
        .debug => .vm,
        .profiler, .release => .llvm_native,
    };
}

fn parseBackend(arg: []const u8) ?build_def.ExecutionTarget {
    if (std.mem.eql(u8, arg, "vm")) return .vm;
    if (std.mem.eql(u8, arg, "llvm")) return .llvm_native;
    if (std.mem.eql(u8, arg, "wasm") or std.mem.eql(u8, arg, "wasm32-emscripten")) return .wasm32_emscripten;
    if (std.mem.eql(u8, arg, "hybrid")) return .hybrid;
    return null;
}

fn backendArg(backend: ?build_def.ExecutionTarget) kira_main.KiraDeveloperBackend {
    return switch (backend orelse return .default) {
        .vm => .vm,
        .llvm_native => .llvm,
        .wasm32_emscripten => .wasm32_emscripten,
        .hybrid => .hybrid,
    };
}
