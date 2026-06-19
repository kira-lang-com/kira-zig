const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

// Validate content-composition directives (`sealed`/`refine`/`passthrough`/`project`) against the
// construct inheritance graph. Runs after `extends` validation, so the graph is acyclic.
pub fn validateConstructContentComposition(
    ctx: *shared.Context,
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
) !void {
    for (constructs) |construct_decl| {
        const declares_content = construct_decl.content_channels.len > 0 or
            construct_decl.content_refine.len > 0 or
            construct_decl.content_projections.len > 0 or
            construct_decl.content_passthrough;

        // `content sealed` on an ancestor closes its content surface to descendants.
        if (declares_content and anyAncestorSealed(constructs, construct_headers, construct_decl)) {
            try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
                .severity = .@"error",
                .code = "KSEM128",
                .title = "content into sealed construct",
                .message = try std.fmt.allocPrint(ctx.allocator, "The construct '{s}' adds content, but an ancestor sealed its content with `content sealed`.", .{construct_decl.name}),
                .labels = &.{diagnostics.primaryLabel(construct_decl.span, "content cannot be added below a sealed construct")},
                .help = "Remove the content here, or remove `content sealed` from the ancestor construct.",
            });
            return error.DiagnosticsEmitted;
        }

        // `content refine { ... }` may only tighten an inherited channel.
        for (construct_decl.content_refine) |refined| {
            const inherited = findInheritedChannel(constructs, construct_headers, construct_decl, refined.name) orelse {
                try emitRefine(ctx, construct_decl, refined.span, try std.fmt.allocPrint(ctx.allocator, "'{s}' is not an inherited content channel.", .{refined.name}));
                return error.DiagnosticsEmitted;
            };
            if (!countIsSubrange(refined, inherited)) {
                try emitRefine(ctx, construct_decl, refined.span, try std.fmt.allocPrint(ctx.allocator, "the refined count of channel '{s}' must be within the inherited range.", .{refined.name}));
                return error.DiagnosticsEmitted;
            }
            if (inherited.accepts != null and refined.accepts != null and !std.mem.eql(u8, inherited.accepts.?, refined.accepts.?)) {
                try emitRefine(ctx, construct_decl, refined.span, try std.fmt.allocPrint(ctx.allocator, "the refined `accepts` of channel '{s}' must match the inherited element type.", .{refined.name}));
                return error.DiagnosticsEmitted;
            }
        }

        // `content passthrough` forwards inherited channels; it must inherit some and own none.
        if (construct_decl.content_passthrough) {
            if (!anyAncestorHasChannels(constructs, construct_headers, construct_decl)) {
                try emitRefine(ctx, construct_decl, construct_decl.span, "`content passthrough` requires a parent construct that declares content channels.");
                return error.DiagnosticsEmitted;
            }
            if (construct_decl.content_channels.len > 0) {
                try emitRefine(ctx, construct_decl, construct_decl.span, "`content passthrough` cannot also declare its own content channels.");
                return error.DiagnosticsEmitted;
            }
        }

        // `content project { local as Parent.channel }` must target an ancestor's real channel.
        for (construct_decl.content_projections) |projection| {
            const header = construct_headers.get(projection.target_construct);
            const is_ancestor = isAncestorConstruct(constructs, construct_headers, construct_decl, projection.target_construct);
            if (header == null or !is_ancestor) {
                try emitProject(ctx, projection.span, try std.fmt.allocPrint(ctx.allocator, "'{s}' is not an ancestor construct of '{s}'.", .{ projection.target_construct, construct_decl.name }));
                return error.DiagnosticsEmitted;
            }
            if (channelOf(constructs[header.?.index], projection.target_channel) == null) {
                try emitProject(ctx, projection.span, try std.fmt.allocPrint(ctx.allocator, "construct '{s}' has no content channel named '{s}'.", .{ projection.target_construct, projection.target_channel }));
                return error.DiagnosticsEmitted;
            }
        }
    }
}

fn emitRefine(ctx: *shared.Context, construct_decl: model.Construct, span: source_pkg.Span, message: []const u8) !void {
    _ = construct_decl;
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM132",
        .title = "invalid content composition",
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, "invalid content composition")},
        .help = "Refinements may only tighten inherited channels; passthrough forwards inherited channels.",
    });
}

fn emitProject(ctx: *shared.Context, span: source_pkg.Span, message: []const u8) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM131",
        .title = "unknown projection target",
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, "unknown projection target")},
        .help = "Project onto a content channel declared by an ancestor construct.",
    });
}

fn channelOf(construct_decl: model.Construct, name: []const u8) ?model.ContentChannel {
    for (construct_decl.content_channels) |channel| {
        if (std.mem.eql(u8, channel.name, name)) return channel;
    }
    return null;
}

fn anyAncestorSealed(
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    construct_decl: model.Construct,
) bool {
    for (construct_decl.parents) |parent_link| {
        const header = construct_headers.get(parent_link.name) orelse continue;
        const parent = constructs[header.index];
        if (parent.content_sealed) return true;
        if (anyAncestorSealed(constructs, construct_headers, parent)) return true;
    }
    return false;
}

fn anyAncestorHasChannels(
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    construct_decl: model.Construct,
) bool {
    for (construct_decl.parents) |parent_link| {
        const header = construct_headers.get(parent_link.name) orelse continue;
        const parent = constructs[header.index];
        if (parent.content_channels.len > 0) return true;
        if (anyAncestorHasChannels(constructs, construct_headers, parent)) return true;
    }
    return false;
}

fn findInheritedChannel(
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    construct_decl: model.Construct,
    name: []const u8,
) ?model.ContentChannel {
    for (construct_decl.parents) |parent_link| {
        const header = construct_headers.get(parent_link.name) orelse continue;
        const parent = constructs[header.index];
        if (channelOf(parent, name)) |channel| return channel;
        if (findInheritedChannel(constructs, construct_headers, parent, name)) |channel| return channel;
    }
    return null;
}

fn isAncestorConstruct(
    constructs: []const model.Construct,
    construct_headers: *const std.StringHashMapUnmanaged(shared.ConstructHeader),
    construct_decl: model.Construct,
    name: []const u8,
) bool {
    for (construct_decl.parents) |parent_link| {
        if (std.mem.eql(u8, parent_link.name, name)) return true;
        const header = construct_headers.get(parent_link.name) orelse continue;
        if (isAncestorConstruct(constructs, construct_headers, constructs[header.index], name)) return true;
    }
    return false;
}

// A refined channel's count must lie within the inherited channel's count range.
fn countIsSubrange(refined: model.ContentChannel, inherited: model.ContentChannel) bool {
    if (refined.min < inherited.min) return false;
    if (inherited.max) |inherited_max| {
        const refined_max = refined.max orelse return false; // refining unbounded->unbounded over a bounded parent widens
        if (refined_max > inherited_max) return false;
    }
    return true;
}
