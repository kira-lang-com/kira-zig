const std = @import("std");
const build = @import("kira_build");
const diagnostics = @import("kira_diagnostics");
const discovery = @import("discovery.zig");

pub fn expectNoDiagnostics(items: []const diagnostics.Diagnostic) !void {
    if (items.len != 0) return error.ExpectationFailed;
}

pub fn expectStdout(allocator: std.mem.Allocator, actual: []const u8, expected: []const u8) !void {
    const normalized_actual = try normalizeNewlines(allocator, actual);
    defer allocator.free(normalized_actual);

    const normalized_expected = try normalizeNewlines(allocator, expected);
    defer allocator.free(normalized_expected);

    if (!std.mem.eql(u8, normalized_expected, normalized_actual)) return error.ExpectationFailed;
}

pub fn expectEmptyText(allocator: std.mem.Allocator, actual: []const u8) !void {
    const normalized_actual = try normalizeNewlines(allocator, actual);
    defer allocator.free(normalized_actual);
    if (normalized_actual.len != 0) return error.ExpectationFailed;
}

pub fn expectDiagnostic(
    items: []const diagnostics.Diagnostic,
    expected_code: []const u8,
    expected_title: []const u8,
) !void {
    if (items.len != 1) return error.ExpectationFailed;
    const code = items[0].code orelse return error.ExpectationFailed;
    if (!std.mem.eql(u8, expected_code, code)) return error.ExpectationFailed;
    if (!std.mem.eql(u8, expected_title, items[0].title)) return error.ExpectationFailed;
}

pub fn expectStage(actual: ?build.FrontendStage, expected: discovery.Stage) !void {
    const stage = actual orelse return error.ExpectationFailed;
    if (fromBuildStage(stage) != expected) return error.ExpectationFailed;
}

fn normalizeNewlines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const ch = text[index];
        if (ch == '\r' and index + 1 < text.len and text[index + 1] == '\n') {
            try bytes.append('\n');
            index += 2;
            continue;
        }
        if (ch == '\r') {
            try bytes.append('\n');
        } else {
            try bytes.append(ch);
        }
        index += 1;
    }
    return bytes.toOwnedSlice();
}

fn fromBuildStage(stage: build.FrontendStage) discovery.Stage {
    return switch (stage) {
        .lexer => .lexer,
        .parser => .parser,
        .semantics => .semantics,
        .ir => .ir,
    };
}
