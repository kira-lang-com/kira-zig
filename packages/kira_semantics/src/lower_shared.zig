const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");
const ImportedGlobals = @import("imported_globals.zig").ImportedGlobals;
const function_types = @import("function_types.zig");
const decls = @import("lower_shared_decls.zig");

pub const lowerAnnotationDecl = decls.lowerAnnotationDecl;
pub const lowerCapabilityDecl = decls.lowerCapabilityDecl;
pub const lowerGeneratedFunctions = decls.lowerGeneratedFunctions;
const ffi_annotations = @import("lower_shared_ffi_annotations.zig");
pub const resolveForeignFunction = ffi_annotations.resolveForeignFunction;
pub const resolveNamedTypeInfo = ffi_annotations.resolveNamedTypeInfo;
pub const CheckedAnnotationValue = ffi_annotations.CheckedAnnotationValue;
pub const annotationValueForParameter = ffi_annotations.annotationValueForParameter;
pub const annotationLiteralValue = ffi_annotations.annotationLiteralValue;
const captures = @import("lower_shared_captures.zig");
pub const CaptureResolution = captures.CaptureResolution;
pub const resolveLocalOrCapture = captures.resolveLocalOrCapture;
pub const emitUnsupportedMutableCapture = captures.emitUnsupportedMutableCapture;
// Construct-surface ownership queries (consuming receivers, Any-storage
// containment) live in lower_shared_construct_queries.zig (Core Law #5).
const construct_queries = @import("lower_shared_construct_queries.zig");
pub const methodConsumesSelf = construct_queries.methodConsumesSelf;
pub const containsConstructAnyStorage = construct_queries.containsConstructAnyStorage;
pub const markAnyFieldMovedIntoOwned = construct_queries.markAnyFieldMovedIntoOwned;

pub const Context = struct {
    allocator: std.mem.Allocator,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    imported_globals: ImportedGlobals = .{},
    annotation_headers: ?*const std.StringHashMapUnmanaged(AnnotationHeader) = null,
    construct_headers: ?*const std.StringHashMapUnmanaged(ConstructHeader) = null,
    type_headers: ?*const std.StringHashMapUnmanaged(TypeHeader) = null,
    type_alias_headers: ?*std.StringHashMapUnmanaged(TypeAliasHeader) = null,
    function_headers: ?*const std.StringHashMapUnmanaged(FunctionHeader) = null,
    enum_headers: ?*const std.StringHashMapUnmanaged(model.EnumDecl) = null,
    // Maps a concrete construct-backed declaration's type name to the construct families it
    // satisfies (its family plus that family's `extends` ancestors), so a concrete widget value
    // coerces to `any Widget`. Populated before function bodies are lowered.
    form_families: ?*const std.StringHashMapUnmanaged([]const []const u8) = null,
    // The lowered construct declarations (family surfaces), so method lowering can
    // resolve `@Consuming` family methods for concrete implementations. Set after
    // every construct declaration has been lowered; stable for the rest of lowering.
    constructs: ?[]const model.Construct = null,
    // Maps a declaration's type name to its `@Content` fields, so a trailing `{ ... }` block at a
    // construction site is routed into them (single `Widget` vs `[Widget]` arity, named fills).
    form_content_fields: ?*const std.StringHashMapUnmanaged([]const ContentFieldRef) = null,
    concrete_enums: ?*std.StringHashMapUnmanaged(model.EnumDecl) = null,
    callback_capture_frame: ?*CallbackCaptureFrame = null,
    active_locals: ?*std.array_list.Managed(model.LocalSymbol) = null,
    active_next_local_id: ?*u32 = null,
    current_package: ?[]const u8 = null,
    current_source_path: ?[]const u8 = null,
    /// Imports are FILE-scoped, not package-scoped: a file only sees the top-level
    /// names of the modules IT imports (plus its own package's names). These two maps
    /// implement that gate. `imported_symbol_owner` maps a top-level symbol's bare name
    /// to the package that declares it, but only for symbols from a NON-root package
    /// that are not shadowed by a root declaration. A name absent from this map is a
    /// root/local symbol (or a builtin) and is always visible. `file_module_imports`
    /// maps a file's canonical source path to the set of module-root names it imports.
    imported_symbol_owner: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    file_module_imports: ?*const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = null,
    /// Owner package name -> importable module root, recorded only when the two differ
    /// (Package UILibrary, moduleRoot "UI"). Import HINTS must name the module root —
    /// `import UILibrary` would not resolve, files import "UI" — while the visibility
    /// maps join on the owner package name.
    module_root_by_owner: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    /// Local type name -> declaring file origin, so header-phase type resolution
    /// (struct/class field types, which are lowered once while building type headers)
    /// is gated by the DECLARING file's imports rather than running ungated.
    local_type_origins: ?*const std.StringHashMapUnmanaged(syntax.ast.DeclOrigin) = null,
    /// When true, the active backend (the VM) can execute direct FFI calls from
    /// ordinary runtime functions through LibFFI, so the KSEM093 "@Native"
    /// requirement is lifted. Set per-target by the build pipeline.
    allow_runtime_direct_ffi: bool = false,
    /// Set transiently while lowering the receiver of `handle.await`,
    /// `handle.requestCancel()`, or `handle.detach()`. Task-handle bindings
    /// (`is_task_handle`) may only be read through those operations; any other
    /// read is rejected (KSEM158) so no code can depend on the handle's
    /// transparent runtime representation.
    allow_task_handle_read: bool = false,
    /// Lazily built index of extern function headers keyed by function id, so the
    /// direct-FFI boundary check resolves a callee's extern header in O(1) instead
    /// of scanning every function header per call expression (which made that check
    /// O(call sites x functions) — a real cost on FFI-heavy programs). Built once
    /// from `function_headers` on first use and stable for the rest of lowering.
    extern_headers_by_id: ?std.AutoHashMapUnmanaged(u32, FunctionHeader) = null,
    /// Current depth of the recursive expression walkers (enum registration and
    /// type lowering). Bounded by `max_lower_depth` so a pathologically deep
    /// expression tree (e.g. a long flat `1 + 1 + 1 + ...` chain, which the parser
    /// builds iteratively and so escapes the parser's nesting guard) raises a clean
    /// diagnostic instead of overflowing the native stack.
    lower_depth: u32 = 0,

    /// A top-level symbol declared in another package is visible in the current file
    /// only when the current file belongs to that package or imports that package's
    /// module. Same-package (root included), builtin, and unknown names are always
    /// visible here so ordinary resolution and unknown-name diagnostics still apply.
    /// Permissive in phases where the current file is not known (e.g. signature/header
    /// resolution) so only body-level references are gated.
    pub fn importedSymbolVisible(ctx: *const Context, name: []const u8) bool {
        const owners = ctx.imported_symbol_owner orelse return true;
        const owner = owners.get(name) orelse return true;
        if (ctx.current_package) |pkg| {
            if (std.mem.eql(u8, pkg, owner)) return true;
        }
        return ctx.fileImportsModule(owner);
    }

    /// Whether the current file imports `module`. Permissive (returns true) when the
    /// current file is unknown, so header/signature phases never spuriously reject.
    pub fn fileImportsModule(ctx: *const Context, module: []const u8) bool {
        const files = ctx.file_module_imports orelse return true;
        const path = ctx.current_source_path orelse return true;
        // Compiler-generated / synthetic decls (e.g. the `kira test` driver) carry an
        // empty source path and belong to no user file; they are never gated.
        if (path.len == 0) return true;
        const set = files.get(path) orelse return false;
        return set.contains(module);
    }

    /// Whether the current file may reference package `module` (it belongs to that
    /// package, or imports it). Permissive when the current file is unknown.
    pub fn moduleVisible(ctx: *const Context, module: []const u8) bool {
        if (ctx.current_package) |pkg| {
            if (std.mem.eql(u8, pkg, module)) return true;
        }
        return ctx.fileImportsModule(module);
    }

    /// File-scope visibility for a dotted name. Two dependency shapes are gated:
    /// the package-scoped key `Module.member` (created for every dependency top-level
    /// symbol, and equal to a user-written qualified reference), and a type-member key
    /// `Type.method` / `Type.constant` whose ROOT is a dependency type — referencing a
    /// dependency type's member is a reference to that type's name. Any other dotted
    /// name (e.g. a local type's method key) is left visible.
    pub fn qualifiedSymbolVisible(ctx: *const Context, name: []const u8) bool {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return ctx.importedSymbolVisible(name);
        const root = name[0..dot];
        const member = name[dot + 1 ..];
        const owners = ctx.imported_symbol_owner orelse return true;
        if (owners.get(member)) |owner| {
            if (std.mem.eql(u8, owner, root)) return ctx.moduleVisible(root);
        }
        if (owners.contains(root)) return ctx.importedSymbolVisible(root);
        return true;
    }

    /// File-scope visibility for an enum name. A generic instantiation is keyed by a
    /// mangled name (`Base__Arg__Arg`) that is not itself a declared symbol, so the base
    /// enum's visibility governs it.
    pub fn enumSymbolVisible(ctx: *const Context, name: []const u8) bool {
        if (!ctx.importedSymbolVisible(name)) return false;
        if (std.mem.indexOf(u8, name, "__")) |idx| {
            if (idx > 0) return ctx.importedSymbolVisible(name[0..idx]);
        }
        return true;
    }

    /// When `name` is only reachable through an import the current file is missing,
    /// returns the IMPORTABLE module name (for an import-hint diagnostic); otherwise
    /// null. For a package whose manifest name differs from its module root (Package
    /// UILibrary, moduleRoot "UI") the hint must name the module root — files write
    /// `import UI`; `import UILibrary` would not resolve.
    pub fn missingImportForSymbol(ctx: *const Context, name: []const u8) ?[]const u8 {
        const owners = ctx.imported_symbol_owner orelse return null;
        const owner = owners.get(name) orelse return null;
        const path = ctx.current_source_path orelse return null;
        if (path.len == 0) return null;
        if (ctx.current_package) |pkg| {
            if (std.mem.eql(u8, pkg, owner)) return null;
        }
        if (ctx.fileImportsModule(owner)) return null;
        if (ctx.module_root_by_owner) |roots| {
            if (roots.get(owner)) |module_root| return module_root;
        }
        return owner;
    }
};

/// Maximum recursion depth of the semantic expression walkers. Kept well below
/// the observed native-stack overflow threshold (~900 frames for the type-lowering
/// walker on an 8 MiB stack) while remaining far above any realistic hand- or
/// machine-written expression.
pub const max_lower_depth: u32 = 512;

/// The span of an arbitrary expression node, used to locate depth-limit
/// diagnostics. Mirrors the per-variant `.span` accessor the parser exposes.
pub fn exprSpan(expr: syntax.ast.Expr) source_pkg.Span {
    return switch (expr) {
        inline else => |node| node.span,
    };
}

/// Enter one level of an expression walker (the caller must pair this with a
/// `defer ctx.lower_depth -= 1;`). Emits KSEM155 and returns
/// `error.DiagnosticsEmitted` once the nesting/chain depth exceeds
/// `max_lower_depth`, before the walker can overflow the native stack.
pub fn checkLoweringDepth(ctx: *Context, span: source_pkg.Span) !void {
    if (ctx.lower_depth <= max_lower_depth) return;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM155",
        .title = "expression nests too deeply",
        .message = "This expression exceeds the maximum nesting/chain depth the compiler can lower without overflowing its stack.",
        .labels = &.{diagnostics.primaryLabel(span, "expression too deeply nested")},
        .help = "Split this into smaller subexpressions bound to intermediate `let` values.",
    });
    return error.DiagnosticsEmitted;
}

pub const CallbackCaptureFrame = struct {
    source_scope: *const model.Scope,
    active_scope: *model.Scope,
    captures: *std.array_list.Managed(model.Capture),
    locals: *std.array_list.Managed(model.LocalSymbol),
    next_local_id: *u32,
    parent: ?*CallbackCaptureFrame = null,
};

pub const AnnotationHeader = struct {
    index: ?usize = null,
    decl: model.AnnotationDecl,
    allows_block: bool = false,
    compiler_builtin: bool = false,
};

// A caller-provided `@Content` field of a declaration. `is_list` distinguishes `[Widget]`
// (ordered many) from a single `Widget`.
pub const ContentFieldRef = struct {
    name: []const u8,
    is_list: bool,
};

pub const FunctionHeader = struct {
    id: u32,
    params: []const model.ResolvedType = &.{},
    param_ownership: []const model.OwnershipMode = &.{},
    param_defaults: []const ?*syntax.ast.Expr = &.{},
    execution: runtime_abi.FunctionExecution,
    return_type: model.ResolvedType,
    return_ownership: model.OwnershipMode = .owned,
    is_extern: bool = false,
    is_comptime: bool = false,
    comptime_decl: ?syntax.ast.FunctionDecl = null,
    foreign: ?model.ForeignFunction = null,
    // A computed-property accessor synthesized from a `let name: T { ... }` member. Such a
    // method may be invoked by bare member access (`widget.node`, no parentheses), which is how
    // the Widget->Node bridge runs. Ordinary methods require an explicit call.
    is_accessor: bool = false,
    span: source_pkg.Span,
};

pub fn scopedSymbolName(allocator: std.mem.Allocator, package_name: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ package_name, name });
}

pub fn findFunctionHeader(ctx: *const Context, headers: *const std.StringHashMapUnmanaged(FunctionHeader), name: []const u8) ?FunctionHeader {
    if (ctx.current_package) |package_name| {
        if (std.mem.indexOfScalar(u8, name, '.') == null) {
            const scoped = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ package_name, name }) catch return null;
            if (headers.get(scoped)) |header| return header;
        }
    }
    if (headers.get(name)) |header| {
        // A bare name (or a package-scoped `Module.member` key) registered from another
        // package leaks package-wide unless the current file imports that package; the
        // file-scope gate rejects it here.
        if (!ctx.qualifiedSymbolVisible(name)) return null;
        return header;
    }
    return null;
}

pub const ConstructHeader = struct {
    index: usize,
    span: source_pkg.Span,
};

pub const ParentView = struct {
    type_name: []const u8,
    offset: u32,
    span: source_pkg.Span,
};

pub const MethodMember = struct {
    name: []const u8,
    full_name: []const u8,
    receiver_type_name: []const u8,
    receiver_offset: u32,
    generated_by: ?[]const u8 = null,
    overridable: bool = true,
    params: []const model.ResolvedType = &.{},
    param_ownership: []const model.OwnershipMode = &.{},
    return_type: model.ResolvedType,
    return_ownership: model.OwnershipMode = .owned,
    span: source_pkg.Span,
};

pub const TypeHeader = struct {
    kind: model.TypeKind = .struct_decl,
    execution: runtime_abi.FunctionExecution = .inherited,
    fields: []const model.Field = &.{},
    methods: []const MethodMember = &.{},
    parent_views: []const ParentView = &.{},
    ffi: ?model.NamedTypeInfo = null,
    is_printable: bool = false,
    // Propagated from the AST `@Derive(Copy)` marker into the HIR type declaration.
    derive_copy: bool = false,
    span: source_pkg.Span,
};

pub const TypeAliasHeader = struct {
    target: TypeAliasTarget,
    resolved: ?model.ResolvedType = null,
    state: TypeAliasResolverState = .unresolved,
    span: source_pkg.Span,
};

pub const TypeAliasTarget = union(enum) {
    syntax: syntax.ast.TypeExpr,
    imported: model.ResolvedType,
};

pub const TypeAliasResolverState = enum {
    unresolved,
    resolving,
    resolved,
};

pub const AnnotationPlacement = enum {
    function_decl,
    class_decl,
    struct_decl,
    construct_decl,
    construct_form_decl,
    field_decl,
    content_section,
};

pub fn registerBuiltinAnnotationHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMapUnmanaged(AnnotationHeader),
) !void {
    try putBuiltinAnnotation(allocator, headers, "Main", false);
    try putBuiltinAnnotation(allocator, headers, "Native", false);
    try putBuiltinAnnotation(allocator, headers, "Runtime", false);
    try putBuiltinAnnotation(allocator, headers, "Printable", false);
    // SwiftUI-style construct surface: `@Required` marks required construct members; `@Content`
    // marks caller-provided child fields on concrete declarations.
    try putBuiltinAnnotation(allocator, headers, "Required", false);
    try putBuiltinAnnotation(allocator, headers, "Content", false);
    // `@Consuming` on a construct-declaration method: the method takes `self`
    // OWNED (Rust `self` receiver) — the call consumes the receiver, the callee
    // owns and drops the shell, content fields may partial-move out. Every
    // concrete implementation of a consuming family method inherits the owned
    // receiver. `body` accessors are implicitly consuming.
    try putBuiltinAnnotation(allocator, headers, "Consuming", false);
    try putBuiltinAnnotation(allocator, headers, "FFI.Extern", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Struct", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Pointer", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Alias", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Array", true);
    try putBuiltinAnnotation(allocator, headers, "FFI.Callback", true);
}

fn putBuiltinAnnotation(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMapUnmanaged(AnnotationHeader),
    name: []const u8,
    allows_block: bool,
) !void {
    try headers.put(allocator, name, .{
        .decl = .{
            .name = name,
            .parameters = &.{},
            .module_path = "kira.compiler",
            .span = .{ .start = 0, .end = 0 },
        },
        .allows_block = allows_block,
        .compiler_builtin = true,
    });
}

const type_text = @import("lower_shared_type_text.zig");
pub const qualifiedNameText = type_text.qualifiedNameText;
pub const qualifiedNameLeaf = type_text.qualifiedNameLeaf;
pub const numericCastTargetType = type_text.numericCastTargetType;
pub const typeFromSyntax = type_text.typeFromSyntax;
pub const typeTextFromSyntax = type_text.typeTextFromSyntax;
pub const typeTextFromResolved = type_text.typeTextFromResolved;
pub const resolvedTypeFromText = type_text.resolvedTypeFromText;
pub fn canAssign(target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (target.eql(actual)) return true;
    if (target.kind == .array or actual.kind == .array) return false;
    return target.kind == .float and actual.kind == .integer;
}

pub fn canAssignExactly(target: model.ResolvedType, actual: model.ResolvedType) bool {
    return target.eql(actual);
}

pub fn canAssignInContext(ctx: *const Context, target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (canAssign(target, actual)) return true;
    if (sameEnumIdentity(ctx, target, actual)) return true;
    if (isConstructFamilyCoercion(ctx, target, actual)) return true;
    return isAssignableClassValue(ctx, target, actual);
}

// A concrete construct-backed declaration value (`Text`) coerces to `any Family` when its family
// (or one of that family's `extends` ancestors) is the constraint. `any Family` also coerces to
// the same `any Family`.
pub fn isConstructFamilyCoercion(ctx: *const Context, target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (target.kind != .construct_any) return false;
    const constraint = (target.construct_constraint orelse return false).construct_name;
    if (actual.kind == .construct_any) {
        const actual_constraint = (actual.construct_constraint orelse return false).construct_name;
        return std.mem.eql(u8, constraint, actual_constraint);
    }
    const actual_name = actual.name orelse return false;
    const families = ctx.form_families orelse return false;
    const list = families.get(actual_name) orelse return false;
    for (list) |family| {
        if (std.mem.eql(u8, family, constraint)) return true;
    }
    return false;
}

fn sameEnumIdentity(ctx: *const Context, target: model.ResolvedType, actual: model.ResolvedType) bool {
    if (!((target.kind == .enum_instance and actual.kind == .named) or (target.kind == .named and actual.kind == .enum_instance))) return false;
    if (target.name == null or actual.name == null) return false;
    if (!std.mem.eql(u8, target.name.?, actual.name.?)) return false;
    if (ctx.enum_headers) |headers| if (headers.get(target.name.?) != null) return true;
    if (ctx.concrete_enums) |enums| if (enums.get(target.name.?) != null) return true;
    return false;
}

pub fn emitTypeMismatch(
    allocator: std.mem.Allocator,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    span: source_pkg.Span,
    target: model.ResolvedType,
    actual: model.ResolvedType,
) !void {
    try diagnostics.appendOwned(allocator, out_diagnostics, .{
        .severity = .@"error",
        .code = "KSEM031",
        .title = "type mismatch",
        .message = try std.fmt.allocPrint(allocator, "Kira expected {s} here, but the value resolves to {s}.", .{ typeLabel(target), typeLabel(actual) }),
        .labels = &.{
            diagnostics.primaryLabel(span, "value does not match the required type"),
        },
        .help = "Add an explicit type declaration where coercion is allowed, or change the value so the type is unambiguous.",
    });
}

pub fn typeLabel(ty: model.ResolvedType) []const u8 {
    if (ty.kind == .construct_any) return ty.name orelse "any Unknown";
    if (ty.kind == .array) return ty.name orelse "[]";
    if (ty.name) |name| return name;
    return switch (ty.kind) {
        .void => "Void",
        .integer => "Int",
        .float => "Float",
        .boolean => "Bool",
        .string => "String",
        .c_string => "CString",
        .raw_ptr => "RawPtr",
        .construct_any => "any Unknown",
        .native_state => "NativeState",
        .native_state_view => "NativeStateView",
        .callback, .ffi_struct, .named, .enum_instance => "Unknown",
        .array => "[]",
        .unknown => "Unknown",
    };
}

pub fn typeFromSyntaxChecked(ctx: *Context, ty: syntax.ast.TypeExpr) anyerror!model.ResolvedType {
    const resolved = try typeFromSyntax(ctx, ty);
    try validateTypeVisibility(ctx, ty);
    const semantic_ty = stripOwnershipType(ty);
    if (semantic_ty == .generic) {
        const base_name = semantic_ty.generic.base.segments[semantic_ty.generic.base.segments.len - 1].text;
        if (ctx.enum_headers == null or ctx.enum_headers.?.get(base_name) == null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM031",
                .title = "type mismatch",
                .message = "Generic type syntax currently requires a declared enum base.",
                .labels = &.{diagnostics.primaryLabel(semantic_ty.generic.span, "generic type base could not be resolved as an enum")},
                .help = "Declare the enum first and use its generic type parameters in type positions only.",
            });
            return error.DiagnosticsEmitted;
        }
    }
    try validateAnyConstructType(ctx, ty);
    return resolved;
}

/// File-scope gate for type annotations: a parameter/return/field/local type that names
/// a dependency package's type requires the file DECLARING that annotation to import the
/// dependency's module. Walks the type expression and checks named leaves and generic
/// bases; `missingImportForSymbol` is permissive for local/builtin/unknown names and for
/// synthetic or unknown files, so only real cross-package references are gated.
pub fn validateTypeVisibility(ctx: *Context, ty: syntax.ast.TypeExpr) anyerror!void {
    switch (ty) {
        .ownership => |info| try validateTypeVisibility(ctx, info.target.*),
        // `any X` / `some X` targets are also validated (with the more specific KSEM097)
        // by validateAnyConstructTarget; this walk still gates non-construct targets.
        .any => |info| try validateTypeVisibility(ctx, info.target.*),
        .array => |info| try validateTypeVisibility(ctx, info.element_type.*),
        .function => |info| {
            for (info.params) |param| try validateTypeVisibility(ctx, param.*);
            try validateTypeVisibility(ctx, info.result.*);
        },
        .named => |name| try checkNamedTypeVisibility(ctx, name.segments[name.segments.len - 1].text, name.span),
        .generic => |info| {
            try checkNamedTypeVisibility(ctx, info.base.segments[info.base.segments.len - 1].text, info.base.span);
            for (info.args) |arg| try validateTypeVisibility(ctx, arg.*);
        },
    }
}

fn checkNamedTypeVisibility(ctx: *Context, leaf: []const u8, span: source_pkg.Span) !void {
    const module = ctx.missingImportForSymbol(leaf) orelse return;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM168",
        .title = "type is not visible in this file",
        .message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is defined in module '{s}', which this file does not import.", .{ leaf, module }),
        .labels = &.{diagnostics.primaryLabel(span, "type is not visible in this file")},
        .help = try std.fmt.allocPrint(ctx.allocator, "Add `import {s}` to this file (imports are per-file).", .{module}),
    });
    return error.DiagnosticsEmitted;
}

pub fn validateAnyConstructType(ctx: *Context, ty: syntax.ast.TypeExpr) !void {
    switch (ty) {
        .ownership => |info| try validateAnyConstructType(ctx, info.target.*),
        .any => |info| {
            try validateAnyConstructTarget(ctx, info.target.*, info.span, info.existential);
            try validateAnyConstructType(ctx, info.target.*);
        },
        .array => |info| try validateAnyConstructType(ctx, info.element_type.*),
        .function => |info| {
            for (info.params) |param| try validateAnyConstructType(ctx, param.*);
            try validateAnyConstructType(ctx, info.result.*);
        },
        .named, .generic => {},
    }
}

pub fn ownershipModeFromSyntax(ty: ?*syntax.ast.TypeExpr) model.OwnershipMode {
    const resolved = ty orelse return .owned;
    return switch (resolved.*) {
        .ownership => |info| ownershipModeFromSyntaxMode(info.mode),
        else => .owned,
    };
}

fn ownershipModeFromSyntaxMode(mode: syntax.ast.OwnershipMode) model.OwnershipMode {
    return switch (mode) {
        .owned => .owned,
        .borrow_read => .borrow_read,
        .borrow_mut => .borrow_mut,
        .move => .move,
        .copy => .copy,
    };
}

pub fn stripOwnershipType(ty: syntax.ast.TypeExpr) syntax.ast.TypeExpr {
    return switch (ty) {
        .ownership => |info| stripOwnershipType(info.target.*),
        else => ty,
    };
}

pub fn paramOwnership(header: FunctionHeader, index: usize) model.OwnershipMode {
    if (index < header.param_ownership.len) return header.param_ownership[index];
    return .owned;
}

fn validateAnyConstructTarget(ctx: *Context, target: syntax.ast.TypeExpr, span: source_pkg.Span, existential: bool) !void {
    const name = switch (target) {
        .named => |qualified| qualified.segments[qualified.segments.len - 1].text,
        else => {
            try emitAnyRequiresConstruct(ctx, span, "target is not a construct", existential);
            return error.DiagnosticsEmitted;
        },
    };
    if (ctx.construct_headers) |headers| if (headers.contains(name)) {
        // Imports are file-scoped: naming a dependency package's construct in an
        // `any`/`some` type requires this file to import its module.
        if (ctx.missingImportForSymbol(name)) |module| {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM097",
                .title = "construct is not visible in this file",
                .message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is defined in module '{s}', which this file does not import.", .{ name, module }),
                .labels = &.{diagnostics.primaryLabel(span, "construct is not visible in this file")},
                .help = try std.fmt.allocPrint(ctx.allocator, "Add `import {s}` to this file (imports are per-file).", .{module}),
            });
            return error.DiagnosticsEmitted;
        }
        return;
    };
    if (ctx.imported_globals.hasConstruct(name)) return;
    if (isBuiltinTypeName(name) or isResolvedNonConstructSymbol(ctx, name)) {
        try emitAnyRequiresConstruct(ctx, span, "resolved target is not a construct", existential);
        return error.DiagnosticsEmitted;
    }
}

fn isResolvedNonConstructSymbol(ctx: *const Context, name: []const u8) bool {
    if (ctx.type_alias_headers) |headers| if (headers.contains(name)) return true;
    if (ctx.type_headers) |headers| if (headers.contains(name)) return true;
    if (ctx.imported_globals.findAlias(name) != null) return true;
    if (ctx.imported_globals.findType(name) != null) return true;
    if (ctx.function_headers) |headers| if (headers.contains(name)) return true;
    if (ctx.imported_globals.findFunction(name) != null) return true;
    if (ctx.annotation_headers) |headers| if (headers.contains(name)) return true;
    return false;
}

pub fn resolveTypeAlias(ctx: *const Context, name: []const u8) !?model.ResolvedType {
    const alias_headers = ctx.type_alias_headers orelse {
        if (ctx.imported_globals.findAlias(name)) |alias_decl| return alias_decl.target;
        return null;
    };
    const header = alias_headers.getPtr(name) orelse {
        if (ctx.imported_globals.findAlias(name)) |alias_decl| return alias_decl.target;
        return null;
    };
    switch (header.state) {
        .resolved => return header.resolved,
        .resolving => {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM157",
                .title = "cyclic type alias",
                .message = try std.fmt.allocPrint(ctx.allocator, "The type alias '{s}' resolves back to itself through another alias.", .{name}),
                .labels = &.{diagnostics.primaryLabel(header.span, "cyclic alias defined here")},
                .help = "Break the alias cycle so every `type Name = Target` chain reaches a concrete target type.",
            });
            return error.DiagnosticsEmitted;
        },
        .unresolved => {},
    }

    header.state = .resolving;
    const resolved = switch (header.target) {
        .syntax => |target| try typeFromSyntax(ctx, target),
        .imported => |target| target,
    };
    header.resolved = resolved;
    header.state = .resolved;
    return resolved;
}

fn isBuiltinTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float") or
        std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Void") or std.mem.eql(u8, name, "I8") or
        std.mem.eql(u8, name, "U8") or std.mem.eql(u8, name, "I16") or
        std.mem.eql(u8, name, "U16") or std.mem.eql(u8, name, "I32") or
        std.mem.eql(u8, name, "U32") or std.mem.eql(u8, name, "I64") or
        std.mem.eql(u8, name, "U64") or std.mem.eql(u8, name, "F32") or
        std.mem.eql(u8, name, "F64") or std.mem.eql(u8, name, "CBool") or
        std.mem.eql(u8, name, "CString") or std.mem.eql(u8, name, "RawPtr");
}

fn emitAnyRequiresConstruct(ctx: *Context, span: source_pkg.Span, label: []const u8, existential: bool) !void {
    const keyword = if (existential) "some" else "any";
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM097",
        .title = try std.fmt.allocPrint(ctx.allocator, "{s} requires a construct", .{keyword}),
        .message = try std.fmt.allocPrint(ctx.allocator, "The `{s}` qualifier can only be applied to a construct name.", .{keyword}),
        .labels = &.{diagnostics.primaryLabel(span, label)},
        .help = try std.fmt.allocPrint(ctx.allocator, "Use `{s} ConstructName` with a declared construct, or remove `{s}` from non-construct types.", .{ keyword, keyword }),
    });
}

const type_relations = @import("lower_shared_type_relations.zig");
pub const namedTypeInfo = type_relations.namedTypeInfo;
pub const namedTypeHeader = type_relations.namedTypeHeader;
pub const namedTypeKind = type_relations.namedTypeKind;
pub const isClassType = type_relations.isClassType;
pub const hasKnownSubclass = type_relations.hasKnownSubclass;
pub const isAssignableClassValue = type_relations.isAssignableClassValue;
pub const commonConstructAnyType = type_relations.commonConstructAnyType;
pub const commonClassType = type_relations.commonClassType;
pub const namedTypeFields = type_relations.namedTypeFields;
pub const isPointerLike = type_relations.isPointerLike;
pub const callbackInfo = type_relations.callbackInfo;
const symbol_helpers = @import("lower_shared_symbols.zig");
pub const emitAmbiguousInference = symbol_helpers.emitAmbiguousInference;
pub const registerTopLevelName = symbol_helpers.registerTopLevelName;
pub const containsAnnotationRule = symbol_helpers.containsAnnotationRule;
pub const containsString = symbol_helpers.containsString;
pub const isImportedRoot = symbol_helpers.isImportedRoot;
pub const importedQualifiedName = symbol_helpers.importedQualifiedName;
pub const resolveAnnotationHeader = symbol_helpers.resolveAnnotationHeader;

const annotation_impl = @import("lower_shared_annotations.zig");
pub const lowerAnnotation = annotation_impl.lowerAnnotation;
pub const validateAnnotationUse = annotation_impl.validateAnnotationUse;
pub const resolveFunctionAnnotations = annotation_impl.resolveFunctionAnnotations;
pub const lowerAnnotations = annotation_impl.lowerAnnotations;
pub const validateAnnotationPlacement = annotation_impl.validateAnnotationPlacement;
