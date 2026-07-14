//! vm_target_locals — the locals/`evaluate` half of the VM `DebugTarget`, split
//! out of `vm_target.zig` (Core Law #5: keep each file focused). It renders a
//! stopped VM frame's named locals into `LocalView`s and evaluates `print EXPR`
//! queries over them, using the exact same building blocks — `value_view.render`
//! (read-only) and the shared `eval.Evaluator` — as the native and hybrid targets,
//! so all three backends produce identical variable views and expression results.
//!
//! ## The two seams this drives
//!
//!   * `VmTarget.frameDecl(frame_index)` -> the stopped frame's `bytecode.Function`
//!     decl, whose `local_names`/`local_types` name and type each local slot.
//!   * `VmTarget.frameValue(frame_index, slot)` -> the live `Value` in that local
//!     slot, or null when the runtime cannot (yet) expose it.
//!
//! When `frameValue` returns null the local is still listed — with its name and
//! declared type — but its value renders as `<unavailable>` rather than a
//! fabricated one. This is the honest degradation while the runtime's per-frame
//! value accessor is a wiring seam (see the note on `VmTarget.frameValue`): the
//! variables view stays populated and, the moment the accessor lands, live values
//! light up here unchanged. `<unavailable>` is not a scalar the evaluator can
//! parse, so any expression over such a local is a truthful `TypeError`, never a
//! guess.
//!
//! Everything here is read-only with respect to runtime storage: `value_view`
//! never moves/drops/frees the slot it inspects (the VM tracks affine ownership
//! via a parallel `owned[]` array the debugger must not disturb), and the
//! evaluator only ever reads the display strings produced here.

const std = @import("std");
const di = @import("debug_info.zig");
const target_mod = @import("target.zig");
const value_view = @import("value_view.zig");
const eval = @import("eval.zig");
const vm_target = @import("vm_target.zig");

const VmTarget = vm_target.VmTarget;
const LocalView = di.LocalView;

/// Shown for a local whose slot exists (named + typed) but whose live value the
/// runtime cannot currently surface. Deliberately not a parseable scalar, so the
/// evaluator treats any operation on it as a `TypeError`.
const unavailable_text = "<unavailable>";

/// Build the variables view for `frame_index`: one `LocalView` per named local in
/// the stopped frame, rendered read-only. Returns `NotFound` when the frame index
/// is out of range, and an empty slice when the frame's function carries no local
/// names (module built without debug names). Caller owns the slice and each
/// `.value` string.
pub fn locals(self: *VmTarget, allocator: std.mem.Allocator, frame_index: u32) anyerror![]LocalView {
    const decl = self.frameDecl(frame_index) orelse {
        if (frame_index >= self.vm.debugFrames().len) return target_mod.TargetError.NotFound;
        // Frame exists but no matching prepared function / no names to show.
        return allocator.alloc(LocalView, 0);
    };

    var out: std.ArrayListUnmanaged(LocalView) = .empty;
    errdefer {
        for (out.items) |lv| allocator.free(lv.value);
        out.deinit(allocator);
    }

    for (decl.local_names, 0..) |name, i| {
        if (name.len == 0) continue; // unnamed slot: not user-visible
        const slot: u32 = @intCast(i);
        const type_name = if (i < decl.local_types.len) typeName(decl.local_types[i]) else "";
        if (self.frameValue(frame_index, slot)) |value| {
            // read-only render; never touches the runtime slot's ownership.
            const view = try value_view.renderLocal(allocator, name, slot, type_name, value, null);
            try out.append(allocator, view);
        } else {
            const rendered = try allocator.dupe(u8, unavailable_text);
            errdefer allocator.free(rendered);
            try out.append(allocator, .{
                .name = name,
                .type_name = type_name,
                .value = rendered,
                .slot = slot,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Evaluate `expr` in the context of `frame_index`'s locals and return a fresh,
/// caller-owned display string. Identifier resolution goes through the shared
/// `eval.Evaluator` (same semantics as native/hybrid); a syntax/type/unknown-name
/// error propagates so the caller (REPL/DAP) can print an honest diagnostic.
pub fn evaluate(
    self: *VmTarget,
    allocator: std.mem.Allocator,
    frame_index: u32,
    expr: []const u8,
) anyerror![]const u8 {
    const views = try locals(self, allocator, frame_index);
    defer {
        for (views) |lv| allocator.free(lv.value);
        allocator.free(views);
    }

    // The evaluator's `LookupFn` is a bare fn pointer with no context slot, so the
    // resolver reads the frame's locals from thread-local state set here. Safe
    // because a session serializes all target access; restored on every path out.
    const prev = active_locals;
    active_locals = views;
    defer active_locals = prev;

    const result = try eval.Evaluator.eval(allocator, expr, lookupActiveLocal);
    return renderValue(allocator, result);
}

// ---------------------------------------------------------------------------
// Evaluator glue
// ---------------------------------------------------------------------------

threadlocal var active_locals: []const LocalView = &.{};

fn lookupActiveLocal(name: []const u8) ?LocalView {
    for (active_locals) |lv| {
        if (std.mem.eql(u8, lv.name, name)) return lv;
    }
    return null;
}

/// Render an evaluated `Value` into a human string owned by `a`. A `.str` result
/// is already an `a`-owned copy from `Evaluator.eval`, so it passes through.
fn renderValue(a: std.mem.Allocator, v: eval.Value) ![]const u8 {
    return switch (v) {
        .int => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .bool => |b| a.dupe(u8, if (b) "true" else "false"),
        .str => |s| s,
        .unknown => a.dupe(u8, "<unknown>"),
    };
}

/// A local's declared type name: the precise `TypeRef.name` when present (structs,
/// enums, FFI primitives), else the kind tag (`integer`, `boolean`, …). Empty
/// string when no type info is attached.
fn typeName(tref: anytype) []const u8 {
    return tref.name orelse @tagName(tref.kind);
}
