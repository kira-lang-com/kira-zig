const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

pub fn resolveMethod(
    ctx: *shared.Context,
    object_type: model.ResolvedType,
    method_name: []const u8,
    span: source_pkg.Span,
    diagnose_missing: bool,
) !?shared.MethodMember {
    const constraint = object_type.construct_constraint orelse return null;
    const families = ctx.form_families orelse return null;
    const headers = ctx.type_headers orelse return null;
    var match: ?shared.MethodMember = null;
    var saw_form = false;

    var iterator = families.iterator();
    while (iterator.next()) |entry| {
        if (!familyListContains(entry.value_ptr.*, constraint.construct_name)) continue;
        saw_form = true;
        const header = headers.get(entry.key_ptr.*) orelse continue;
        const method = methodByName(header.methods, method_name) orelse {
            if (!diagnose_missing) return null;
            try emitMissingConstructAnyMethod(ctx, constraint.construct_name, entry.key_ptr.*, method_name, span);
            return error.DiagnosticsEmitted;
        };
        if (match) |existing| {
            if (!sameSignature(existing, method)) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM066",
                    .title = "unknown method",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The construct family '{s}' does not expose a uniform method named '{s}'.", .{ constraint.construct_name, method_name }),
                    .labels = &.{diagnostics.primaryLabel(span, "method is not uniform across the construct family")},
                    .help = "Give every declaration in the family the same method signature before calling it through `any`.",
                });
                return error.DiagnosticsEmitted;
            }
        } else {
            match = method;
        }
    }

    if (!saw_form or match == null) {
        if (diagnose_missing) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM066",
                .title = "unknown method",
                .message = try std.fmt.allocPrint(ctx.allocator, "The construct family '{s}' does not declare a method named '{s}'.", .{ constraint.construct_name, method_name }),
                .labels = &.{diagnostics.primaryLabel(span, "method name is not declared on this construct family")},
                .help = "Declare the method on every concrete declaration that satisfies the family.",
            });
            return error.DiagnosticsEmitted;
        }
        return null;
    }
    return match;
}

fn familyListContains(families: []const []const u8, name: []const u8) bool {
    for (families) |family| {
        if (std.mem.eql(u8, family, name)) return true;
    }
    return false;
}

fn methodByName(methods: []const shared.MethodMember, name: []const u8) ?shared.MethodMember {
    for (methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, name)) return method_decl;
    }
    return null;
}

fn sameSignature(lhs: shared.MethodMember, rhs: shared.MethodMember) bool {
    if (lhs.params.len != rhs.params.len) return false;
    if (!shared.canAssignExactly(lhs.return_type, rhs.return_type)) return false;
    for (lhs.params, rhs.params) |lhs_param, rhs_param| {
        if (!shared.canAssignExactly(lhs_param, rhs_param)) return false;
    }
    return true;
}

fn emitMissingConstructAnyMethod(
    ctx: *shared.Context,
    family: []const u8,
    type_name: []const u8,
    method_name: []const u8,
    span: source_pkg.Span,
) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM066",
        .title = "unknown method",
        .message = try std.fmt.allocPrint(ctx.allocator, "The construct declaration '{s}' satisfies '{s}' but does not expose method '{s}'.", .{ type_name, family, method_name }),
        .labels = &.{diagnostics.primaryLabel(span, "method is missing from at least one concrete declaration")},
        .help = "Declare the method on every concrete declaration that satisfies the family.",
    });
}
