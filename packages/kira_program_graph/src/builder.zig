const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const syntax = @import("kira_syntax_model");
const package_manager = @import("kira_package_manager");
const imports = @import("imports.zig");
const paths = @import("paths.zig");

pub const ProgramGraph = struct {
    program: syntax.ast.Program,
};

pub fn buildProgramGraph(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    root_program: syntax.ast.Program,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    var visited = std.StringHashMap(void).init(allocator);
    var import_list = std.array_list.Managed(syntax.ast.ImportDecl).init(allocator);
    var decls = std.array_list.Managed(syntax.ast.Decl).init(allocator);
    var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(allocator);

    try appendProgramGraph(allocator, &visited, &import_list, &decls, &functions, source_path, root_program, module_map, diags);

    return .{
        .imports = try import_list.toOwnedSlice(),
        .decls = try decls.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
    };
}

pub fn buildProgramGraphFromFiles(
    allocator: std.mem.Allocator,
    source_paths: [][]u8,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    var visited = std.StringHashMap(void).init(allocator);
    var import_list = std.array_list.Managed(syntax.ast.ImportDecl).init(allocator);
    var decls = std.array_list.Managed(syntax.ast.Decl).init(allocator);
    var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(allocator);

    for (source_paths) |source_path| {
        const program = try parseModuleProgram(allocator, source_path, diags);
        try appendProgramGraph(allocator, &visited, &import_list, &decls, &functions, source_path, program, module_map, diags);
    }

    return .{
        .imports = try import_list.toOwnedSlice(),
        .decls = try decls.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
    };
}

fn appendProgramGraph(
    allocator: std.mem.Allocator,
    visited: *std.StringHashMap(void),
    import_list: *std.array_list.Managed(syntax.ast.ImportDecl),
    decls: *std.array_list.Managed(syntax.ast.Decl),
    functions: *std.array_list.Managed(syntax.ast.FunctionDecl),
    source_path: []const u8,
    program: syntax.ast.Program,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    try validateSourcePathAllowed(allocator, source_path, module_map, diags);

    const visited_key = try paths.canonicalizeExistingPath(allocator, source_path);
    defer allocator.free(visited_key);

    if (visited.contains(visited_key)) return;
    try visited.put(try allocator.dupe(u8, visited_key), {});

    for (program.imports) |import_decl| try import_list.append(import_decl);
    for (program.decls) |decl| try decls.append(decl);
    for (program.functions) |function_decl| try functions.append(function_decl);

    for (program.imports) |import_decl| {
        if (imports.packageRootOwnerForImport(module_map, import_decl.module_name)) |owner| {
            const module_files = try collectPackageModuleFiles(allocator, owner.source_root);
            defer freeModuleFiles(allocator, module_files);
            for (module_files) |module_path| {
                const imported_program = try parseModuleProgram(allocator, module_path, diags);
                try appendProgramGraph(allocator, visited, import_list, decls, functions, module_path, imported_program, module_map, diags);
            }
            continue;
        }

        const resolved = try imports.resolveImportPath(allocator, source_path, import_decl.module_name, module_map);
        defer freeResolution(allocator, resolved);

        const module_path = imports.firstExistingCandidate(resolved.candidates) orelse continue;
        const imported_program = try parseModuleProgram(allocator, module_path, diags);
        try appendProgramGraph(allocator, visited, import_list, decls, functions, module_path, imported_program, module_map, diags);
    }
}

pub fn parseModuleProgram(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const source = try source_pkg.SourceFile.fromPath(allocator, module_path);
    var module_diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = lexer.tokenize(allocator, &source, &module_diags) catch {
        for (module_diags.items) |diag| try out_diagnostics.append(diag);
        return error.DiagnosticsEmitted;
    };
    return parser.parse(allocator, tokens, &module_diags) catch {
        for (module_diags.items) |diag| try out_diagnostics.append(diag);
        return error.DiagnosticsEmitted;
    };
}

pub fn collectPackageModuleFiles(allocator: std.mem.Allocator, source_root: []const u8) ![][]u8 {
    const canonical_root = try paths.canonicalizeSourceRoot(allocator, source_root);
    defer allocator.free(canonical_root);

    var files = std.array_list.Managed([]u8).init(allocator);
    if (!paths.dirExists(canonical_root)) return files.toOwnedSlice();
    try appendPackageModuleFiles(allocator, &files, canonical_root);
    sortPaths(files.items);
    return files.toOwnedSlice();
}

fn appendPackageModuleFiles(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed([]u8),
    current_path: []const u8,
) !void {
    var dir = try std.fs.openDirAbsolute(current_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => try appendPackageModuleFiles(allocator, files, child_path),
            .file => {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".kira")) continue;
                try files.append(try paths.canonicalizeExistingPath(allocator, child_path));
            },
            else => {},
        }
    }
}

fn validateSourcePathAllowed(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    if (try imports.sourcePathIsAllowed(allocator, source_path, module_map)) return;

    try diagnostics.appendOwned(allocator, diags, .{
        .severity = .@"error",
        .code = "KGRAPH001",
        .title = "source file outside canonical source root",
        .message = try std.fmt.allocPrint(
            allocator,
            "Kira source file `{s}` is outside the allowed `app/` source roots for this package graph.",
            .{source_path},
        ),
        .notes = try allowedRootNotes(allocator, module_map),
        .help = "Move the Kira source file under the package `app/` directory or import a declared dependency through its `app/` source root.",
    });
    return error.DiagnosticsEmitted;
}

fn allowedRootNotes(allocator: std.mem.Allocator, module_map: package_manager.ModuleMap) ![]const []const u8 {
    const notes = try allocator.alloc([]const u8, module_map.owners.len);
    for (module_map.owners, 0..) |owner, index| {
        notes[index] = try std.fmt.allocPrint(
            allocator,
            "allowed source root for `{s}` is {s}",
            .{ owner.package_name, owner.source_root },
        );
    }
    return notes;
}

fn freeResolution(allocator: std.mem.Allocator, resolution: imports.ImportResolution) void {
    allocator.free(resolution.display_name);
    for (resolution.candidates) |candidate| allocator.free(candidate);
    allocator.free(resolution.candidates);
}

fn freeModuleFiles(allocator: std.mem.Allocator, module_files: [][]u8) void {
    for (module_files) |module_file| allocator.free(module_file);
    allocator.free(module_files);
}

fn sortPaths(items: [][]u8) void {
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, items[cursor - 1], items[cursor]) == .gt) : (cursor -= 1) {
            const tmp = items[cursor - 1];
            items[cursor - 1] = items[cursor];
            items[cursor] = tmp;
        }
    }
}

test "collectPackageModuleFiles ignores package-root Kira files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Package/app");
    try tmp.dir.writeFile(.{ .sub_path = "Package/root.kira", .data = "function rootOnly() { return; }\n" });
    try tmp.dir.writeFile(.{ .sub_path = "Package/app/main.kira", .data = "function appOnly() { return; }\n" });

    const app_root = try tmp.dir.realpathAlloc(std.testing.allocator, "Package/app");
    defer std.testing.allocator.free(app_root);
    const files = try collectPackageModuleFiles(std.testing.allocator, app_root);
    defer freeModuleFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("main.kira", std.fs.path.basename(files[0]));
}

test "canonical visited identity deduplicates alternate path spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Package/app");
    try tmp.dir.writeFile(.{ .sub_path = "Package/app/main.kira", .data = "function onlyOnce() { return; }\n" });

    const app_root = try tmp.dir.realpathAlloc(allocator, "Package/app");
    const canonical = try tmp.dir.realpathAlloc(allocator, "Package/app/main.kira");
    const alternate = try std.fmt.allocPrint(allocator, "{s}/main.kira", .{app_root});
    const source_paths = try allocator.alloc([]u8, 2);
    source_paths[0] = canonical;
    source_paths[1] = alternate;

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try buildProgramGraphFromFiles(allocator, source_paths, .{ .owners = &.{} }, &diags);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
}

test "graph rejects an entry source outside declared app roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Package/app");
    try tmp.dir.writeFile(.{ .sub_path = "Package/main.kira", .data = "" });

    const app_root = try tmp.dir.realpathAlloc(allocator, "Package/app");
    const source_path = try tmp.dir.realpathAlloc(allocator, "Package/main.kira");
    const owners = [_]package_manager.ModuleMap.ModuleOwner{.{
        .module_root = "Package",
        .package_name = "Package",
        .source_root = app_root,
    }};

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const empty_program: syntax.ast.Program = .{ .imports = &.{}, .decls = &.{}, .functions = &.{} };
    try std.testing.expectError(
        error.DiagnosticsEmitted,
        buildProgramGraph(allocator, source_path, empty_program, .{ .owners = owners[0..] }, &diags),
    );
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("KGRAPH001", diags.items[0].code.?);
}
