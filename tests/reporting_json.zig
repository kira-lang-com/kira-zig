// JSON test-report serialization for the corpus runner. Split out of
// tests/reporting.zig (Core Law #5): the human/skip report + failure grouping
// stay there; this module owns only the machine-readable `.kira/test-report.json`
// projection. Depends one-directionally on reporting.zig for the shared report
// types and failure grouping.
const std = @import("std");
const support = @import("execute_support.zig");
const reporting = @import("reporting.zig");

const SuiteReport = reporting.SuiteReport;
const FailureRecord = reporting.FailureRecord;

pub fn writeJsonReportFile(allocator: std.mem.Allocator, report: SuiteReport) !void {
    if (std.fs.path.dirname(reporting.default_report_path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    }
    var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, reporting.default_report_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buffer);
    try writeJsonReport(allocator, &writer.interface, report);
    try writer.interface.flush();
}

pub fn writeJsonReport(allocator: std.mem.Allocator, writer: anytype, report: SuiteReport) !void {
    const groups = try reporting.groupFailures(allocator, report.failures);
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
