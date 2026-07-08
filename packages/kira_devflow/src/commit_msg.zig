//! Conventional-commit message inference from a staged `--name-status` diff.
//! Used as the fallback when the invoking agent does not pass an explicit `-m`
//! subject: the agent knows intent best, but a sensible auto-message beats a
//! forced hand-typed flag for mechanical commits.

const std = @import("std");

pub const Kind = enum { docs, test_, chore };

/// Infer a Conventional Commit subject from `git diff --cached --name-status`.
/// Caller owns the returned slice.
pub fn infer(allocator: std.mem.Allocator, name_status: []const u8) ![]u8 {
    var scopes: std.StringArrayHashMapUnmanaged(void) = .{};
    defer scopes.deinit(allocator);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var any_code = false;
    var any_docs = false;
    var any_test = false;

    var lines = std.mem.tokenizeScalar(u8, name_status, '\n');
    while (lines.next()) |line| {
        const path = lastField(line);
        if (path.len == 0) continue;
        try paths.append(allocator, path);

        const scope = scopeOf(path);
        if (scope.len != 0) _ = try scopes.getOrPut(allocator, scope);

        if (std.mem.endsWith(u8, path, ".md")) {
            any_docs = true;
        } else if (std.mem.startsWith(u8, path, "tests/") or std.mem.indexOf(u8, path, "/tests/") != null) {
            any_test = true;
        } else if (std.mem.endsWith(u8, path, ".zig")) {
            any_code = true;
        }
    }

    const kind: Kind = if (any_code)
        .chore
    else if (any_test and !any_docs)
        .test_
    else if (any_docs and !any_test)
        .docs
    else
        .chore;

    const type_str = switch (kind) {
        .docs => "docs",
        .test_ => "test",
        .chore => "chore",
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, type_str);
    if (scopes.count() == 1) {
        try buf.append(allocator, '(');
        try buf.appendSlice(allocator, scopes.keys()[0]);
        try buf.append(allocator, ')');
    } else if (scopes.count() > 1) {
        try buf.appendSlice(allocator, "(repo)");
    }
    try buf.appendSlice(allocator, ": ");

    if (paths.items.len == 1) {
        try buf.appendSlice(allocator, "update ");
        try buf.appendSlice(allocator, paths.items[0]);
    } else {
        var num_buf: [32]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "update {d} files", .{paths.items.len});
        try buf.appendSlice(allocator, num_str);
        if (scopes.count() >= 1 and scopes.count() <= 3) {
            try buf.appendSlice(allocator, " (");
            for (scopes.keys(), 0..) |s, i| {
                if (i != 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, s);
            }
            try buf.append(allocator, ')');
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// The last tab-separated field of a name-status line (handles rename "R\told\tnew").
fn lastField(line: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, line, '\t');
    var last: []const u8 = "";
    while (it.next()) |f| last = f;
    return std.mem.trim(u8, last, " \t\r");
}

/// Derive a short scope from a repo path.
fn scopeOf(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "packages/")) {
        const rest = path["packages/".len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var pkg = rest[0..end];
        // Trim the conventional "kira_" prefix for a tighter scope.
        if (std.mem.startsWith(u8, pkg, "kira_")) pkg = pkg["kira_".len..];
        return pkg;
    }
    if (std.mem.startsWith(u8, path, "docs/")) return "docs";
    if (std.mem.startsWith(u8, path, "tests/")) return "tests";
    if (std.mem.startsWith(u8, path, ".codex/")) return "codex";
    if (std.mem.startsWith(u8, path, "examples/")) return "examples";
    if (std.mem.startsWith(u8, path, "templates/")) return "templates";
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return "build";
    return "";
}

test "infer single package code change" {
    const a = std.testing.allocator;
    const msg = try infer(a, "M\tpackages/kira_llvm_backend/src/backend_capi.zig");
    defer a.free(msg);
    try std.testing.expectEqualStrings("chore(llvm_backend): update packages/kira_llvm_backend/src/backend_capi.zig", msg);
}

test "infer docs-only change" {
    const a = std.testing.allocator;
    const msg = try infer(a, "M\tdocs/incremental_native_codegen.md");
    defer a.free(msg);
    try std.testing.expectEqualStrings("docs(docs): update docs/incremental_native_codegen.md", msg);
}

test "infer multi-file multi-scope" {
    const a = std.testing.allocator;
    const msg = try infer(a,
        "M\tpackages/kira_ir/src/ir.zig\nM\tdocs/x.md",
    );
    defer a.free(msg);
    try std.testing.expectEqualStrings("chore(repo): update 2 files (ir, docs)", msg);
}
