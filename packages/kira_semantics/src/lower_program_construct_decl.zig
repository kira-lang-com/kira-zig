//! Lowering of `construct C { ... }` declarations: sections (content/requires/
//! lifecycle/sections), Construct 2.0 removed-surface rejections, and the direct
//! member surface. Split from lower_program_types.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const construct_members = @import("lower_construct_members.zig");

pub fn lowerConstructDecl(ctx: *shared.Context, construct_decl: syntax.ast.ConstructDecl) !model.Construct {
    try shared.validateAnnotationPlacement(ctx, construct_decl.annotations, .construct_decl, null);
    var allowed_annotations = std.array_list.Managed(model.AnnotationRule).init(ctx.allocator);
    var allowed_lifecycle_hooks = std.array_list.Managed([]const u8).init(ctx.allocator);
    var parents = std.array_list.Managed(model.ConstructParent).init(ctx.allocator);
    var properties = std.array_list.Managed(model.PropertySchema).init(ctx.allocator);
    var property_names = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer property_names.deinit(ctx.allocator);
    var content_channels = std.array_list.Managed(model.ContentChannel).init(ctx.allocator);
    var content_refine = std.array_list.Managed(model.ContentChannel).init(ctx.allocator);
    var content_projections = std.array_list.Managed(model.ContentProjection).init(ctx.allocator);
    var content_sealed = false;
    var content_passthrough = false;
    var channel_names = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer channel_names.deinit(ctx.allocator);
    var required_functions = std.array_list.Managed(model.RequiredFunction).init(ctx.allocator);
    var section_functions = std.array_list.Managed(model.SectionFunction).init(ctx.allocator);
    var content_element_type: ?[]const u8 = null;

    for (construct_decl.parents) |parent_name| {
        try parents.append(.{
            .name = try shared.qualifiedNameLeaf(ctx.allocator, parent_name),
            .span = parent_name.span,
        });
    }

    for (construct_decl.sections) |section| {
        // A typed content section `content: Content<T>;` parses as a custom section
        // named "content" whose single entry is a named_rule carrying the type expr.
        // It both requires a content block and pins the element type used to validate
        // construct-backed declarations.
        if (std.mem.eql(u8, section.name, "content")) {
            // Construct 2.0 (item 6): named content channels (`head { accepts X; count 0..1 }`)
            // and the content-composition directives (`sealed` / `refine` / `passthrough` /
            // `project`) are removed. A construct types its child slots directly as `some X` /
            // `[some X]` fields instead. A typed `content: Content<T>;` section (a named_rule
            // entry) is left alone here.
            for (section.entries) |entry| {
                const is_channel_surface = switch (entry) {
                    .content_channel, .content_directive, .content_projection => true,
                    else => false,
                };
                if (!is_channel_surface) continue;
                const entry_span = switch (entry) {
                    .content_channel => |c| c.span,
                    .content_directive => |d| d.span,
                    .content_projection => |p| p.span,
                    else => section.span,
                };
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM165",
                    .title = "content channels are removed",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' declares a content channel or composition directive, which Construct 2.0 no longer supports.", .{construct_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(entry_span, "content channels / `accepts` / `count` / `sealed` / `refine` / `project` are no longer a construct surface")},
                    .help = "Type the construct's child slot directly as a field: `some X` for one child or `[some X]` for many.",
                });
                return error.DiagnosticsEmitted;
            }
            var refine_mode = false;
            for (section.entries) |entry| {
                if (entry == .content_directive and entry.content_directive.mode == .refine) refine_mode = true;
            }
            for (section.entries) |entry| {
                switch (entry) {
                    .named_rule => |rule| {
                        // A typed `content: Content<T>;` section pins the element type used
                        // to validate construct-backed declarations. Content-requiredness is
                        // expressed through content channels (`count`), not this section.
                        if (rule.type_expr) |type_expr| {
                            content_element_type = contentElementTypeName(type_expr.*);
                        }
                    },
                    .content_directive => |directive| switch (directive.mode) {
                        .sealed => content_sealed = true,
                        .passthrough => content_passthrough = true,
                        .refine, .project => {},
                    },
                    .content_projection => |projection| {
                        try content_projections.append(.{
                            .local = try ctx.allocator.dupe(u8, projection.local),
                            .target_construct = try ctx.allocator.dupe(u8, projection.target_construct.segments[projection.target_construct.segments.len - 1].text),
                            .target_channel = try ctx.allocator.dupe(u8, projection.target_channel),
                            .span = projection.span,
                        });
                    },
                    .content_channel => |channel| {
                        if (refine_mode) {
                            try content_refine.append(.{
                                .name = try ctx.allocator.dupe(u8, channel.name),
                                .accepts = if (channel.accepts) |a| try ctx.allocator.dupe(u8, a.segments[a.segments.len - 1].text) else null,
                                .min = if (channel.count) |range| range.min else 0,
                                .max = if (channel.count) |range| range.max else null,
                                .span = channel.span,
                            });
                            continue;
                        }
                        if (channel_names.get(channel.name)) |previous_span| {
                            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                                .severity = .@"error",
                                .code = "KSEM138",
                                .title = "duplicate content channel",
                                .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' declares the content channel '{s}' more than once.", .{ construct_decl.name, channel.name }),
                                .labels = &.{
                                    diagnostics.primaryLabel(channel.span, "duplicate content channel declared here"),
                                    diagnostics.secondaryLabel(previous_span, "the channel was already declared here"),
                                },
                                .help = "Declare each content channel at most once in the construct's `content { ... }` block.",
                            });
                            return error.DiagnosticsEmitted;
                        }
                        try channel_names.put(ctx.allocator, channel.name, channel.span);
                        const accepts: ?[]const u8 = if (channel.accepts) |accepts_name|
                            try ctx.allocator.dupe(u8, accepts_name.segments[accepts_name.segments.len - 1].text)
                        else
                            null;
                        try content_channels.append(.{
                            .name = try ctx.allocator.dupe(u8, channel.name),
                            .accepts = accepts,
                            .min = if (channel.count) |range| range.min else 0,
                            .max = if (channel.count) |range| range.max else null,
                            .span = channel.span,
                        });
                    },
                    else => {},
                }
            }
        }
        switch (section.kind) {
            .annotations => {
                for (section.entries) |entry| {
                    if (entry == .annotation_spec) {
                        _ = try shared.resolveAnnotationHeader(ctx, entry.annotation_spec.name);
                        try allowed_annotations.append(.{
                            .name = try shared.qualifiedNameLeaf(ctx.allocator, entry.annotation_spec.name),
                            .span = entry.annotation_spec.span,
                        });
                    }
                }
            },
            .requires => {
                // `requires` declares required *functions*. Content-requiredness is
                // expressed through content channels (`content { name { count 1.. } }`).
                for (section.entries) |entry| {
                    switch (entry) {
                        .function_signature => |signature| {
                            var param_types = std.array_list.Managed([]const u8).init(ctx.allocator);
                            for (signature.params) |param| {
                                const text = if (param.type_expr) |type_expr|
                                    try shared.typeTextFromSyntax(ctx, type_expr.*)
                                else
                                    "";
                                try param_types.append(text);
                            }
                            const return_type = if (signature.return_type) |type_expr|
                                try shared.typeTextFromSyntax(ctx, type_expr.*)
                            else
                                "Void";
                            try required_functions.append(.{
                                .name = try ctx.allocator.dupe(u8, signature.name),
                                .param_types = try param_types.toOwnedSlice(),
                                .return_type = return_type,
                                .span = signature.span,
                            });
                        },
                        else => {},
                    }
                }
            },
            .lifecycle => {
                for (section.entries) |entry| {
                    if (entry == .lifecycle_hook) {
                        try allowed_lifecycle_hooks.append(try ctx.allocator.dupe(u8, entry.lifecycle_hook.name));
                    }
                }
            },
            .custom => {
                if (std.mem.eql(u8, section.name, "sections")) {
                    for (section.entries) |entry| {
                        if (entry != .function_signature) continue;
                        const signature = entry.function_signature;
                        var param_types = std.array_list.Managed([]const u8).init(ctx.allocator);
                        for (signature.params) |param| {
                            const text = if (param.type_expr) |type_expr|
                                try shared.typeTextFromSyntax(ctx, type_expr.*)
                            else
                                "";
                            try param_types.append(text);
                        }
                        const return_type = if (signature.return_type) |type_expr|
                            try shared.typeTextFromSyntax(ctx, type_expr.*)
                        else
                            "Void";
                        try section_functions.append(.{
                            .name = try ctx.allocator.dupe(u8, signature.name),
                            .required = hasAnnotation(signature.annotations, "Required"),
                            .param_types = try param_types.toOwnedSlice(),
                            .return_type = return_type,
                            .span = signature.span,
                        });
                    }
                }
            },
            .properties => {
                // Construct 2.0 (item 6): the `properties { ... }` schema surface is removed.
                // A construct expresses caller-provided values as `@Required let name: T` and
                // defaults as `let name: T = value` direct members instead.
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM164",
                    .title = "properties block is removed",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' declares a `properties {{ ... }}` schema, which Construct 2.0 no longer supports.", .{construct_decl.name}),
                    .labels = &.{diagnostics.primaryLabel(section.span, "`properties { ... }` is no longer a construct surface")},
                    .help = "Declare caller-provided values as `@Required let name: T` and defaults as `let name: T = value` direct members.",
                });
                return error.DiagnosticsEmitted;
            },
            else => {},
        }
    }

    // SwiftUI-style direct members (`@Required let/function`, default `let node: Node { ... }`)
    // contribute required fields/functions and default members alongside the section surface.
    const direct = try construct_members.collectConstructDirectMembers(ctx, construct_decl);
    try required_functions.appendSlice(direct.required_functions);

    return .{
        .name = try ctx.allocator.dupe(u8, construct_decl.name),
        .parents = try parents.toOwnedSlice(),
        .properties = try properties.toOwnedSlice(),
        .content_channels = try content_channels.toOwnedSlice(),
        .content_refine = try content_refine.toOwnedSlice(),
        .content_projections = try content_projections.toOwnedSlice(),
        .content_sealed = content_sealed,
        .content_passthrough = content_passthrough,
        .required_functions = try required_functions.toOwnedSlice(),
        .section_functions = try section_functions.toOwnedSlice(),
        .consuming_functions = direct.consuming_functions,
        .required_fields = direct.required_fields,
        .default_members = direct.default_members,
        .allowed_annotations = try allowed_annotations.toOwnedSlice(),
        .content_element_type = if (content_element_type) |name| try ctx.allocator.dupe(u8, name) else null,
        .allowed_lifecycle_hooks = try allowed_lifecycle_hooks.toOwnedSlice(),
        .span = construct_decl.span,
    };
}

fn hasAnnotation(annotations: []const syntax.ast.Annotation, name: []const u8) bool {
    for (annotations) |annotation| {
        if (construct_members.isAnnotation(annotation, name)) return true;
    }
    return false;
}

// Extract the element type leaf from a typed content section. `content: Content<Widget>`
// yields "Widget"; a bare `content: Widget` yields "Widget". Returns null for shapes that
// do not name a single element type (so no element validation is imposed).
fn contentElementTypeName(type_expr: syntax.ast.TypeExpr) ?[]const u8 {
    return switch (type_expr) {
        .generic => |generic| if (generic.args.len == 1)
            leafTypeName(generic.args[0].*)
        else
            null,
        .named => |named| named.segments[named.segments.len - 1].text,
        else => null,
    };
}

fn leafTypeName(type_expr: syntax.ast.TypeExpr) ?[]const u8 {
    return switch (type_expr) {
        .named => |named| named.segments[named.segments.len - 1].text,
        .generic => |generic| generic.base.segments[generic.base.segments.len - 1].text,
        else => null,
    };
}
