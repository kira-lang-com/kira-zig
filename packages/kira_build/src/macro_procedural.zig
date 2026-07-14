//! Attribute (`@Name`) and derive (`@Derive(Name, ...)`) procedural macro invocation. Runs the
//! compile-time evaluator (macro_eval.zig) over the decorated declaration, strips the macro
//! annotation, and re-parses the macro's `Syntax` output into declarations to splice. Split from
//! macro_expand.zig (Core Law #5).

const std = @import("std");
const syntax = @import("kira_syntax_model");
const source_pkg = @import("kira_source");
const parser = @import("kira_parser");
const expand = @import("macro_expand.zig");
const eval = @import("macro_eval.zig");

const ast = syntax.ast;
const Span = source_pkg.Span;
const Expander = expand.Expander;

pub const DeclMacroResult = struct {
    decl: ast.Decl,
    generated: []ast.Decl,
    // A `replace { true }` macro ran: `generated` stands in for the declaration, which the caller
    // must drop.
    replaced: bool = false,
};

/// Run attribute (`@Name`) and derive (`@Derive(Name, ...)`) macros attached to `decl`, plus any
/// field-triggered macros (`trigger { field }` macros summoned by an annotation on one of the
/// declaration's fields). Returns the declaration with macro annotations stripped, plus the
/// declarations the macros generated (each re-parsed from the macro's `Syntax` text via
/// `parser.parseSource`). When a replace-mode macro ran, `replaced` is set and the caller drops
/// the original declaration in favor of `generated`.
pub fn applyDeclMacros(exp: *Expander, decl: ast.Decl) !DeclMacroResult {
    const annotations = declAnnotations(decl);
    const triggered = try fieldTriggeredMacros(exp, decl);
    const summons = try wrapperFieldSummons(exp, decl);
    if (annotations.len == 0 and triggered.len == 0 and summons.len == 0) {
        return .{ .decl = decl, .generated = &.{} };
    }
    // `@Derive(Copy)` is a builtin copyability assertion, not a user macro, so it must be
    // handled even when no procedural macros are registered (otherwise the guard below would
    // return the declaration with the `@Derive(Copy)` annotation unstripped).
    const wants_copy = deriveCopyRequested(annotations);
    if (exp.proc_macros.count() == 0 and summons.len == 0 and !wants_copy) {
        return .{ .decl = decl, .generated = &.{} };
    }

    const target = try buildDeclaration(exp, decl);
    const target_kind = declTargetKind(decl);
    var kept = std.array_list.Managed(ast.Annotation).init(exp.allocator);
    var generated = std.array_list.Managed(ast.Decl).init(exp.allocator);
    var stripped_any = false;
    var derive_copy = false;
    var replaced_by: ?[]const u8 = null;

    for (annotations) |annotation| {
        const name = annotationName(annotation);
        if (std.mem.eql(u8, name, "Derive")) {
            for (annotation.args) |arg| {
                const derive_name = identifierArg(arg.value) orelse continue;
                // `Copy` is a builtin derive: it records the opt-in copyability assertion
                // (verified downstream by the structural classifier) rather than invoking a
                // user macro, so it is recognized BEFORE the user-macro lookup / KMAC011.
                if (std.mem.eql(u8, derive_name, "Copy")) {
                    derive_copy = true;
                    continue;
                }
                const macro = exp.proc_macros.get(derive_name);
                if (macro != null and macro.?.kind == .proc_derive) {
                    if (!try checkAppliesTo(exp, macro.?, target_kind, annotation.span)) continue;
                    try runProcMacro(exp, macro.?, target, annotation.span, &generated);
                } else {
                    try exp.err("KMAC011", "not a derive macro", "Only a `comptime macro { kind { derive } }` may appear in `@Derive(...)`.", annotation.span, "this is not a derive macro", "Declare the macro with `kind { derive }`, or use it as a function/attribute macro.");
                }
            }
            stripped_any = true;
            continue;
        }
        const macro = exp.proc_macros.get(name);
        if (macro != null and macro.?.kind == .proc_attribute) {
            if (try checkAppliesTo(exp, macro.?, target_kind, annotation.span)) {
                if (try noteReplacer(exp, macro.?, &replaced_by, annotation.span)) {
                    try runProcMacro(exp, macro.?, target, annotation.span, &generated);
                }
            }
            stripped_any = true;
            continue;
        }
        try kept.append(annotation);
    }

    // Field-triggered macros observe the same original declaration; each must be replace-mode
    // (its whole purpose is rewriting the declaration that carries the triggering field).
    for (triggered) |macro| {
        const span = declSpan(decl);
        if (!macro.replace) {
            const message = try std.fmt.allocPrint(exp.allocator, "macro '{s}' is field-triggered but not replace-mode", .{macro.name});
            try exp.err("KMAC029", "field-triggered macro must replace", message, span, "a field annotation summoned this macro", "Add `replace { true }` to the macro: a field-triggered macro rewrites the declaration carrying the field, so its output must replace it.");
            continue;
        }
        if (!try checkAppliesTo(exp, macro, target_kind, span)) continue;
        if (try noteReplacer(exp, macro, &replaced_by, span)) {
            try runProcMacro(exp, macro, target, span, &generated);
        }
    }

    // Wrapper summons: a field annotated with a registered wrapper TEMPLATE's name
    // (`@State var count: Int = 0`) summons the template's wrapper-kind macro over this
    // declaration with both sides bound — expand(target, wrapper). Always replace-mode.
    for (summons) |summon| {
        const span = declSpan(decl);
        if (!try checkAppliesTo(exp, summon.macro, target_kind, span)) continue;
        if (try noteWrapperReplacer(exp, summon.macro, &replaced_by, span)) {
            const wrapper_target = try buildDeclaration(exp, .{ .type_decl = summon.template });
            try runProcMacroPair(exp, summon.macro, target, wrapper_target, span, &generated);
        }
    }

    const stripped_decl = if (!stripped_any and replaced_by == null)
        decl
    else
        setDeclAnnotations(decl, try kept.toOwnedSlice());
    const final_decl = if (derive_copy) setDeriveCopyFlag(stripped_decl) else stripped_decl;
    return .{
        .decl = final_decl,
        .generated = try generated.toOwnedSlice(),
        .replaced = replaced_by != null,
    };
}

/// Whether the declaration carries `@Derive(Copy)` (the builtin copyability assertion).
fn deriveCopyRequested(annotations: []const ast.Annotation) bool {
    for (annotations) |annotation| {
        if (!std.mem.eql(u8, annotationName(annotation), "Derive")) continue;
        for (annotation.args) |arg| {
            const derive_name = identifierArg(arg.value) orelse continue;
            if (std.mem.eql(u8, derive_name, "Copy")) return true;
        }
    }
    return false;
}

/// Record the `@Derive(Copy)` marker on the declaration so it survives annotation stripping
/// into the semantics model, where the structural classifier enforces the assertion.
fn setDeriveCopyFlag(decl: ast.Decl) ast.Decl {
    switch (decl) {
        .type_decl => |d| {
            var nd = d;
            nd.derive_copy = true;
            return .{ .type_decl = nd };
        },
        .enum_decl => |d| {
            var nd = d;
            nd.derive_copy = true;
            return .{ .enum_decl = nd };
        },
        else => return decl,
    }
}

/// Record `macro` as the declaration's replacer if it is replace-mode. At most one replace-mode
/// macro may run per declaration — a second one has no original left to observe (KMAC028).
fn noteReplacer(exp: *Expander, macro: ast.MacroDecl, replaced_by: *?[]const u8, span: Span) !bool {
    if (!macro.replace) return true;
    return noteWrapperReplacer(exp, macro, replaced_by, span);
}

/// A wrapper summon is ALWAYS replace-mode regardless of the macro's `replace` member.
fn noteWrapperReplacer(exp: *Expander, macro: ast.MacroDecl, replaced_by: *?[]const u8, span: Span) !bool {
    if (replaced_by.*) |first| {
        const message = try std.fmt.allocPrint(exp.allocator, "macros '{s}' and '{s}' both replace this declaration", .{ first, macro.name });
        try exp.err("KMAC028", "multiple replacing macros", message, span, "second replace-mode macro here", "Only one `replace { true }` macro may apply to a declaration; merge the rewrites into one macro.");
        return false;
    }
    replaced_by.* = macro.name;
    return true;
}

const WrapperSummon = struct {
    macro: ast.MacroDecl,
    template: ast.TypeDecl,
};

/// Distinct wrapper templates named by this declaration's field annotations, in first-use order.
/// Each summons its wrapper-kind macro once over the whole declaration (a form with three
/// `@State` fields produces ONE `State` summon — the macro loops over the fields itself).
fn wrapperFieldSummons(exp: *Expander, decl: ast.Decl) ![]WrapperSummon {
    if (exp.wrapper_templates.count() == 0) return &.{};
    const members = declBodyMembers(decl) orelse return &.{};
    var found = std.array_list.Managed(WrapperSummon).init(exp.allocator);
    for (members) |member| {
        if (member != .field_decl) continue;
        for (member.field_decl.annotations) |annotation| {
            const template = exp.wrapper_templates.get(annotationName(annotation)) orelse continue;
            var already = false;
            for (found.items) |existing| {
                if (std.mem.eql(u8, existing.template.name, template.decl.name)) already = true;
            }
            if (!already) try found.append(.{ .macro = template.macro, .template = template.decl });
        }
    }
    return found.toOwnedSlice();
}

/// Run a wrapper-kind macro's VALIDATION invocation over its own template struct — both `target`
/// and `wrapper` bound to the template (`target.name == wrapper.name` marks the validation path
/// inside the macro). Returns the declarations it generates; the template itself is dropped by
/// the caller.
pub fn applyWrapperTemplate(exp: *Expander, template: ast.TypeDecl) ![]ast.Decl {
    const registered = exp.wrapper_templates.get(template.name) orelse return &.{};
    var generated = std.array_list.Managed(ast.Decl).init(exp.allocator);
    const target = try buildDeclaration(exp, .{ .type_decl = template });
    try runProcMacroPair(exp, registered.macro, target, target, template.span, &generated);
    return generated.toOwnedSlice();
}

/// Distinct `trigger { field }` attribute macros summoned by annotations on the declaration's
/// fields, in first-trigger order.
fn fieldTriggeredMacros(exp: *Expander, decl: ast.Decl) ![]ast.MacroDecl {
    if (exp.proc_macros.count() == 0) return &.{};
    const members = declBodyMembers(decl) orelse return &.{};
    var found = std.array_list.Managed(ast.MacroDecl).init(exp.allocator);
    for (members) |member| {
        if (member != .field_decl) continue;
        for (member.field_decl.annotations) |annotation| {
            const macro = exp.proc_macros.get(annotationName(annotation)) orelse continue;
            if (!macro.trigger_field or macro.kind != .proc_attribute) continue;
            var already = false;
            for (found.items) |existing| {
                if (std.mem.eql(u8, existing.name, macro.name)) already = true;
            }
            if (!already) try found.append(macro);
        }
    }
    return found.toOwnedSlice();
}

fn declBodyMembers(decl: ast.Decl) ?[]ast.BodyMember {
    return switch (decl) {
        .type_decl => |d| d.members,
        .construct_decl => |d| d.members,
        .construct_form_decl => |d| d.body.members,
        else => null,
    };
}

fn declSpan(decl: ast.Decl) Span {
    return switch (decl) {
        inline .macro_invocation => |d| d.span,
        inline else => |d| d.span,
    };
}

/// Look up a function-position macro by call name, or null if `name` is not a `kind { function }`
/// macro in scope. Callers in expression/statement position use this to decide whether a
/// `name!(args)` call is a procedural function macro (vs an unknown declarative macro -> KMAC001).
pub fn lookupFuncMacro(exp: *Expander, call: ast.CallExpr) ?ast.MacroDecl {
    if (call.callee.* != .identifier or call.callee.identifier.name.segments.len != 1) return null;
    return exp.func_macros.get(call.callee.identifier.name.segments[0].text);
}

/// Render a function macro's call arguments to source text and run `expand(input: Syntax)`,
/// returning the generated source text (or null if the macro emitted a diagnostic).
fn runFuncMacroText(exp: *Expander, macro: ast.MacroDecl, call: ast.CallExpr) !?[]const u8 {
    var input = std.array_list.Managed(u8).init(exp.allocator);
    for (call.args, 0..) |arg, i| {
        if (i != 0) try input.appendSlice(", ");
        try input.appendSlice(try eval.exprToText(exp.allocator, arg.value.*));
    }
    var evaluator = eval.Evaluator{ .allocator = exp.allocator, .diags = exp.diags };
    return evaluator.runOnInput(macro, try input.toOwnedSlice()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MacroEvalError => return null,
    };
}

/// Expand a top-level `name!(args)` function-macro invocation: render the arguments to source,
/// run the macro's `expand(input: Syntax)`, and re-parse the generated declarations.
pub fn expandMacroInvocation(exp: *Expander, call: ast.CallExpr) ![]ast.Decl {
    const macro = lookupFuncMacro(exp, call) orelse {
        const name = if (call.callee.* == .identifier and call.callee.identifier.name.segments.len == 1)
            call.callee.identifier.name.segments[0].text
        else
            "";
        const message = try std.fmt.allocPrint(exp.allocator, "no function macro named '{s}' is in scope", .{name});
        try exp.err("KMAC001", "unknown macro", message, call.span, "this macro is not declared", "Declare it with `comptime macro <name> { kind { function } ... }`.");
        return &.{};
    };
    const text = (try runFuncMacroText(exp, macro, call)) orelse return &.{};
    const generated_program = parser.parseSource(exp.allocator, text, exp.diags) catch return &.{};
    return generated_program.decls;
}

const frag_wrapper_name = "__kira_macro_frag__";

/// Parse the generated source of a function macro by wrapping it in a throwaway function and
/// returning that function's body statements (or null if the wrapper did not parse).
fn parseFuncMacroBody(exp: *Expander, macro: ast.MacroDecl, call: ast.CallExpr) !?[]ast.Statement {
    const text = (try runFuncMacroText(exp, macro, call)) orelse return null;
    const wrapped = try std.fmt.allocPrint(exp.allocator, "function {s}() {{\n{s}\n}}", .{ frag_wrapper_name, text });
    const program = parser.parseSource(exp.allocator, wrapped, exp.diags) catch return null;
    const body = wrapperBody(program) orelse return null;
    return body.statements;
}

/// A function macro used in *statement* position: its expansion's statements are spliced in place
/// of the `name!(...)` call.
pub fn expandFuncMacroStatements(exp: *Expander, macro: ast.MacroDecl, call: ast.CallExpr) ![]ast.Statement {
    return (try parseFuncMacroBody(exp, macro, call)) orelse {
        try exp.err("KMAC016", "macro output is not a statement list", "This function macro was used in statement position, but its expansion did not parse as Kira statements.", call.span, "expansion used as statements here", "Return statements/expressions from the macro, or use it in declaration position at top level.");
        return &.{};
    };
}

/// A function macro used in *expression* position: its expansion must be a single expression
/// statement, whose expression becomes the value. Anything else (a `let`, multiple statements) has
/// no value and is rejected with KMAC017.
pub fn expandFuncMacroExpr(exp: *Expander, macro: ast.MacroDecl, call: ast.CallExpr) !?*ast.Expr {
    const statements = (try parseFuncMacroBody(exp, macro, call)) orelse return null;
    if (statements.len != 1 or statements[0] != .expr_stmt) {
        try exp.err("KMAC017", "macro output is not an expression", "This function macro was used in expression position, but its expansion did not parse as a single Kira expression.", call.span, "expansion used as a value here", "Return one expression from the macro, or use it in statement position.");
        return null;
    }
    return statements[0].expr_stmt.expr;
}

/// Find the throwaway wrapper function's body in a parsed program.
fn wrapperBody(program: ast.Program) ?ast.Block {
    for (program.decls) |decl| {
        if (decl == .function_decl and std.mem.eql(u8, decl.function_decl.name, frag_wrapper_name)) {
            return decl.function_decl.body;
        }
    }
    return null;
}

fn runProcMacro(exp: *Expander, macro: ast.MacroDecl, target: ?eval.Declaration, span: Span, generated: *std.array_list.Managed(ast.Decl)) !void {
    const decl_target = target orelse {
        try exp.err("KMAC007", "macro target not supported", "This macro can only be applied to a struct or class declaration.", span, "unsupported macro target", "Apply the macro to a `struct` or `class` declaration.");
        return;
    };
    var evaluator = eval.Evaluator{ .allocator = exp.allocator, .diags = exp.diags };
    const text_opt = evaluator.runOnDeclaration(macro, decl_target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MacroEvalError => return, // diagnostic already emitted
    };
    const text = text_opt orelse return;
    try spliceGeneratedText(exp, macro, text, generated);
}

/// Run a wrapper-kind macro with BOTH declarations bound: expand(target, wrapper). Used for the
/// validation invocation (target == wrapper == the template) and for field summons (target = the
/// declaration carrying the wrapped field, wrapper = the template).
fn runProcMacroPair(exp: *Expander, macro: ast.MacroDecl, target: ?eval.Declaration, wrapper: ?eval.Declaration, span: Span, generated: *std.array_list.Managed(ast.Decl)) !void {
    const decl_target = target orelse {
        try exp.err("KMAC007", "macro target not supported", "A wrapper macro applies to struct, class, enum, or form declarations.", span, "unsupported macro target", "Use the wrapper on a declaration kind listed in its `appliesTo`.");
        return;
    };
    const decl_wrapper = wrapper orelse return;
    var evaluator = eval.Evaluator{ .allocator = exp.allocator, .diags = exp.diags };
    const text_opt = evaluator.runOnDeclarationPair(macro, decl_target, decl_wrapper) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MacroEvalError => return, // diagnostic already emitted
    };
    const text = text_opt orelse return;
    try spliceGeneratedText(exp, macro, text, generated);
}

fn spliceGeneratedText(exp: *Expander, macro: ast.MacroDecl, text: []const u8, generated: *std.array_list.Managed(ast.Decl)) !void {
    // KIRA_MACRO_DEBUG=1 dumps every attribute/derive/wrapper macro expansion to stderr — the only
    // way to see the generated source when it fails to re-parse (its spans have no real file).
    if (std.c.getenv("KIRA_MACRO_DEBUG")) |debug_flag| {
        if (debug_flag[0] != 0) {
            std.debug.print("=== macro '{s}' expansion ===\n{s}\n=== end expansion ===\n", .{ macro.name, text });
        }
    }

    const generated_program = parser.parseSource(exp.allocator, text, exp.diags) catch return;
    for (generated_program.decls) |gen_decl| try generated.append(gen_decl);
}

/// The source text a span points into, when it is available (a real file, cached by the
/// expander) and the span is inside it. Spans into macro-generated text have no file to read.
fn spanSource(exp: *Expander, span: Span) ?[]const u8 {
    const path = span.source_path orelse return null;
    const text = exp.sourceText(path) orelse return null;
    if (span.end > text.len or span.start > span.end) return null;
    return text;
}

fn spanSlice(exp: *Expander, span: Span) ?[]const u8 {
    const text = spanSource(exp, span) orelse return null;
    return span.slice(text);
}

/// Source text of a whole declaration for `Declaration.syntax` (falls back to the bare name when
/// the source is unavailable, e.g. a declaration generated by another macro). The declaration's
/// own annotations are excluded — they are consumed by expansion, and a rewriting macro splicing
/// `target.syntax` back must not re-emit `@State` / `@PropertyWrapper`. Field annotations inside
/// the body are unaffected.
fn declSyntaxText(exp: *Expander, name: []const u8, span: Span, annotations: []const ast.Annotation) []const u8 {
    const text = spanSource(exp, span) orelse return name;
    var start = span.start;
    for (annotations) |annotation| {
        if (annotation.span.end > start and annotation.span.end <= span.end) start = annotation.span.end;
    }
    while (start < span.end and (text[start] == ' ' or text[start] == '\t' or text[start] == '\n' or text[start] == '\r')) start += 1;
    return text[start..span.end];
}

/// Build the reflection `Field` records for a declaration body's field members, with annotations,
/// initializer source, and full field source when the file text is reachable.
fn buildFields(exp: *Expander, members: []const ast.BodyMember) ![]eval.Field {
    var fields = std.array_list.Managed(eval.Field).init(exp.allocator);
    for (members) |member| {
        if (member != .field_decl) continue;
        const field = member.field_decl;
        const type_text = if (field.type_expr) |type_expr|
            try eval.typeToText(exp.allocator, type_expr.*)
        else
            "";
        var annotation_names = std.array_list.Managed([]const u8).init(exp.allocator);
        for (field.annotations) |annotation| try annotation_names.append(annotationName(annotation));
        const initializer_text = if (field.value) |value|
            (spanSlice(exp, exprSpan(value.*)) orelse "")
        else
            "";
        // The field's own source, annotations included.
        var field_span = field.span;
        for (field.annotations) |annotation| {
            if (annotation.span.start < field_span.start) field_span.start = annotation.span.start;
        }
        try fields.append(.{
            .name = field.name,
            .type_text = type_text,
            .annotations = try annotation_names.toOwnedSlice(),
            .initializer_text = initializer_text,
            .syntax_text = spanSlice(exp, field_span) orelse "",
        });
    }
    return fields.toOwnedSlice();
}

fn exprSpan(expr: ast.Expr) Span {
    return switch (expr) {
        inline else => |e| e.span,
    };
}

fn buildDeclaration(exp: *Expander, decl: ast.Decl) !?eval.Declaration {
    switch (decl) {
        .type_decl => |type_decl| {
            return eval.Declaration{
                .name = type_decl.name,
                .fields = try buildFields(exp, type_decl.members),
                .syntax = declSyntaxText(exp, type_decl.name, type_decl.span, type_decl.annotations),
                .span = type_decl.span,
            };
        },
        .construct_form_decl => |form_decl| {
            return eval.Declaration{
                .name = form_decl.name,
                .fields = try buildFields(exp, form_decl.body.members),
                .syntax = declSyntaxText(exp, form_decl.name, form_decl.span, form_decl.annotations),
                .span = form_decl.span,
            };
        },
        .enum_decl => |enum_decl| {
            // Enum variants surface through the same `fields` reflection: `field.name` is the
            // variant name, `field.type` its associated payload type (empty if the variant is bare).
            var fields = std.array_list.Managed(eval.Field).init(exp.allocator);
            for (enum_decl.variants) |variant| {
                const type_text = if (variant.associated_type) |type_expr|
                    try eval.typeToText(exp.allocator, type_expr.*)
                else
                    "";
                try fields.append(.{ .name = variant.name, .type_text = type_text });
            }
            return eval.Declaration{
                .name = enum_decl.name,
                .fields = try fields.toOwnedSlice(),
                .syntax = enum_decl.name,
                .span = enum_decl.span,
            };
        },
        else => return null,
    }
}

/// The `appliesTo` target kind of a declaration, or null for kinds that can't carry derive/attribute
/// macros (a class/struct distinction comes from `TypeDecl.kind`).
fn declTargetKind(decl: ast.Decl) ?ast.MacroTargetKind {
    return switch (decl) {
        .type_decl => |d| switch (d.kind) {
            .class => .class_target,
            .struct_decl => .struct_target,
        },
        .enum_decl => .enum_target,
        .construct_form_decl => .form_target,
        else => null,
    };
}

/// Verify a derive/attribute macro's `appliesTo` list admits this declaration kind. An empty list
/// admits everything (back-compat with macros that omit `appliesTo`). Emits KMAC007 and returns
/// false on a mismatch.
fn checkAppliesTo(exp: *Expander, macro: ast.MacroDecl, target_kind: ?ast.MacroTargetKind, span: Span) !bool {
    if (macro.applies_to.len == 0) return true;
    const kind = target_kind orelse {
        try exp.err("KMAC007", "macro target not supported", "This macro can only be applied to a struct, class, or enum declaration.", span, "unsupported macro target", "Apply the macro to a `struct`, `class`, or `enum` declaration.");
        return false;
    };
    for (macro.applies_to) |allowed| {
        if (allowed == kind) return true;
    }
    const kind_name = switch (kind) {
        .struct_target => "struct",
        .class_target => "class",
        .enum_target => "enum",
        .form_target => "form",
    };
    const message = try std.fmt.allocPrint(exp.allocator, "macro '{s}' does not apply to a {s} declaration", .{ macro.name, kind_name });
    try exp.err("KMAC007", "macro target not in appliesTo", message, span, "this declaration kind is not in the macro's `appliesTo`", "Add this declaration kind to the macro's `appliesTo`, or remove the annotation.");
    return false;
}

fn declAnnotations(decl: ast.Decl) []const ast.Annotation {
    return switch (decl) {
        .type_decl => |d| d.annotations,
        .enum_decl => |d| d.annotations,
        .construct_decl => |d| d.annotations,
        .construct_form_decl => |d| d.annotations,
        .extend_decl => |d| d.annotations,
        .function_decl => |d| d.annotations,
        else => &.{},
    };
}

fn setDeclAnnotations(decl: ast.Decl, annotations: []const ast.Annotation) ast.Decl {
    switch (decl) {
        .type_decl => |d| {
            var nd = d;
            nd.annotations = annotations;
            return .{ .type_decl = nd };
        },
        .enum_decl => |d| {
            var nd = d;
            nd.annotations = annotations;
            return .{ .enum_decl = nd };
        },
        .construct_form_decl => |d| {
            var nd = d;
            nd.annotations = annotations;
            return .{ .construct_form_decl = nd };
        },
        else => return decl,
    }
}

fn annotationName(annotation: ast.Annotation) []const u8 {
    const segments = annotation.name.segments;
    if (segments.len == 0) return "";
    return segments[segments.len - 1].text;
}

fn identifierArg(expr: *ast.Expr) ?[]const u8 {
    if (expr.* == .identifier and expr.identifier.name.segments.len == 1) {
        return expr.identifier.name.segments[0].text;
    }
    return null;
}
