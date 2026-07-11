const std = @import("std");

/// Line-oriented TOML text primitives shared by the manifest parsers
/// (`parser.zig` for project/package/lockfile manifests, `native_lib_parser.zig`
/// for NativeLibs manifests). Extracted from `parser.zig` (Core Law #5).
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidManifest;
}

pub fn trimComment(line: []const u8) []const u8 {
    var in_string = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const ch = line[index];
        if (ch == '"') in_string = !in_string;
        if (ch == '#' and !in_string) break;
    }
    return std.mem.trim(u8, line[0..index], " \t\r");
}

pub fn isSectionHeader(line: []const u8) bool {
    return line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']';
}

pub fn splitKeyValue(line: []const u8) !KeyValue {
    const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
    return .{
        .key = std.mem.trim(u8, line[0..equal_index], " \t"),
        .value = std.mem.trim(u8, line[equal_index + 1 ..], " \t"),
    };
}

pub fn assignString(line: []const u8, key: []const u8) ?[]const u8 {
    const kv = splitKeyValue(line) catch return null;
    if (!std.mem.eql(u8, kv.key, key)) return null;
    return parseBorrowedString(kv.value) catch null;
}

pub fn parseOwnedString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, try parseBorrowedString(value));
}

pub fn parseBorrowedString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidManifest;
    return value[1 .. value.len - 1];
}

pub fn parseStringArray(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidManifest;
    const body = value[1 .. value.len - 1];
    var items = std.array_list.Managed([]const u8).init(allocator);
    var start: usize = 0;
    var in_string = false;
    for (body, 0..) |ch, index| {
        if (ch == '"') in_string = !in_string;
        if (ch == ',' and !in_string) {
            const part = std.mem.trim(u8, body[start..index], " \t");
            if (part.len > 0) try items.append(try parseOwnedString(allocator, part));
            start = index + 1;
        }
    }
    const trailing = std.mem.trim(u8, body[start..], " \t");
    if (trailing.len > 0) try items.append(try parseOwnedString(allocator, trailing));
    return items.toOwnedSlice();
}

pub fn appendStringArrayValue(
    allocator: std.mem.Allocator,
    value: []const u8,
    list: *std.array_list.Managed([]const u8),
) !bool {
    if (value.len < 1 or value[0] != '[') return error.InvalidManifest;
    if (value.len >= 2 and value[value.len - 1] == ']') {
        const parsed = try parseStringArray(allocator, value);
        try list.appendSlice(parsed);
        return true;
    }

    try appendStringArrayFragment(allocator, value[1..], list);
    return false;
}

pub fn appendStringArrayContinuation(
    allocator: std.mem.Allocator,
    line: []const u8,
    list: *std.array_list.Managed([]const u8),
) !bool {
    if (std.mem.eql(u8, line, "]")) return true;
    if (line[line.len - 1] == ']') {
        try appendStringArrayFragment(allocator, line[0 .. line.len - 1], list);
        return true;
    }

    try appendStringArrayFragment(allocator, line, list);
    return false;
}

fn appendStringArrayFragment(
    allocator: std.mem.Allocator,
    fragment: []const u8,
    list: *std.array_list.Managed([]const u8),
) !void {
    const trimmed = std.mem.trim(u8, fragment, " \t,");
    if (trimmed.len == 0) return;
    try list.append(try parseOwnedString(allocator, trimmed));
}

pub fn parseInlineTable(allocator: std.mem.Allocator, value: []const u8) ![]const KeyValue {
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.InvalidManifest;
    const body = value[1 .. value.len - 1];
    var fields = std.array_list.Managed(KeyValue).init(allocator);
    var start: usize = 0;
    var in_string = false;
    for (body, 0..) |ch, index| {
        if (ch == '"') in_string = !in_string;
        if (ch == ',' and !in_string) {
            const part = std.mem.trim(u8, body[start..index], " \t");
            if (part.len > 0) try fields.append(try parseInlineField(allocator, part));
            start = index + 1;
        }
    }
    const trailing = std.mem.trim(u8, body[start..], " \t");
    if (trailing.len > 0) try fields.append(try parseInlineField(allocator, trailing));
    return fields.toOwnedSlice();
}

fn parseInlineField(allocator: std.mem.Allocator, part: []const u8) !KeyValue {
    const kv = try splitKeyValue(part);
    return .{
        .key = try allocator.dupe(u8, kv.key),
        .value = try parseOwnedString(allocator, kv.value),
    };
}
