const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const hybrid_runtime = @import("kira_hybrid_runtime");
const source_pkg = @import("kira_source");
const discovery = @import("discovery.zig");
const support = @import("execute_support.zig");

pub const max_ungrouped_failures = 5;
pub const default_report_path = ".kira/test-report.json";

pub const PhaseProfile = struct {
    kind: Kind = .not_run,
    duration_ns: u64 = 0,
    cache_status: build.CacheStatus = .not_checked,
    cache_restore_ns: u64 = 0,
    cache_store_ns: u64 = 0,

    pub const Kind = enum {
        not_run,
        assumed_pass,
        blocked,
        executed,
    };
};

pub const JobReport = struct {
    passed: usize,
    failed: usize,
    failures: []const FailureRecord = &.{},
};

pub const FailureDetail = struct {
    case_name: ?[]const u8 = null,
    backend: ?discovery.Backend = null,
    phase: ?discovery.Phase = null,
    signature: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    diagnostic_code: ?[]const u8 = null,
    diagnostic_title: ?[]const u8 = null,
    stage: ?discovery.Stage = null,
};

pub const FailureRecord = struct {
    label: []const u8,
    error_name: []const u8,
    signature: []const u8,
    trace: []const u8,
    case_name: ?[]const u8 = null,
    backend: ?discovery.Backend = null,
    phase: ?discovery.Phase = null,
    diagnostic_code: ?[]const u8 = null,
    diagnostic_title: ?[]const u8 = null,
    stage: ?discovery.Stage = null,
};

pub const SuiteReport = struct {
    total: usize,
    passed: usize,
    failed: usize,
    failures: []const FailureRecord,
};

pub const PhaseFailureActual = struct {
    result: discovery.ExpectedResult,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
    stage: ?discovery.Stage = null,
};

pub const BufferedReporter = struct {
    allocator: std.mem.Allocator,
    passed: usize = 0,
    failed: usize = 0,
    failures: std.array_list.Managed(FailureRecord),

    pub fn init(allocator: std.mem.Allocator) BufferedReporter {
        return .{
            .allocator = allocator,
            .failures = std.array_list.Managed(FailureRecord).init(allocator),
        };
    }

    pub fn pass(self: *BufferedReporter, _: []const u8) void {
        self.passed += 1;
    }

    pub fn fail(self: *BufferedReporter, label: []const u8, err: anyerror) void {
        self.failDetailed(label, err, .{}) catch {};
    }

    pub fn failDetailed(self: *BufferedReporter, label: []const u8, err: anyerror, detail: FailureDetail) !void {
        self.failed += 1;
        const error_name = @errorName(err);
        const trace = detail.trace orelse try std.fmt.allocPrint(
            self.allocator,
            "FAIL {s}: {s}\n",
            .{ label, error_name },
        );
        const signature = detail.signature orelse try std.fmt.allocPrint(
            self.allocator,
            "error:{s}",
            .{error_name},
        );
        try self.failures.append(.{
            .label = label,
            .error_name = error_name,
            .signature = signature,
            .trace = trace,
            .case_name = detail.case_name,
            .backend = detail.backend,
            .phase = detail.phase,
            .diagnostic_code = detail.diagnostic_code,
            .diagnostic_title = detail.diagnostic_title,
            .stage = detail.stage,
        });
    }

    pub fn writeTimingSummary(self: *BufferedReporter, case_name: []const u8, backend: discovery.Backend, profiles: *const [3]PhaseProfile) void {
        var trace: std.Io.Writer.Allocating = .init(self.allocator);
        writeProfileTimingSummary(&trace.writer, case_name, backend, profiles) catch return;
        const line = trace.toOwnedSlice() catch return;
        self.failures.append(.{
            .label = line,
            .error_name = "Profile",
            .signature = "profile",
            .trace = line,
        }) catch {};
    }

    pub fn finish(self: *BufferedReporter) !JobReport {
        var kept_failures = std.array_list.Managed(FailureRecord).init(self.allocator);
        for (self.failures.items) |failure| {
            if (std.mem.eql(u8, failure.signature, "profile")) continue;
            try kept_failures.append(failure);
        }
        return .{
            .passed = self.passed,
            .failed = self.failed,
            .failures = try kept_failures.toOwnedSlice(),
        };
    }
};

pub fn writeHumanReport(allocator: std.mem.Allocator, writer: anytype, report: SuiteReport) !void {
    try writer.print("{d} passed\n", .{report.passed});
    try writer.print("{d} failed\n", .{report.failed});
    if (report.failed == 0) return;

    if (report.failed <= max_ungrouped_failures) {
        try writer.writeAll("\nFailures:\n");
        for (report.failures, 0..) |failure, index| {
            try writer.print("\n[{d}/{d}] {s}\n", .{ index + 1, report.failed, failure.label });
            try writer.writeAll(failure.trace);
            if (failure.trace.len == 0 or failure.trace[failure.trace.len - 1] != '\n') try writer.writeByte('\n');
        }
        return;
    }

    const groups = try groupFailures(allocator, report.failures);
    try writer.print("\nFailure groups: {d}\n", .{groups.len});
    for (groups, 0..) |group, index| {
        const representative = group.failures[0];
        try writer.writeAll("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
        try writer.print("Group {d}\n", .{index + 1});
        try writer.print("Occurrences: {d}\n\n", .{group.failures.len});
        try writer.writeAll("Representative tests:\n\n");
        const representative_count = @min(group.failures.len, 5);
        for (group.failures[0..representative_count]) |failure| {
            try writer.print("* {s}\n", .{failure.case_name orelse failure.label});
        }
        if (group.failures.len > representative_count) {
            try writer.print("* ... {d} more\n", .{group.failures.len - representative_count});
        }
        try writer.writeAll("\nDiagnostic:\n");
        if (representative.diagnostic_code) |code| {
            try writer.print("{s}\n", .{code});
        } else {
            try writer.print("{s}\n", .{representative.error_name});
        }
        try writer.writeAll("\nFull trace:\n");
        try writer.writeAll("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        try writer.writeAll(representative.trace);
        if (representative.trace.len == 0 or representative.trace[representative.trace.len - 1] != '\n') try writer.writeByte('\n');
    }
}

pub fn writeJsonReportFile(allocator: std.mem.Allocator, report: SuiteReport) !void {
    if (std.fs.path.dirname(default_report_path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    }
    var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, default_report_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    try writeJsonReport(allocator, &writer.interface, report);
    try writer.interface.flush();
}

pub fn writeJsonReport(allocator: std.mem.Allocator, writer: anytype, report: SuiteReport) !void {
    const groups = try groupFailures(allocator, report.failures);
    try writer.writeAll("{\n");
    try writer.print("  \"total_tests\": {d},\n", .{report.total});
    try writer.print("  \"passed_tests\": {d},\n", .{report.passed});
    try writer.print("  \"failed_tests\": {d},\n", .{report.failed});
    try writer.print("  \"failure_group_count\": {d},\n", .{groups.len});
    try writer.writeAll("  \"failure_groups\": [");
    for (groups, 0..) |group, group_index| {
        if (group_index != 0) try writer.writeAll(",");
        const representative = group.failures[0];
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"signature\": ");
        try writeJsonString(writer, group.signature);
        try writer.print(",\n      \"occurrences\": {d},\n", .{group.failures.len});
        try writer.writeAll("      \"representative_cases\": [");
        const representative_count = @min(group.failures.len, 5);
        for (group.failures[0..representative_count], 0..) |failure, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeJsonString(writer, failure.label);
        }
        try writer.writeAll("],\n");
        try writer.writeAll("      \"diagnostic_metadata\": ");
        try writeDiagnosticMetadata(writer, representative);
        try writer.writeAll(",\n      \"full_trace\": ");
        try writeJsonString(writer, representative.trace);
        try writer.writeAll(",\n      \"occurrence_labels\": [");
        for (group.failures, 0..) |failure, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeJsonString(writer, failure.label);
        }
        try writer.writeAll("]\n    }");
    }
    if (groups.len != 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");
}

pub fn renderDiagnosticsTrace(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    diagnostics_items: []const diagnostics.Diagnostic,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    if (diagnostics_items.len == 0) {
        try output.writer.writeAll("<no diagnostics>\n");
        return output.toOwnedSlice();
    }

    var source = source_pkg.SourceFile.fromPath(allocator, source_path) catch {
        try renderDiagnosticsFallback(&output.writer, diagnostics_items);
        return output.toOwnedSlice();
    };
    defer source.deinit();
    try diagnostics.renderer.renderAll(&output.writer, &source, diagnostics_items);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

pub fn childTrace(allocator: std.mem.Allocator, backend: []const u8, term: std.process.Child.Term, stdout: []const u8, stderr: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.print("{s} child failed with term={any}\n", .{ backend, term });
    if (stdout.len != 0) try output.writer.print("{s} child stdout:\n{s}\n", .{ backend, stdout });
    if (stderr.len != 0) try output.writer.print("{s} child stderr:\n{s}\n", .{ backend, stderr });
    return output.toOwnedSlice();
}

pub fn hybridFailureTrace(
    allocator: std.mem.Allocator,
    child: anytype,
    manifest_path: []const u8,
    runner_path: []const u8,
    run_cwd: []const u8,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const first_trace = try childTrace(allocator, "hybrid", child.term, child.stdout, child.stderr);
    try output.writer.writeAll(first_trace);
    try appendHybridManifestTrace(allocator, &output.writer, manifest_path);
    const retry_trace = runHybridTraceRetry(allocator, runner_path, manifest_path, run_cwd) catch |err|
        try std.fmt.allocPrint(allocator, "hybrid trace retry failed before launch: {s}\n", .{@errorName(err)});
    try output.writer.writeAll("hybrid trace retry follows\n");
    try output.writer.writeAll(retry_trace);
    return output.toOwnedSlice();
}

pub fn failureDetail(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    source_path: []const u8,
    backend: discovery.Backend,
    phase: discovery.Phase,
    reason: []const u8,
    actual: PhaseFailureActual,
) !FailureDetail {
    const diag = support.firstDiagnostic(actual.diagnostics);
    const signature = if (actual.diagnostics.len != 0)
        try std.fmt.allocPrint(
            allocator,
            "diagnostic:{s}:{s}:{s}",
            .{ if (actual.stage) |stage| support.stageName(stage) else "unknown", diag.code, diag.title },
        )
    else if (actual.trace) |trace|
        try std.fmt.allocPrint(
            allocator,
            "runtime:{s}:{s}:{s}",
            .{ support.backendName(backend), support.phaseName(phase), try firstTraceLine(allocator, trace) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "expectation:{s}:{s}:{s}:{s}",
            .{ support.backendName(backend), support.phaseName(phase), reason, support.expectedResultName(actual.result) },
        );

    var trace: std.Io.Writer.Allocating = .init(allocator);
    try trace.writer.print(
        "FAIL {s} [{s} {s}]: {s}\n",
        .{ case_name, support.backendName(backend), support.phaseName(phase), reason },
    );
    if (actual.trace) |runtime_trace| {
        try trace.writer.writeAll(runtime_trace);
        if (runtime_trace.len == 0 or runtime_trace[runtime_trace.len - 1] != '\n') try trace.writer.writeByte('\n');
    }
    if (actual.diagnostics.len != 0) {
        const rendered = try renderDiagnosticsTrace(allocator, source_path, actual.diagnostics);
        try trace.writer.writeAll(rendered);
    }
    if (actual.stdout) |stdout| {
        if (stdout.len != 0) try trace.writer.print("stdout:\n{s}\n", .{stdout});
    }
    if (actual.stderr) |stderr| {
        if (stderr.len != 0) try trace.writer.print("stderr:\n{s}\n", .{stderr});
    }

    return .{
        .case_name = case_name,
        .backend = backend,
        .phase = phase,
        .signature = signature,
        .trace = try trace.toOwnedSlice(),
        .diagnostic_code = if (actual.diagnostics.len == 0) null else diag.code,
        .diagnostic_title = if (actual.diagnostics.len == 0) null else diag.title,
        .stage = actual.stage,
    };
}

pub fn writeProfileTimingSummary(writer: *std.Io.Writer, case_name: []const u8, backend: discovery.Backend, profiles: *const [3]PhaseProfile) !void {
    try writer.print("TIME {s} [{s}]: ", .{ case_name, support.backendName(backend) });
    const phases = [_]discovery.Phase{ .check, .build, .run };
    for (phases, 0..) |phase, index| {
        if (index != 0) try writer.writeAll(", ");
        try writePhaseProfile(writer, phase, profiles[index]);
    }
    try writer.writeByte('\n');
}

const FailureGroup = struct {
    signature: []const u8,
    failures: []const FailureRecord,
};

fn groupFailures(allocator: std.mem.Allocator, failures: []const FailureRecord) ![]const FailureGroup {
    var groups = std.array_list.Managed(FailureGroup).init(allocator);
    var grouped = std.array_list.Managed(std.array_list.Managed(FailureRecord)).init(allocator);
    for (failures) |failure| {
        var found: ?usize = null;
        for (groups.items, 0..) |group, index| {
            if (std.mem.eql(u8, group.signature, failure.signature)) {
                found = index;
                break;
            }
        }
        if (found) |index| {
            try grouped.items[index].append(failure);
        } else {
            var list = std.array_list.Managed(FailureRecord).init(allocator);
            try list.append(failure);
            try grouped.append(list);
            try groups.append(.{
                .signature = failure.signature,
                .failures = &.{},
            });
        }
    }
    for (groups.items, 0..) |*group, index| {
        group.failures = try grouped.items[index].toOwnedSlice();
    }
    return groups.toOwnedSlice();
}

fn appendHybridManifestTrace(allocator: std.mem.Allocator, writer: *std.Io.Writer, manifest_path: []const u8) !void {
    const manifest = hybrid_runtime.loadHybridModule(allocator, manifest_path) catch |err| {
        try writer.print("hybrid manifest unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print(
        "hybrid manifest: entry={d} entry_exec={s} bytecode={s} native_library={s} functions={d}\n",
        .{
            manifest.entry_function_id,
            @tagName(manifest.entry_execution),
            manifest.bytecode_path,
            manifest.native_library_path,
            manifest.functions.len,
        },
    );
    for (manifest.functions) |function_decl| {
        try writer.print(
            "hybrid manifest fn: id={d} exec={s} name={s} params={d} exported={s}\n",
            .{
                function_decl.id,
                @tagName(function_decl.execution),
                function_decl.name,
                function_decl.param_types.len,
                function_decl.exported_name orelse "<none>",
            },
        );
    }
}

fn runHybridTraceRetry(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    manifest_path: []const u8,
    run_cwd: []const u8,
) ![]const u8 {
    const process_environ = support.inheritedProcessEnviron();
    var environ_map = try std.process.Environ.createMap(process_environ, allocator);
    defer environ_map.deinit();
    try environ_map.put("KIRA_TRACE_EXECUTION", "1");

    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{ .environ = process_environ });
    defer io_impl.deinit();
    const child = try std.process.run(allocator, io_impl.io(), .{
        .argv = &.{ runner_path, manifest_path },
        .cwd = .{ .path = run_cwd },
        .environ_map = &environ_map,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(child.stdout);
    defer allocator.free(child.stderr);

    return childTrace(allocator, "hybrid trace", child.term, child.stdout, child.stderr);
}

fn firstTraceLine(allocator: std.mem.Allocator, trace: []const u8) ![]const u8 {
    const line_end = std.mem.indexOfScalar(u8, trace, '\n') orelse trace.len;
    const line = std.mem.trim(u8, trace[0..line_end], " \t\r\n");
    const capped = line[0..@min(line.len, 160)];
    var sanitized = std.array_list.Managed(u8).init(allocator);
    for (capped) |byte| {
        switch (byte) {
            '\\' => try sanitized.append('/'),
            '"' => try sanitized.append('\''),
            else => try sanitized.append(byte),
        }
    }
    return sanitized.toOwnedSlice();
}

fn writePhaseProfile(writer: *std.Io.Writer, phase: discovery.Phase, profile: PhaseProfile) !void {
    try writer.print("{s}=", .{support.phaseName(phase)});
    switch (profile.kind) {
        .not_run => try writer.writeAll("not-run"),
        .assumed_pass => try writer.writeAll("assumed-pass"),
        .blocked => try writer.writeAll("blocked"),
        .executed => {
            try support.writeDuration(writer, profile.duration_ns);
            if (profile.cache_status != .not_checked) {
                try writer.writeAll(" cache=");
                try writer.writeAll(support.cacheStatusName(profile.cache_status));
                if (profile.cache_restore_ns != 0) {
                    try writer.writeAll("(restore=");
                    try support.writeDuration(writer, profile.cache_restore_ns);
                    try writer.writeByte(')');
                }
                if (profile.cache_store_ns != 0) {
                    try writer.writeAll("(store=");
                    try support.writeDuration(writer, profile.cache_store_ns);
                    try writer.writeByte(')');
                }
            }
        },
    }
}

fn renderDiagnosticsFallback(writer: *std.Io.Writer, diagnostics_items: []const diagnostics.Diagnostic) !void {
    for (diagnostics_items, 0..) |item, index| {
        if (index != 0) try writer.writeByte('\n');
        if (item.code) |code| {
            try writer.print("{s}[{s}]: {s}\n", .{ @tagName(item.severity), code, item.title });
        } else {
            try writer.print("{s}: {s}\n", .{ @tagName(item.severity), item.title });
        }
        try writer.print("  {s}\n", .{item.message});
    }
}

fn writeDiagnosticMetadata(writer: anytype, failure: FailureRecord) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"error\": ");
    try writeJsonString(writer, failure.error_name);
    try writer.writeAll(", \"backend\": ");
    if (failure.backend) |backend| {
        try writeJsonString(writer, support.backendName(backend));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"phase\": ");
    if (failure.phase) |phase| {
        try writeJsonString(writer, support.phaseName(phase));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"stage\": ");
    if (failure.stage) |stage| {
        try writeJsonString(writer, support.stageName(stage));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"diagnostic_code\": ");
    if (failure.diagnostic_code) |code| {
        try writeJsonString(writer, code);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"diagnostic_title\": ");
    if (failure.diagnostic_title) |title| {
        try writeJsonString(writer, title);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.print("{c}", .{byte}),
        }
    }
    try writer.writeAll("\"");
}

test "groups failures by stable signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failures = [_]FailureRecord{
        .{ .label = "a", .error_name = "ExpectationFailed", .signature = "diagnostic:semantics:KSEM001", .trace = "first\n" },
        .{ .label = "b", .error_name = "ExpectationFailed", .signature = "diagnostic:semantics:KSEM001", .trace = "second\n" },
        .{ .label = "c", .error_name = "ExpectationFailed", .signature = "runtime:llvm:exit", .trace = "third\n" },
    };
    const groups = try groupFailures(arena.allocator(), &failures);
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].failures.len);
    try std.testing.expectEqualStrings("a", groups[0].failures[0].label);
    try std.testing.expectEqualStrings("c", groups[1].failures[0].label);
}

test "json report includes group trace and representative cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failures = [_]FailureRecord{
        .{
            .label = "tests/fail/example [vm check]",
            .error_name = "ExpectationFailed",
            .signature = "diagnostic:semantics:KSEM001",
            .trace = "error[KSEM001]: missing @Main entrypoint\n",
            .diagnostic_code = "KSEM001",
            .diagnostic_title = "missing @Main entrypoint",
            .stage = .semantics,
        },
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJsonReport(arena.allocator(), &writer, .{
        .total = 4,
        .passed = 3,
        .failed = 1,
        .failures = &failures,
    });
    const json = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"failure_group_count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"representative_cases\": [\"tests/fail/example [vm check]\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "missing @Main entrypoint") != null);
}
