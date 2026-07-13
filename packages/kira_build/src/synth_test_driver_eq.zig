//! Structural-equality synthesis for the pure-Kira test driver.
//!
//! The base driver (`synth_test_driver.zig`) compares a Test's `__actual`
//! against its `__expected` with Kira's `==`. That is only correct for scalars
//! (Int/Bool/String/numeric) and payload-less enums — for a struct-typed Test
//! result `==` silently returns `false` even for equal values. This module
//! teaches the driver to compare struct results *structurally*.
//!
//! Type discovery runs at the SYNTAX layer, before semantics and before macro
//! expansion. For each Test we read the value type `T` out of the `expect`
//! body's `let e: Result<T, TestFailure>` annotation (it is right there in the
//! Test source). When `T` is a user struct we synthesize a recursive comparator
//!
//!     function __kira_test_eq_<T>(a: borrow <T>, b: borrow <T>) -> Bool
//!
//! and dispatch through it instead of `==`. Field walk:
//!   * scalar / payload-less-enum leaf   -> `a.f != b.f`
//!   * nested struct field               -> recursive comparator
//!   * array field                       -> count compare + elementwise loop
//!
//! CONVENTION BRIDGE: when the package already provides `eq_<T>` — either a
//! hand-written `function eq_<T>(...)` or a struct/enum carrying
//! `@Derive(Equatable)` (which expands to `eq_<T>` later in the pipeline) — that
//! comparator is authoritative and the driver calls it instead of synthesizing
//! its own. This lets a user override structural equality (e.g. ignore a field).
//!
//! Enums with payloads have no synthesized comparator (matching two borrowed
//! enums payload-wise is a separate change): a payload-carrying enum used as a
//! Test result or struct field is honored ONLY through the `eq_<T>` bridge; with
//! no bridge it is REFUSED at synthesis time (a hard diagnostic) rather than
//! compared tag-only — silent-wrong tag-only equality is forbidden.

const std = @import("std");
const syntax = @import("kira_syntax_model");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");

const ast = syntax.ast;

/// Builtin scalar type names — compared with `!=` at the leaves. Mirrors the
/// list Foundation's `@Derive(Equatable)` uses (foundation/app/Derive.kira).
const scalar_names = [_][]const u8{
    "Int",   "Float", "Bool", "String", "I8",      "U8",      "I16",
    "U16",   "I32",   "U32",  "I64",    "U64",     "F32",     "F64",
    "USize", "ISize", "Byte", "Char",   "CBool",   "CInt",    "CString",
    "RawPtr",
};

fn isScalarName(name: []const u8) bool {
    for (scalar_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Synthesized comparator prefix. Leading underscores dodge the user namespace
/// (the parser accepts them — the base driver already uses `__kira_test_main`).
pub const synth_prefix = "__kira_test_eq_";

pub const Env = struct {
    allocator: std.mem.Allocator,
    structs: std.StringHashMapUnmanaged(ast.TypeDecl) = .{},
    enums: std.StringHashMapUnmanaged(ast.EnumDecl) = .{},
    /// Type names that already have a hand-written `eq_<T>` function.
    handwritten_eq: std.StringHashMapUnmanaged(void) = .{},

    pub fn build(allocator: std.mem.Allocator, program: ast.Program) !Env {
        var env = Env{ .allocator = allocator };
        for (program.decls) |decl| {
            switch (decl) {
                .type_decl => |td| {
                    if (td.kind == .struct_decl) try env.structs.put(allocator, td.name, td);
                },
                .enum_decl => |ed| try env.enums.put(allocator, ed.name, ed),
                .function_decl => |fd| {
                    if (std.mem.startsWith(u8, fd.name, "eq_"))
                        try env.handwritten_eq.put(allocator, fd.name["eq_".len..], {});
                },
                else => {},
            }
        }
        // Top-level functions are also recorded in `functions`; scan there too so
        // a hand-written `eq_<T>` is found regardless of which list holds it.
        for (program.functions) |fd| {
            if (std.mem.startsWith(u8, fd.name, "eq_"))
                try env.handwritten_eq.put(allocator, fd.name["eq_".len..], {});
        }
        return env;
    }

    /// Whether `name` has an authoritative `eq_<name>` (hand-written now, or a
    /// `@Derive(Equatable)` that will expand to one after synthesis).
    fn hasUserEq(self: *const Env, name: []const u8) bool {
        if (self.handwritten_eq.contains(name)) return true;
        if (self.structs.get(name)) |td| return hasDeriveEquatable(td.annotations);
        if (self.enums.get(name)) |ed| return hasDeriveEquatable(ed.annotations);
        return false;
    }

    fn isStruct(self: *const Env, name: []const u8) bool {
        return self.structs.contains(name);
    }

    fn enumHasPayload(self: *const Env, name: []const u8) bool {
        const ed = self.enums.get(name) orelse return false;
        for (ed.variants) |v| {
            if (v.associated_type != null) return true;
        }
        return false;
    }
};

fn hasDeriveEquatable(annotations: []const ast.Annotation) bool {
    for (annotations) |anno| {
        if (anno.name.segments.len == 0) continue;
        if (!std.mem.eql(u8, anno.name.segments[anno.name.segments.len - 1].text, "Derive")) continue;
        for (anno.args) |arg| {
            if (arg.value.* != .identifier) continue;
            const segs = arg.value.identifier.name.segments;
            if (segs.len != 0 and std.mem.eql(u8, segs[segs.len - 1].text, "Equatable")) return true;
        }
    }
    return false;
}

/// Peel `borrow`/`copy`/... ownership wrappers off a type expression.
fn unwrapOwnership(ty: *const ast.TypeExpr) *const ast.TypeExpr {
    var cur = ty;
    while (cur.* == .ownership) cur = cur.ownership.target;
    return cur;
}

/// The single bare identifier of a `named` type, or null for anything else
/// (generic, array, qualified, existential).
fn bareName(ty: *const ast.TypeExpr) ?[]const u8 {
    const t = unwrapOwnership(ty);
    if (t.* != .named) return null;
    const segs = t.named.segments;
    if (segs.len != 1) return null;
    return segs[0].text;
}

/// Read the value type `T` out of a Test form's `expect { let e: Result<T,
/// TestFailure> = ... }` annotation. Returns null when no such annotated `let`
/// is present (the driver then falls back to scalar `==`).
pub fn resultValueType(form: ast.ConstructFormDecl) ?*ast.TypeExpr {
    for (form.body.members) |member| {
        if (member != .named_rule) continue;
        const rule = member.named_rule;
        if (rule.name.segments.len != 1) continue;
        if (!std.mem.eql(u8, rule.name.segments[0].text, "expect")) continue;
        const block = rule.block orelse return null;
        for (block.statements) |stmt| {
            if (stmt != .let_stmt) continue;
            const type_expr = stmt.let_stmt.type_expr orelse continue;
            if (type_expr.* != .generic) continue;
            const gen = type_expr.generic;
            if (gen.base.segments.len == 0) continue;
            if (!std.mem.eql(u8, gen.base.segments[gen.base.segments.len - 1].text, "Result")) continue;
            if (gen.args.len == 0) continue;
            return gen.args[0];
        }
        return null;
    }
    return null;
}

pub const Dispatch = union(enum) {
    /// Compare with `==` (scalars, payload-less enums, arrays/generics —
    /// unchanged behavior).
    scalar,
    /// Call this comparator function: `if <name>(__actual, __expected) { ... }`.
    comparator: []const u8,
    /// The value type cannot be compared structurally and has no `eq_` bridge —
    /// the caller must refuse injection (payload_name is for the diagnostic).
    refuse: []const u8,
};

/// How the top-level driver should compare a Test whose value type is `ty`.
pub fn topLevelDispatch(env: *const Env, ty: ?*ast.TypeExpr) !Dispatch {
    const type_expr = ty orelse return .scalar;
    const name = bareName(type_expr) orelse return .scalar;
    if (isScalarName(name)) return .scalar;
    if (env.hasUserEq(name)) {
        return .{ .comparator = try std.fmt.allocPrint(env.allocator, "eq_{s}", .{name}) };
    }
    if (env.isStruct(name)) {
        return .{ .comparator = try std.fmt.allocPrint(env.allocator, "{s}{s}", .{ synth_prefix, name }) };
    }
    // A payload-carrying enum with no `eq_` bridge cannot be compared: Kira's
    // `==` on such an enum is tag-only, so `Circle(3) == Circle(9)` — a
    // silent-wrong PASS. Refuse rather than emit that. Payload-less enums and
    // unknown named types keep the correct `==` tag path.
    if (env.enums.contains(name) and env.enumHasPayload(name)) return .{ .refuse = name };
    return .scalar;
}

/// Append the KTEST001 refusal diagnostic for a top-level Test result type that
/// cannot be compared structurally and has no `eq_` bridge.
pub fn refuseTopLevel(
    env: *const Env,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    type_name: []const u8,
    span: source_pkg.Span,
) !void {
    const msg = try std.fmt.allocPrint(
        env.allocator,
        "cannot compare Test result of type `{s}`: `==` on an enum with payloads is tag-only (silent-wrong)",
        .{type_name},
    );
    try diagnostics.appendOwned(env.allocator, diags, .{
        .severity = .@"error",
        .code = "KTEST001",
        .title = "unsupported Test result type",
        .message = msg,
        .labels = &.{diagnostics.primaryLabel(span, "this Test returns it")},
        .help = "Provide a user `function eq_<Type>(a: borrow T, b: borrow T) -> Bool` (or `@Derive(Equatable)`) so the test driver can compare this type.",
    });
}

/// Grow `needed` (a set of struct names to synthesize) to the transitive
/// closure reachable from its current seeds through struct fields and
/// array-of-struct fields. Structs that have an authoritative `eq_` bridge are
/// never synthesized (the bridge is used) and so are not added.
pub fn expandNeeded(env: *const Env, needed: *std.StringHashMapUnmanaged(void)) !void {
    var changed = true;
    while (changed) {
        changed = false;
        var it = needed.iterator();
        var pending = std.array_list.Managed([]const u8).init(env.allocator);
        defer pending.deinit();
        while (it.next()) |entry| {
            const td = env.structs.get(entry.key_ptr.*) orelse continue;
            for (td.members) |member| {
                if (member != .field_decl) continue;
                const field = member.field_decl;
                if (field.body != null) continue;
                const fty = field.type_expr orelse continue;
                try collectStructRefs(env, fty, &pending);
            }
        }
        for (pending.items) |name| {
            if (!needed.contains(name)) {
                try needed.put(env.allocator, name, {});
                changed = true;
            }
        }
    }
}

fn collectStructRefs(env: *const Env, ty: *const ast.TypeExpr, out: *std.array_list.Managed([]const u8)) !void {
    const t = unwrapOwnership(ty);
    switch (t.*) {
        .array => |arr| try collectStructRefs(env, arr.element_type, out),
        else => {
            const name = bareName(t) orelse return;
            if (isScalarName(name)) return;
            if (env.hasUserEq(name)) return; // bridged, not synthesized
            if (env.isStruct(name)) try out.append(name);
        },
    }
}

/// Emit `function __kira_test_eq_<name>(...) -> Bool { ... }` into `writer`.
/// Returns false (after appending an error diagnostic) when a field type cannot
/// be compared structurally and has no `eq_` bridge — the caller then declines
/// to inject the driver so the build fails loudly instead of silent-wrong.
pub fn emitStructComparator(
    env: *const Env,
    writer: *std.Io.Writer,
    name: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !bool {
    const td = env.structs.get(name).?;
    try writer.print(
        "function {s}{s}(a: borrow {s}, b: borrow {s}) -> Bool {{\n",
        .{ synth_prefix, name, name, name },
    );
    var loop_counter: usize = 0;
    for (td.members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        if (field.body != null) continue; // computed member, not stored state
        const fty = field.type_expr orelse continue;
        const a_expr = try std.fmt.allocPrint(env.allocator, "a.{s}", .{field.name});
        const b_expr = try std.fmt.allocPrint(env.allocator, "b.{s}", .{field.name});
        if (!try emitCompare(env, writer, a_expr, b_expr, fty, td, name, field.name, &loop_counter, diags))
            return false;
    }
    try writer.writeAll("    return true\n}\n");
    return true;
}

/// Emit an inequality guard `if <not equal> { return false }` comparing the two
/// accessor expressions per `ty`. Arrays emit a count guard plus a `while` loop.
fn emitCompare(
    env: *const Env,
    writer: *std.Io.Writer,
    a_expr: []const u8,
    b_expr: []const u8,
    ty: *const ast.TypeExpr,
    owner: ast.TypeDecl,
    owner_name: []const u8,
    field_path: []const u8,
    loop_counter: *usize,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !bool {
    const t = unwrapOwnership(ty);
    switch (t.*) {
        .array => |arr| {
            const idx = loop_counter.*;
            loop_counter.* += 1;
            const iv = try std.fmt.allocPrint(env.allocator, "__k{d}", .{idx});
            try writer.print("    if {s}.count != {s}.count {{ return false }}\n", .{ a_expr, b_expr });
            try writer.print("    var {s} = 0\n", .{iv});
            try writer.print("    while {s} < {s}.count {{\n", .{ iv, a_expr });
            const a_el = try std.fmt.allocPrint(env.allocator, "{s}[{s}]", .{ a_expr, iv });
            const b_el = try std.fmt.allocPrint(env.allocator, "{s}[{s}]", .{ b_expr, iv });
            const elem = arr.element_type;
            // Nested arrays are refused (v1): no fresh-loop nesting story yet.
            if (unwrapOwnership(elem).* == .array)
                return refuse(env, diags, owner, owner_name, field_path, "nested array");
            if (!try emitScalarOrCall(env, writer, a_el, b_el, elem, owner, owner_name, field_path, diags))
                return false;
            try writer.print("        {s} = {s} + 1\n", .{ iv, iv });
            try writer.writeAll("    }\n");
            return true;
        },
        else => return emitScalarOrCall(env, writer, a_expr, b_expr, t, owner, owner_name, field_path, diags),
    }
}

/// Emit the leaf/recursive guard for a non-array element type.
fn emitScalarOrCall(
    env: *const Env,
    writer: *std.Io.Writer,
    a_expr: []const u8,
    b_expr: []const u8,
    ty: *const ast.TypeExpr,
    owner: ast.TypeDecl,
    owner_name: []const u8,
    field_path: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !bool {
    const t = unwrapOwnership(ty);
    const name = bareName(t) orelse
        return refuse(env, diags, owner, owner_name, field_path, "generic/existential type");

    if (isScalarName(name)) {
        try writer.print("    if {s} != {s} {{ return false }}\n", .{ a_expr, b_expr });
        return true;
    }
    if (env.hasUserEq(name)) {
        try writer.print("    if eq_{s}({s}, {s}) == false {{ return false }}\n", .{ name, a_expr, b_expr });
        return true;
    }
    if (env.isStruct(name)) {
        try writer.print("    if {s}{s}({s}, {s}) == false {{ return false }}\n", .{ synth_prefix, name, a_expr, b_expr });
        return true;
    }
    if (env.enums.contains(name)) {
        if (!env.enumHasPayload(name)) {
            // Payload-less enum: `!=` is correct tag inequality.
            try writer.print("    if {s} != {s} {{ return false }}\n", .{ a_expr, b_expr });
            return true;
        }
        return refuse(env, diags, owner, owner_name, field_path, "enum with payload (add @Derive(Equatable) or a user eq_ function)");
    }
    // Unknown bare named type (alias, cross-module type): best-effort leaf.
    try writer.print("    if {s} != {s} {{ return false }}\n", .{ a_expr, b_expr });
    return true;
}

fn refuse(
    env: *const Env,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    owner: ast.TypeDecl,
    owner_name: []const u8,
    field_path: []const u8,
    reason: []const u8,
) !bool {
    const msg = try std.fmt.allocPrint(
        env.allocator,
        "cannot synthesize structural equality for struct `{s}`: field `{s}` has an unsupported type ({s})",
        .{ owner_name, field_path, reason },
    );
    try diagnostics.appendOwned(env.allocator, diags, .{
        .severity = .@"error",
        .code = "KTEST001",
        .title = "unsupported Test result type",
        .message = msg,
        .labels = &.{diagnostics.primaryLabel(owner.span, "declared here")},
        .help = "Provide a user `function eq_<Type>(a: borrow T, b: borrow T) -> Bool` (or `@Derive(Equatable)`) so the test driver can compare this type.",
    });
    return false;
}
