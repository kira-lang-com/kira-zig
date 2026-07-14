const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const exprs = @import("lower_exprs.zig");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;
const type_impl = @import("lower_program_types.zig");
const enum_impl = @import("lower_program_enums.zig");
const ffi_boundary = @import("lower_program_ffi_boundary.zig");
const requirements = @import("lower_construct_requirements.zig");
const field_requirements = @import("lower_construct_field_requirements.zig");
const widget_content = @import("lower_widget_content.zig");
const content_composition = @import("lower_construct_content.zig");
const content_validation = @import("lower_construct_content_validation.zig");
const construct_functions = @import("lower_construct_functions.zig");
const construct_extensions = @import("lower_construct_extensions.zig");
const construct_defaults = @import("lower_construct_default_accessors.zig");
const construct_members = @import("lower_construct_members.zig");
const construct_tests = @import("lower_construct_tests.zig");
const node_bridge = @import("lower_construct_node_bridge.zig");
const type_accessors = @import("lower_type_constant_accessors.zig");
const form_surface = @import("construct_form_surface.zig");
const form_lowering = @import("lower_program_forms.zig");
const function_impl = @import("lower_program_functions.zig");

pub const lowerImports = type_impl.lowerImports;
pub const composeAnnotationGeneratedFunctions = type_impl.composeAnnotationGeneratedFunctions;
pub const appendGeneratedFunctionUnique = type_impl.appendGeneratedFunctionUnique;
pub const registerImportAliases = type_impl.registerImportAliases;
pub const lowerConstructDecl = type_impl.lowerConstructDecl;
pub const registerImportedFunctionHeaders = type_impl.registerImportedFunctionHeaders;
pub const resolveTypeHeader = type_impl.resolveTypeHeader;
pub const resolveLocalTypeHeader = type_impl.resolveLocalTypeHeader;
pub const resolveImportedTypeHeader = type_impl.resolveImportedTypeHeader;
pub const typeSourceSpan = type_impl.typeSourceSpan;
pub const findTypeSource = type_impl.findTypeSource;
pub const appendResolvedParents = type_impl.appendResolvedParents;
pub const appendImportedParents = type_impl.appendImportedParents;
pub const appendDeclaredImportedMethods = type_impl.appendDeclaredImportedMethods;
pub const appendGeneratedAnnotationMethods = type_impl.appendGeneratedAnnotationMethods;
pub const applyLocalTypeMembers = type_impl.applyLocalTypeMembers;
pub const emitInvalidFieldOverride = type_impl.emitInvalidFieldOverride;
pub const findSingleInheritedField = type_impl.findSingleInheritedField;
pub const fieldNameExists = type_impl.fieldNameExists;
pub const methodNameExists = type_impl.methodNameExists;
pub const countMethodsByName = type_impl.countMethodsByName;
pub const countExactMethodMatches = type_impl.countExactMethodMatches;
pub const hasNonOverridableExactMethod = type_impl.hasNonOverridableExactMethod;
pub const sameMethodSignature = type_impl.sameMethodSignature;
pub const makeDeclaredMethodMember = type_impl.makeDeclaredMethodMember;
pub const registerTypeMethodHeaders = type_impl.registerTypeMethodHeaders;
pub const lowerTypeMethods = type_impl.lowerTypeMethods;
pub const lowerMethodFunction = type_impl.lowerMethodFunction;
pub const lowerConstructForm = function_impl.lowerConstructForm;
pub const lowerFunction = function_impl.lowerFunction;
pub const lowerTypeMethodMembers = function_impl.lowerTypeMethodMembers;
pub const lowerImportedParams = function_impl.lowerImportedParams;
pub const hasFfiAnnotation = function_impl.hasFfiAnnotation;
pub const ownedEnumSlice = function_impl.ownedEnumSlice;
pub const validatePrintableTypes = function_impl.validatePrintableTypes;
const field_defaults = @import("lower_program_field_defaults.zig");
pub const lowerField = field_defaults.lowerField;
pub const lowerFieldDefaultExpr = field_defaults.lowerFieldDefaultExpr;
pub const lowerFieldDefaultExprExpected = field_defaults.lowerFieldDefaultExprExpected;

pub const ResolvedFieldOverride = struct {
    field: model.Field,
    inherited_offset: u32,
};

pub const ResolvedMethodMember = shared.MethodMember;

pub const AnalysisOptions = struct {
    require_main: bool = true,
    /// Set for the VM target: ordinary runtime functions may call FFI-bound
    /// symbols directly because the VM dispatches them through LibFFI. Other
    /// backends keep the KSEM093 "@Native" requirement.
    allow_runtime_direct_ffi: bool = false,
};

pub const TypeSource = union(enum) {
    local: syntax.ast.TypeDecl,
    imported: @import("imported_globals.zig").ImportedType,
};

pub const LocalTypeMap = std.StringHashMapUnmanaged(syntax.ast.TypeDecl);

pub const ResolverState = enum {
    resolving,
    resolved,
};

fn declOrigin(program: syntax.ast.Program, index: usize) syntax.ast.DeclOrigin {
    if (index < program.decl_origins.len) return program.decl_origins[index];
    return .{};
}
fn scopedTopLevelName(allocator: std.mem.Allocator, origin: syntax.ast.DeclOrigin, name: []const u8) ![]const u8 {
    if (origin.package_name) |package_name| {
        return shared.scopedSymbolName(allocator, package_name, name);
    }
    return name;
}

fn registerScopedTopLevelName(
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

fn collectRootTopLevelNames(
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
fn collectImportedSymbolOwners(
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
fn collectFileModuleImports(
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

fn putFunctionHeader(
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

pub fn lowerProgram(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    imported_globals: ImportedGlobals,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Program {
    return lowerProgramWithOptions(allocator, program, imported_globals, .{}, out_diagnostics);
}

pub fn lowerProgramWithOptions(
    allocator: std.mem.Allocator,
    program: syntax.ast.Program,
    imported_globals: ImportedGlobals,
    options: AnalysisOptions,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !model.Program {
    var ctx = shared.Context{
        .allocator = allocator,
        .diagnostics = out_diagnostics,
        .imported_globals = imported_globals,
        .allow_runtime_direct_ffi = options.allow_runtime_direct_ffi,
    };
    // The direct-FFI boundary check lazily builds this extern-header-by-id index on
    // ctx (see lower_program_ffi_boundary.externIndex); it is context-owned, so free
    // it here — the other header maps below are locals with their own defers.
    defer if (ctx.extern_headers_by_id) |*map| map.deinit(allocator);

    const imports = try lowerImports(&ctx, program);

    // Built before registering import aliases so the alias/module-root collision check can
    // see this package's own top-level declaration names.
    var root_top_level_names = std.StringHashMapUnmanaged(void){};
    defer root_top_level_names.deinit(allocator);
    try collectRootTopLevelNames(allocator, program, &root_top_level_names);

    var top_level_names = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer top_level_names.deinit(allocator);
    try registerImportAliases(&ctx, imports, &root_top_level_names, &top_level_names);

    var construct_headers = std.StringHashMapUnmanaged(shared.ConstructHeader){};
    defer construct_headers.deinit(allocator);
    ctx.construct_headers = &construct_headers;
    var function_headers = std.StringHashMapUnmanaged(shared.FunctionHeader){};
    defer function_headers.deinit(allocator);
    ctx.function_headers = &function_headers;
    var enum_headers = std.StringHashMapUnmanaged(model.EnumDecl){};
    defer enum_headers.deinit(allocator);
    ctx.enum_headers = &enum_headers;
    var concrete_enums = std.StringHashMapUnmanaged(model.EnumDecl){};
    defer concrete_enums.deinit(allocator);
    ctx.concrete_enums = &concrete_enums;
    var type_headers = std.StringHashMapUnmanaged(shared.TypeHeader){};
    defer type_headers.deinit(allocator);
    ctx.type_headers = &type_headers;
    var type_alias_headers = std.StringHashMapUnmanaged(shared.TypeAliasHeader){};
    defer type_alias_headers.deinit(allocator);
    ctx.type_alias_headers = &type_alias_headers;
    var annotation_headers = std.StringHashMapUnmanaged(shared.AnnotationHeader){};
    defer annotation_headers.deinit(allocator);
    try shared.registerBuiltinAnnotationHeaders(allocator, &annotation_headers);
    ctx.annotation_headers = &annotation_headers;

    var annotations = std.array_list.Managed(model.AnnotationDecl).init(allocator);
    var capabilities = std.array_list.Managed(model.CapabilityDecl).init(allocator);
    var capability_headers = std.StringHashMapUnmanaged(usize){};
    defer capability_headers.deinit(allocator);
    var constructs = std.array_list.Managed(model.Construct).init(allocator);
    var types = std.array_list.Managed(model.TypeDecl).init(allocator);
    var forms = std.array_list.Managed(model.ConstructForm).init(allocator);
    var tests = std.array_list.Managed(model.TestCase).init(allocator);
    var functions = std.array_list.Managed(model.Function).init(allocator);
    var local_types = LocalTypeMap{};
    defer local_types.deinit(allocator);
    var resolver_states = std.StringHashMapUnmanaged(ResolverState){};
    defer resolver_states.deinit(allocator);
    // Imports are file-scoped: build the owner index (dependency symbol -> package) and
    // the per-file import set, then expose them on the context so name resolution can
    // reject a dependency symbol used in a file that never imported its module.
    var imported_symbol_owner = std.StringHashMapUnmanaged([]const u8){};
    defer imported_symbol_owner.deinit(allocator);
    try collectImportedSymbolOwners(allocator, program, &root_top_level_names, &imported_symbol_owner);
    ctx.imported_symbol_owner = &imported_symbol_owner;

    var file_module_imports = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)){};
    defer {
        var file_import_it = file_module_imports.valueIterator();
        while (file_import_it.next()) |set| set.deinit(allocator);
        file_module_imports.deinit(allocator);
    }
    try collectFileModuleImports(allocator, program, &file_module_imports);
    ctx.file_module_imports = &file_module_imports;

    for (program.decls, 0..) |decl, decl_index| {
        const origin = declOrigin(program, decl_index);
        switch (decl) {
            .annotation_decl => |annotation_decl| {
                if (annotation_headers.get(annotation_decl.name)) |previous| {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM060",
                        .title = "duplicate annotation declaration",
                        .message = try std.fmt.allocPrint(allocator, "Kira found more than one annotation declaration named '{s}'.", .{annotation_decl.name}),
                        .labels = &.{
                            diagnostics.primaryLabel(annotation_decl.span, "duplicate annotation declaration"),
                            diagnostics.secondaryLabel(previous.decl.span, "first annotation declaration was here"),
                        },
                        .help = "Rename one of the annotations so the symbol is unambiguous.",
                    });
                    return error.DiagnosticsEmitted;
                }
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, annotation_decl.name, annotation_decl.span);
                const lowered = try shared.lowerAnnotationDecl(&ctx, annotation_decl, "");
                try annotation_headers.put(allocator, lowered.name, .{
                    .index = annotations.items.len,
                    .decl = lowered,
                });
                try annotations.append(lowered);
            },
            .capability_decl => |capability_decl| {
                if (capability_headers.get(capability_decl.name)) |previous_index| {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KSEM072",
                        .title = "duplicate capability declaration",
                        .message = try std.fmt.allocPrint(allocator, "Kira found more than one capability declaration named '{s}'.", .{capability_decl.name}),
                        .labels = &.{
                            diagnostics.primaryLabel(capability_decl.span, "duplicate capability declaration"),
                            diagnostics.secondaryLabel(capabilities.items[previous_index].span, "first capability declaration was here"),
                        },
                        .help = "Rename one of the capabilities so annotation composition stays unambiguous.",
                    });
                    return error.DiagnosticsEmitted;
                }
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, capability_decl.name, capability_decl.span);
                const lowered = try shared.lowerCapabilityDecl(&ctx, capability_decl, "");
                try capability_headers.put(allocator, lowered.name, capabilities.items.len);
                try capabilities.append(lowered);
            },
            else => {},
        }
    }

    for (annotations.items) |*annotation_decl| {
        annotation_decl.generated_functions = try composeAnnotationGeneratedFunctions(&ctx, annotation_decl.*, capabilities.items, &capability_headers);
        if (annotation_headers.getPtr(annotation_decl.name)) |header| {
            header.decl = annotation_decl.*;
        }
    }

    for (imported_globals.aliases) |alias_decl| {
        try type_alias_headers.put(allocator, alias_decl.name, .{
            .target = .{ .imported = alias_decl.target },
            .span = .{ .start = 0, .end = 0 },
        });
    }

    for (program.decls, 0..) |decl, decl_index| {
        const origin = declOrigin(program, decl_index);
        if (decl != .type_alias_decl) continue;
        const alias_decl = decl.type_alias_decl;
        try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, alias_decl.name, alias_decl.span);
        try type_alias_headers.put(allocator, alias_decl.name, .{
            .target = .{ .syntax = alias_decl.target.* },
            .span = alias_decl.span,
        });
    }

    for (program.decls, 0..) |decl, decl_index| {
        const origin = declOrigin(program, decl_index);
        switch (decl) {
            .annotation_decl, .capability_decl, .type_alias_decl, .extend_decl, .macro_decl, .macro_invocation => {},
            // FailTest bodies are never lowered — their `source` is quoted text the
            // runner compiles in isolation, so they emit no types/functions here.
            .fail_test_decl => {},
            .construct_decl => |construct_decl| {
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, construct_decl.name, construct_decl.span);
                const lowered = try lowerConstructDecl(&ctx, construct_decl);
                try construct_headers.put(allocator, lowered.name, .{
                    .index = constructs.items.len,
                    .span = lowered.span,
                });
                try constructs.append(lowered);
            },
            .enum_decl => |enum_decl| {
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, enum_decl.name, enum_decl.span);
                const lowered = try enum_impl.lowerEnumDecl(&ctx, enum_decl);
                try enum_headers.put(allocator, lowered.name, lowered);
                if (lowered.type_params.len == 0) try concrete_enums.put(allocator, lowered.name, lowered);
            },
            .type_decl => |type_decl| {
                if (!hasFfiAnnotation(type_decl.annotations)) {
                    try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, type_decl.name, type_decl.span);
                }
                try local_types.put(allocator, type_decl.name, type_decl);
            },
            .construct_form_decl => |form_decl| {
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, form_decl.name, form_decl.span);
                // Gap #1 (runtime): a concrete declaration is also a struct type of its stored
                // scalar fields, so `Text(text: "hi")` lowers through the ordinary struct
                // construction path into an `alloc_struct`. Composition members (`@Content`
                // children, computed `let node { ... }`) are excluded — they are not stored state.
                try local_types.put(allocator, form_decl.name, try form_lowering.synthesizeFormStruct(&ctx, form_decl));
            },
            .function_decl => |function_decl| {
                try registerScopedTopLevelName(allocator, out_diagnostics, &top_level_names, origin, function_decl.name, function_decl.span);
                const annotation_info = try shared.resolveFunctionAnnotations(&ctx, function_decl.annotations);
                const foreign = try shared.resolveForeignFunction(&ctx, function_decl.annotations, function_decl.span);
                var param_types = std.array_list.Managed(model.ResolvedType).init(allocator);
                var param_ownership = std.array_list.Managed(model.OwnershipMode).init(allocator);
                var param_defaults = std.array_list.Managed(?*syntax.ast.Expr).init(allocator);
                for (function_decl.params) |param| {
                    try param_ownership.append(shared.ownershipModeFromSyntax(param.type_expr));
                    try param_defaults.append(param.default_value);
                    if (param.type_expr) |type_expr| {
                        try param_types.append(try shared.typeFromSyntax(&ctx, type_expr.*));
                    } else {
                        try param_types.append(.{ .kind = .unknown });
                    }
                }
                const return_ownership = shared.ownershipModeFromSyntax(function_decl.return_type);
                try putFunctionHeader(allocator, &function_headers, &root_top_level_names, origin, function_decl.name, .{
                    .id = @as(u32, @intCast(function_headers.count())),
                    .params = try param_types.toOwnedSlice(),
                    .param_ownership = try param_ownership.toOwnedSlice(),
                    .param_defaults = try param_defaults.toOwnedSlice(),
                    .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
                    .return_type = if (function_decl.return_type) |return_type| try shared.typeFromSyntax(&ctx, return_type.*) else .{ .kind = .unknown },
                    .return_ownership = return_ownership,
                    .is_extern = foreign != null,
                    .is_comptime = function_decl.is_comptime,
                    .comptime_decl = if (function_decl.is_comptime) function_decl else null,
                    .foreign = foreign,
                    .span = function_decl.span,
                });
            },
        }
    }

    try enum_impl.registerGenericEnumInstantiations(&ctx, program);

    for (imported_globals.types) |type_decl| {
        _ = try resolveTypeHeader(&ctx, &local_types, &resolver_states, &type_headers, .{ .imported = type_decl }, type_decl.name);
    }
    var local_type_iterator = local_types.iterator();
    while (local_type_iterator.next()) |entry| {
        _ = try resolveTypeHeader(&ctx, &local_types, &resolver_states, &type_headers, .{ .local = entry.value_ptr.* }, entry.key_ptr.*);
    }

    // All constructs are registered above; validate `extends` (unknown parent + cycles)
    // before registering construct-family methods that depend on the family graph.
    try type_impl.validateConstructInheritance(&ctx, constructs.items, &construct_headers);
    try content_composition.validateConstructContentComposition(&ctx, constructs.items, &construct_headers);

    // Map each construct-backed declaration to its declared parent (a construct or another
    // declaration), so a declaration's construct family can be resolved through a chain such as
    // `Drawable Sprite { ... }` then `Sprite Player { ... }`.
    var form_parent = std.StringHashMapUnmanaged([]const u8){};
    defer form_parent.deinit(allocator);
    for (program.decls) |decl| {
        if (decl != .construct_form_decl) continue;
        const form_decl = decl.construct_form_decl;
        const parent_leaf = form_decl.construct_name.segments[form_decl.construct_name.segments.len - 1].text;
        try form_parent.put(allocator, form_decl.name, parent_leaf);
    }
    // Reject declaration-parent cycles before lowering, so they surface as cycles (KSEM119)
    // rather than as unresolvable parents during form lowering.
    try requirements.validateFormParentCycles(&ctx, program, &form_parent);

    // Map each declaration's type name to the construct families it satisfies, so concrete widget
    // values coerce to `any Widget` during body lowering and method registration.
    var form_families = std.StringHashMapUnmanaged([]const []const u8){};
    defer form_families.deinit(allocator);
    try form_lowering.buildFormFamilies(allocator, program, constructs.items, &construct_headers, &form_parent, &form_families);
    ctx.form_families = &form_families;
    // Construct declarations are all lowered above; expose the family surfaces so
    // method lowering can resolve @Consuming (owned-self) methods.
    ctx.constructs = constructs.items;

    try registerImportedFunctionHeaders(&ctx, &function_headers);
    for (program.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                try registerTypeMethodHeaders(&ctx, type_decl, &function_headers);
                try type_accessors.registerTypeAccessorHeaders(&ctx, type_decl, &function_headers);
            },
            .construct_form_decl => |form_decl| {
                try construct_tests.registerTestSectionHeaders(&ctx, form_decl, &function_headers);
                try construct_functions.registerConstructFormFunctionHeaders(&ctx, form_decl, &function_headers);
                try construct_functions.registerConstructFormMethods(&ctx, form_decl, &type_headers, &function_headers);
                try node_bridge.registerFormAccessorHeaders(&ctx, form_decl, &function_headers);
                try node_bridge.registerFormAccessorMethods(&ctx, form_decl, &type_headers, &function_headers);
                try construct_defaults.registerDefaultFunctionHeaders(&ctx, program, form_decl, &function_headers);
                try construct_defaults.registerDefaultMethods(&ctx, program, form_decl, &type_headers, &function_headers);
            },
            .extend_decl => |extend_decl| {
                try construct_extensions.registerExtendFunctionHeaders(&ctx, extend_decl, &function_headers);
                try construct_extensions.registerExtendMethods(&ctx, extend_decl, &type_headers, &function_headers);
            },
            .function_decl => {},
            else => {},
        }
    }
    try validatePrintableTypes(&ctx, &type_headers, &function_headers);

    var type_header_iterator = type_headers.iterator();
    while (type_header_iterator.next()) |entry| {
        try types.append(.{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .kind = entry.value_ptr.kind,
            .execution = entry.value_ptr.execution,
            .fields = @constCast(entry.value_ptr.fields),
            .methods = try lowerTypeMethodMembers(allocator, entry.value_ptr.methods),
            .ffi = entry.value_ptr.ffi,
            .derive_copy = entry.value_ptr.derive_copy,
            .span = entry.value_ptr.span,
        });
    }

    var main_index: ?usize = null;
    var first_main_span: ?source_pkg.Span = null;

    for (imported_globals.functions) |function_decl| {
        if (!function_decl.is_extern) continue;
        const header = function_headers.get(function_decl.name) orelse continue;
        const empty_statements = try allocator.alloc(model.Statement, 0);
        const params = try lowerImportedParams(allocator, function_decl.params, function_decl.param_ownership);
        try functions.append(.{
            .id = header.id,
            .name = try allocator.dupe(u8, function_decl.name),
            .is_main = false,
            .execution = header.execution,
            .is_extern = true,
            .foreign = function_decl.foreign,
            .annotations = &.{},
            .params = params,
            .locals = &.{},
            .return_type = function_decl.return_type,
            .return_ownership = function_decl.return_ownership,
            .body = empty_statements,
            .span = header.span,
        });
    }

    // Record each declaration's `@Content` fields so construction routes trailing blocks into them.
    var form_content_fields = std.StringHashMapUnmanaged([]const shared.ContentFieldRef){};
    defer form_content_fields.deinit(allocator);
    try form_lowering.buildFormContentFields(&ctx, program, &form_content_fields);
    ctx.form_content_fields = &form_content_fields;

    // Validate caller-provided `@Content` at construction sites before lowering the forms. The
    // content diagnostics (KSEM142-145) are more specific than the struct-construction errors
    // (e.g. KSEM081 missing field) that `@Content`-as-real-fields lowering would otherwise raise
    // first for the same mistake.
    try widget_content.validateWidgetContent(&ctx, program);

    for (program.decls, 0..) |decl, decl_index| {
        const previous_package = ctx.current_package;
        const previous_source_path = ctx.current_source_path;
        ctx.current_package = declOrigin(program, decl_index).package_name;
        ctx.current_source_path = declOrigin(program, decl_index).source_path;
        switch (decl) {
            .construct_form_decl => |form_decl| {
                try forms.append(try lowerConstructForm(&ctx, form_decl, imports, constructs.items, &construct_headers, &form_parent));
                try functions.appendSlice(try construct_functions.lowerConstructFormFunctions(&ctx, form_decl, imports, &function_headers));
                try functions.appendSlice(try construct_tests.lowerTestSections(&ctx, form_decl, imports, &function_headers, &tests));
                try functions.appendSlice(try node_bridge.lowerFormAccessors(&ctx, form_decl, imports, &function_headers));
                try functions.appendSlice(try construct_defaults.lowerDefaultFunctions(&ctx, program, form_decl, imports, &function_headers));
            },
            .function_decl => |function_decl| {
                if (function_decl.is_comptime) continue;
                const lowered = try lowerFunction(&ctx, function_decl, imports, &function_headers);
                if (lowered.is_main) {
                    if (first_main_span) |previous_span| {
                        try diagnostics.appendOwned(allocator, out_diagnostics, .{
                            .severity = .@"error",
                            .code = "KSEM002",
                            .title = "multiple @Main entrypoints",
                            .message = "A module can only have one @Main entrypoint.",
                            .labels = &.{
                                diagnostics.primaryLabel(function_decl.span, "this function is marked as another entrypoint"),
                                diagnostics.secondaryLabel(previous_span, "the first @Main entrypoint was declared here"),
                            },
                            .help = "Keep @Main on exactly one function.",
                        });
                        return error.DiagnosticsEmitted;
                    }
                    first_main_span = function_decl.span;
                    main_index = functions.items.len;
                }
                try functions.append(lowered);
            },
            .type_decl => |type_decl| {
                const lowered_methods = try lowerTypeMethods(&ctx, type_decl, imports, &function_headers);
                try functions.appendSlice(lowered_methods);
                try functions.appendSlice(try type_accessors.lowerTypeAccessors(&ctx, type_decl, imports, &function_headers));
            },
            .extend_decl => |extend_decl| {
                try functions.appendSlice(try construct_extensions.lowerExtendFunctions(&ctx, extend_decl, imports, &function_headers));
            },
            else => {},
        }
        ctx.current_package = previous_package;
        ctx.current_source_path = previous_source_path;
    }

    // Validate required-function satisfaction across the mixed construct/declaration graph.
    try requirements.validateConstructFormRequirements(&ctx, program, constructs.items, &construct_headers, &form_parent);
    // Validate `@Required` field satisfaction with the terminal-`node` rule.
    try field_requirements.validateConstructFormFieldRequirements(&ctx, program, constructs.items, &construct_headers, &form_parent);
    // `extend C { ... }` must target a known construct family.
    for (program.decls) |decl| {
        if (decl != .extend_decl) continue;
        const extend_decl = decl.extend_decl;
        const name = try shared.qualifiedNameText(allocator, extend_decl.construct_name);
        const leaf = extend_decl.construct_name.segments[extend_decl.construct_name.segments.len - 1].text;
        const root = extend_decl.construct_name.segments[0].text;
        const known = construct_headers.get(leaf) != null or
            ctx.imported_globals.hasConstruct(name) or
            shared.isImportedRoot(&ctx, root, imports);
        if (!known) {
            try diagnostics.appendOwned(allocator, out_diagnostics, .{
                .severity = .@"error",
                .code = "KSEM146",
                .title = "unknown extend target",
                .message = try std.fmt.allocPrint(allocator, "Kira could not find a construct named '{s}' to extend.", .{name}),
                .labels = &.{diagnostics.primaryLabel(extend_decl.construct_name.span, "unknown construct")},
                .help = "Declare the construct before extending it, or import the module that provides it.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    if (main_index == null and options.require_main) {
        try diagnostics.appendOwned(allocator, out_diagnostics, .{
            .severity = .@"error",
            .code = "KSEM001",
            .title = "missing @Main entrypoint",
            .message = "This module cannot run because no function is marked with @Main.",
            .help = "Add @Main to exactly one zero-argument function, for example `@Main function entry() { ... }`.",
        });
        return error.DiagnosticsEmitted;
    }

    if (diagnostics.hasErrors(out_diagnostics.items)) return error.DiagnosticsEmitted;

    return .{
        .imports = imports,
        .annotations = try annotations.toOwnedSlice(),
        .capabilities = try capabilities.toOwnedSlice(),
        .enums = try ownedEnumSlice(allocator, &concrete_enums),
        .constructs = try constructs.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
        .forms = try forms.toOwnedSlice(),
        .tests = try tests.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .entry_index = main_index orelse 0,
    };
}
