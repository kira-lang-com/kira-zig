const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;
const paramsEnd = parent.paramsEnd;
const sectionKind = parent.sectionKind;
const tokenDescription = parent.tokenDescription;
const unexpectedTokenLabel = parent.unexpectedTokenLabel;
const expectedTokenHelp = parent.expectedTokenHelp;
const cloneQualifiedName = parent.cloneQualifiedName;
const complex = @import("parser_decls_complex.zig");

pub const parseTypeDeclWithAnnotations = complex.parseTypeDeclWithAnnotations;
pub const parseConstructDeclWithAnnotations = complex.parseConstructDeclWithAnnotations;
pub const parseConstructSection = complex.parseConstructSection;
pub const parseConstructContentSection = complex.parseConstructContentSection;
pub const parseContentProjection = complex.parseContentProjection;
pub const parseContentChannel = complex.parseContentChannel;
pub const parseCountRange = complex.parseCountRange;
pub const parsePropertySchemaField = complex.parsePropertySchemaField;
pub const parseDeclPropertiesSection = complex.parseDeclPropertiesSection;
pub const parseAnnotationSpec = complex.parseAnnotationSpec;
pub const parseConstructFormDeclWithAnnotations = complex.parseConstructFormDeclWithAnnotations;
pub const parseExtendDecl = complex.parseExtendDecl;
pub const parseConstructBody = complex.parseConstructBody;
pub const parseBodyMember = complex.parseBodyMember;
pub const parseFieldDecl = complex.parseFieldDecl;
pub const parseContentSection = complex.parseContentSection;
pub const parseLifecycleHook = complex.parseLifecycleHook;
pub const parseNamedRule = complex.parseNamedRule;

pub fn parseTopLevelDecl(self: *Parser, annotations: []const syntax.ast.Annotation) !?syntax.ast.Decl {
    if (self.at(.kw_annotation)) {
        return .{ .annotation_decl = try self.parseAnnotationDeclWithAnnotations(annotations) };
    }
    if (self.at(.kw_capability)) {
        if (annotations.len != 0) {
            try self.emitUnexpectedToken(
                "capability declarations cannot be annotated",
                self.peek(),
                "capability declaration starts here",
                "Remove the preceding annotation usage.",
            );
            return error.DiagnosticsEmitted;
        }
        return .{ .capability_decl = try self.parseCapabilityDecl() };
    }
    if (self.at(.kw_enum)) {
        return .{ .enum_decl = try self.parseEnumDeclWithAnnotations(annotations) };
    }
    if (self.at(.kw_comptime)) {
        const comptime_token = self.advance();
        if (self.at(.kw_function)) {
            return .{ .function_decl = try self.parseFunctionDeclWithAnnotations(annotations, false, true) };
        }
        if (self.at(.kw_construct)) {
            return .{ .construct_decl = try self.parseConstructDeclWithAnnotations(annotations, true) };
        }
        if (self.at(.kw_macro)) {
            return .{ .macro_decl = try self.parseProceduralMacroDecl(annotations) };
        }
        try self.emitUnexpectedToken(
            "expected comptime declaration",
            self.peek(),
            "`comptime` applies to function, construct, or macro declarations",
            "Write `comptime function ...`, `comptime construct ...`, or `comptime macro ...`.",
        );
        _ = comptime_token;
        return error.DiagnosticsEmitted;
    }
    if (self.at(.kw_macro)) {
        return .{ .macro_decl = try self.parseDeclarativeMacroDecl(annotations) };
    }
    if (self.at(.kw_async) and self.peekNext().kind == .kw_function) {
        _ = self.advance();
        return .{ .function_decl = try self.parseFunctionDeclWithAnnotationsAsync(annotations, false, false, true) };
    }
    if (self.at(.kw_function)) {
        return .{ .function_decl = try self.parseFunctionDeclWithAnnotations(annotations, false, false) };
    }
    if (self.at(.kw_class)) {
        return .{ .type_decl = try self.parseTypeDeclWithAnnotations(annotations, .class) };
    }
    if (self.at(.kw_struct)) {
        return .{ .type_decl = try self.parseTypeDeclWithAnnotations(annotations, .struct_decl) };
    }
    if (self.at(.kw_type)) {
        if (self.peekNext().kind == .identifier and self.index + 2 < self.tokens.len and self.tokens[self.index + 2].kind == .equal) {
            return .{ .type_alias_decl = try self.parseTypeAliasDecl() };
        }
        try self.emitUnexpectedToken(
            "removed type declaration syntax",
            self.peek(),
            "`type` no longer starts nominal declarations like `type Name { ... }`",
            "Use `type Name = OtherType` for aliases, or `struct` / `class` for nominal declarations.",
        );
        return error.DiagnosticsEmitted;
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "static")) {
        try self.emitUnexpectedToken(
            "removed static keyword",
            self.peek(),
            "`static` has been removed and is not valid Kira syntax",
            "Use `let` for immutable members and `var` for mutable members.",
        );
        return error.DiagnosticsEmitted;
    }
    if (self.at(.kw_construct)) {
        return .{ .construct_decl = try self.parseConstructDeclWithAnnotations(annotations, false) };
    }
    if (self.at(.kw_extend)) {
        return .{ .extend_decl = try parseExtendDecl(self, annotations) };
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "func")) {
        try self.emitUnexpectedToken(
            "outdated function declaration syntax",
            self.peek(),
            "`func` has been replaced by `function`",
            "Write `function` for function declarations.",
        );
        return error.DiagnosticsEmitted;
    }
    if (self.at(.identifier) and self.peekNext().kind == .bang) {
        const expr = try self.parseExpression();
        if (expr.* == .call and expr.call.is_macro) {
            _ = self.match(.semicolon);
            return .{ .macro_invocation = expr.call };
        }
        try self.emitUnexpectedToken("expected a macro invocation", self.peek(), "a top-level '!' must be a `name!(args)` macro call", "Write `name!(args)` to invoke a function macro.");
        return error.DiagnosticsEmitted;
    }
    if (self.looksLikeConstructFormDecl()) {
        return .{ .construct_form_decl = try self.parseConstructFormDeclWithAnnotations(annotations) };
    }

    const token = self.peek();
    try self.emitUnexpectedToken(
        "expected top-level declaration",
        token,
        "expected a declaration here",
        "Start a declaration with `annotation`, `capability`, `enum`, `type`, `class`, `struct`, `function`, `async function`, `construct`, or a construct-defined declaration form such as `Widget Button(...) { ... }`.",
    );
    return error.DiagnosticsEmitted;
}

pub fn parseTypeAliasDecl(self: *Parser) !syntax.ast.TypeAliasDecl {
    const type_token = try self.expect(.kw_type, "expected 'type'", "type aliases start with 'type'");
    const name_token = try self.expect(.identifier, "expected alias name", "name the alias here");
    _ = try self.expect(.equal, "expected '=' after alias name", "write aliases as `type Name = TargetType`");
    const target = try self.parseTypeExpr();
    const end = try self.consumeStatementTerminator(typeSpan(target.*).end, "expected ';' after type alias", "terminate the alias with ';'");
    return .{
        .name = name_token.lexeme,
        .target = target,
        .span = source_pkg.Span.init(type_token.span.start, end),
    };
}

pub fn parseAnnotationDecl(self: *Parser) !syntax.ast.AnnotationDecl {
    const annotation_token = try self.expect(.kw_annotation, "expected 'annotation'", "annotation declarations start with 'annotation'");
    const name_token = try self.expect(.identifier, "expected annotation name", "name the annotation here");
    _ = try self.expect(.l_brace, "expected '{' to start annotation body", "open the annotation body here");
    var parameters = std.array_list.Managed(syntax.ast.AnnotationParameterDecl).init(self.allocator);
    var targets = std.array_list.Managed(syntax.ast.AnnotationTarget).init(self.allocator);
    var uses = std.array_list.Managed(syntax.ast.QualifiedName).init(self.allocator);
    var generated_members = std.array_list.Managed(syntax.ast.GeneratedMember).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (self.at(.kw_targets)) {
            _ = self.advance();
            _ = try self.expect(.colon, "expected ':' after targets", "declare annotation targets after `targets:`");
            while (true) {
                try targets.append(try self.parseAnnotationTarget());
                if (!self.match(.comma)) break;
            }
            _ = self.match(.semicolon);
            continue;
        }
        if (self.at(.kw_uses)) {
            _ = self.advance();
            while (true) {
                try uses.append(try self.parseQualifiedName("expected capability name after 'uses'"));
                if (!self.match(.comma)) break;
            }
            _ = self.match(.semicolon);
            continue;
        }
        if (self.at(.kw_generated)) {
            try generated_members.appendSlice(try self.parseGeneratedBlock());
            continue;
        }

        const block_token = try self.expect(.identifier, "expected annotation declaration member", "annotation declarations support `targets: ...`, `uses ...`, `generated { ... }`, and `parameters { ... }`");
        if (!std.mem.eql(u8, block_token.lexeme, "parameters")) {
            try self.emitUnexpectedToken(
                "unsupported annotation declaration block",
                block_token,
                "unsupported annotation block here",
                "Use `targets: ...`, `uses CapabilityName`, `generated { ... }`, or `parameters { ... }` inside an annotation.",
            );
            return error.DiagnosticsEmitted;
        }
        _ = try self.expect(.l_brace, "expected '{' after parameters", "open the parameters block here");
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try parameters.append(try self.parseAnnotationParameterDecl());
        }
        _ = try self.expect(.r_brace, "expected '}' to close parameters", "parameters block should end here");
    }

    const close = try self.expect(.r_brace, "expected '}' to close annotation body", "annotation body should end here");
    return .{
        .name = name_token.lexeme,
        .targets = try targets.toOwnedSlice(),
        .uses = try uses.toOwnedSlice(),
        .parameters = try parameters.toOwnedSlice(),
        .generated_members = try generated_members.toOwnedSlice(),
        .span = source_pkg.Span.init(annotation_token.span.start, close.span.end),
    };
}

pub fn parseAnnotationDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.AnnotationDecl {
    const decl = try self.parseAnnotationDecl();
    if (annotations.len == 0) return decl;
    var uses = std.array_list.Managed(syntax.ast.QualifiedName).init(self.allocator);
    try uses.appendSlice(decl.uses);
    for (annotations) |annotation| try uses.append(annotation.name);
    return .{
        .name = decl.name,
        .targets = decl.targets,
        .uses = try uses.toOwnedSlice(),
        .parameters = decl.parameters,
        .generated_members = decl.generated_members,
        .span = source_pkg.Span.init(annotations[0].span.start, decl.span.end),
    };
}

pub fn parseCapabilityDecl(self: *Parser) !syntax.ast.CapabilityDecl {
    const capability_token = try self.expect(.kw_capability, "expected 'capability'", "capability declarations start with 'capability'");
    const name_token = try self.expect(.identifier, "expected capability name", "name the capability here");
    _ = try self.expect(.l_brace, "expected '{' to start capability body", "open the capability body here");
    var generated_members = std.array_list.Managed(syntax.ast.GeneratedMember).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (self.at(.kw_generated)) {
            try generated_members.appendSlice(try self.parseGeneratedBlock());
            continue;
        }
        try self.emitUnexpectedToken(
            "unsupported capability declaration member",
            self.peek(),
            "capabilities currently declare reusable generated members",
            "Use `generated { ... }` inside a capability.",
        );
        return error.DiagnosticsEmitted;
    }

    const close = try self.expect(.r_brace, "expected '}' to close capability body", "capability body should end here");
    return .{
        .name = name_token.lexeme,
        .generated_members = try generated_members.toOwnedSlice(),
        .span = source_pkg.Span.init(capability_token.span.start, close.span.end),
    };
}

pub fn parseEnumDecl(self: *Parser) !syntax.ast.EnumDecl {
    return self.parseEnumDeclWithAnnotations(&.{});
}

pub fn parseEnumDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.EnumDecl {
    const enum_token = try self.expect(.kw_enum, "expected 'enum'", "enum declarations start with 'enum'");
    const name_token = try self.expect(.identifier, "expected enum name", "name the enum here");
    var type_params = std.array_list.Managed([]const u8).init(self.allocator);
    if (self.match(.less)) {
        while (!self.at(.greater) and !self.at(.eof)) {
            const type_param = try self.expect(.identifier, "expected enum type parameter", "write the type parameter name here");
            try type_params.append(type_param.lexeme);
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.greater, "expected '>' after enum type parameters", "close the enum type parameter list here");
    }

    _ = try self.expect(.l_brace, "expected '{' to start enum body", "open the enum body here");
    var variants = std.array_list.Managed(syntax.ast.EnumVariantDecl).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        const variant_name = try self.expect(.identifier, "expected enum variant name", "name the enum variant here");
        var associated_type: ?*syntax.ast.TypeExpr = null;
        var default_value: ?*syntax.ast.Expr = null;
        var end = variant_name.span.end;

        if (self.match(.colon)) {
            associated_type = try self.parseTypeExpr();
            end = typeSpan(associated_type.?.*).end;
        } else if (self.match(.l_paren)) {
            associated_type = try self.parseTypeExpr();
            const close_payload = try self.expect(.r_paren, "expected ')' after enum payload type", "close the enum payload type here");
            end = close_payload.span.end;
        }

        if (self.match(.equal)) {
            default_value = try self.parseExpression();
            end = exprSpan(default_value.?.*).end;
        }

        _ = self.match(.semicolon);
        _ = self.match(.comma);
        try variants.append(.{
            .name = variant_name.lexeme,
            .associated_type = associated_type,
            .default_value = default_value,
            .span = source_pkg.Span.init(variant_name.span.start, end),
        });
    }

    const close = try self.expect(.r_brace, "expected '}' to close enum body", "enum body should end here");
    const start = if (annotations.len != 0) annotations[0].span.start else enum_token.span.start;
    return .{
        .annotations = annotations,
        .name = name_token.lexeme,
        .type_params = try type_params.toOwnedSlice(),
        .variants = try variants.toOwnedSlice(),
        .span = source_pkg.Span.init(start, close.span.end),
    };
}

pub fn parseAnnotationTarget(self: *Parser) !syntax.ast.AnnotationTarget {
    if (self.match(.kw_class)) return .class;
    if (self.match(.kw_struct)) return .struct_decl;
    if (self.match(.kw_function)) return .function;
    if (self.match(.kw_construct)) return .construct;
    if (self.match(.identifier)) {
        const token = self.previous();
        if (std.mem.eql(u8, token.lexeme, "field")) return .field;
    }
    try self.emitUnexpectedToken(
        "expected annotation target",
        self.peek(),
        "target must name a declaration kind",
        "Use targets such as `class`, `struct`, `function`, `construct`, or `field`.",
    );
    return error.DiagnosticsEmitted;
}

pub fn parseGeneratedBlock(self: *Parser) ![]syntax.ast.GeneratedMember {
    const generated_token = try self.expect(.kw_generated, "expected 'generated'", "generated member blocks start with 'generated'");
    _ = try self.expect(.l_brace, "expected '{' to start generated block", "open the generated block here");
    var members = std.array_list.Managed(syntax.ast.GeneratedMember).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        try members.append(try self.parseGeneratedMember());
    }
    _ = try self.expect(.r_brace, "expected '}' to close generated block", "generated block should end here");
    _ = generated_token;
    return members.toOwnedSlice();
}

pub fn parseGeneratedMember(self: *Parser) !syntax.ast.GeneratedMember {
    const start_token = self.peek();
    const overridable = self.match(.kw_overridable);
    if (self.at(.kw_function)) {
        const function_decl = try self.parseFunctionDeclWithAnnotations(&.{}, false, false);
        return .{
            .overridable = overridable,
            .member = .{ .function_decl = function_decl },
            .span = source_pkg.Span.init(start_token.span.start, function_decl.span.end),
        };
    }
    try self.emitUnexpectedToken(
        "expected generated member",
        self.peek(),
        "generated blocks currently support functions",
        "Write `function name(...) { ... }` or `overridable function name(...) { ... }`.",
    );
    return error.DiagnosticsEmitted;
}

pub fn parseAnnotationParameterDecl(self: *Parser) !syntax.ast.AnnotationParameterDecl {
    const name_token = try self.expect(.identifier, "expected annotation parameter name", "name the annotation parameter here");
    _ = try self.expect(.colon, "expected ':' after annotation parameter name", "declare the parameter type here");
    const type_expr = try self.parseTypeExpr();
    var default_value: ?*syntax.ast.Expr = null;
    var end = typeSpan(type_expr.*).end;
    if (self.match(.equal)) {
        default_value = try self.parseExpression();
        end = exprSpan(default_value.?.*).end;
    }
    _ = self.match(.semicolon);
    return .{
        .name = name_token.lexeme,
        .type_expr = type_expr,
        .default_value = default_value,
        .span = source_pkg.Span.init(name_token.span.start, end),
    };
}

pub fn parseAnnotations(self: *Parser) ![]syntax.ast.Annotation {
    var annotations = std.array_list.Managed(syntax.ast.Annotation).init(self.allocator);
    while (self.match(.at_sign)) {
        const at_token = self.previous();
        const name = try self.parseQualifiedName("expected annotation name after '@'");
        if (name.segments.len == 1 and std.mem.eql(u8, name.segments[0].text, "Doc")) {
            try self.emitUnexpectedToken(
                "removed @Doc annotation",
                at_token,
                "`@Doc` has been removed from Kira documentation syntax",
                "Use consecutive `///` documentation comments immediately above the declaration or member.",
            );
            return error.DiagnosticsEmitted;
        }
        var args = std.array_list.Managed(syntax.ast.AnnotationArg).init(self.allocator);
        var block: ?syntax.ast.AnnotationBlock = null;
        var end = name.span.end;

        if (self.match(.l_paren)) {
            while (!self.at(.r_paren) and !self.at(.eof)) {
                const start_token = self.peek();
                var label: ?[]const u8 = null;
                if (self.at(.identifier) and self.peekNext().kind == .colon) {
                    label = self.advance().lexeme;
                    _ = self.advance();
                }
                const value = try self.parseExpression();
                try args.append(.{
                    .label = label,
                    .value = value,
                    .span = source_pkg.Span.init(start_token.span.start, exprSpan(value.*).end),
                });
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_paren, "expected ')' after annotation arguments", "close the annotation arguments here");
            end = close.span.end;
        }

        if (self.at(.l_brace)) {
            block = try self.parseAnnotationBlock();
            end = block.?.span.end;
        }

        try annotations.append(.{
            .name = name,
            .args = try args.toOwnedSlice(),
            .block = block,
            .span = source_pkg.Span.init(at_token.span.start, end),
        });
    }
    return annotations.toOwnedSlice();
}

pub fn parseAnnotationBlock(self: *Parser) !syntax.ast.AnnotationBlock {
    const open = try self.expect(.l_brace, "expected '{' to start annotation block", "open the annotation block here");
    var entries = std.array_list.Managed(syntax.ast.AnnotationBlockEntry).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (self.at(.identifier) and self.peekNext().kind == .colon) {
            const name_token = self.advance();
            _ = self.advance();
            const value = try self.parseExpression();
            try entries.append(.{ .field = .{
                .name = name_token.lexeme,
                .value = value,
                .span = source_pkg.Span.init(name_token.span.start, exprSpan(value.*).end),
            } });
        } else {
            const value = try self.parseExpression();
            try entries.append(.{ .value = .{
                .value = value,
                .span = exprSpan(value.*),
            } });
        }
        _ = self.match(.semicolon);
    }

    const close = try self.expect(.r_brace, "expected '}' to close annotation block", "annotation block should end here");
    return .{
        .entries = try entries.toOwnedSlice(),
        .span = source_pkg.Span.init(open.span.start, close.span.end),
    };
}

pub fn parseFunctionDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation, is_override: bool, is_comptime: bool) !syntax.ast.FunctionDecl {
    return self.parseFunctionDeclWithAnnotationsAsync(annotations, is_override, is_comptime, false);
}

pub fn parseFunctionDeclWithAnnotationsAsync(self: *Parser, annotations: []const syntax.ast.Annotation, is_override: bool, is_comptime: bool, is_async: bool) !syntax.ast.FunctionDecl {
    const function_token = try self.expect(.kw_function, "expected 'function'", "function declarations start with 'function'");
    const name_token = try self.expect(.identifier, "expected function name", "name the function here");
    const params = try self.parseParamList();
    const return_type = try self.parseOptionalReturnType();
    var body: ?syntax.ast.Block = null;
    var end = if (return_type) |ty| typeSpan(ty.*).end else paramsEnd(params, name_token.span.end);
    if (self.match(.semicolon)) {
        end = self.previous().span.end;
    } else {
        body = try self.parseBlock();
        end = body.?.span.end;
    }
    const start = if (annotations.len > 0) annotations[0].span.start else function_token.span.start;
    return .{
        .annotations = annotations,
        .is_override = is_override,
        .is_comptime = is_comptime,
        .is_async = is_async,
        .name = name_token.lexeme,
        .params = params,
        .return_type = return_type,
        .body = body,
        .span = source_pkg.Span.init(start, end),
    };
}

pub fn parseFunctionSignature(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.FunctionSignature {
    const function_token = try self.expect(.kw_function, "expected 'function'", "function signatures start with 'function'");
    const name_token = try self.expect(.identifier, "expected function name", "name the function here");
    const has_params = self.at(.l_paren);
    const params = if (has_params) try self.parseParamList() else try self.allocator.alloc(syntax.ast.ParamDecl, 0);
    const return_type = try self.parseOptionalReturnType();
    const end = if (return_type) |ty| typeSpan(ty.*).end else if (has_params) paramsEnd(params, name_token.span.end) else name_token.span.end;
    return .{
        .annotations = annotations,
        .name = name_token.lexeme,
        .params = params,
        .return_type = return_type,
        .span = source_pkg.Span.init(function_token.span.start, end),
    };
}

pub fn parseOptionalReturnType(self: *Parser) !?*syntax.ast.TypeExpr {
    if (self.match(.colon) or self.match(.arrow)) return self.parseTypeExpr();
    return null;
}

pub fn parseParamList(self: *Parser) ![]syntax.ast.ParamDecl {
    _ = try self.expect(.l_paren, "expected '(' after name", "open the parameter list here");
    var params = std.array_list.Managed(syntax.ast.ParamDecl).init(self.allocator);

    while (!self.at(.r_paren) and !self.at(.eof)) {
        const annotations = try self.parseAnnotations();
        const name_token = try self.expect(.identifier, "expected parameter name", "write the parameter name here");
        var type_expr: ?*syntax.ast.TypeExpr = null;
        var end = name_token.span.end;
        if (std.mem.eql(u8, name_token.lexeme, "_")) {
            const unlabeled_name = try self.expect(.identifier, "expected parameter name after '_'", "write the internal parameter name here");
            end = unlabeled_name.span.end;
            if (self.match(.colon)) {
                type_expr = try self.parseTypeExpr();
                end = typeSpan(type_expr.?.*).end;
            }
            try params.append(.{
                .annotations = annotations,
                .name = unlabeled_name.lexeme,
                .type_expr = type_expr,
                .span = source_pkg.Span.init(name_token.span.start, end),
            });
            if (!self.match(.comma)) break;
            continue;
        }
        if (self.match(.colon)) {
            type_expr = try self.parseTypeExpr();
            end = typeSpan(type_expr.?.*).end;
        }
        try params.append(.{
            .annotations = annotations,
            .name = name_token.lexeme,
            .type_expr = type_expr,
            .span = source_pkg.Span.init(name_token.span.start, end),
        });
        if (!self.match(.comma)) break;
    }

    _ = try self.expect(.r_paren, "expected ')' after parameters", "close the parameter list here");
    return params.toOwnedSlice();
}
