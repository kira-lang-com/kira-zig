//! Program-graph symbol indexing for lowerProgram: per-decl origins, package-scoped
//! top-level names, and the file-scoped import gate's maps (dependency-symbol owners,
//! per-file import sets, owner->module-root hints). Split from lower_program.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const shared = @import("lower_shared.zig");

pub fn declOrigin(program: syntax.ast.Program, index: usize) syntax.ast.DeclOrigin {
    if (index < program.decl_origins.len) return program.decl_origins[index];
    return .{};
}
fn scopedTopLevelName(allocator: std.mem.Allocator, origin: syntax.ast.DeclOrigin, name: []const u8) ![]const u8 {
    if (origin.package_name) |package_name| {
        return shared.scopedSymbolName(allocator, package_name, name);
    }
    return name;
}

pub fn registerScopedTopLevelName(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    map: *std.StringHashMapUnmanaged(source_pkg.Span),
    origin: syntax.ast.DeclOrigin,
    name: []const u8,
    span: source_pkg.Span,
) !void {
    const key = try scopedTopLevelName(allocator, origin, name);
    try shared.registerTopLevelName(allocator, out_diagnostics, map, key, span);
}

pub fn collectRootTopLevelNames(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    names: *std.StringHashMapUnmanaged(void),
) !void {
    for (program.decls, 0..) |decl, decl_index| {
        if (declOrigin(program, decl_index).package_name != null) continue;
        switch (decl) {
            .annotation_decl => |item| try names.put(allocator, item.name, {}),
            .capability_decl => |item| try names.put(allocator, item.name, {}),
            .enum_decl => |item| try names.put(allocator, item.name, {}),
            .type_alias_decl => |item| try names.put(allocator, item.name, {}),
            .type_decl => |item| try names.put(allocator, item.name, {}),
            .construct_decl => |item| try names.put(allocator, item.name, {}),
            .construct_form_decl => |item| try names.put(allocator, item.name, {}),
            // A FailTest is compiled by the `kira test` runner as an isolated
            // synthetic package; it contributes no runtime top-level name here.
            .fail_test_decl => |item| try names.put(allocator, item.name, {}),
            .function_decl => |item| try names.put(allocator, item.name, {}),
            // Extension declarations add no new top-level name; they extend an existing construct.
            .extend_decl => {},
            // Macro declarations and top-level macro invocations are consumed by the
            // macro-expansion pass before semantics; no runtime top-level name.
            .macro_decl, .macro_invocation => {},
        }
    }
}

fn declTopLevelName(decl: syntax.ast.Decl) ?[]const u8 {
    return switch (decl) {
        .annotation_decl => |item| item.name,
        .capability_decl => |item| item.name,
        .enum_decl => |item| item.name,
        .type_alias_decl => |item| item.name,
        .type_decl => |item| item.name,
        .construct_decl => |item| item.name,
        .construct_form_decl => |item| item.name,
        .fail_test_decl => |item| item.name,
        .function_decl => |item| item.name,
        .extend_decl, .macro_decl, .macro_invocation => null,
    };
}

// Map each top-level symbol declared by a NON-root (dependency) package to that
// package, unless a root declaration shadows the name. A name absent from the map is
// a root/local symbol and is always visible; the file-scope gate consults this map to
// reject a dependency symbol referenced from a file that did not import its module.
pub fn collectImportedSymbolOwners(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    root_top_level_names: *const std.StringHashMapUnmanaged(void),
    owners: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (program.decls, 0..) |decl, decl_index| {
        const package_name = declOrigin(program, decl_index).package_name orelse continue;
        const name = declTopLevelName(decl) orelse continue;
        // A root declaration of the same name wins the bare slot (see putFunctionHeader),
        // so the dependency symbol is not reachable bare and must not be gated by module.
        if (root_top_level_names.contains(name)) continue;
        if (owners.contains(name)) continue;
        try owners.put(allocator, name, package_name);
    }
}

// Map each file's canonical source path to the set of module names it imports. A file
// references a dependency by its module root (e.g. `import Foundation` -> "Foundation"),
// but `collectImportedSymbolOwners` keys dependency symbols by the OWNER package name.
// Those two names are usually identical, but a package may split them (Package UILibrary,
// moduleRoot "UI"): the file writes `import UI` while the owner is "UILibrary". The graph
// builder records that owner on the import origin (`module_owner_package`), so we register
// BOTH the written module root and the owner package name — the gate joins on the owner.
pub fn collectFileModuleImports(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    file_imports: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
) !void {
    for (program.imports, 0..) |import_decl, import_index| {
        const origin = if (import_index < program.import_origins.len) program.import_origins[import_index] else syntax.ast.DeclOrigin{};
        if (origin.source_path.len == 0) continue;
        if (import_decl.module_name.segments.len == 0) continue;
        const module_root = import_decl.module_name.segments[0].text;
        const entry = try file_imports.getOrPut(allocator, origin.source_path);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        try entry.value_ptr.put(allocator, module_root, {});
        if (origin.module_owner_package) |owner_package| {
            try entry.value_ptr.put(allocator, owner_package, {});
        }
    }
}

// Owner package name -> importable module root, for import-hint diagnostics. Recorded only
// when a dependency's manifest name differs from the module root files import (Package
// UILibrary, moduleRoot "UI"): a missing-import hint must say `import UI` — the owner name
// would not resolve as an import.
pub fn collectModuleRootsByOwner(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    roots: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (program.imports, 0..) |import_decl, import_index| {
        const origin = if (import_index < program.import_origins.len) program.import_origins[import_index] else syntax.ast.DeclOrigin{};
        const owner_package = origin.module_owner_package orelse continue;
        if (import_decl.module_name.segments.len == 0) continue;
        const module_root = import_decl.module_name.segments[0].text;
        if (std.mem.eql(u8, owner_package, module_root)) continue;
        try roots.put(allocator, owner_package, module_root);
    }
}

pub fn putFunctionHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
    root_top_level_names: *const std.StringHashMapUnmanaged(void),
    origin: syntax.ast.DeclOrigin,
    name: []const u8,
    header: shared.FunctionHeader,
) !void {
    const scoped_name = try scopedTopLevelName(allocator, origin, name);
    try headers.put(allocator, scoped_name, header);
    if (origin.package_name == null) return;
    if (root_top_level_names.contains(name)) return;
    if (headers.get(name) != null) return;
    try headers.put(allocator, name, header);
}
