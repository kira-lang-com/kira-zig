const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const manifest = @import("kira_manifest");
const kira_toolchain = @import("kira_toolchain");
const types = @import("types.zig");
const diag = @import("diagnostics.zig");
const git = @import("git.zig");
const registry_fetch = @import("registry_fetch.zig");

pub fn syncProject(
    allocator: std.mem.Allocator,
    path: []const u8,
    toolchain_version: []const u8,
    options: types.SyncOptions,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !types.SyncResult {
    const resolved = try resolveProjectPaths(allocator, path);
    defer allocator.free(resolved.root_path);
    defer allocator.free(resolved.manifest_path);
    defer allocator.free(resolved.lockfile_path);

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, resolved.manifest_path, allocator, .limited(2 * 1024 * 1024));
    const project_manifest = manifest.parseProjectManifest(allocator, manifest_text) catch |err| switch (err) {
        error.UnsupportedVersionRange => {
            try diag.append(allocator, out_diagnostics, "KPKG007", "unsupported version range", "Kira package management v1 only supports exact registry versions.", "Use an exact version such as \"0.1.0\".");
            return error.DiagnosticsEmitted;
        },
        else => return err,
    };

    const existing_lockfile = loadLockfileIfPresent(allocator, resolved.lockfile_path) catch null;
    if (options.locked and existing_lockfile == null) {
        try diag.append(allocator, out_diagnostics, "KPKG011", "lockfile is required", "Locked mode requires an existing kira.lock file for deterministic restoration.", "Run `kira sync` first to create kira.lock.");
        return error.DiagnosticsEmitted;
    }

    if (options.locked and existing_lockfile != null and !rootMatchesLock(project_manifest, existing_lockfile.?)) {
        try diag.append(allocator, out_diagnostics, "KPKG010", "lockfile is out of sync", "The current manifest does not match the locked dependency set.", "Run `kira sync` to refresh kira.lock, or use `kira sync --locked` only after the manifest is unchanged.");
        return error.DiagnosticsEmitted;
    }

    var resolver = Resolver{
        .allocator = allocator,
        .toolchain_version = toolchain_version,
        .options = options,
        .diagnostics = out_diagnostics,
        .lockfile = existing_lockfile,
        .root_manifest = project_manifest,
        .root_path = resolved.root_path,
    };
    const graph = try resolver.resolve();

    const lockfile = try buildLockfile(allocator, project_manifest, graph);
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try manifest.writeLockFile(&buffer.writer, lockfile);
    const rendered = buffer.written();

    var changed = true;
    if (fileExists(resolved.lockfile_path)) {
        const existing = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, resolved.lockfile_path, allocator, .limited(2 * 1024 * 1024));
        changed = !std.mem.eql(u8, existing, rendered);
    }
    if (!options.locked and changed) {
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, resolved.lockfile_path, .{ .truncate = true });
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, rendered);
    }

    return .{
        .graph = graph,
        .lockfile = lockfile,
        .changed = changed,
    };
}

pub fn loadModuleMapForSource(allocator: std.mem.Allocator, source_path: []const u8) !types.ModuleMap {
    const project_root = try discoverProjectRootFromSource(allocator, source_path) orelse return .{ .owners = &.{} };
    defer allocator.free(project_root);

    var owners = std.array_list.Managed(types.ModuleMap.ModuleOwner).init(allocator);
    try appendCurrentProjectOwner(allocator, &owners, project_root);
    try appendBundledFoundationOwner(allocator, &owners, source_path);

    const lockfile_path = try std.fs.path.join(allocator, &.{ project_root, "kira.lock" });
    defer allocator.free(lockfile_path);
    if (!fileExists(lockfile_path)) return .{ .owners = try owners.toOwnedSlice() };

    const lockfile_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, lockfile_path, allocator, .limited(2 * 1024 * 1024));
    const lockfile = try manifest.parseLockFile(allocator, lockfile_text);

    for (lockfile.packages) |item| {
        const source_root = switch (item.source) {
            .registry => |registry| blk: {
                const package_root = try registry_fetch.ensureRegistrySource(allocator, registry.archive_path, registry.checksum, true);
                break :blk try discoverModuleSourceRoot(allocator, package_root);
            },
            .path => |path_source| try discoverModuleSourceRoot(allocator, path_source.path),
            .git => |git_source| blk: {
                const checkout = try git.resolveGitCheckout(allocator, git_source.url, null, null, true, git_source.commit);
                break :blk try discoverModuleSourceRoot(allocator, checkout.source_root);
            },
        };
        try owners.append(.{
            .module_root = item.module_root,
            .package_name = item.name,
            .source_root = source_root,
        });
    }
    return .{ .owners = try owners.toOwnedSlice() };
}

fn appendCurrentProjectOwner(
    allocator: std.mem.Allocator,
    owners: *std.array_list.Managed(types.ModuleMap.ModuleOwner),
    project_root: []const u8,
) !void {
    const loaded = loadPackageManifest(allocator, project_root) catch return;
    const module_root = loaded.manifest.module_root orelse loaded.manifest.name;
    try owners.append(.{
        .module_root = module_root,
        .package_name = loaded.manifest.name,
        .source_root = loaded.module_source_root,
    });
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    toolchain_version: []const u8,
    options: types.SyncOptions,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    lockfile: ?manifest.LockFile,
    root_manifest: manifest.ProjectManifest,
    root_path: []const u8,
    packages: std.array_list.Managed(types.ResolvedPackage) = undefined,
    package_keys: std.StringHashMap(void) = undefined,
    module_roots: std.StringHashMap([]const u8) = undefined,
    stack: std.array_list.Managed([]const u8) = undefined,

    fn resolve(self: *Resolver) anyerror!types.ResolvedGraph {
        self.packages = std.array_list.Managed(types.ResolvedPackage).init(self.allocator);
        self.package_keys = std.StringHashMap(void).init(self.allocator);
        self.module_roots = std.StringHashMap([]const u8).init(self.allocator);
        self.stack = std.array_list.Managed([]const u8).init(self.allocator);

        try validateToolchain(self.allocator, self.diagnostics, self.toolchain_version, self.root_manifest.kira_version, self.root_manifest.name);

        for (self.root_manifest.dependencies) |dep_spec| {
            try self.resolveDependency(dep_spec, self.root_path);
        }
        return .{ .packages = try self.packages.toOwnedSlice() };
    }

    fn resolveDependency(self: *Resolver, dep_spec: manifest.DependencySpec, parent_root: []const u8) anyerror!void {
        switch (dep_spec.source) {
            .path => |path_source| try self.resolvePath(dep_spec.name, path_source.path, parent_root),
            .registry => |registry_source| try self.resolveRegistry(dep_spec.name, registry_source.version),
            .git => |git_source| try self.resolveGit(dep_spec.name, git_source.url, git_source.rev, git_source.tag),
        }
    }

    fn resolvePath(self: *Resolver, name: []const u8, relative_path: []const u8, parent_root: []const u8) anyerror!void {
        const abs_path = canonicalizePath(self.allocator, parent_root, relative_path) catch |err| switch (err) {
            error.FileNotFound => {
                try emitMissingPathDependencyDiagnostic(self.allocator, self.diagnostics, name, relative_path, parent_root);
                return error.DiagnosticsEmitted;
            },
            else => return err,
        };
        defer self.allocator.free(abs_path);
        const key = try std.fmt.allocPrint(self.allocator, "path|{s}", .{abs_path});
        defer self.allocator.free(key);
        if (self.package_keys.contains(key)) return;

        try self.pushStack(key);
        defer self.popStack();

        const loaded = loadPackageManifest(self.allocator, abs_path) catch |err| switch (err) {
            error.ProjectManifestNotFound => {
                try emitMissingPathManifestDiagnostic(self.allocator, self.diagnostics, name, abs_path);
                return error.DiagnosticsEmitted;
            },
            error.FileNotFound => {
                try emitMissingPathDependencyDiagnostic(self.allocator, self.diagnostics, name, relative_path, parent_root);
                return error.DiagnosticsEmitted;
            },
            else => return err,
        };
        try validateToolchain(self.allocator, self.diagnostics, self.toolchain_version, loaded.manifest.kira_version, loaded.manifest.name);
        if (!std.mem.eql(u8, loaded.manifest.name, name)) return error.InvalidManifest;

        const module_root = loaded.manifest.module_root orelse loaded.manifest.name;
        try self.ensureModuleRootUnique(module_root, name);

        try self.package_keys.put(try self.allocator.dupe(u8, key), {});
        try self.packages.append(.{
            .name = loaded.manifest.name,
            .version = loaded.manifest.version,
            .kind = @tagName(loaded.manifest.kind),
            .kira_version = loaded.manifest.kira_version,
            .module_root = module_root,
            .source_root = loaded.module_source_root,
            .source = .{ .path = .{ .path = loaded.root_path } },
            .dependencies = loaded.manifest.dependencies,
        });

        for (loaded.manifest.dependencies) |dep_spec| try self.resolveDependency(dep_spec, loaded.root_path);
    }

    fn resolveRegistry(self: *Resolver, name: []const u8, version: []const u8) anyerror!void {
        const registry_url = self.options.registry_url_override orelse self.root_manifest.registry_url orelse default_registry_url;
        const key = try std.fmt.allocPrint(self.allocator, "registry|{s}|{s}|{s}", .{ registry_url, name, version });
        defer self.allocator.free(key);
        if (self.package_keys.contains(key)) return;

        try self.pushStack(key);
        defer self.popStack();

        var archive_url: []const u8 = undefined;
        var checksum: []const u8 = undefined;
        if (findLockedRegistry(self.lockfile, name, version, registry_url)) |locked| {
            archive_url = locked.archive_path;
            checksum = locked.checksum;
        } else {
            if (self.options.offline or self.options.locked) return error.RegistryMetadataUnavailableOffline;
            const resolved = try registry_fetch.fetchPackageVersion(self.allocator, registry_url, name, version);
            archive_url = resolved.archive_url;
            checksum = resolved.version.checksum;
        }

        const source_root = try registry_fetch.ensureRegistrySource(self.allocator, archive_url, checksum, self.options.offline);
        const loaded = try loadPackageManifest(self.allocator, source_root);
        if (!std.mem.eql(u8, loaded.manifest.name, name)) return error.InvalidManifest;
        if (!std.mem.eql(u8, loaded.manifest.version, version)) return error.InvalidManifest;
        try validateToolchain(self.allocator, self.diagnostics, self.toolchain_version, loaded.manifest.kira_version, loaded.manifest.name);

        const module_root = loaded.manifest.module_root orelse loaded.manifest.name;
        try self.ensureModuleRootUnique(module_root, name);

        try self.package_keys.put(try self.allocator.dupe(u8, key), {});
        try self.packages.append(.{
            .name = loaded.manifest.name,
            .version = loaded.manifest.version,
            .kind = @tagName(loaded.manifest.kind),
            .kira_version = loaded.manifest.kira_version,
            .module_root = module_root,
            .source_root = loaded.module_source_root,
            .source = .{ .registry = .{
                .registry_url = registry_url,
                .archive_path = archive_url,
                .checksum = checksum,
            } },
            .dependencies = loaded.manifest.dependencies,
        });

        for (loaded.manifest.dependencies) |dep_spec| try self.resolveDependency(dep_spec, source_root);
    }

    fn resolveGit(self: *Resolver, name: []const u8, url: []const u8, rev: ?[]const u8, tag: ?[]const u8) anyerror!void {
        const locked_commit = findLockedGitCommit(self.lockfile, name, url, rev, tag);
        const checkout = try git.resolveGitCheckout(
            self.allocator,
            url,
            rev,
            tag,
            self.options.offline,
            if (self.options.update_git) null else locked_commit,
        );
        const key = try std.fmt.allocPrint(self.allocator, "git|{s}|{s}", .{ url, checkout.commit });
        defer self.allocator.free(key);
        if (self.package_keys.contains(key)) return;

        try self.pushStack(key);
        defer self.popStack();

        const loaded = try loadPackageManifest(self.allocator, checkout.source_root);
        if (!std.mem.eql(u8, loaded.manifest.name, name)) return error.InvalidManifest;
        try validateToolchain(self.allocator, self.diagnostics, self.toolchain_version, loaded.manifest.kira_version, loaded.manifest.name);

        const module_root = loaded.manifest.module_root orelse loaded.manifest.name;
        try self.ensureModuleRootUnique(module_root, name);

        try self.package_keys.put(try self.allocator.dupe(u8, key), {});
        try self.packages.append(.{
            .name = loaded.manifest.name,
            .version = loaded.manifest.version,
            .kind = @tagName(loaded.manifest.kind),
            .kira_version = loaded.manifest.kira_version,
            .module_root = module_root,
            .source_root = loaded.module_source_root,
            .source = .{ .git = .{
                .url = url,
                .commit = checkout.commit,
                .requested_rev = rev,
                .requested_tag = tag,
            } },
            .dependencies = loaded.manifest.dependencies,
        });

        for (loaded.manifest.dependencies) |dep_spec| try self.resolveDependency(dep_spec, checkout.source_root);
    }

    fn ensureModuleRootUnique(self: *Resolver, module_root: []const u8, package_name: []const u8) anyerror!void {
        if (self.module_roots.get(module_root)) |existing| {
            if (!std.mem.eql(u8, existing, package_name)) return error.ModuleRootConflict;
            return;
        }
        try self.module_roots.put(module_root, package_name);
    }

    fn pushStack(self: *Resolver, key: []const u8) anyerror!void {
        for (self.stack.items) |item| {
            if (std.mem.eql(u8, item, key)) return error.DependencyCycleDetected;
        }
        try self.stack.append(try self.allocator.dupe(u8, key));
    }

    fn popStack(self: *Resolver) void {
        _ = self.stack.pop();
    }
};

const LoadedPackageManifest = struct {
    root_path: []const u8,
    module_source_root: []const u8,
    manifest_path: []const u8,
    manifest: manifest.ProjectManifest,
};

const ResolvedProjectPaths = struct {
    root_path: []const u8,
    manifest_path: []const u8,
    lockfile_path: []const u8,
};

fn resolveProjectPaths(allocator: std.mem.Allocator, path: []const u8) !ResolvedProjectPaths {
    const root_path = if (isDirectory(path))
        try absolutize(allocator, path)
    else if (isManifestPath(path))
        try absolutize(allocator, std.fs.path.dirname(path) orelse ".")
    else
        try absolutize(allocator, ".");
    errdefer allocator.free(root_path);

    const manifest_path = try discoverManifestPath(allocator, root_path) orelse return error.ProjectManifestNotFound;
    errdefer allocator.free(manifest_path);
    const lockfile_path = try std.fs.path.join(allocator, &.{ root_path, "kira.lock" });
    return .{
        .root_path = root_path,
        .manifest_path = manifest_path,
        .lockfile_path = lockfile_path,
    };
}

fn loadPackageManifest(allocator: std.mem.Allocator, root_path: []const u8) !LoadedPackageManifest {
    var actual_root = try allocator.dupe(u8, root_path);
    errdefer allocator.free(actual_root);
    var manifest_path = try discoverManifestPath(allocator, actual_root);
    if (manifest_path == null) {
        if (try discoverNestedPackageRoot(allocator, actual_root)) |nested_root| {
            allocator.free(actual_root);
            actual_root = nested_root;
            manifest_path = try discoverManifestPath(allocator, actual_root);
        }
    }
    const resolved_manifest_path = manifest_path orelse return error.ProjectManifestNotFound;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, resolved_manifest_path, allocator, .limited(2 * 1024 * 1024));
    const parsed = try manifest.parseProjectManifest(allocator, text);
    const module_source_root = try discoverModuleSourceRoot(allocator, actual_root);
    return .{
        .root_path = actual_root,
        .module_source_root = module_source_root,
        .manifest_path = resolved_manifest_path,
        .manifest = parsed,
    };
}

fn buildLockfile(
    allocator: std.mem.Allocator,
    root_manifest: manifest.ProjectManifest,
    graph: types.ResolvedGraph,
) !manifest.LockFile {
    var root_dependencies = std.array_list.Managed(manifest.LockFile.RootDependency).init(allocator);
    for (root_manifest.dependencies) |dep_spec| {
        try root_dependencies.append(.{
            .name = dep_spec.name,
            .source = dep_spec.source,
        });
    }

    var packages = std.array_list.Managed(manifest.LockFile.LockedPackage).init(allocator);
    for (graph.packages) |pkg| {
        var dependency_names = std.array_list.Managed([]const u8).init(allocator);
        for (pkg.dependencies) |dep_spec| try dependency_names.append(dep_spec.name);

        try packages.append(.{
            .name = pkg.name,
            .version = pkg.version,
            .kind = pkg.kind,
            .kira_version = pkg.kira_version,
            .module_root = pkg.module_root,
            .source = switch (pkg.source) {
                .registry => |registry_source| .{ .registry = .{
                    .registry_url = registry_source.registry_url,
                    .archive_path = registry_source.archive_path,
                    .checksum = registry_source.checksum,
                } },
                .path => |path_source| .{ .path = .{
                    .path = path_source.path,
                } },
                .git => |git_source| .{ .git = .{
                    .url = git_source.url,
                    .commit = git_source.commit,
                    .requested_rev = git_source.requested_rev,
                    .requested_tag = git_source.requested_tag,
                } },
            },
            .dependencies = try dependency_names.toOwnedSlice(),
        });
    }

    return .{
        .schema_version = 1,
        .root = .{
            .name = root_manifest.name,
            .version = root_manifest.version,
            .kind = @tagName(root_manifest.kind),
            .kira_version = root_manifest.kira_version,
            .dependencies = try root_dependencies.toOwnedSlice(),
        },
        .packages = try packages.toOwnedSlice(),
    };
}

fn rootMatchesLock(project_manifest: manifest.ProjectManifest, lockfile: manifest.LockFile) bool {
    if (!std.mem.eql(u8, project_manifest.name, lockfile.root.name)) return false;
    if (!std.mem.eql(u8, project_manifest.version, lockfile.root.version)) return false;
    if (!std.mem.eql(u8, @tagName(project_manifest.kind), lockfile.root.kind)) return false;
    if (!std.mem.eql(u8, project_manifest.kira_version, lockfile.root.kira_version)) return false;
    if (project_manifest.dependencies.len != lockfile.root.dependencies.len) return false;

    for (project_manifest.dependencies) |dep_spec| {
        var matched = false;
        for (lockfile.root.dependencies) |locked| {
            if (std.mem.eql(u8, dep_spec.name, locked.name) and dependencySourceMatches(dep_spec.source, locked.source)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

fn dependencySourceMatches(lhs: manifest.DependencySpec.Source, rhs: manifest.DependencySpec.Source) bool {
    return switch (lhs) {
        .registry => |left| rhs == .registry and std.mem.eql(u8, left.version, rhs.registry.version),
        .path => |left| rhs == .path and std.mem.eql(u8, left.path, rhs.path.path),
        .git => |left| rhs == .git and std.mem.eql(u8, left.url, rhs.git.url) and
            optionalEql(left.rev, rhs.git.rev) and optionalEql(left.tag, rhs.git.tag),
    };
}

fn optionalEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn validateToolchain(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    current_version: []const u8,
    required_version: []const u8,
    package_name: []const u8,
) !void {
    const current = std.SemanticVersion.parse(current_version) catch return;
    const required = std.SemanticVersion.parse(required_version) catch return;
    if (std.SemanticVersion.order(current, required) == .lt) {
        const message = try std.fmt.allocPrint(
            allocator,
            "Package `{s}` requires Kira {s}, but the active toolchain is {s}.",
            .{ package_name, required_version, current_version },
        );
        try diag.append(allocator, out_diagnostics, "KPKG009", "package requires a newer Kira toolchain", message, "Update the toolchain or choose a compatible package version.");
        return error.DiagnosticsEmitted;
    }
}

fn findLockedRegistry(
    lockfile: ?manifest.LockFile,
    name: []const u8,
    version: []const u8,
    registry_url: []const u8,
) ?manifest.LockFile.LockedPackage.RegistrySource {
    const value = lockfile orelse return null;
    for (value.packages) |pkg| {
        if (!std.mem.eql(u8, pkg.name, name)) continue;
        if (!std.mem.eql(u8, pkg.version, version)) continue;
        if (pkg.source != .registry) continue;
        if (!std.mem.eql(u8, pkg.source.registry.registry_url, registry_url)) continue;
        return pkg.source.registry;
    }
    return null;
}

fn findLockedGitCommit(
    lockfile: ?manifest.LockFile,
    name: []const u8,
    url: []const u8,
    requested_rev: ?[]const u8,
    requested_tag: ?[]const u8,
) ?[]const u8 {
    const value = lockfile orelse return null;
    for (value.packages) |pkg| {
        if (!std.mem.eql(u8, pkg.name, name)) continue;
        if (pkg.source != .git) continue;
        if (!std.mem.eql(u8, pkg.source.git.url, url)) continue;
        if (!optionalEql(pkg.source.git.requested_rev, requested_rev)) continue;
        if (!optionalEql(pkg.source.git.requested_tag, requested_tag)) continue;
        return pkg.source.git.commit;
    }
    return null;
}

fn loadLockfileIfPresent(allocator: std.mem.Allocator, lockfile_path: []const u8) !?manifest.LockFile {
    if (!fileExists(lockfile_path)) return null;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, lockfile_path, allocator, .limited(2 * 1024 * 1024));
    return try manifest.parseLockFile(allocator, text);
}

fn discoverProjectRootFromSource(allocator: std.mem.Allocator, source_path: []const u8) !?[]u8 {
    const source_dir = try absolutize(allocator, std.fs.path.dirname(source_path) orelse ".");
    defer allocator.free(source_dir);
    const canonical_source = try absolutize(allocator, source_path);
    defer allocator.free(canonical_source);

    var current = try allocator.dupe(u8, source_dir);
    errdefer allocator.free(current);
    while (true) {
        if ((try discoverManifestPath(allocator, current)) != null) {
            const app_root = try std.fs.path.join(allocator, &.{ current, "app" });
            defer allocator.free(app_root);
            if (std.mem.eql(u8, current, source_dir) or pathWithinRoot(canonical_source, app_root)) return current;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = copy;
    }
    allocator.free(current);
    return null;
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path[root.len] == '/' or path[root.len] == '\\';
}

fn discoverManifestPath(allocator: std.mem.Allocator, root_path: []const u8) !?[]u8 {
    const candidates = [_][]const u8{ "kira.toml", "project.toml", "Kira.toml" };
    for (candidates) |name| {
        const path = try std.fs.path.join(allocator, &.{ root_path, name });
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn discoverNestedPackageRoot(allocator: std.mem.Allocator, root_path: []const u8) !?[]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, root_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var iterator = dir.iterate();
    var only_directory: ?[]const u8 = null;
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (only_directory != null) return null;
        only_directory = try std.fs.path.join(allocator, &.{ root_path, entry.name });
    }
    const candidate = only_directory orelse return null;
    if ((try discoverManifestPath(allocator, candidate)) != null) return try allocator.dupe(u8, candidate);
    allocator.free(candidate);
    return null;
}

fn discoverModuleSourceRoot(allocator: std.mem.Allocator, package_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ package_root, "app" });
}

fn canonicalizePath(allocator: std.mem.Allocator, parent_root: []const u8, relative: []const u8) ![]u8 {
    const joined = if (std.fs.path.isAbsolute(relative))
        try allocator.dupe(u8, relative)
    else
        try std.fs.path.join(allocator, &.{ parent_root, relative });
    defer allocator.free(joined);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, joined, allocator);
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, allocator);
}

fn isDirectory(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

fn isManifestPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "kira.toml") or std.mem.eql(u8, base, "project.toml") or std.mem.eql(u8, base, "Kira.toml");
}

fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn directoryExists(path: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    dir.close(std.Options.debug_io);
    return true;
}

const default_registry_url = "https://registry.kira.sh";

fn emitMissingPathDependencyDiagnostic(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    name: []const u8,
    relative_path: []const u8,
    parent_root: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "Path dependency `{s}` could not be found at `{s}` relative to `{s}`.",
        .{ name, relative_path, parent_root },
    );
    const help = try std.fmt.allocPrint(
        allocator,
        "Check the dependency path or point it at the package root directory that contains `kira.toml`.",
        .{},
    );
    try diag.append(allocator, out_diagnostics, "KPKG001", "path dependency not found", message, help);
}

fn emitMissingPathManifestDiagnostic(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    name: []const u8,
    abs_path: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "Path dependency `{s}` does not contain a `kira.toml` or legacy `project.toml` manifest at `{s}`.",
        .{ name, abs_path },
    );
    try diag.append(
        allocator,
        out_diagnostics,
        "KPKG002",
        "path dependency manifest not found",
        message,
        "Point the dependency at the package root directory.",
    );
}

fn appendBundledFoundationOwner(
    allocator: std.mem.Allocator,
    owners: *std.array_list.Managed(types.ModuleMap.ModuleOwner),
    source_path: []const u8,
) !void {
    const foundation_root = try discoverBundledFoundationRoot(allocator, source_path) orelse return;
    const foundation_source_root = try discoverModuleSourceRoot(allocator, foundation_root);
    try owners.append(.{
        .module_root = "Foundation",
        .package_name = "Foundation",
        .source_root = foundation_source_root,
    });
}

fn discoverBundledFoundationRoot(allocator: std.mem.Allocator, source_path: []const u8) !?[]u8 {
    if (try kira_toolchain.toolchainRootFromSelfExecutable(allocator)) |toolchain_root| {
        defer allocator.free(toolchain_root);
        const foundation_root = try std.fs.path.join(allocator, &.{ toolchain_root, "foundation" });
        const foundation_manifest = try std.fs.path.join(allocator, &.{ foundation_root, "kira.toml" });
        defer allocator.free(foundation_manifest);
        if (fileExists(foundation_manifest)) return foundation_root;
        allocator.free(foundation_root);
    }

    if (try findRepoRootFromPath(allocator, std.fs.path.dirname(source_path) orelse ".")) |repo_root| {
        defer allocator.free(repo_root);
        if (try foundationRootFromRepoRoot(allocator, repo_root)) |foundation_root| return foundation_root;
    }

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    if (try findRepoRootFromPath(allocator, cwd)) |repo_root| {
        defer allocator.free(repo_root);
        if (try foundationRootFromRepoRoot(allocator, repo_root)) |foundation_root| return foundation_root;
    }

    const exe_path = try std.process.executablePathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(exe_path);
    if (try findRepoRootFromPath(allocator, std.fs.path.dirname(exe_path) orelse ".")) |repo_root| {
        defer allocator.free(repo_root);
        if (try foundationRootFromRepoRoot(allocator, repo_root)) |foundation_root| return foundation_root;
    }

    return null;
}

fn foundationRootFromRepoRoot(allocator: std.mem.Allocator, repo_root: []const u8) !?[]u8 {
    const foundation_root = try std.fs.path.join(allocator, &.{ repo_root, "foundation" });
    errdefer allocator.free(foundation_root);
    const foundation_manifest = try std.fs.path.join(allocator, &.{ foundation_root, "kira.toml" });
    defer allocator.free(foundation_manifest);
    if (!fileExists(foundation_manifest)) return null;
    return foundation_root;
}

fn findRepoRootFromPath(allocator: std.mem.Allocator, start_path: []const u8) !?[]u8 {
    var current = try absolutize(allocator, start_path);
    errdefer allocator.free(current);

    while (true) {
        const build_path = try std.fs.path.join(allocator, &.{ current, "build.zig" });
        defer allocator.free(build_path);
        if (fileExists(build_path)) return current;

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = copy;
    }

    allocator.free(current);
    return null;
}
