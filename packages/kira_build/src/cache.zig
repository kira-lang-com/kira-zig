const std = @import("std");
const builtin = @import("builtin");
const build_def = @import("kira_build_definition");
const hybrid = @import("kira_hybrid_definition");
const kira_toolchain = @import("kira_toolchain");

pub const Cache = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,

    pub fn initForSource(allocator: std.mem.Allocator, source_path: []const u8) !Cache {
        const root = try projectRootForSource(allocator, source_path);
        defer allocator.free(root);
        const cache_root = try std.fs.path.join(allocator, &.{ root, ".kira-build" });
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cache_root);
        return .{ .allocator = allocator, .root_path = cache_root };
    }

    pub fn entryForBuild(self: Cache, source_path: []const u8, target: build_def.ExecutionTarget) !Entry {
        const key = try fingerprintBuild(self.allocator, source_path, target);
        defer self.allocator.free(key);
        const backend_dir = backendName(target);
        const root = try std.fs.path.join(self.allocator, &.{ self.root_path, "cache", backend_dir, key });
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, root);
        return Entry.init(self.allocator, root, target);
    }
};

pub const Entry = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    target: build_def.ExecutionTarget,

    fn init(allocator: std.mem.Allocator, root_path: []const u8, target: build_def.ExecutionTarget) Entry {
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .target = target,
        };
    }

    pub fn outputPath(self: Entry) ![]const u8 {
        return switch (self.target) {
            .vm => std.fs.path.join(self.allocator, &.{ self.root_path, "main.kbc" }),
            .llvm_native => std.fs.path.join(self.allocator, &.{ self.root_path, try executableName(self.allocator, "main") }),
            .hybrid => std.fs.path.join(self.allocator, &.{ self.root_path, "main.khm" }),
        };
    }

    pub fn hasArtifacts(self: Entry) bool {
        return switch (self.target) {
            .vm => fileExistsJoin(self.root_path, "main.kbc"),
            .llvm_native => fileExistsJoin(self.root_path, objectName()) and fileExistsJoin(self.root_path, executableNamePage("main")),
            .hybrid => fileExistsJoin(self.root_path, "main.kbc") and
                fileExistsJoin(self.root_path, objectName()) and
                fileExistsJoin(self.root_path, sharedLibraryName()) and
                fileExistsJoin(self.root_path, "main.khm"),
        };
    }

    pub fn hasCheckSuccess(self: Entry) bool {
        return fileExistsJoin(self.root_path, "check.ok");
    }

    pub fn storeCheckSuccess(self: Entry) !void {
        try writeFile(try self.join("check.ok"), "ok\n");
    }

    pub fn restoreTo(self: Entry, output_path: []const u8) ![]build_def.Artifact {
        return switch (self.target) {
            .vm => self.restoreVm(output_path),
            .llvm_native => self.restoreLlvm(output_path),
            .hybrid => self.restoreHybrid(output_path),
        };
    }

    pub fn storeFrom(self: Entry, output_path: []const u8) !void {
        switch (self.target) {
            .vm => try copyFile(output_path, try self.join("main.kbc")),
            .llvm_native => {
                try copyFile(try defaultObjectPath(self.allocator, output_path), try self.join(objectName()));
                try copyFile(output_path, try self.join(executableNamePage("main")));
            },
            .hybrid => {
                try copyFile(try replaceExtension(self.allocator, output_path, ".kbc"), try self.join("main.kbc"));
                try copyFile(try replaceExtension(self.allocator, output_path, objectExtension()), try self.join(objectName()));
                try copyFile(try replaceExtension(self.allocator, output_path, sharedLibraryExtension()), try self.join(sharedLibraryName()));

                var manifest = try hybrid.HybridModuleManifest.readFromFile(self.allocator, output_path);
                manifest.bytecode_path = try self.join("main.kbc");
                manifest.native_library_path = try self.join(sharedLibraryName());
                try manifest.writeToFile(try self.join("main.khm"));
            },
        }
    }

    fn restoreVm(self: Entry, output_path: []const u8) ![]build_def.Artifact {
        try copyFile(try self.join("main.kbc"), output_path);
        const artifacts = try self.allocator.alloc(build_def.Artifact, 1);
        artifacts[0] = .{ .kind = .bytecode, .path = try self.allocator.dupe(u8, output_path) };
        return artifacts;
    }

    fn restoreLlvm(self: Entry, output_path: []const u8) ![]build_def.Artifact {
        const object_path = try defaultObjectPath(self.allocator, output_path);
        try copyFile(try self.join(objectName()), object_path);
        try copyFile(try self.join(executableNamePage("main")), output_path);

        const artifacts = try self.allocator.alloc(build_def.Artifact, 2);
        artifacts[0] = .{ .kind = .native_object, .path = object_path };
        artifacts[1] = .{ .kind = .executable, .path = try self.allocator.dupe(u8, output_path) };
        return artifacts;
    }

    fn restoreHybrid(self: Entry, output_path: []const u8) ![]build_def.Artifact {
        const bytecode_path = try replaceExtension(self.allocator, output_path, ".kbc");
        const object_path = try replaceExtension(self.allocator, output_path, objectExtension());
        const library_path = try replaceExtension(self.allocator, output_path, sharedLibraryExtension());

        try copyFile(try self.join("main.kbc"), bytecode_path);
        try copyFile(try self.join(objectName()), object_path);
        try copyFile(try self.join(sharedLibraryName()), library_path);

        var manifest = try hybrid.HybridModuleManifest.readFromFile(self.allocator, try self.join("main.khm"));
        manifest.bytecode_path = bytecode_path;
        manifest.native_library_path = library_path;
        try manifest.writeToFile(output_path);

        const artifacts = try self.allocator.alloc(build_def.Artifact, 4);
        artifacts[0] = .{ .kind = .bytecode, .path = bytecode_path };
        artifacts[1] = .{ .kind = .hybrid_manifest, .path = try self.allocator.dupe(u8, output_path) };
        artifacts[2] = .{ .kind = .native_object, .path = object_path };
        artifacts[3] = .{ .kind = .native_library, .path = library_path };
        return artifacts;
    }

    fn join(self: Entry, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, name });
    }
};

fn fingerprintBuild(allocator: std.mem.Allocator, source_path: []const u8, target: build_def.ExecutionTarget) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("kira-build-cache-v1\n");
    hasher.update(@tagName(target));
    hasher.update("\n");
    hasher.update(@tagName(builtin.cpu.arch));
    hasher.update("-");
    hasher.update(@tagName(builtin.os.tag));
    hasher.update("-");
    hasher.update(@tagName(builtin.abi));
    hasher.update("\n");
    try hashCompilerIdentity(allocator, &hasher);
    if (kira_toolchain.envVarOwned(allocator, "KIRA_LLVM_HOME")) |value| {
        defer allocator.free(value);
        hasher.update("KIRA_LLVM_HOME=");
        hasher.update(value);
        hasher.update("\n");
    } else |_| {}

    const files = try inputFiles(allocator, source_path);
    defer allocator.free(files);
    for (files) |path| {
        hasher.update(path);
        hasher.update("\n");
        const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(contents);
        hasher.update(contents);
        hasher.update("\n");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexDigest(allocator, &digest);
}

fn hashCompilerIdentity(allocator: std.mem.Allocator, hasher: anytype) !void {
    const exe_path = std.process.executablePathAlloc(std.Options.debug_io, allocator) catch return;
    defer allocator.free(exe_path);
    const stat = if (std.fs.path.isAbsolute(exe_path))
        std.Io.Dir.cwd().statFile(std.Options.debug_io, exe_path, .{}) catch return
    else
        std.Io.Dir.cwd().statFile(std.Options.debug_io, exe_path, .{}) catch return;

    hasher.update("compiler=");
    hasher.update(exe_path);
    hasher.update("\n");
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "size={d};mtime={d}\n", .{ stat.size, stat.mtime });
    hasher.update(text);
}

fn inputFiles(allocator: std.mem.Allocator, source_path: []const u8) ![]const []const u8 {
    var files = std.array_list.Managed([]const u8).init(allocator);
    const root = try projectRootForSource(allocator, source_path);
    defer allocator.free(root);
    try collectInputs(allocator, root, "", &files);
    if (files.items.len == 0) {
        try files.append(try absolutize(allocator, source_path));
    }
    sortStrings(files.items);
    return files.toOwnedSlice();
}

fn collectInputs(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
    files: *std.array_list.Managed([]const u8),
) !void {
    const dir_path = if (relative.len == 0) root else try std.fs.path.join(allocator, &.{ root, relative });
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind == .directory) {
            if (skipDirectory(entry.name)) continue;
            const child_rel = if (relative.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ relative, entry.name });
            try collectInputs(allocator, root, child_rel, files);
            continue;
        }
        if (entry.kind != .file or !isInputFile(entry.name)) continue;
        const rel_path = if (relative.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ relative, entry.name });
        const full_path = try std.fs.path.join(allocator, &.{ root, rel_path });
        try files.append(try absolutize(allocator, full_path));
    }
}

fn projectRootForSource(allocator: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    const absolute = try absolutize(allocator, source_path);
    defer allocator.free(absolute);
    var current = try allocator.dupe(u8, std.fs.path.dirname(absolute) orelse ".");
    errdefer allocator.free(current);

    while (true) {
        if (hasProjectManifest(current) and sourceBelongsToProject(allocator, current, absolute)) return current;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }

    allocator.free(current);
    return allocator.dupe(u8, std.fs.path.dirname(absolute) orelse ".");
}

fn hasProjectManifest(path: []const u8) bool {
    return fileExistsAt(path, "kira.toml") or fileExistsAt(path, "project.toml") or fileExistsAt(path, "Kira.toml");
}

fn sourceBelongsToProject(allocator: std.mem.Allocator, root: []const u8, source_path: []const u8) bool {
    const app_root = std.fs.path.join(allocator, &.{ root, "app" }) catch return false;
    defer allocator.free(app_root);
    return pathStartsWith(source_path, app_root);
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    const next = path[prefix.len];
    return next == std.fs.path.sep or next == '/' or next == '\\';
}

fn skipDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".kira-build") or
        std.mem.eql(u8, name, ".kira") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "generated");
}

fn isInputFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.mem.eql(u8, ext, ".kira") or
        std.mem.eql(u8, ext, ".toml") or
        std.mem.eql(u8, ext, ".ksl") or
        std.mem.eql(u8, ext, ".c") or
        std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".m") or
        std.mem.eql(u8, ext, ".mm");
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
}

fn copyFile(source_path: []const u8, destination_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_path, std.heap.page_allocator, .limited(256 * 1024 * 1024));
    defer std.heap.page_allocator.free(data);
    try ensureParentDir(destination_path);
    const file = if (std.fs.path.isAbsolute(destination_path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, destination_path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, destination_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try ensureParentDir(path);
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, data);
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
}

fn fileExistsAt(root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    return fileExists(path);
}

fn fileExistsJoin(root: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    return fileExists(path);
}

fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator);
}

fn hexDigest(allocator: std.mem.Allocator, digest: []const u8) ![]const u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn backendName(target: build_def.ExecutionTarget) []const u8 {
    return switch (target) {
        .vm => "vm",
        .llvm_native => "llvm",
        .hybrid => "hybrid",
    };
}

fn objectName() []const u8 {
    return if (builtin.os.tag == .windows) "main.obj" else "main.o";
}

fn objectExtension() []const u8 {
    return if (builtin.os.tag == .windows) ".obj" else ".o";
}

fn executableNamePage(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

fn executableName(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return if (builtin.os.tag == .windows) std.fmt.allocPrint(allocator, "{s}.exe", .{base}) else allocator.dupe(u8, base);
}

fn sharedLibraryName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "main.dll",
        .macos => "main.dylib",
        else => "main.so",
    };
}

fn sharedLibraryExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn defaultObjectPath(allocator: std.mem.Allocator, executable_path: []const u8) ![]const u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    if (ext.len > 0 and std.mem.endsWith(u8, executable_path, ext)) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ executable_path[0 .. executable_path.len - ext.len], objectExtension() });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ executable_path, objectExtension() });
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, extension });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - ext.len], extension });
}
