const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const type_impl = @import("lower_program_types.zig");
const parent = @import("lower_program.zig");

const lowerFunction = parent.lowerFunction;

// A construct-backed declaration's functions and lifecycle hooks are real instance methods on the
// declaration value. They lower to flat `Form.member(self, ...)` functions, exactly like struct
// methods, so widget inputs declared in the form header become runtime fields that methods such as
// `lower(context)` can read through implicit `self`.

fn memberName(allocator: std.mem.Allocator, form_name: []const u8, member: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ form_name, member });
}

// Register a callable header for every function and lifecycle hook of a construct-backed
// declaration, so cross-references (e.g. one declaration function calling another) resolve
// during body lowering.
pub fn registerConstructFormFunctionHeaders(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    for (form_decl.body.members) |member| {
        switch (member) {
            .function_decl => |function_decl| try registerCallableHeader(
                ctx,
                form_decl.name,
                function_decl.annotations,
                function_decl.name,
                function_decl.params,
                function_decl.return_type,
                function_decl.span,
                function_headers,
            ),
            .lifecycle_hook => |hook| try registerCallableHeader(
                ctx,
                form_decl.name,
                &.{},
                hook.name,
                &.{},
                null,
                hook.span,
                function_headers,
            ),
            else => {},
        }
    }
}

fn registerCallableHeader(
    ctx: *shared.Context,
    form_name: []const u8,
    annotations: []const syntax.ast.Annotation,
    member: []const u8,
    params: []const syntax.ast.ParamDecl,
    return_type: ?*syntax.ast.TypeExpr,
    span: source_pkg.Span,
    function_headers: *std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    const annotation_info = try shared.resolveFunctionAnnotations(ctx, annotations);
    const foreign = try shared.resolveForeignFunction(ctx, annotations, span);

    var param_types = std.array_list.Managed(model.ResolvedType).init(ctx.allocator);
    var param_ownership = std.array_list.Managed(model.OwnershipMode).init(ctx.allocator);
    var param_defaults = std.array_list.Managed(?*syntax.ast.Expr).init(ctx.allocator);
    try param_types.append(.{ .kind = .named, .name = form_name });
    try param_ownership.append(.borrow_read);
    try param_defaults.append(null);
    for (params) |param| {
        try param_ownership.append(shared.ownershipModeFromSyntax(param.type_expr));
        try param_defaults.append(param.default_value);
        if (param.type_expr) |type_expr| {
            try param_types.append(try shared.typeFromSyntaxChecked(ctx, type_expr.*));
        } else {
            try param_types.append(.{ .kind = .unknown });
        }
    }

    const name = try memberName(ctx.allocator, form_name, member);
    try function_headers.put(ctx.allocator, name, .{
        .id = @as(u32, @intCast(function_headers.count())),
        .params = try param_types.toOwnedSlice(),
        .param_ownership = try param_ownership.toOwnedSlice(),
        .param_defaults = try param_defaults.toOwnedSlice(),
        .execution = if (foreign != null and annotation_info.execution == .inherited) .native else annotation_info.execution,
        .return_type = if (return_type) |rt| try shared.typeFromSyntaxChecked(ctx, rt.*) else .{ .kind = .unknown },
        .return_ownership = shared.ownershipModeFromSyntax(return_type),
        .is_extern = foreign != null,
        .foreign = foreign,
        .span = span,
    });
}

pub fn registerConstructFormMethods(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    type_headers: *std.StringHashMapUnmanaged(shared.TypeHeader),
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    var header = type_headers.get(form_decl.name) orelse return;
    var methods = std.array_list.Managed(shared.MethodMember).init(ctx.allocator);
    try methods.appendSlice(header.methods);

    for (form_decl.body.members) |member| {
        switch (member) {
            .function_decl => |function_decl| {
                if (type_impl.methodNameExists(methods.items, function_decl.name)) continue;
                try methods.append(try type_impl.makeDeclaredMethodMember(ctx, form_decl.name, function_decl));
            },
            .lifecycle_hook => |hook| {
                if (type_impl.methodNameExists(methods.items, hook.name)) continue;
                const full_name = try memberName(ctx.allocator, form_decl.name, hook.name);
                const function_header = function_headers.get(full_name) orelse continue;
                try methods.append(.{
                    .name = try ctx.allocator.dupe(u8, hook.name),
                    .full_name = full_name,
                    .receiver_type_name = try ctx.allocator.dupe(u8, form_decl.name),
                    .receiver_offset = 0,
                    .params = if (function_header.params.len > 0) function_header.params[1..] else &.{},
                    .param_ownership = if (function_header.param_ownership.len > 0) function_header.param_ownership[1..] else &.{},
                    .return_type = function_header.return_type,
                    .return_ownership = function_header.return_ownership,
                    .span = hook.span,
                });
            },
            else => {},
        }
    }

    header.methods = try methods.toOwnedSlice();
    try type_headers.put(ctx.allocator, form_decl.name, header);
}

// Lower a construct-backed declaration's functions and lifecycle hook bodies into flat
// `model.Function`s. Each one's id is read from the header registered above (by name), so the
// append order here is independent of id assignment.
pub fn lowerConstructFormFunctions(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    imports: []const model.Import,
    function_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) ![]model.Function {
    var functions = std.array_list.Managed(model.Function).init(ctx.allocator);

    for (form_decl.body.members) |member| {
        switch (member) {
            .function_decl => |function_decl| {
                try functions.append(try type_impl.lowerMethodFunction(ctx, form_decl.name, function_decl, imports, function_headers));
            },
            .lifecycle_hook => |hook| {
                try functions.append(try type_impl.lowerMethodFunction(ctx, form_decl.name, .{
                    .annotations = &.{},
                    .name = hook.name,
                    .params = &.{},
                    .return_type = null,
                    .body = hook.body,
                    .span = hook.span,
                }, imports, function_headers));
            },
            else => {},
        }
    }

    return functions.toOwnedSlice();
}
