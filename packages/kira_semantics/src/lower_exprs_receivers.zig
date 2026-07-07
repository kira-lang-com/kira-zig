// Consuming-receiver bookkeeping for method calls (body-consumes-self), split
// out of lower_exprs_members.zig (Core Law #5). A consuming method takes
// `self` OWNED (Rust `self` receiver): `@Consuming` family methods and every
// `body` accessor. These helpers decide whether a resolved method consumes
// its receiver and apply the receiver-side ownership transfer at the call
// site.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");
const ownership_exprs = @import("lower_exprs_ownership.zig");

// Does the resolved method take `self` OWNED (a consuming method)? Concrete
// resolutions read the registered header's param_ownership[0]; existential
// (family) dispatch falls back to the construct surface (`@Consuming` methods
// and `body` accessors).
pub fn methodCallConsumesReceiver(
    ctx: *shared.Context,
    static_type_name: []const u8,
    method_name: []const u8,
    full_name: []const u8,
) bool {
    if (ctx.function_headers) |headers| {
        if (headers.get(full_name)) |header| {
            if (header.param_ownership.len > 0) {
                return header.param_ownership[0] == .owned or header.param_ownership[0] == .move;
            }
        }
    }
    return shared.methodConsumesSelf(ctx, static_type_name, method_name, &.{});
}

// Receiver-side ownership bookkeeping for a CONSUMING method call
// (`x.render()` where render takes owned self — the Rust `self` receiver).
// Mirrors what owned ARGUMENT passing does, adapted to receivers:
//   - a bare owned local receiver is implicitly moved (Rust semantics; no
//     explicit `move` required for method calls) and later uses are
//     use-after-move;
//   - a field receiver (`self.content.render()`) is a partial move: the field
//     is marked moved on its root binding and the read is re-tagged `.moved`
//     so both backends null/void the field slot (the base then drops with its
//     remaining fields — the body-consumes-self content-channel pattern);
//   - a BORROWED receiver whose type carries type-erased (Any) storage is
//     rejected (KSEM157): the callee frees what it receives, and Any values
//     are move-only (deep-cloning a widget tree is forbidden). Borrowed
//     receivers of plain struct types stay legal — the backends hand the
//     callee an independent deep clone.
//   - temporaries (call results, fresh construct values) need no bookkeeping.
pub fn applyConsumingReceiver(
    ctx: *shared.Context,
    scope: *model.Scope,
    receiver: *model.Expr,
    span: source_pkg.Span,
) !void {
    switch (receiver.*) {
        .local => |*local_node| {
            const binding = scope.entries.getPtr(local_node.name) orelse return;
            if (binding.moved) {
                try ownership_exprs.emitUseAfterMove(ctx, local_node.name, span, binding.move_span);
                return error.DiagnosticsEmitted;
            }
            if (binding.hasMovedFields()) {
                try ownership_exprs.emitUseAfterPartialMove(ctx, local_node.name, span, binding.move_span);
                return error.DiagnosticsEmitted;
            }
            if (binding.ownership == .borrow_read or binding.ownership == .borrow_mut) {
                if (shared.containsConstructAnyStorage(ctx, binding.ty)) {
                    try emitConsumingBorrowedReceiver(ctx, local_node.name, span);
                    return error.DiagnosticsEmitted;
                }
                return; // struct receiver: backends deep-clone into the callee
            }
            local_node.ownership = .move;
            binding.moved = true;
            binding.move_span = span;
        },
        .field => |*field_node| {
            // Walk the (possibly NESTED) field chain to its root, tracking the
            // outermost field so `outer.inner.leaf.render()` is handled, not just
            // `self.field.render()`. Without this a nested field receiver skipped
            // both the borrow rejection and the moved-read tag: the callee freed
            // the leaf's Any/array payload while the root later dropped the same
            // sub-field — a double free (Codex P2).
            var obj = field_node.object;
            var outermost_field = field_node.field_name;
            while (obj.* == .field) {
                outermost_field = obj.field.field_name;
                obj = obj.field.object;
            }
            const transferable = field_node.ty.kind == .array or field_node.ty.kind == .enum_instance or
                field_node.ty.kind == .construct_any or shared.containsConstructAnyStorage(ctx, field_node.ty);
            if (obj.* != .local) {
                // Rooted in a temporary (call result / index): no other binding
                // owns it, but the callee takes the leaf — tag the read so its
                // slot is voided and exclusive ownership holds.
                if (transferable) field_node.moved = true;
                return;
            }
            const root_name = obj.local.name;
            const binding = scope.entries.getPtr(root_name) orelse return;
            if (binding.ownership == .borrow_read or binding.ownership == .borrow_mut) {
                if (shared.containsConstructAnyStorage(ctx, field_node.ty)) {
                    try emitConsumingBorrowedReceiver(ctx, root_name, span);
                    return error.DiagnosticsEmitted;
                }
                return;
            }
            // Only pointer-transferable field kinds need the moved-read tag;
            // matches applyBindingMove's partial-move rule.
            if (!transferable) return;
            // A DIRECT field of the root (`self.content`) records the partial
            // move so whole-base reuse is rejected. A NESTED path
            // (`outer.inner.child`) only voids the leaf slot: the single-field
            // move bookkeeping cannot represent a deep path, and marking the
            // outermost field (a struct) would wrongly reject the base at scope
            // exit — the leaf `moved` tag already prevents the double free.
            if (field_node.object.* == .local) {
                try binding.markFieldMoved(ctx.allocator, outermost_field);
                if (binding.move_span == null) binding.move_span = span;
            }
            field_node.moved = true;
        },
        .index => |*index_node| {
            // Element DRAIN: `widgets[index].lower(ctx)` on an OWNED array
            // moves the element into the consuming callee; the slot tombstones
            // to VOID on every backend (array release skips it, a re-read of
            // the drained slot fails dispatch deterministically). Indices are
            // dynamic, so drained elements are runtime-checked, not tracked as
            // static moved paths. A BORROWED array's element cannot be drained
            // (the borrow does not own it) — reject when it carries Any
            // storage, same rule as the other receiver shapes.
            if (index_node.ty.kind != .construct_any and !shared.containsConstructAnyStorage(ctx, index_node.ty)) return;
            // Reject only when the drained array roots in a BORROWED local — the
            // borrow does not own the element the callee frees. An owned-local
            // root (`self.children[i]`, `outer.inner.children[i]`) or a temporary
            // array (a call result) is drainable: void the element slot. Walk
            // through nested fields AND indexes so a deep receiver is handled,
            // not just `arr[i]` / `self.children[i]` (Codex P1).
            if (arrayRootLocal(index_node.object)) |root| {
                if (scope.entries.getPtr(root)) |binding| {
                    if (binding.ownership == .borrow_read or binding.ownership == .borrow_mut) {
                        try emitConsumingBorrowedReceiver(ctx, root, span);
                        return error.DiagnosticsEmitted;
                    }
                }
            }
            index_node.moved = true;
        },
        else => {},
    }
}

// The root local a (possibly NESTED) indexed/field receiver bottoms out in:
// `arr[i]` -> arr, `self.children[i]` -> self, `outer.inner.children[i]` ->
// outer. Null when it roots in a temporary (call result, another index of a
// temporary) — those have no binding to consult and are drainable as-is.
fn arrayRootLocal(object: *const model.Expr) ?[]const u8 {
    var obj = object;
    while (true) {
        switch (obj.*) {
            .local => |node| return node.name,
            .field => |node| obj = node.object,
            .index => |node| obj = node.object,
            else => return null,
        }
    }
}

fn emitConsumingBorrowedReceiver(ctx: *shared.Context, name: []const u8, span: source_pkg.Span) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM157",
        .title = "consuming method call on borrowed receiver",
        .message = try std.fmt.allocPrint(ctx.allocator, "This method consumes its receiver, but `{s}` is only borrowed here and its type-erased contents cannot be copied.", .{name}),
        .labels = &.{diagnostics.primaryLabel(span, "the callee would free a value this borrow does not own")},
        .help = "Call the consuming method on an owned value (move it into a local first), or make the method non-consuming.",
    });
}

