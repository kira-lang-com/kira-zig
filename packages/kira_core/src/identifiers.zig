const std = @import("std");

pub fn writeKiraIdentifier(writer: anytype, name: []const u8, fallback: []const u8) !void {
    const source = if (name.len == 0) fallback else name;
    if (isKeyword(source) or std.ascii.isDigit(source[0])) try writer.writeAll("_");
    for (source) |byte| {
        try writer.writeByte(if (std.ascii.isAlphanumeric(byte) or byte == '_') byte else '_');
    }
}

pub fn sanitizeKiraIdentifier(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeKiraIdentifier(&output.writer, name, fallback);
    return output.toOwnedSlice();
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "annotation", "capability", "class",    "comptime",  "macro",    "quote",       "construct",
        "enum",       "struct",     "type",     "extends",   "extend",   "attempt",     "try",
        "Self",       "async",      "function", "generated", "override", "overridable", "targets",
        "uses",       "let",        "var",      "return",    "import",   "as",          "if",
        "else",       "for",        "in",       "while",     "break",    "continue",    "match",
        "switch",     "case",       "default",  "true",      "false",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

test "sanitizes paths, leading digits, empty names, and keywords" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "hello-world", .expected = "hello_world" },
        .{ .input = "9lives", .expected = "_9lives" },
        .{ .input = "", .expected = "Package" },
        .{ .input = "class", .expected = "_class" },
    };
    for (cases) |case| {
        const actual = try sanitizeKiraIdentifier(allocator, case.input, "Package");
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
