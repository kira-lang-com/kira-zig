//! Pull-request metadata derived from the complete branch diff. PR scope is a
//! property of `base...HEAD`, never of the current process, conversation, or
//! editing session.

const std = @import("std");
const Context = @import("context.zig").Context;
const git = @import("git_ops.zig");

const Area = enum {
    compiler_runtime,
    packages_manifests,
    tests,
    developer_tooling,
    platforms_web,
    docs_workflow,
};

const area_count = @typeInfo(Area).@"enum".fields.len;
const areas = [_]Area{ .compiler_runtime, .packages_manifests, .tests, .developer_tooling, .platforms_web, .docs_workflow };

pub const Metadata = struct {
    base_ref: []u8,
    title: []u8,
    body: []u8,

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.base_ref);
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

pub fn generate(ctx: Context) !Metadata {
    const base_ref = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{
        if (ctx.hasUpstream()) "upstream" else "origin",
        ctx.default_branch,
    });
    errdefer ctx.allocator.free(base_ref);

    const files = try git.branchChangedFiles(ctx, base_ref);
    defer ctx.allocator.free(files);
    const commits = try git.branchCommitSubjects(ctx, base_ref);
    defer ctx.allocator.free(commits);

    const rendered = try render(ctx.allocator, base_ref, files, commits);
    return .{ .base_ref = base_ref, .title = rendered.title, .body = rendered.body };
}

const Rendered = struct { title: []u8, body: []u8 };

fn render(allocator: std.mem.Allocator, base_ref: []const u8, files: []const u8, commits: []const u8) !Rendered {
    var counts = [_]usize{0} ** area_count;
    var file_count: usize = 0;
    var file_it = std.mem.splitScalar(u8, files, '\n');
    while (file_it.next()) |path| {
        if (path.len == 0) continue;
        file_count += 1;
        counts[@intFromEnum(classify(path))] += 1;
    }

    var active_count: usize = 0;
    for (counts) |count| if (count != 0) {
        active_count += 1;
    };

    const title = if (active_count >= 4)
        try allocator.dupe(u8, "Advance Kira compiler/runtime, packages, tests, and developer tooling")
    else
        try focusedTitle(allocator, counts);
    errdefer allocator.free(title);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.print(
        "## Summary\n\nThis description is generated from the complete `{s}...HEAD` branch diff ({d} changed files), not from the current session.\n",
        .{ base_ref, file_count },
    );
    for (areas) |area| {
        const count = counts[@intFromEnum(area)];
        if (count != 0) try body.writer.print("\n- {s} ({d} files)", .{ areaDescription(area), count });
    }

    try body.writer.writeAll("\n\n## Branch commits\n");
    var commit_count: usize = 0;
    var commit_it = std.mem.splitScalar(u8, commits, '\n');
    while (commit_it.next()) |subject| {
        if (subject.len == 0) continue;
        commit_count += 1;
        try body.writer.print("\n- {s}", .{subject});
    }
    if (commit_count == 0) try body.writer.writeAll("\n- No commits found beyond the base ref");
    try body.writer.writeAll("\n");

    return .{ .title = title, .body = try body.toOwnedSlice() };
}

fn focusedTitle(allocator: std.mem.Allocator, counts: [area_count]usize) ![]u8 {
    var title: std.Io.Writer.Allocating = .init(allocator);
    defer title.deinit();
    try title.writer.writeAll("Advance Kira ");
    var written: usize = 0;
    for (areas) |area| {
        if (counts[@intFromEnum(area)] == 0) continue;
        if (written != 0) try title.writer.writeAll(if (written == 1) " and " else ", ");
        try title.writer.writeAll(areaTitle(area));
        written += 1;
    }
    if (written == 0) try title.writer.writeAll("development");
    return title.toOwnedSlice();
}

fn classify(path: []const u8) Area {
    if (hasAny(path, &.{ "test", "tests", "corpus", "FailTest" })) return .tests;
    if (hasAny(path, &.{ "manifest", "package.kira", "package_manager", "dependency" })) return .packages_manifests;
    if (hasAny(path, &.{ "wasm", "web", "shader", "platform_runner", "kira_graphics" })) return .platforms_web;
    if (hasAny(path, &.{ ".codex/", "AGENTS.md", "CHANGELOG", "README", "docs/", ".github/" })) return .docs_workflow;
    if (hasAny(path, &.{ "kira_cli", "kira_devflow", "toolchain", "debugger", "build.zig" })) return .developer_tooling;
    return .compiler_runtime;
}

fn hasAny(path: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, path, needle) != null) return true;
    return false;
}

fn areaTitle(area: Area) []const u8 {
    return switch (area) {
        .compiler_runtime => "compiler/runtime",
        .packages_manifests => "packages",
        .tests => "tests",
        .developer_tooling => "developer tooling",
        .platforms_web => "platforms and Web",
        .docs_workflow => "documentation and workflow",
    };
}

fn areaDescription(area: Area) []const u8 {
    return switch (area) {
        .compiler_runtime => "advances compiler, IR, VM, LLVM, hybrid, FFI, and runtime implementation",
        .packages_manifests => "evolves declarative packages, manifests, dependencies, and package management",
        .tests => "expands Kira-native tests, backend parity, fixtures, and validation infrastructure",
        .developer_tooling => "improves the CLI, build system, debugger, toolchain, and developer workflow",
        .platforms_web => "advances Web, WASM, shaders, graphics, and platform runners",
        .docs_workflow => "updates documentation, repository policy, CI, and agent workflow",
    };
}

test "renders metadata from the complete branch inventory" {
    const rendered = try render(std.testing.allocator, "upstream/main",
        \\packages/kira_compiler/src/root.zig
        \\packages/kira_manifest/src/parser.zig
        \\tests-kik/app/package.kira
        \\packages/kira_cli/src/main.zig
        \\.codex/skills/working-with-git/SKILL.md
    ,
        \\Implement compiler work
        \\Migrate packages
    );
    defer std.testing.allocator.free(rendered.title);
    defer std.testing.allocator.free(rendered.body);
    try std.testing.expectEqualStrings("Advance Kira compiler/runtime, packages, tests, and developer tooling", rendered.title);
    try std.testing.expect(std.mem.indexOf(u8, rendered.body, "complete `upstream/main...HEAD` branch diff (5 changed files)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.body, "Implement compiler work") != null);
}
