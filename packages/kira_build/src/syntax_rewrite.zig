//! Scope-aware source rewriting for `Syntax` reflection values (`Syntax.dropField`,
//! `Syntax.rewriteProperty`) — the machinery behind pure-Kira property-wrapper macros.
//!
//! A `Syntax` value in the macro evaluator is source text. These helpers parse that text, walk
//! the declaration's member bodies with full lexical-scope tracking, and apply *span edits* back
//! onto the original text — no pretty-printer, so untouched source (comments, spacing) survives
//! byte-for-byte. The edited text is re-parsed by the normal expansion flow like any other macro
//! output; a rewrite can never smuggle in unparseable code silently.
//!
//! `rewriteProperty(name, read, writeCallee)` rewrites, inside every member body of the
//! declaration:
//!   * bare reads of `name`        -> the `read` syntax (e.g. `__state_Counter_get_count()`)
//!   * assignments `name = value`  -> `writeCallee(value)`
//! A use is rewritten only when `name` is not shadowed by a local binding (let/var, parameter,
//! callback parameter, for/builder-for binding, match `as` binding, attempt handler binding) —
//! mirroring name resolution. Assigning *through* a wrapped property (`name.x = v`, `name[i] = v`)
//! is a diagnostic: the proxy has no place to write through.
//!
//! `dropField(name)` removes the named field declaration (including its annotations) from the
//! declaration body.

const std = @import("std");
const syntax = @import("kira_syntax_model");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const parser = @import("kira_parser");

const ast = syntax.ast;
const Span = source_pkg.Span;

pub const RewriteError = error{ RewriteFailed, OutOfMemory };

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

const Context = struct {
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    /// Span of the macro-body call that requested the rewrite — every diagnostic points here,
    /// because the rewritten text has no stable location in the user's source.
    call_span: Span,
    property: []const u8,
    read_text: []const u8,
    write_callee: []const u8,
    edits: std.array_list.Managed(Edit),
    shadows: std.array_list.Managed(ShadowEntry),
    depth: u32 = 0,
    failed: bool = false,

    const ShadowEntry = struct { name: []const u8, depth: u32 };

    fn err(self: *Context, code: []const u8, title: []const u8, message: []const u8, label: []const u8, help: []const u8) !void {
        self.failed = true;
        try diagnostics.appendOwned(self.allocator, self.diags, .{
            .severity = .@"error",
            .code = code,
            .title = title,
            .message = message,
            .labels = &.{diagnostics.primaryLabel(self.call_span, label)},
            .help = help,
        });
    }

    fn pushShadow(self: *Context, name: []const u8) !void {
        try self.shadows.append(.{ .name = name, .depth = self.depth });
    }

    fn enterScope(self: *Context) void {
        self.depth += 1;
    }

    fn exitScope(self: *Context) void {
        std.debug.assert(self.depth > 0);
        while (self.shadows.items.len > 0 and self.shadows.items[self.shadows.items.len - 1].depth == self.depth) {
            _ = self.shadows.pop();
        }
        self.depth -= 1;
    }

    fn isShadowed(self: *Context, name: []const u8) bool {
        for (self.shadows.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    /// True when this expression is a bare, unshadowed use of the wrapped property.
    fn isPropertyUse(self: *Context, expr: *ast.Expr) bool {
        if (expr.* != .identifier) return false;
        const segments = expr.identifier.name.segments;
        if (segments.len != 1) return false;
        if (!std.mem.eql(u8, segments[0].text, self.property)) return false;
        return !self.isShadowed(self.property);
    }

    fn addEdit(self: *Context, start: usize, end: usize, replacement: []const u8) !void {
        try self.edits.append(.{ .start = start, .end = end, .replacement = replacement });
    }
};

/// Apply span edits (sorted, non-overlapping) to `text`.
fn applyEdits(allocator: std.mem.Allocator, text: []const u8, edits: []Edit) ![]const u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.end < b.end;
        }
    }.lessThan);
    var out = std.array_list.Managed(u8).init(allocator);
    var cursor: usize = 0;
    for (edits) |edit| {
        std.debug.assert(edit.start >= cursor);
        try out.appendSlice(text[cursor..edit.start]);
        try out.appendSlice(edit.replacement);
        cursor = edit.end;
    }
    try out.appendSlice(text[cursor..]);
    return out.toOwnedSlice();
}

/// Parse a `Syntax` text expected to hold exactly one rewritable declaration. Diagnostics from
/// the parse are DROPPED (parsed into a scratch list): a non-declaration `Syntax` value is the
/// macro author's error and gets one clear KMAC026, not a cascade of parse errors pointing at
/// synthetic text.
fn parseSingleDecl(allocator: std.mem.Allocator, text: []const u8) ?ast.Program {
    var scratch = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    defer scratch.deinit();
    const program = parser.parseSource(allocator, text, &scratch) catch return null;
    for (scratch.items) |diag| {
        if (diag.severity == .@"error") return null;
    }
    return program;
}

// --- dropField -----------------------------------------------------------------

pub fn dropField(
    allocator: std.mem.Allocator,
    text: []const u8,
    field_name: []const u8,
    call_span: Span,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) RewriteError![]const u8 {
    const program = parseSingleDecl(allocator, text) orelse {
        try appendErr(allocator, diags, call_span, "KMAC026", "Syntax value is not a declaration", "dropField/rewriteProperty require a Syntax value holding one declaration (a struct, class, or construct form).", "this call received non-declaration syntax", "Call these methods on `target.syntax` (or a value derived from it).");
        return error.RewriteFailed;
    };

    var edits = std.array_list.Managed(Edit).init(allocator);
    defer edits.deinit();

    for (program.decls) |decl| {
        const members = declMembers(decl) orelse continue;
        for (members) |member| {
            if (member != .field_decl) continue;
            const field = member.field_decl;
            if (!std.mem.eql(u8, field.name, field_name)) continue;
            var start = field.span.start;
            for (field.annotations) |annotation| {
                if (annotation.span.start < start) start = annotation.span.start;
            }
            var end = field.span.end;
            // Swallow the rest of the line (trailing whitespace + newline) so no blank hole stays.
            while (end < text.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
            if (end < text.len and text[end] == '\n') end += 1;
            try edits.append(.{ .start = start, .end = end, .replacement = "" });
        }
    }

    if (edits.items.len == 0) {
        const message = try std.fmt.allocPrint(allocator, "the declaration has no field named '{s}'", .{field_name});
        try appendErr(allocator, diags, call_span, "KMAC025", "dropField: no such field", message, "requested field does not exist", "Pass the name of a field that exists on the target declaration.");
        return error.RewriteFailed;
    }

    return applyEdits(allocator, text, edits.items);
}

// --- rewriteProperty --------------------------------------------------------------

pub fn rewriteProperty(
    allocator: std.mem.Allocator,
    text: []const u8,
    property: []const u8,
    read_text: []const u8,
    write_callee: []const u8,
    call_span: Span,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) RewriteError![]const u8 {
    const program = parseSingleDecl(allocator, text) orelse {
        try appendErr(allocator, diags, call_span, "KMAC026", "Syntax value is not a declaration", "dropField/rewriteProperty require a Syntax value holding one declaration (a struct, class, or construct form).", "this call received non-declaration syntax", "Call these methods on `target.syntax` (or a value derived from it).");
        return error.RewriteFailed;
    };

    var context = Context{
        .allocator = allocator,
        .diags = diags,
        .call_span = call_span,
        .property = property,
        .read_text = read_text,
        .write_callee = write_callee,
        .edits = std.array_list.Managed(Edit).init(allocator),
        .shadows = std.array_list.Managed(Context.ShadowEntry).init(allocator),
    };
    defer context.edits.deinit();
    defer context.shadows.deinit();

    for (program.decls) |decl| {
        const members = declMembers(decl) orelse continue;
        for (members) |member| try walkMember(&context, member);
    }
    if (context.failed) return error.RewriteFailed;

    return applyEdits(allocator, text, context.edits.items);
}

fn appendErr(
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    span: Span,
    code: []const u8,
    title: []const u8,
    message: []const u8,
    label: []const u8,
    help: []const u8,
) !void {
    try diagnostics.appendOwned(allocator, diags, .{
        .severity = .@"error",
        .code = code,
        .title = title,
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, label)},
        .help = help,
    });
}

fn declMembers(decl: ast.Decl) ?[]ast.BodyMember {
    return switch (decl) {
        .type_decl => |d| d.members,
        .construct_decl => |d| d.members,
        .construct_form_decl => |d| d.body.members,
        .extend_decl => |d| d.members,
        else => null,
    };
}

// --- Member / statement / expression walk -----------------------------------------

fn walkMember(ctx: *Context, member: ast.BodyMember) RewriteError!void {
    switch (member) {
        .field_decl => |f| {
            // A field named like the property would re-declare it; the caller drops the wrapped
            // field itself before rewriting, so any remaining same-named field shadows nothing at
            // member level (fields are not lexical shadows for sibling members). Walk the default
            // value and computed body.
            if (f.value) |value| try walkExpr(ctx, value);
            if (f.body) |body| try walkBlockScoped(ctx, body);
        },
        .function_decl => |f| {
            ctx.enterScope();
            defer ctx.exitScope();
            for (f.params) |param| try ctx.pushShadow(param.name);
            if (f.body) |body| try walkBlock(ctx, body);
        },
        .content_section => |c| try walkBuilder(ctx, c.builder),
        .lifecycle_hook => |h| {
            for (h.args) |arg| {
                if (arg.value) |value| try walkExpr(ctx, value);
            }
            try walkBlockScoped(ctx, h.body);
        },
        .named_rule => |r| {
            for (r.args) |arg| {
                if (arg.value) |value| try walkExpr(ctx, value);
            }
            if (r.value) |value| try walkExpr(ctx, value);
            if (r.block) |block| try walkBlockScoped(ctx, block);
        },
        .properties_section => |p| {
            for (p.entries) |entry| try walkExpr(ctx, entry.value);
        },
    }
}

fn walkBlockScoped(ctx: *Context, block: ast.Block) RewriteError!void {
    ctx.enterScope();
    defer ctx.exitScope();
    try walkBlock(ctx, block);
}

fn walkBlock(ctx: *Context, block: ast.Block) RewriteError!void {
    ctx.enterScope();
    defer ctx.exitScope();
    for (block.statements) |statement| try walkStatement(ctx, statement);
}

fn walkStatement(ctx: *Context, statement: ast.Statement) RewriteError!void {
    switch (statement) {
        .let_stmt => |s| {
            if (s.value) |value| try walkExpr(ctx, value);
            // The binding shadows the property from here to the end of the enclosing scope.
            try ctx.pushShadow(s.name);
        },
        .assign_stmt => |s| {
            try walkExpr(ctx, s.value);
            if (ctx.isPropertyUse(s.target)) {
                // `count = v`  =>  `writeCallee(v)`
                try ctx.addEdit(s.target.identifier.span.start, exprSpan(s.value.*).start, try std.fmt.allocPrint(ctx.allocator, "{s}(", .{ctx.write_callee}));
                try ctx.addEdit(exprSpan(s.value.*).end, exprSpan(s.value.*).end, ")");
                return;
            }
            if (pathRootsAtProperty(ctx, s.target)) {
                try ctx.err("KMAC027", "cannot assign through a property wrapper", "Assigning into a member or element of a wrapped property is not supported; read the value, modify the copy, and assign it back.", "assignment through a wrapped property path", "Write `var copy = property`, mutate `copy`, then `property = copy`.");
                return;
            }
            try walkExpr(ctx, s.target);
        },
        .expr_stmt => |s| try walkExpr(ctx, s.expr),
        .return_stmt => |s| {
            if (s.value) |value| try walkExpr(ctx, value);
        },
        .if_stmt => |s| {
            try walkExpr(ctx, s.condition);
            try walkBlock(ctx, s.then_block);
            if (s.else_block) |eb| try walkBlock(ctx, eb);
        },
        .for_stmt => |s| {
            try walkExpr(ctx, s.iterator);
            if (s.range_end) |re| try walkExpr(ctx, re);
            ctx.enterScope();
            defer ctx.exitScope();
            try ctx.pushShadow(s.binding_name);
            try walkBlock(ctx, s.body);
        },
        .while_stmt => |s| {
            try walkExpr(ctx, s.condition);
            try walkBlock(ctx, s.body);
        },
        .match_stmt => |s| {
            try walkExpr(ctx, s.subject);
            for (s.arms) |arm| {
                ctx.enterScope();
                defer ctx.exitScope();
                for (arm.patterns) |pattern| try shadowPattern(ctx, pattern);
                if (arm.guard) |guard| try walkExpr(ctx, guard);
                try walkBlock(ctx, arm.body);
            }
        },
        .switch_stmt => |s| {
            try walkExpr(ctx, s.subject);
            for (s.cases) |case| {
                try walkExpr(ctx, case.pattern);
                try walkBlock(ctx, case.body);
            }
            if (s.default_block) |db| try walkBlock(ctx, db);
        },
        .attempt_stmt => |s| {
            ctx.enterScope();
            for (s.body) |inner| try walkStatement(ctx, inner);
            ctx.exitScope();
            for (s.handlers) |handler| {
                ctx.enterScope();
                defer ctx.exitScope();
                if (handler.binding_name) |binding| try ctx.pushShadow(binding);
                try walkBlock(ctx, handler.body);
            }
        },
        .break_stmt, .continue_stmt => {},
    }
}

fn shadowPattern(ctx: *Context, pattern: ast.MatchPattern) RewriteError!void {
    switch (pattern) {
        // A destructure binding (`Some(v)`) introduces `v`; a bare variant introduces nothing.
        // MatchPattern models payload binding as a nested pattern whose leaf is a bare name; treat
        // every leaf name inside a destructure as a binding to stay conservative (a false shadow
        // only suppresses a rewrite, never corrupts one — and the property name colliding with a
        // match binding is the same collision it would be in hand-written code).
        .bare_variant => {},
        .destructure => |d| try shadowPatternNames(ctx, d.inner.*),
        .as_binding => |b| {
            try ctx.pushShadow(b.binding_name);
            try shadowPattern(ctx, b.inner.*);
        },
    }
}

fn shadowPatternNames(ctx: *Context, pattern: ast.MatchPattern) RewriteError!void {
    switch (pattern) {
        .bare_variant => |v| try ctx.pushShadow(v.name),
        .destructure => |d| try shadowPatternNames(ctx, d.inner.*),
        .as_binding => |b| {
            try ctx.pushShadow(b.binding_name);
            try shadowPatternNames(ctx, b.inner.*);
        },
    }
}

fn pathRootsAtProperty(ctx: *Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .member => |m| pathRootsAtProperty(ctx, m.object),
        .index => |i| pathRootsAtProperty(ctx, i.object),
        .identifier => ctx.isPropertyUse(expr),
        else => false,
    };
}

fn walkExpr(ctx: *Context, expr: *ast.Expr) RewriteError!void {
    if (ctx.isPropertyUse(expr)) {
        try ctx.addEdit(expr.identifier.span.start, expr.identifier.span.end, ctx.read_text);
        return;
    }
    switch (expr.*) {
        .call => |c| {
            try walkExpr(ctx, c.callee);
            for (c.args) |arg| try walkExpr(ctx, arg.value);
            if (c.trailing_builder) |tb| try walkBuilder(ctx, tb);
            if (c.trailing_callback) |cb| {
                ctx.enterScope();
                defer ctx.exitScope();
                for (cb.params) |param| try ctx.pushShadow(param.name);
                try walkBlock(ctx, cb.body);
            }
        },
        .callback => |cb| {
            ctx.enterScope();
            defer ctx.exitScope();
            for (cb.params) |param| try ctx.pushShadow(param.name);
            try walkBlock(ctx, cb.body);
        },
        .binary => |b| {
            try walkExpr(ctx, b.lhs);
            try walkExpr(ctx, b.rhs);
        },
        .unary => |u| try walkExpr(ctx, u.operand),
        .ownership => |o| try walkExpr(ctx, o.operand),
        .try_expr => |t| try walkExpr(ctx, t.operand),
        .member => |m| try walkExpr(ctx, m.object),
        .index => |i| {
            try walkExpr(ctx, i.object);
            try walkExpr(ctx, i.index);
        },
        .conditional => |c| {
            try walkExpr(ctx, c.condition);
            try walkExpr(ctx, c.then_expr);
            try walkExpr(ctx, c.else_expr);
        },
        .array => |a| {
            for (a.elements) |element| try walkExpr(ctx, element);
        },
        .builder_array => |b| try walkBuilder(ctx, b.builder),
        .struct_literal => |s| {
            for (s.fields) |field| try walkExpr(ctx, field.value);
        },
        .native_state => |n| try walkExpr(ctx, n.value),
        .native_user_data => |n| try walkExpr(ctx, n.state),
        .native_recover => |n| try walkExpr(ctx, n.value),
        .native_state_free => |n| try walkExpr(ctx, n.state),
        else => {},
    }
}

fn walkBuilder(ctx: *Context, block: ast.BuilderBlock) RewriteError!void {
    ctx.enterScope();
    defer ctx.exitScope();
    for (block.items) |item| {
        switch (item) {
            .expr => |e| try walkExpr(ctx, e.expr),
            .if_item => |i| {
                try walkExpr(ctx, i.condition);
                try walkBuilder(ctx, i.then_block);
                if (i.else_block) |eb| try walkBuilder(ctx, eb);
            },
            .for_item => |f| {
                try walkExpr(ctx, f.iterator);
                ctx.enterScope();
                defer ctx.exitScope();
                try ctx.pushShadow(f.binding_name);
                try walkBuilder(ctx, f.body);
            },
            .switch_item => |s| {
                try walkExpr(ctx, s.subject);
                for (s.cases) |case| {
                    try walkExpr(ctx, case.pattern);
                    try walkBuilder(ctx, case.body);
                }
                if (s.default_block) |db| try walkBuilder(ctx, db);
            },
        }
    }
}

fn exprSpan(expr: ast.Expr) Span {
    return switch (expr) {
        inline else => |e| e.span,
    };
}
