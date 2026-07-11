const std = @import("std");

pub const FileState = struct {
    path: []const u8,
    mtime_ns: i96,
    size: u64,
};

/// Polling watcher over every file-system input of a live bundle build:
/// Kira sources, shader sources, package manifests, assets under `app/`, and
/// native-library sources. Any change triggers a rebuild; the reload tier is
/// decided downstream (VM-only edit → in-place hot patch, native change →
/// process relaunch via the runner's dylib byte compare).
pub const SourceWatcher = struct {
    allocator: std.mem.Allocator,
    watched_dirs: std.array_list.Managed([]const u8),
    watched_files: std.array_list.Managed([]const u8),
    files: std.array_list.Managed(FileState),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .watched_dirs = std.array_list.Managed([]const u8).init(allocator),
            .watched_files = std.array_list.Managed([]const u8).init(allocator),
            .files = std.array_list.Managed(FileState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.watched_dirs.items) |dir| {
            self.allocator.free(dir);
        }
        self.watched_dirs.deinit();
        for (self.watched_files.items) |path| {
            self.allocator.free(path);
        }
        self.watched_files.deinit();
        for (self.files.items) |file| {
            self.allocator.free(file.path);
        }
        self.files.deinit();
    }

    pub fn addDirectory(self: *Self, path: []const u8) !void {
        for (self.watched_dirs.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }

        const dir_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(dir_copy);
        try self.watched_dirs.append(dir_copy);

        self.collectFiles(path) catch {};
    }

    /// Watch a single file (e.g. a package's `kira.toml`) without recursing
    /// into its directory — watching a package ROOT recursively would pick up
    /// `.kira-build/` outputs and re-trigger forever.
    pub fn addFile(self: *Self, path: []const u8) !void {
        for (self.watched_files.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return;
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.watched_files.append(path_copy);
        const tracked_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(tracked_copy);
        try self.files.append(.{
            .path = tracked_copy,
            .mtime_ns = stat.mtime.nanoseconds,
            .size = stat.size,
        });
    }

    /// True for a file that is a real build input. Everything a bundle build
    /// consumes counts — sources, shaders, manifests, assets — EXCEPT editor
    /// and OS noise, which would otherwise fire spurious reloads on every
    /// save-in-progress or Finder visit.
    fn isWatchableFile(name: []const u8) bool {
        if (name.len == 0 or name[0] == '.') return false; // .DS_Store, .main.kira.swp, ...
        if (name[name.len - 1] == '~') return false; // editor backup
        if (std.mem.endsWith(u8, name, ".swp") or std.mem.endsWith(u8, name, ".swx")) return false;
        if (std.mem.endsWith(u8, name, ".tmp")) return false;
        return true;
    }

    /// Directories that are build OUTPUTS or caches; recursing into them
    /// would make every rebuild look like a source change (infinite reload).
    fn isIgnoredDir(name: []const u8) bool {
        if (name.len == 0 or name[0] == '.') return true; // .kira-build, .git, .zig-cache
        const ignored = [_][]const u8{ "generated", "exports", "zig-out" };
        for (ignored) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return true;
        }
        return false;
    }

    fn collectFiles(self: *Self, root: []const u8) !void {
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{ .iterate = true }) catch return;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            const path = try std.fs.path.join(self.allocator, &.{ root, entry.name });
            defer self.allocator.free(path);

            switch (entry.kind) {
                .directory => {
                    if (!isIgnoredDir(entry.name)) try self.collectFiles(path);
                },
                .file => {
                    if (isWatchableFile(entry.name)) {
                        const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
                        const path_copy = try self.allocator.dupe(u8, path);
                        errdefer self.allocator.free(path_copy);
                        try self.files.append(.{
                            .path = path_copy,
                            .mtime_ns = stat.mtime.nanoseconds,
                            .size = stat.size,
                        });
                    }
                },
                else => {},
            }
        }
    }

    pub fn changed(self: *Self) !bool {
        for (self.files.items) |file| {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, file.path, .{}) catch return true;
            if (stat.mtime.nanoseconds != file.mtime_ns or stat.size != file.size) return true;
        }

        for (self.watched_dirs.items) |dir| {
            if (try self.hasNewOrDeletedFiles(dir)) return true;
        }

        return false;
    }

    fn hasNewOrDeletedFiles(self: *Self, root: []const u8) !bool {
        // Count every watchable file under `root` *recursively*, then compare
        // against the recursive count of tracked files under `root`. The two
        // counts must be gathered the same way: an earlier version counted only
        // direct children here but compared against the recursive tracked set,
        // so any watched directory containing a subdirectory with sources
        // reported a spurious change on the very first poll — triggering an
        // unwanted hot reload (and the crashes that cascade from it).
        const found = try self.countWatchableFiles(root);

        var tracked_in_dir: usize = 0;
        for (self.files.items) |file| {
            if (isPathUnder(file.path, root)) tracked_in_dir += 1;
        }

        return found != tracked_in_dir;
    }

    fn countWatchableFiles(self: *Self, root: []const u8) !usize {
        var count: usize = 0;
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{ .iterate = true }) catch return 0;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            const path = try std.fs.path.join(self.allocator, &.{ root, entry.name });
            defer self.allocator.free(path);
            switch (entry.kind) {
                .directory => {
                    if (!isIgnoredDir(entry.name)) count += try self.countWatchableFiles(path);
                },
                .file => {
                    if (isWatchableFile(entry.name)) count += 1;
                },
                else => {},
            }
        }
        return count;
    }

    // True when `path` names a file inside directory `root` (exact prefix on a path
    // boundary), avoiding the false positives a bare `startsWith` produces for sibling
    // directories that share a name prefix (e.g. `/a/app` vs `/a/app-extra`).
    fn isPathUnder(path: []const u8, root: []const u8) bool {
        if (!std.mem.startsWith(u8, path, root)) return false;
        return path.len > root.len and path[root.len] == std.fs.path.sep;
    }

    pub fn refresh(self: *Self) !void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
        }
        self.files.clearRetainingCapacity();

        for (self.watched_dirs.items) |dir| {
            try self.collectFiles(dir);
        }
        for (self.watched_files.items) |path| {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch continue;
            const path_copy = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(path_copy);
            try self.files.append(.{
                .path = path_copy,
                .mtime_ns = stat.mtime.nanoseconds,
                .size = stat.size,
            });
        }
    }
};

test "SourceWatcher detects file modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary directory with a .kira file
    const tmp_path = "/tmp/kira_live_test_app";
    const test_file = "/tmp/kira_live_test_app/main.kira";

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, test_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// initial");
        file.close(std.Options.debug_io);
    }

    var watcher = SourceWatcher.init(allocator);
    defer watcher.deinit();
    try watcher.addDirectory(tmp_path);

    try std.testing.expect(!try watcher.changed());

    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, test_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// modified");
        file.close(std.Options.debug_io);
    }

    try std.testing.expect(try watcher.changed());

    try watcher.refresh();
    try std.testing.expect(!try watcher.changed());
}

test "SourceWatcher does not report a spurious change for nested .kira files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A watched directory whose .kira files live in a subdirectory must not be reported
    // as changed on the first poll. Regression for the live hot-reload crash cascade: the
    // new/deleted-file check counted only the directory's direct .kira children but
    // compared against the recursive tracked set, so any nested layout always looked
    // "changed" and triggered an unwanted reload.
    const tmp_path = "/tmp/kira_live_nested_test_app";
    const nested_dir = "/tmp/kira_live_nested_test_app/components";
    const nested_file = "/tmp/kira_live_nested_test_app/components/widget.kira";

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, nested_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, nested_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// nested");
        file.close(std.Options.debug_io);
    }

    var watcher = SourceWatcher.init(allocator);
    defer watcher.deinit();
    try watcher.addDirectory(tmp_path);

    // No edit yet — must be quiet despite the .kira file living one level down.
    try std.testing.expect(!try watcher.changed());

    // Adding a new nested file is a real change.
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, "/tmp/kira_live_nested_test_app/components/extra.kira", .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// extra");
        file.close(std.Options.debug_io);
    }
    try std.testing.expect(try watcher.changed());
}

test "SourceWatcher watches shader, native, and manifest inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tmp_path = "/tmp/kira_live_inputs_test_app";
    const shader_file = "/tmp/kira_live_inputs_test_app/Shader/effect.ksl";
    const native_file = "/tmp/kira_live_inputs_test_app/impl.c";
    const manifest_file = "/tmp/kira_live_inputs_test_manifest/kira.toml";

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, "/tmp/kira_live_inputs_test_app/Shader");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, "/tmp/kira_live_inputs_test_manifest");
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, "/tmp/kira_live_inputs_test_manifest") catch {};

    for ([_][]const u8{ shader_file, native_file, manifest_file }) |path| {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// v1");
        file.close(std.Options.debug_io);
    }

    var watcher = SourceWatcher.init(allocator);
    defer watcher.deinit();
    try watcher.addDirectory(tmp_path);
    try watcher.addFile(manifest_file);
    try std.testing.expect(!try watcher.changed());

    // Shader edit is a change.
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, shader_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// v2 shader");
        file.close(std.Options.debug_io);
    }
    try std.testing.expect(try watcher.changed());
    try watcher.refresh();
    try std.testing.expect(!try watcher.changed());

    // Native source edit is a change.
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, native_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// v2 native");
        file.close(std.Options.debug_io);
    }
    try std.testing.expect(try watcher.changed());
    try watcher.refresh();
    try std.testing.expect(!try watcher.changed());

    // Watched single file (kira.toml) edit is a change.
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, manifest_file, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "# v2 manifest");
        file.close(std.Options.debug_io);
    }
    try std.testing.expect(try watcher.changed());
}

test "SourceWatcher ignores editor and OS noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tmp_path = "/tmp/kira_live_noise_test_app";
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, "/tmp/kira_live_noise_test_app/main.kira", .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// v1");
        file.close(std.Options.debug_io);
    }

    var watcher = SourceWatcher.init(allocator);
    defer watcher.deinit();
    try watcher.addDirectory(tmp_path);
    try std.testing.expect(!try watcher.changed());

    // Dotfiles, editor backups/swaps, and build-output dirs must not trigger.
    for ([_][]const u8{
        "/tmp/kira_live_noise_test_app/.DS_Store",
        "/tmp/kira_live_noise_test_app/main.kira~",
        "/tmp/kira_live_noise_test_app/.main.kira.swp",
    }) |path| {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "noise");
        file.close(std.Options.debug_io);
    }
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, "/tmp/kira_live_noise_test_app/generated");
    {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, "/tmp/kira_live_noise_test_app/generated/out.kira", .{ .truncate = true });
        try file.writeStreamingAll(std.Options.debug_io, "// generated output");
        file.close(std.Options.debug_io);
    }
    try std.testing.expect(!try watcher.changed());
}
