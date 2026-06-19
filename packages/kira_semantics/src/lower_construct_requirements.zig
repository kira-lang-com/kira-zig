const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

// A construct-backed declaration's own implemented function signatures, captured at the AST
// level (param/return types as canonical text; `Self` left literal for late normalization).
const FormFuncSig = struct {
    name: []const u8,
    param_types: [][]const u8,
    return_type: []const u8,
    span: source_pkg.Span,
};

const FormInfo = struct {
    name: []const u8,
    parent_leaf: []const u8,
    funcs: []FormFuncSig,
    span: source_pkg.Span,
};

// Detect cycles in declaration-parent chains (`A B { ... }` then `B A { ... }`) and reject them
// (KSEM119). Runs before declarations are lowered, so a cycle is reported as a cycle rather than
// surfacing later as an unresolvable parent. `form_parent` maps each declaration to its parent
// name; constructs are not keys, so the walk terminates when it reaches a construct.
pub fn validateFormParentCycles(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    form_parent: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    for (program.decls) |decl| {
        if (decl != .construct_form_decl) continue;
        const form_decl = decl.construct_form_decl;
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(ctx.allocator);
        var current: []const u8 = form_decl.name;
        while (true) {
            if (seen.contains(current)) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM119",
                    .title = "construct inheritance cycle",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The declaration '{s}' is part of an inheritance cycle.", .{form_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(form_decl.span, "this declaration's parent chain forms a cycle")},
                    .help = "Break the cycle so declaration inheritance forms a directed acyclic graph.",
                });
                return error.DiagnosticsEmitted;
            }
            try seen.put(ctx.allocator, current, {});
            current = form_parent.get(current) orelse break;
        }
    }
}

// Resolve any name (construct or construct-backed declaration) to the construct family it
// belongs to, by walking declaration parents up to the construct that roots the chain. Returns
// null when the chain does not terminate at a locally-known construct (e.g. an imported or
// unknown parent), or when a declaration-parent cycle is detected.
pub fn resolveFamilyConstructModel(
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    form_parent: *const std.StringHashMapUnmanaged([]const u8),
    name: []const u8,
) ?model.Construct {
    var current = name;
    var hops: usize = 0;
    while (hops < 4096) : (hops += 1) {
        if (construct_headers.get(current)) |header| return constructs[header.index];
        current = form_parent.get(current) orelse return null;
    }
    return null;
}

// Validate that every construct-backed declaration satisfies its construct family's required
// functions. The inheritance graph spans construct->construct (`extends`), declaration->construct
// (a first concrete child), and declaration->declaration (a child reusing a prior declaration as
// its parent). A required function is satisfied by the declaration itself or by any ancestor
// declaration; the first declaration that leaves a requirement unmet is rejected (KSEM120).
// Declaration-parent cycles are rejected (KSEM119); a parent that is neither a construct nor a
// declaration is rejected (KSEM122). Implementations of a required function must match its
// signature with `Self` resolved to the implementing declaration (KSEM121).
pub fn validateConstructFormRequirements(
    ctx: *shared.Context,
    program: syntax.ast.Program,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    form_parent: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    var forms = std.StringHashMapUnmanaged(FormInfo){};
    defer forms.deinit(ctx.allocator);

    for (program.decls) |decl| {
        if (decl != .construct_form_decl) continue;
        const form_decl = decl.construct_form_decl;
        var funcs = std.array_list.Managed(FormFuncSig).init(ctx.allocator);
        for (form_decl.body.members) |member| {
            if (member != .function_decl) continue;
            try funcs.append(try formFuncSig(ctx, member.function_decl));
        }
        try forms.put(ctx.allocator, form_decl.name, .{
            .name = form_decl.name,
            .parent_leaf = form_decl.construct_name.segments[form_decl.construct_name.segments.len - 1].text,
            .funcs = try funcs.toOwnedSlice(),
            .span = form_decl.span,
        });
    }

    var it = forms.iterator();
    while (it.next()) |entry| {
        try validateForm(ctx, entry.value_ptr.*, &forms, constructs, construct_headers, form_parent);
    }
}

fn validateForm(
    ctx: *shared.Context,
    form: FormInfo,
    forms: *const std.StringHashMapUnmanaged(FormInfo),
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    form_parent: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    // A declaration whose family does not resolve to a locally-known construct is either rooted
    // at an imported construct (whose requirements are not visible here) or was already rejected
    // as an unknown parent during form lowering (KSEM020). Either way there is nothing to check.
    const family = resolveFamilyConstructModel(constructs, construct_headers, form_parent, form.parent_leaf) orelse return;

    var required = std.StringArrayHashMapUnmanaged(model.RequiredFunction){};
    defer required.deinit(ctx.allocator);
    try collectConstructRequiredFunctions(ctx, family, constructs, construct_headers, &required);
    if (required.count() == 0) return;

    var implemented = std.StringHashMapUnmanaged(FormFuncSig){};
    defer implemented.deinit(ctx.allocator);
    try collectChainImplemented(ctx, form.name, forms, construct_headers, &implemented);

    for (required.values()) |req| {
        if (implemented.get(req.name) == null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM120",
                .title = "missing required function",
                .message = try std.fmt.allocPrint(ctx.allocator, "The declaration '{s}' must implement the required function '{s}' of construct '{s}'.", .{ form.name, req.name, family.name }),
                .labels = &.{diagnostics.primaryLabel(form.span, "required function is not implemented")},
                .help = "Implement the required function in this declaration, or inherit it from a parent declaration that does.",
            });
            return error.DiagnosticsEmitted;
        }
    }

    // A direct implementation of a required function must match the required signature, with
    // `Self` resolved to the implementing declaration's type.
    for (form.funcs) |impl| {
        const req = required.get(impl.name) orelse continue;
        if (!signaturesMatch(req, impl, form.name)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM121",
                .title = "required function signature mismatch",
                .message = try std.fmt.allocPrint(ctx.allocator, "The implementation of '{s}' in declaration '{s}' does not match the signature required by construct '{s}'.", .{ impl.name, form.name, family.name }),
                .labels = &.{diagnostics.primaryLabel(impl.span, "signature does not match the required function")},
                .help = "Match the required parameter and return types (use `Self` for the implementing type).",
            });
            return error.DiagnosticsEmitted;
        }
    }
}

// Collect a construct's transitive required functions (its own plus all `extends` ancestors').
fn collectConstructRequiredFunctions(
    ctx: *shared.Context,
    construct_model: model.Construct,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    out: *std.StringArrayHashMapUnmanaged(model.RequiredFunction),
) !void {
    for (construct_model.parents) |parent_link| {
        if (construct_headers.get(parent_link.name)) |header| {
            try collectConstructRequiredFunctions(ctx, constructs[header.index], constructs, construct_headers, out);
        }
    }
    for (construct_model.required_functions) |req| {
        try out.put(ctx.allocator, req.name, req);
    }
}

// Collect the function implementations visible to a declaration: its own plus those of every
// ancestor declaration, stopping at the construct that roots the chain.
fn collectChainImplemented(
    ctx: *shared.Context,
    form_name: []const u8,
    forms: *const std.StringHashMapUnmanaged(FormInfo),
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    out: *std.StringHashMapUnmanaged(FormFuncSig),
) !void {
    var current = form_name;
    var hops: usize = 0;
    while (hops < 4096) : (hops += 1) {
        const info = forms.get(current) orelse return;
        for (info.funcs) |func| {
            if (!out.contains(func.name)) try out.put(ctx.allocator, func.name, func);
        }
        if (construct_headers.get(info.parent_leaf) != null) return;
        current = info.parent_leaf;
    }
}

fn formFuncSig(ctx: *shared.Context, function_decl: syntax.ast.FunctionDecl) !FormFuncSig {
    var param_types = std.array_list.Managed([]const u8).init(ctx.allocator);
    for (function_decl.params) |param| {
        const text = if (param.type_expr) |type_expr|
            try shared.typeTextFromSyntax(ctx, type_expr.*)
        else
            "";
        try param_types.append(text);
    }
    const return_type = if (function_decl.return_type) |type_expr|
        try shared.typeTextFromSyntax(ctx, type_expr.*)
    else
        "Void";
    return .{
        .name = function_decl.name,
        .param_types = try param_types.toOwnedSlice(),
        .return_type = return_type,
        .span = function_decl.span,
    };
}

fn signaturesMatch(req: model.RequiredFunction, impl: FormFuncSig, self_name: []const u8) bool {
    if (req.param_types.len != impl.param_types.len) return false;
    for (req.param_types, impl.param_types) |req_param, impl_param| {
        if (!typeTextMatches(req_param, impl_param, self_name)) return false;
    }
    return typeTextMatches(req.return_type, impl.return_type, self_name);
}

fn typeTextMatches(required: []const u8, actual: []const u8, self_name: []const u8) bool {
    const req_norm = if (std.mem.eql(u8, required, "Self")) self_name else required;
    const act_norm = if (std.mem.eql(u8, actual, "Self")) self_name else actual;
    return std.mem.eql(u8, req_norm, act_norm);
}
