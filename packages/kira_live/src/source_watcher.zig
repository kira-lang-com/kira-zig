const std = @import("std");

pub const FileState = struct {
    path: []const u8,
    mtime_ns: i96,
    size: u64,
};

pub const SourceWatcher = struct {
    allocator: std.mem.Allocator,
    watched_dirs: std.array_list.Managed([]const u8),
    files: std.array_list.Managed(FileState),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .watched_dirs = std.array_list.Managed([]const u8).init(allocator),
            .files = std.array_list.Managed(FileState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.watched_dirs.items) |dir| {
            self.allocator.free(dir);
        }
        self.watched_dirs.deinit();
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

    fn collectFiles(self: *Self, root: []const u8) !void {
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{ .iterate = true }) catch return;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            const path = try std.fs.path.join(self.allocator, &.{ root, entry.name });
            defer self.allocator.free(path);

            switch (entry.kind) {
                .directory => try self.collectFiles(path),
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".kira")) {
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
        // Count every `.kira` file under `root` *recursively*, then compare against the
        // recursive count of tracked files under `root`. The two counts must be gathered
        // the same way: an earlier version counted only direct children here but compared
        // against the recursive tracked set, so any watched directory containing a
        // subdirectory with `.kira` files reported a spurious change on the very first
        // poll — triggering an unwanted hot reload (and the crashes that cascade from it).
        const found = try self.countKiraFiles(root);

        var tracked_in_dir: usize = 0;
        for (self.files.items) |file| {
            if (isPathUnder(file.path, root)) tracked_in_dir += 1;
        }

        return found != tracked_in_dir;
    }

    fn countKiraFiles(self: *Self, root: []const u8) !usize {
        var count: usize = 0;
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, root, .{ .iterate = true }) catch return 0;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            const path = try std.fs.path.join(self.allocator, &.{ root, entry.name });
            defer self.allocator.free(path);
            switch (entry.kind) {
                .directory => count += try self.countKiraFiles(path),
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".kira")) count += 1;
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
