//! Construct-graph validation: `extends` inheritance (unknown parents, cycles),
//! effective property schemas, and content-channel validation for construct-backed
//! declarations. Split from lower_program_types.zig.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const exprs = @import("lower_exprs.zig");

const ConstructCycleState = enum(u8) { unvisited, in_stack, done };

// Validate `construct C extends A, B { ... }` inheritance. A construct may only extend a
// known construct (declared locally or imported); the local inheritance graph must be acyclic.
// Form-level parents (`Sprite Player { ... }`) are validated separately during form lowering.
pub fn validateConstructInheritance(
    ctx: *shared.Context,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
) !void {
    for (constructs) |construct_decl| {
        for (construct_decl.parents) |parent_link| {
            const resolved_locally = construct_headers.get(parent_link.name) != null;
            const resolved_import = ctx.imported_globals.hasConstruct(parent_link.name);
            if (!resolved_locally and !resolved_import) {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM118",
                    .title = "unknown parent construct",
                    .message = try std.fmt.allocPrint(ctx.allocator, "Kira could not resolve the parent construct '{s}'.", .{parent_link.name}),
                    .labels = &.{diagnostics.primaryLabel(parent_link.span, "unknown parent construct")},
                    .help = "Declare the parent construct before extending it, or import the module that defines it.",
                });
                return error.DiagnosticsEmitted;
            }
        }
    }

    if (constructs.len == 0) return;
    const states = try ctx.allocator.alloc(ConstructCycleState, constructs.len);
    defer ctx.allocator.free(states);
    @memset(states, .unvisited);
    for (constructs, 0..) |_, index| {
        if (states[index] == .unvisited) {
            try detectConstructCycle(ctx, constructs, construct_headers, states, index);
        }
    }
}

fn detectConstructCycle(
    ctx: *shared.Context,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    states: []ConstructCycleState,
    index: usize,
) anyerror!void {
    states[index] = .in_stack;
    for (constructs[index].parents) |parent_link| {
        // Imported parents are external roots and cannot close a local cycle.
        const header = construct_headers.get(parent_link.name) orelse continue;
        switch (states[header.index]) {
            .in_stack => {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM119",
                    .title = "construct inheritance cycle",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' is part of an inheritance cycle.", .{constructs[index].name}),
                    .labels = &.{diagnostics.primaryLabel(parent_link.span, "this `extends` edge closes the cycle")},
                    .help = "Break the cycle so construct inheritance forms a directed acyclic graph.",
                });
                return error.DiagnosticsEmitted;
            },
            .unvisited => try detectConstructCycle(ctx, constructs, construct_headers, states, header.index),
            .done => {},
        }
    }
    states[index] = .done;
}

// Collect the effective property schema for a construct: parent (`extends`) properties
// first, then the construct's own, so a construct may override an inherited property by
// re-declaring it. The inheritance graph is already validated acyclic before forms are
// lowered. Imported parents' schemas are not visible here, so they are skipped.
pub fn collectConstructPropertySchema(
    ctx: *shared.Context,
    construct_model: model.Construct,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    out: *std.StringArrayHashMapUnmanaged(model.PropertySchema),
) !void {
    for (construct_model.parents) |parent_link| {
        if (construct_headers.get(parent_link.name)) |header| {
            try collectConstructPropertySchema(ctx, constructs[header.index], constructs, construct_headers, out);
        }
    }
    for (construct_model.properties) |property| {
        try out.put(ctx.allocator, property.name, property);
    }
}

// Validate a construct-backed declaration's `properties { ... }` section against the
// effective schema of its construct family: unknown properties (KSEM124), type mismatches
// (KSEM125), duplicate declarations (KSEM126), and missing required properties (KSEM123).
pub fn validateFormProperties(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    construct_model: model.Construct,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
) !void {
    // Construct 2.0 (item 6): a declaration that supplies a `properties { ... }` section is
    // rejected — the whole properties surface is removed.
    for (form_decl.body.members) |member| {
        if (member != .properties_section) continue;
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM164",
            .title = "properties block is removed",
            .message = try std.fmt.allocPrint(ctx.allocator, "The declaration '{s}' supplies a `properties {{ ... }}` section, which Construct 2.0 no longer supports.", .{form_decl.name}),
            .labels = &.{diagnostics.primaryLabel(member.properties_section.span, "`properties { ... }` is no longer a declaration surface")},
            .help = "Pass values as constructor arguments `Name(field = value)` or an override block `Name { let field = value }`.",
        });
        return error.DiagnosticsEmitted;
    }

    var schema = std.StringArrayHashMapUnmanaged(model.PropertySchema){};
    defer schema.deinit(ctx.allocator);
    try collectConstructPropertySchema(ctx, construct_model, constructs, construct_headers, &schema);

    var provided = std.StringHashMapUnmanaged(source_pkg.Span){};
    defer provided.deinit(ctx.allocator);

    for (form_decl.body.members) |member| {
        if (member != .properties_section) continue;
        for (member.properties_section.entries) |entry| {
            if (provided.get(entry.name)) |previous_span| {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM126",
                    .title = "duplicate property",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The declaration '{s}' assigns the property '{s}' more than once.", .{ form_decl.name, entry.name }),
                    .labels = &.{
                        diagnostics.primaryLabel(entry.span, "duplicate property assignment"),
                        diagnostics.secondaryLabel(previous_span, "the property was already assigned here"),
                    },
                    .help = "Assign each property at most once in the declaration's `properties { ... }` section.",
                });
                return error.DiagnosticsEmitted;
            }
            try provided.put(ctx.allocator, entry.name, entry.span);

            const property = schema.get(entry.name) orelse {
                try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSEM124",
                    .title = "unknown property",
                    .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' does not declare a property named '{s}'.", .{ construct_model.name, entry.name }),
                    .labels = &.{diagnostics.primaryLabel(entry.span, "unknown property")},
                    .help = "Declare the property in the construct's `properties { ... }` schema, or remove this assignment.",
                });
                return error.DiagnosticsEmitted;
            };

            try validatePropertyValueType(ctx, construct_model.name, property, entry);
        }
    }

    for (schema.values()) |property| {
        if (property.required and provided.get(property.name) == null) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM123",
                .title = "missing required property",
                .message = try std.fmt.allocPrint(ctx.allocator, "The declaration '{s}' must provide the required property '{s}' declared by construct '{s}'.", .{ form_decl.name, property.name, construct_model.name }),
                .labels = &.{diagnostics.primaryLabel(form_decl.span, "required property is not provided")},
                .help = "Add the property to this declaration's `properties { ... }` section.",
            });
            return error.DiagnosticsEmitted;
        }
    }
}

fn validatePropertyValueType(
    ctx: *shared.Context,
    construct_name: []const u8,
    property: model.PropertySchema,
    entry: syntax.ast.DeclPropertyEntry,
) !void {
    if (property.type_text.len == 0) return;
    const expected = try shared.resolvedTypeFromText(property.type_text);
    const actual = try exprs.resolveSyntaxExprType(ctx, entry.value, entry.span);
    // An undeterminable value type is not treated as a mismatch (avoid false positives).
    if (actual.kind == .unknown) return;
    if (shared.canAssignInContext(ctx, expected, actual)) return;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM125",
        .title = "property type mismatch",
        .message = try std.fmt.allocPrint(ctx.allocator, "Property '{s}' of construct '{s}' expects '{s}'.", .{ entry.name, construct_name, property.type_text }),
        .labels = &.{diagnostics.primaryLabel(entry.span, "property value does not match the declared type")},
        .help = "Provide a value whose type matches the property's declared type.",
    });
    return error.DiagnosticsEmitted;
}

// Collect the effective named content channels for a construct: inherited (`extends`)
// channels first, then the construct's own (so a construct may override an inherited channel).
pub fn collectConstructContentChannels(
    ctx: *shared.Context,
    construct_model: model.Construct,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    out: *std.StringArrayHashMapUnmanaged(model.ContentChannel),
) !void {
    for (construct_model.parents) |parent_link| {
        if (construct_headers.get(parent_link.name)) |header| {
            try collectConstructContentChannels(ctx, constructs[header.index], constructs, construct_headers, out);
        }
    }
    for (construct_model.content_channels) |channel| {
        try out.put(ctx.allocator, channel.name, channel);
    }
}

// Validate a construct-backed declaration's content against its construct family's content
// channels: unknown channel (KSEM127), accepts mismatch (KSEM130), and count bounds (KSEM129).
// Only runs when the construct declares at least one channel; channel-less constructs keep
// their existing single-`content` behavior. Content children are validated at the AST level:
// a channel that `accepts` a named element type rejects primitive literals (which are never
// elements), mirroring typed-`content` validation.
pub fn validateFormContentChannels(
    ctx: *shared.Context,
    form_decl: syntax.ast.ConstructFormDecl,
    construct_model: model.Construct,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
) !void {
    var channels = std.StringArrayHashMapUnmanaged(model.ContentChannel){};
    defer channels.deinit(ctx.allocator);
    try collectConstructContentChannels(ctx, construct_model, constructs, construct_headers, &channels);
    if (channels.count() == 0) return;

    var counts = std.StringHashMapUnmanaged(u32){};
    defer counts.deinit(ctx.allocator);

    for (form_decl.body.members) |member| {
        switch (member) {
            .content_section => |content_section| {
                const channel = try resolveFilledChannel(ctx, construct_model.name, "content", content_section.span, &channels);
                var count: u32 = 0;
                try validateBuilderChannelItems(ctx, construct_model.name, channel, content_section.builder, &count);
                try counts.put(ctx.allocator, channel.name, (counts.get(channel.name) orelse 0) + count);
            },
            .named_rule => |rule| {
                const block = rule.block orelse continue;
                const channel_name = rule.name.segments[rule.name.segments.len - 1].text;
                const channel = try resolveFilledChannel(ctx, construct_model.name, channel_name, rule.span, &channels);
                var count: u32 = 0;
                for (block.statements) |statement| {
                    if (statement != .expr_stmt) continue;
                    try checkChannelChildExpr(ctx, construct_model.name, channel, statement.expr_stmt.expr.*, statement.expr_stmt.span);
                    count += 1;
                }
                try counts.put(ctx.allocator, channel.name, (counts.get(channel.name) orelse 0) + count);
            },
            else => {},
        }
    }

    for (channels.values()) |channel| {
        const filled = counts.get(channel.name) orelse 0;
        const under = filled < channel.min;
        const over = channel.max != null and filled > channel.max.?;
        if (under or over) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM129",
                .title = "content count violation",
                .message = try std.fmt.allocPrint(ctx.allocator, "Channel '{s}' of construct '{s}' accepts {s}, but the declaration '{s}' provides {d}.", .{ channel.name, construct_model.name, try countBoundsText(ctx, channel), form_decl.name, filled }),
                .labels = &.{diagnostics.primaryLabel(form_decl.span, "content count is outside the channel's allowed range")},
                .help = "Provide a number of content items within the channel's `count` range.",
            });
            return error.DiagnosticsEmitted;
        }
    }
}

fn resolveFilledChannel(
    ctx: *shared.Context,
    construct_name: []const u8,
    channel_name: []const u8,
    span: source_pkg.Span,
    channels: *const std.StringArrayHashMapUnmanaged(model.ContentChannel),
) !model.ContentChannel {
    return channels.get(channel_name) orelse {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM127",
            .title = "unknown content channel",
            .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' does not declare a content channel named '{s}'.", .{ construct_name, channel_name }),
            .labels = &.{diagnostics.primaryLabel(span, "unknown content channel")},
            .help = "Declare the channel in the construct's `content { ... }` block, or fill an existing channel.",
        });
        return error.DiagnosticsEmitted;
    };
}

fn validateBuilderChannelItems(
    ctx: *shared.Context,
    construct_name: []const u8,
    channel: model.ContentChannel,
    builder: syntax.ast.BuilderBlock,
    count: *u32,
) !void {
    for (builder.items) |item| {
        if (item != .expr) continue;
        try checkChannelChildExpr(ctx, construct_name, channel, item.expr.expr.*, item.expr.span);
        count.* += 1;
    }
}

fn checkChannelChildExpr(
    ctx: *shared.Context,
    construct_name: []const u8,
    channel: model.ContentChannel,
    expr: syntax.ast.Expr,
    span: source_pkg.Span,
) !void {
    const accepts = channel.accepts orelse return;
    const primitive_label: ?[]const u8 = switch (expr) {
        .string => "String",
        .integer => "Int",
        .float => "Float",
        .bool => "Bool",
        else => null,
    };
    if (primitive_label) |label| {
        try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
            .severity = .@"error",
            .code = "KSEM130",
            .title = "content type mismatch",
            .message = try std.fmt.allocPrint(ctx.allocator, "Channel '{s}' of construct '{s}' accepts '{s}' elements, but found a {s} literal.", .{ channel.name, construct_name, accepts, label }),
            .labels = &.{diagnostics.primaryLabel(span, "this value is not an accepted content element")},
            .help = try std.fmt.allocPrint(ctx.allocator, "Provide a '{s}'-producing element here.", .{accepts}),
        });
        return error.DiagnosticsEmitted;
    }
}

fn countBoundsText(ctx: *shared.Context, channel: model.ContentChannel) ![]const u8 {
    if (channel.max) |max| {
        if (channel.min == max) return std.fmt.allocPrint(ctx.allocator, "exactly {d}", .{max});
        return std.fmt.allocPrint(ctx.allocator, "between {d} and {d}", .{ channel.min, max });
    }
    return std.fmt.allocPrint(ctx.allocator, "at least {d}", .{channel.min});
}
