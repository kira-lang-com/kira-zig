const std = @import("std");

pub const CorpusMode = enum {
    run,
    check,
    fail,
};

pub const Backend = enum {
    vm,
    llvm,
    hybrid,
};

pub const Stage = enum {
    lexer,
    parser,
    semantics,
    ir,
};

pub const Expectation = struct {
    mode: CorpusMode,
    backends: []const Backend = &.{},
    stdout: ?[]const u8 = null,
    diagnostic_code: ?[]const u8 = null,
    diagnostic_title: ?[]const u8 = null,
    stage: ?Stage = null,
};

pub const Case = struct {
    name: []const u8,
    source_path: []const u8,
    expectation: Expectation,
};

pub fn discoverCases(allocator: std.mem.Allocator) ![]Case {
    var cases = std.array_list.Managed(Case).init(allocator);
    try scanRoot(allocator, "tests/pass/run", .run, &cases);
    try scanRoot(allocator, "tests/pass/check", .check, &cases);
    try scanRoot(allocator, "tests/fail", .fail, &cases);
    sortCases(cases.items);
    return cases.toOwnedSlice();
}

fn scanRoot(
    allocator: std.mem.Allocator,
    root_rel: []const u8,
    expected_mode: CorpusMode,
    cases: *std.array_list.Managed(Case),
) !void {
    if (!dirExists(root_rel)) return;
    try scanDir(allocator, root_rel, "", expected_mode, cases);
}

fn scanDir(
    allocator: std.mem.Allocator,
    root_rel: []const u8,
    current_rel: []const u8,
    expected_mode: CorpusMode,
    cases: *std.array_list.Managed(Case),
) !void {
    const dir_path = if (current_rel.len == 0)
        root_rel
    else
        try std.fs.path.join(allocator, &.{ root_rel, current_rel });

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const next_rel = if (current_rel.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ current_rel, entry.name });
                try scanDir(allocator, root_rel, next_rel, expected_mode, cases);
            },
            .file => {
                if (!std.mem.eql(u8, entry.name, "main.kira")) continue;
                const case_rel = if (current_rel.len == 0)
                    entry.name
                else
                    current_rel;
                const source_path = try std.fs.path.join(allocator, &.{ root_rel, case_rel, "main.kira" });
                const expect_path = try std.fs.path.join(allocator, &.{ root_rel, case_rel, "expect.toml" });
                const expectation = try loadExpectation(allocator, expect_path, expected_mode);
                try cases.append(.{
                    .name = try std.fs.path.join(allocator, &.{ root_rel, case_rel }),
                    .source_path = source_path,
                    .expectation = expectation,
                });
            },
            else => {},
        }
    }
}

fn loadExpectation(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_mode: CorpusMode,
) !Expectation {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    return parseExpectation(allocator, text, expected_mode);
}

fn parseExpectation(
    allocator: std.mem.Allocator,
    text: []const u8,
    expected_mode: CorpusMode,
) !Expectation {
    var mode: ?CorpusMode = null;
    var backends = std.array_list.Managed(Backend).init(allocator);
    var stdout: ?[]const u8 = null;
    var diagnostic_code: ?[]const u8 = null;
    var diagnostic_title: ?[]const u8 = null;
    var stage: ?Stage = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidExpectation;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");

        if (std.mem.eql(u8, key, "mode")) {
            if (mode != null) return error.InvalidExpectation;
            const parsed_opt = try parseTomlString(allocator, value);
            const parsed = parsed_opt orelse return error.InvalidExpectation;
            mode = try parseMode(parsed);
            continue;
        }

        if (std.mem.eql(u8, key, "backends")) {
            if (backends.items.len != 0) return error.InvalidExpectation;
            const parsed = try parseBackends(allocator, value);
            try backends.appendSlice(parsed);
            continue;
        }

        if (std.mem.eql(u8, key, "stdout")) {
            if (stdout != null) return error.InvalidExpectation;
            const parsed_opt = try parseTomlString(allocator, value);
            stdout = parsed_opt orelse return error.InvalidExpectation;
            continue;
        }

        if (std.mem.eql(u8, key, "diagnostic_code")) {
            if (diagnostic_code != null) return error.InvalidExpectation;
            const parsed_opt = try parseTomlString(allocator, value);
            diagnostic_code = parsed_opt orelse return error.InvalidExpectation;
            continue;
        }

        if (std.mem.eql(u8, key, "diagnostic_title")) {
            if (diagnostic_title != null) return error.InvalidExpectation;
            const parsed_opt = try parseTomlString(allocator, value);
            diagnostic_title = parsed_opt orelse return error.InvalidExpectation;
            continue;
        }

        if (std.mem.eql(u8, key, "stage")) {
            if (stage != null) return error.InvalidExpectation;
            const parsed_opt = try parseTomlString(allocator, value);
            const parsed = parsed_opt orelse return error.InvalidExpectation;
            stage = try parseStage(parsed);
            continue;
        }

        return error.InvalidExpectation;
    }

    const actual_mode = mode orelse return error.InvalidExpectation;
    if (actual_mode != expected_mode) return error.InvalidExpectation;

    return .{
        .mode = actual_mode,
        .backends = try backends.toOwnedSlice(),
        .stdout = stdout,
        .diagnostic_code = diagnostic_code,
        .diagnostic_title = diagnostic_title,
        .stage = stage,
    };
}

fn parseMode(text: []const u8) !CorpusMode {
    if (std.mem.eql(u8, text, "run")) return .run;
    if (std.mem.eql(u8, text, "check")) return .check;
    if (std.mem.eql(u8, text, "fail")) return .fail;
    return error.InvalidExpectation;
}

fn parseStage(text: []const u8) !Stage {
    if (std.mem.eql(u8, text, "lexer")) return .lexer;
    if (std.mem.eql(u8, text, "parser")) return .parser;
    if (std.mem.eql(u8, text, "semantics")) return .semantics;
    if (std.mem.eql(u8, text, "ir")) return .ir;
    return error.InvalidExpectation;
}

fn parseBackends(allocator: std.mem.Allocator, value: []const u8) ![]const Backend {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidExpectation;
    var list = std.array_list.Managed(Backend).init(allocator);
    var parts = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed_opt = try parseTomlString(allocator, trimmed);
        const parsed_text = parsed_opt orelse return error.InvalidExpectation;
        const parsed = try parseBackend(parsed_text);
        try list.append(parsed);
    }
    return list.toOwnedSlice();
}

fn parseBackend(text: []const u8) !Backend {
    if (std.mem.eql(u8, text, "vm")) return .vm;
    if (std.mem.eql(u8, text, "llvm")) return .llvm;
    if (std.mem.eql(u8, text, "hybrid")) return .hybrid;
    return error.InvalidExpectation;
}

fn parseTomlString(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (value.len == 0 or value[0] != '"') return null;
    if (value[value.len - 1] != '"') return error.InvalidExpectation;

    var buffer = std.array_list.Managed(u8).init(allocator);
    var index: usize = 1;
    while (index < value.len - 1) {
        const ch = value[index];
        if (ch == '\\') {
            index += 1;
            if (index >= value.len - 1) return error.InvalidExpectation;
            switch (value[index]) {
                'n' => try buffer.append('\n'),
                'r' => try buffer.append('\r'),
                't' => try buffer.append('\t'),
                '"' => try buffer.append('"'),
                '\\' => try buffer.append('\\'),
                else => return error.InvalidExpectation,
            }
        } else {
            try buffer.append(ch);
        }
        index += 1;
    }
    return @as(?[]const u8, try buffer.toOwnedSlice());
}

fn sortCases(items: []Case) void {
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, items[cursor - 1].name, items[cursor].name) == .gt) : (cursor -= 1) {
            const tmp = items[cursor - 1];
            items[cursor - 1] = items[cursor];
            items[cursor] = tmp;
        }
    }
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}
