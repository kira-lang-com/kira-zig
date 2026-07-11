const std = @import("std");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;
const paramsEnd = parent.paramsEnd;
const sectionKind = parent.sectionKind;
const rules = @import("parser_decls_rules.zig");

pub const parseLifecycleHook = rules.parseLifecycleHook;
pub const parseNamedRule = rules.parseNamedRule;

pub fn parseTypeDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation, kind: syntax.ast.TypeKind) !syntax.ast.TypeDecl {
    const decl_token = if (kind == .class)
        try self.expect(.kw_class, "expected 'class'", "class declarations start with 'class'")
    else
        try self.expect(.kw_struct, "expected 'struct'", "struct declarations start with 'struct'");
    const name_token = try self.expect(.identifier, "expected declaration name", "name the declaration here");
    var parents = std.array_list.Managed(syntax.ast.QualifiedName).init(self.allocator);
    if (self.match(.kw_extends)) {
        if (kind == .struct_decl) {
            try self.emitUnexpectedToken(
                "struct cannot inherit",
                self.previous(),
                "`extends` is only valid on classes",
                "Use `class` when inheritance is intended, or remove the `extends` clause for a value-oriented struct.",
            );
            return error.DiagnosticsEmitted;
        }
        while (true) {
            try parents.append(try self.parseQualifiedName("expected parent type name after 'extends'"));
            if (!self.match(.comma)) break;
        }
    }
    _ = try self.expect(.l_brace, "expected '{' to start declaration body", "open the declaration body here");
    var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        self.consumeDocComments();
        const annotations_inner = try self.parseAnnotations();
        try members.append(try self.parseBodyMember(annotations_inner));
    }

    const close = try self.expect(.r_brace, "expected '}' to close declaration body", "declaration body should end here");
    const start = if (annotations.len > 0) annotations[0].span.start else decl_token.span.start;
    return .{
        .kind = kind,
        .annotations = annotations,
        .name = name_token.lexeme,
        .parents = try parents.toOwnedSlice(),
        .members = try members.toOwnedSlice(),
        .span = source_pkg.Span.init(start, close.span.end),
    };
}

pub fn parseConstructDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation, is_comptime: bool) !syntax.ast.ConstructDecl {
    const construct_token = try self.expect(.kw_construct, "expected 'construct'", "construct declarations start with 'construct'");
    const name_token = try self.expect(.identifier, "expected construct name", "name the construct here");
    var parents = std.array_list.Managed(syntax.ast.QualifiedName).init(self.allocator);
    if (self.match(.kw_extends)) {
        while (true) {
            try parents.append(try self.parseQualifiedName("expected parent construct name after 'extends'"));
            if (!self.match(.comma)) break;
        }
    }
    _ = try self.expect(.l_brace, "expected '{' to start construct body", "open the construct body here");
    var sections = std.array_list.Managed(syntax.ast.ConstructSection).init(self.allocator);
    var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        self.consumeDocComments();
        if (self.at(.at_sign) or self.at(.kw_let) or self.at(.kw_var) or self.at(.kw_function) or self.at(.kw_override)) {
            const member_annotations = try self.parseAnnotations();
            try members.append(try parseConstructMember(self, member_annotations));
        } else {
            try sections.append(try self.parseConstructSection());
        }
    }

    const close = try self.expect(.r_brace, "expected '}' to close construct body", "construct body should end here");
    const start = if (annotations.len > 0) annotations[0].span.start else construct_token.span.start;
    return .{
        .annotations = annotations,
        .is_comptime = is_comptime,
        .name = name_token.lexeme,
        .parents = try parents.toOwnedSlice(),
        .sections = try sections.toOwnedSlice(),
        .members = try members.toOwnedSlice(),
        .span = source_pkg.Span.init(start, close.span.end),
    };
}

fn parseConstructMember(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.BodyMember {
    const is_override = self.match(.kw_override);
    if (self.at(.kw_let) or self.at(.kw_var)) {
        return .{ .field_decl = try self.parseFieldDecl(annotations, is_override) };
    }
    if (self.at(.kw_function)) {
        return .{ .function_decl = try parseConstructMemberFunction(self, annotations, is_override) };
    }
    try self.emitUnexpectedToken(
        "expected construct member",
        self.peek(),
        "construct members are fields or functions",
        "Use `let`/`var` for fields (including computed `let node: Node { body.node }`) or `function` for behaviors.",
    );
    return error.DiagnosticsEmitted;
}

fn parseConstructMemberFunction(self: *Parser, annotations: []const syntax.ast.Annotation, is_override: bool) !syntax.ast.FunctionDecl {
    const function_token = try self.expect(.kw_function, "expected 'function'", "function declarations start with 'function'");
    const name_token = try self.expect(.identifier, "expected function name", "name the function here");
    const params = try self.parseParamList();
    const return_type = try self.parseOptionalReturnType();
    var body: ?syntax.ast.Block = null;
    var end = if (return_type) |ty| typeSpan(ty.*).end else paramsEnd(params, name_token.span.end);
    if (self.at(.l_brace)) {
        body = try self.parseBlock();
        end = body.?.span.end;
    } else {
        end = try self.consumeFieldTerminator(end);
    }
    const start = if (annotations.len > 0) annotations[0].span.start else function_token.span.start;
    return .{
        .annotations = annotations,
        .is_override = is_override,
        .name = name_token.lexeme,
        .params = params,
        .return_type = return_type,
        .body = body,
        .span = source_pkg.Span.init(start, end),
    };
}

pub fn parseConstructSection(self: *Parser) !syntax.ast.ConstructSection {
    const name_token = try self.expect(.identifier, "expected construct section name", "name the section here");
    if (self.match(.colon)) {
        const type_expr = try self.parseTypeExpr();
        const end = try self.consumeStatementTerminator(typeSpan(type_expr.*).end, "expected ';' after construct section type", "terminate the typed construct section with ';'");
        const qualified = try self.makeSingleSegmentName(name_token);
        const entries = try self.allocator.alloc(syntax.ast.ConstructSectionEntry, 1);
        entries[0] = .{ .named_rule = .{
            .name = qualified,
            .args = &.{},
            .type_expr = type_expr,
            .value = null,
            .block = null,
            .span = source_pkg.Span.init(name_token.span.start, end),
        } };
        return .{
            .name = name_token.lexeme,
            .kind = sectionKind(name_token.lexeme),
            .entries = entries,
            .span = source_pkg.Span.init(name_token.span.start, end),
        };
    }
    if (std.mem.eql(u8, name_token.lexeme, "content")) {
        return self.parseConstructContentSection(name_token);
    }
    _ = try self.expect(.l_brace, "expected '{' after construct section name", "open the construct section here");
    var entries = std.array_list.Managed(syntax.ast.ConstructSectionEntry).init(self.allocator);

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (sectionKind(name_token.lexeme) == .modifiers and self.at(.identifier) and self.peekNext().kind == .l_brace) {
            const subgroup = self.advance();
            _ = try self.expect(.l_brace, "expected '{' after wrapper group", "open the wrapper group here");
            while (!self.at(.r_brace) and !self.at(.eof)) {
                if (self.at(.at_sign)) {
                    try entries.append(.{ .annotation_spec = try self.parseAnnotationSpec() });
                    continue;
                }
                try self.emitUnexpectedToken(
                    "expected wrapper annotation",
                    self.peek(),
                    "wrapper groups contain annotation specs",
                    "Use entries such as `@State;` inside `member { ... }` or `parameter { ... }`.",
                );
                return error.DiagnosticsEmitted;
            }
            _ = try self.expect(.r_brace, "expected '}' to close wrapper group", "wrapper group should end here");
            _ = subgroup;
            continue;
        }
        if (self.at(.at_sign) and sectionKind(name_token.lexeme) == .annotations) {
            try entries.append(.{ .annotation_spec = try self.parseAnnotationSpec() });
            continue;
        }
        if (self.at(.kw_let)) {
            try entries.append(.{ .field_decl = try self.parseFieldDecl(&.{}, false) });
            continue;
        }
        const entry_annotations = try self.parseAnnotations();
        if (self.at(.kw_function)) {
            const signature = try self.parseFunctionSignature(entry_annotations);
            _ = self.match(.semicolon);
            try entries.append(.{ .function_signature = signature });
            continue;
        }
        if (entry_annotations.len != 0) {
            try self.emitUnexpectedToken(
                "expected annotated construct section entry",
                self.peek(),
                "annotations in construct sections must apply to a function signature",
                "Write `@Required function name(...) -> Type` or remove the annotation.",
            );
            return error.DiagnosticsEmitted;
        }
        if (self.isLifecycleHookStart()) {
            try entries.append(.{ .lifecycle_hook = try self.parseLifecycleHook() });
            continue;
        }
        if (sectionKind(name_token.lexeme) == .properties) {
            try entries.append(.{ .property_schema = try self.parsePropertySchemaField() });
            continue;
        }
        if (self.at(.identifier)) {
            try entries.append(.{ .named_rule = try self.parseNamedRule() });
            continue;
        }

        try self.emitUnexpectedToken(
            "expected construct section entry",
            self.peek(),
            "expected a construct section entry here",
            "Use an annotation spec, field, lifecycle hook, function signature, or named rule inside this section.",
        );
        return error.DiagnosticsEmitted;
    }

    const close = try self.expect(.r_brace, "expected '}' to close construct section", "construct section should end here");
    return .{
        .name = name_token.lexeme,
        .kind = sectionKind(name_token.lexeme),
        .entries = try entries.toOwnedSlice(),
        .span = source_pkg.Span.init(name_token.span.start, close.span.end),
    };
}

pub fn parseConstructContentSection(self: *Parser, name_token: syntax.Token) !syntax.ast.ConstructSection {
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "sealed")) {
        return finishContentDirectiveSection(self, name_token, .sealed);
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "passthrough")) {
        return finishContentDirectiveSection(self, name_token, .passthrough);
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "refine")) {
        const directive_token = self.advance();
        _ = try self.expect(.l_brace, "expected '{' after 'refine'", "open the refinement block here");
        var entries = std.array_list.Managed(syntax.ast.ConstructSectionEntry).init(self.allocator);
        try entries.append(.{ .content_directive = .{ .mode = .refine, .span = directive_token.span } });
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try entries.append(.{ .content_channel = try self.parseContentChannel() });
        }
        const close = try self.expect(.r_brace, "expected '}' to close refinement block", "refinement block should end here");
        return makeContentSection(self, name_token, try entries.toOwnedSlice(), close.span.end);
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "project")) {
        const directive_token = self.advance();
        _ = try self.expect(.l_brace, "expected '{' after 'project'", "open the projection block here");
        var entries = std.array_list.Managed(syntax.ast.ConstructSectionEntry).init(self.allocator);
        try entries.append(.{ .content_directive = .{ .mode = .project, .span = directive_token.span } });
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try entries.append(.{ .content_projection = try self.parseContentProjection() });
        }
        const close = try self.expect(.r_brace, "expected '}' to close projection block", "projection block should end here");
        return makeContentSection(self, name_token, try entries.toOwnedSlice(), close.span.end);
    }

    _ = try self.expect(.l_brace, "expected '{' to start content channels", "open the content channel block here");
    var entries = std.array_list.Managed(syntax.ast.ConstructSectionEntry).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        try entries.append(.{ .content_channel = try self.parseContentChannel() });
    }
    const close = try self.expect(.r_brace, "expected '}' to close content channels", "content channel block should end here");
    return makeContentSection(self, name_token, try entries.toOwnedSlice(), close.span.end);
}

fn finishContentDirectiveSection(self: *Parser, name_token: syntax.Token, mode: syntax.ast.ContentDirectiveMode) !syntax.ast.ConstructSection {
    const directive_token = self.advance();
    _ = self.match(.semicolon);
    const entries = try self.allocator.alloc(syntax.ast.ConstructSectionEntry, 1);
    entries[0] = .{ .content_directive = .{ .mode = mode, .span = directive_token.span } };
    return makeContentSection(self, name_token, entries, directive_token.span.end);
}

fn makeContentSection(self: *Parser, name_token: syntax.Token, entries: []syntax.ast.ConstructSectionEntry, end: usize) syntax.ast.ConstructSection {
    _ = self;
    return .{
        .name = name_token.lexeme,
        .kind = .custom,
        .entries = entries,
        .span = source_pkg.Span.init(name_token.span.start, end),
    };
}

pub fn parseContentProjection(self: *Parser) !syntax.ast.ContentProjection {
    const local_token = try self.expect(.identifier, "expected projection source name", "name the local declaration section to project");
    _ = try self.expect(.kw_as, "expected 'as' in projection", "write projections as `local as Parent.channel`");
    const target = try self.parseQualifiedName("expected `Parent.channel` projection target");
    if (target.segments.len < 2) {
        try self.emitUnexpectedToken(
            "incomplete projection target",
            self.previous(),
            "projection targets are written `Parent.channel`",
            "Name both the parent construct and its channel, for example `WebElement.content`.",
        );
        return error.DiagnosticsEmitted;
    }
    _ = self.match(.semicolon);
    const channel_segment = target.segments[target.segments.len - 1];
    const construct_segments = target.segments[0 .. target.segments.len - 1];
    return .{
        .local = local_token.lexeme,
        .target_construct = .{ .segments = construct_segments, .span = target.span },
        .target_channel = channel_segment.text,
        .span = source_pkg.Span.init(local_token.span.start, channel_segment.span.end),
    };
}

pub fn parseContentChannel(self: *Parser) !syntax.ast.ContentChannelSchema {
    const name_token = try self.expect(.identifier, "expected content channel name", "name the content channel here");
    _ = try self.expect(.l_brace, "expected '{' after channel name", "open the channel rule block here");
    var accepts: ?syntax.ast.QualifiedName = null;
    var count: ?syntax.ast.CountRange = null;
    while (!self.at(.r_brace) and !self.at(.eof)) {
        const rule_token = try self.expect(.identifier, "expected 'accepts' or 'count'", "channel rules are `accepts Type` and `count min..max`");
        if (std.mem.eql(u8, rule_token.lexeme, "accepts")) {
            accepts = try self.parseQualifiedName("expected accepted type name after 'accepts'");
            _ = self.match(.semicolon);
        } else if (std.mem.eql(u8, rule_token.lexeme, "count")) {
            count = try self.parseCountRange();
            _ = self.match(.semicolon);
        } else {
            try self.emitUnexpectedToken(
                "unknown content channel rule",
                rule_token,
                "expected 'accepts' or 'count'",
                "Channel rules are `accepts Type` and `count min..max`.",
            );
            return error.DiagnosticsEmitted;
        }
    }
    const close = try self.expect(.r_brace, "expected '}' to close channel rules", "channel rule block should end here");
    return .{
        .name = name_token.lexeme,
        .accepts = accepts,
        .count = count,
        .span = source_pkg.Span.init(name_token.span.start, close.span.end),
    };
}

pub fn parseCountRange(self: *Parser) !syntax.ast.CountRange {
    const min_token = try self.expect(.integer, "expected lower bound", "count ranges start with an integer lower bound");
    const min = std.fmt.parseInt(u32, min_token.lexeme, 10) catch 0;
    _ = try self.expect(.dot_dot, "expected '..' in count range", "write count ranges as `min..max` or `min..`");
    var max: ?u32 = null;
    var end = self.previous().span.end;
    if (self.at(.integer)) {
        const max_token = self.advance();
        max = std.fmt.parseInt(u32, max_token.lexeme, 10) catch null;
        end = max_token.span.end;
    }
    return .{ .min = min, .max = max, .span = source_pkg.Span.init(min_token.span.start, end) };
}

pub fn parsePropertySchemaField(self: *Parser) !syntax.ast.PropertySchemaField {
    const start = self.peek().span.start;
    var required = false;
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "required") and self.peekNext().kind == .identifier) {
        _ = self.advance();
        required = true;
    }
    const name_token = try self.expect(.identifier, "expected property name", "name the property here");
    _ = try self.expect(.colon, "expected ':' after property name", "declare the property type with `name: Type`");
    const type_expr = try self.parseTypeExpr();
    var end = typeSpan(type_expr.*).end;
    var default_value: ?*syntax.ast.Expr = null;
    if (self.match(.equal)) {
        default_value = try self.parseExpression();
        end = exprSpan(default_value.?.*).end;
    }
    _ = self.match(.semicolon);
    return .{
        .required = required,
        .name = name_token.lexeme,
        .type_expr = type_expr,
        .default_value = default_value,
        .span = source_pkg.Span.init(start, end),
    };
}

pub fn parseDeclPropertiesSection(self: *Parser) !syntax.ast.DeclPropertiesSection {
    const properties_token = try self.expect(.identifier, "expected 'properties'", "declaration property sections start with 'properties'");
    _ = try self.expect(.l_brace, "expected '{' after 'properties'", "open the properties section here");
    var entries = std.array_list.Managed(syntax.ast.DeclPropertyEntry).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        const name_token = try self.expect(.identifier, "expected property name", "name the property here");
        _ = try self.expect(.colon, "expected ':' after property name", "assign the property with `name: value`");
        const value = try self.parseExpression();
        const end = exprSpan(value.*).end;
        _ = self.match(.semicolon);
        try entries.append(.{
            .name = name_token.lexeme,
            .value = value,
            .span = source_pkg.Span.init(name_token.span.start, end),
        });
    }
    const close = try self.expect(.r_brace, "expected '}' to close properties section", "properties section should end here");
    return .{
        .entries = try entries.toOwnedSlice(),
        .span = source_pkg.Span.init(properties_token.span.start, close.span.end),
    };
}

pub fn parseAnnotationSpec(self: *Parser) !syntax.ast.AnnotationSpec {
    const at_token = try self.expect(.at_sign, "expected '@' in annotation spec", "annotation specs start with '@'");
    const name = try self.parseQualifiedName("expected annotation name in construct section");
    var type_expr: ?*syntax.ast.TypeExpr = null;
    var default_value: ?*syntax.ast.Expr = null;
    var end = name.span.end;
    if (self.match(.colon)) {
        type_expr = try self.parseTypeExpr();
        end = typeSpan(type_expr.?.*).end;
    }
    if (self.match(.equal)) {
        default_value = try self.parseExpression();
        end = exprSpan(default_value.?.*).end;
    }
    _ = try self.expect(.semicolon, "expected ';' after annotation spec", "terminate the annotation spec with ';'");
    return .{
        .name = name,
        .type_expr = type_expr,
        .default_value = default_value,
        .span = source_pkg.Span.init(at_token.span.start, end),
    };
}

pub fn parseConstructFormDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ConstructFormDecl {
    const construct_name = try self.parseQualifiedName("expected construct name");
    const name_token = try self.expect(.identifier, "expected declaration name after construct name", "name the construct-defined declaration here");
    const params = if (self.at(.l_paren)) try self.parseParamList() else try self.allocator.alloc(syntax.ast.ParamDecl, 0);
    const body = try self.parseConstructBody();
    const start = if (annotations.len > 0) annotations[0].span.start else construct_name.span.start;
    return .{
        .annotations = annotations,
        .construct_name = construct_name,
        .name = name_token.lexeme,
        .params = params,
        .body = body,
        .span = source_pkg.Span.init(start, body.span.end),
    };
}

pub fn parseExtendDecl(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ExtendDecl {
    const extend_token = try self.expect(.kw_extend, "expected 'extend'", "extension declarations start with 'extend'");
    const construct_name = try self.parseQualifiedName("expected the construct name to extend");
    _ = try self.expect(.l_brace, "expected '{' to start extension body", "open the extension body here");
    var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        self.consumeDocComments();
        const member_annotations = try self.parseAnnotations();
        try members.append(try parseConstructMember(self, member_annotations));
    }
    const close = try self.expect(.r_brace, "expected '}' to close extension body", "extension body should end here");
    const start = if (annotations.len > 0) annotations[0].span.start else extend_token.span.start;
    return .{
        .annotations = annotations,
        .construct_name = construct_name,
        .members = try members.toOwnedSlice(),
        .span = source_pkg.Span.init(start, close.span.end),
    };
}

pub fn parseConstructBody(self: *Parser) !syntax.ast.ConstructBody {
    const open = try self.expect(.l_brace, "expected '{' to start declaration body", "open the declaration body here");
    var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        self.consumeDocComments();
        const annotations = try self.parseAnnotations();
        try members.append(try self.parseBodyMember(annotations));
    }
    const close = try self.expect(.r_brace, "expected '}' to close declaration body", "declaration body should end here");
    return .{
        .members = try members.toOwnedSlice(),
        .span = source_pkg.Span.init(open.span.start, close.span.end),
    };
}

pub fn parseBodyMember(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.BodyMember {
    const is_override = self.match(.kw_override);
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "static")) {
        try self.emitUnexpectedToken(
            "removed static keyword",
            self.peek(),
            "`static` has been removed and is not valid Kira syntax",
            "Use `let` for immutable members and `var` for mutable members.",
        );
        return error.DiagnosticsEmitted;
    }
    if (self.at(.kw_let) or self.at(.kw_var)) return .{ .field_decl = try self.parseFieldDecl(annotations, is_override) };
    if (self.at(.kw_function)) return .{ .function_decl = try self.parseFunctionDeclWithAnnotations(annotations, is_override, false) };
    if (is_override) {
        try self.emitUnexpectedToken(
            "expected override member declaration",
            self.peek(),
            "override must apply to a field or function declaration",
            "Use `override function ...`, `override let ...`, or `override var ...` inside a type body.",
        );
        return error.DiagnosticsEmitted;
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "content") and self.peekNext().kind == .l_brace) {
        return .{ .content_section = try self.parseContentSection(annotations) };
    }
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "properties") and self.peekNext().kind == .l_brace) {
        return .{ .properties_section = try self.parseDeclPropertiesSection() };
    }
    if (self.isLifecycleHookStart()) return .{ .lifecycle_hook = try self.parseLifecycleHook() };
    return .{ .named_rule = try self.parseNamedRule() };
}

pub fn parseFieldDecl(self: *Parser, annotations: []const syntax.ast.Annotation, is_override: bool) !syntax.ast.FieldDecl {
    const storage_token = if (self.at(.kw_let) or self.at(.kw_var))
        self.advance()
    else
        try self.expect(.kw_let, "expected field declaration", "field declarations use 'let' or 'var'");
    const name_token = try self.expect(.identifier, "expected field name", "name the field here");
    var type_expr: ?*syntax.ast.TypeExpr = null;
    var value: ?*syntax.ast.Expr = null;
    var body: ?syntax.ast.Block = null;
    var end = name_token.span.end;
    if (self.match(.colon)) {
        type_expr = try self.parseTypeExpr();
        end = typeSpan(type_expr.?.*).end;
    }
    if (self.at(.l_brace)) {
        body = try self.parseBlock();
        end = body.?.span.end;
    } else {
        if (self.match(.equal)) {
            value = try self.parseExpression();
            end = exprSpan(value.?.*).end;
        }
        end = try self.consumeFieldTerminator(end);
    }
    return .{
        .annotations = annotations,
        .is_override = is_override,
        .storage = switch (storage_token.kind) {
            .kw_let => .immutable,
            .kw_var => .mutable,
            else => unreachable,
        },
        .name = name_token.lexeme,
        .type_expr = type_expr,
        .value = value,
        .body = body,
        .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else storage_token.span.start, end),
    };
}

pub fn parseContentSection(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ContentSection {
    const content_token = try self.expect(.identifier, "expected 'content'", "content sections start with 'content'");
    const builder = try self.parseBuilderBlock();
    return .{
        .annotations = annotations,
        .builder = builder,
        .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else content_token.span.start, builder.span.end),
    };
}
