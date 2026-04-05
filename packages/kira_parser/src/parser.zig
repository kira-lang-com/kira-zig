const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");

pub fn parse(allocator: std.mem.Allocator, tokens: []const syntax.Token, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) !syntax.ast.Program {
    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .diagnostics = out_diagnostics,
    };
    return parser.parseProgram();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const syntax.Token,
    index: usize = 0,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),

    fn parseProgram(self: *Parser) !syntax.ast.Program {
        var imports = std.array_list.Managed(syntax.ast.ImportDecl).init(self.allocator);
        var decls = std.array_list.Managed(syntax.ast.Decl).init(self.allocator);
        var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(self.allocator);
        var had_errors = false;

        while (!self.at(.eof)) {
            if (self.at(.kw_import)) {
                const import_decl = self.parseImportDecl() catch |err| switch (err) {
                    error.DiagnosticsEmitted => blk: {
                        had_errors = true;
                        self.recoverToTopLevel();
                        break :blk null;
                    },
                    else => return err,
                };
                if (import_decl) |value| try imports.append(value);
                continue;
            }

            const annotations = self.parseAnnotations() catch |err| switch (err) {
                error.DiagnosticsEmitted => blk: {
                    had_errors = true;
                    self.recoverToTopLevel();
                    break :blk &.{};
                },
                else => return err,
            };

            const decl = self.parseTopLevelDecl(annotations) catch |err| switch (err) {
                error.DiagnosticsEmitted => blk: {
                    had_errors = true;
                    self.recoverToTopLevel();
                    break :blk null;
                },
                else => return err,
            };

            if (decl) |value| {
                switch (value) {
                    .function_decl => |function_decl| try functions.append(function_decl),
                    else => {},
                }
                try decls.append(value);
            }
        }

        if (had_errors) return error.DiagnosticsEmitted;
        return .{
            .imports = try imports.toOwnedSlice(),
            .decls = try decls.toOwnedSlice(),
            .functions = try functions.toOwnedSlice(),
        };
    }

    fn parseImportDecl(self: *Parser) !?syntax.ast.ImportDecl {
        const import_token = try self.expect(.kw_import, "expected 'import'", "imports start with 'import'");
        const module_name = try self.parseQualifiedName("expected module name after 'import'");
        var alias: ?[]const u8 = null;
        var end = module_name.span.end;
        if (self.match(.kw_as)) {
            const alias_token = try self.expect(.identifier, "expected alias after 'as'", "write the import alias here");
            alias = alias_token.lexeme;
            end = alias_token.span.end;
        }
        return .{
            .module_name = module_name,
            .alias = alias,
            .span = source_pkg.Span.init(import_token.span.start, end),
        };
    }

    fn parseTopLevelDecl(self: *Parser, annotations: []const syntax.ast.Annotation) !?syntax.ast.Decl {
        if (self.at(.kw_function)) {
            return .{ .function_decl = try self.parseFunctionDeclWithAnnotations(annotations) };
        }
        if (self.at(.kw_type)) {
            return .{ .type_decl = try self.parseTypeDeclWithAnnotations(annotations) };
        }
        if (self.at(.kw_construct)) {
            return .{ .construct_decl = try self.parseConstructDeclWithAnnotations(annotations) };
        }
        if (self.looksLikeConstructFormDecl()) {
            return .{ .construct_form_decl = try self.parseConstructFormDeclWithAnnotations(annotations) };
        }

        const token = self.peek();
        try self.emitUnexpectedToken(
            "expected top-level declaration",
            token,
            "expected a declaration here",
            "Start a declaration with `function`, `type`, `construct`, or a construct-defined declaration form such as `Widget Button(...) { ... }`.",
        );
        return error.DiagnosticsEmitted;
    }

    fn parseAnnotations(self: *Parser) ![]syntax.ast.Annotation {
        var annotations = std.array_list.Managed(syntax.ast.Annotation).init(self.allocator);
        while (self.match(.at_sign)) {
            const at_token = self.previous();
            const name = try self.parseQualifiedName("expected annotation name after '@'");
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

    fn parseAnnotationBlock(self: *Parser) !syntax.ast.AnnotationBlock {
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

    fn parseFunctionDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.FunctionDecl {
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
            .name = name_token.lexeme,
            .params = params,
            .return_type = return_type,
            .body = body,
            .span = source_pkg.Span.init(start, end),
        };
    }

    fn parseFunctionSignature(self: *Parser) !syntax.ast.FunctionSignature {
        const function_token = try self.expect(.kw_function, "expected 'function'", "function signatures start with 'function'");
        const name_token = try self.expect(.identifier, "expected function name", "name the function here");
        const params = try self.parseParamList();
        const return_type = try self.parseOptionalReturnType();
        const end = if (return_type) |ty| typeSpan(ty.*).end else paramsEnd(params, name_token.span.end);
        return .{
            .name = name_token.lexeme,
            .params = params,
            .return_type = return_type,
            .span = source_pkg.Span.init(function_token.span.start, end),
        };
    }

    fn parseOptionalReturnType(self: *Parser) !?*syntax.ast.TypeExpr {
        if (self.match(.colon) or self.match(.arrow)) return self.parseTypeExpr();
        return null;
    }

    fn parseParamList(self: *Parser) ![]syntax.ast.ParamDecl {
        _ = try self.expect(.l_paren, "expected '(' after name", "open the parameter list here");
        var params = std.array_list.Managed(syntax.ast.ParamDecl).init(self.allocator);

        while (!self.at(.r_paren) and !self.at(.eof)) {
            const annotations = try self.parseAnnotations();
            const name_token = try self.expect(.identifier, "expected parameter name", "write the parameter name here");
            var type_expr: ?*syntax.ast.TypeExpr = null;
            var end = name_token.span.end;
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

    fn parseTypeDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.TypeDecl {
        const type_token = try self.expect(.kw_type, "expected 'type'", "type declarations start with 'type'");
        const name_token = try self.expect(.identifier, "expected type name", "name the type here");
        _ = try self.expect(.l_brace, "expected '{' to start type body", "open the type body here");
        var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);

        while (!self.at(.r_brace) and !self.at(.eof)) {
            const annotations_inner = try self.parseAnnotations();
            try members.append(try self.parseBodyMember(annotations_inner));
        }

        const close = try self.expect(.r_brace, "expected '}' to close type body", "type body should end here");
        const start = if (annotations.len > 0) annotations[0].span.start else type_token.span.start;
        return .{
            .annotations = annotations,
            .name = name_token.lexeme,
            .members = try members.toOwnedSlice(),
            .span = source_pkg.Span.init(start, close.span.end),
        };
    }

    fn parseConstructDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ConstructDecl {
        const construct_token = try self.expect(.kw_construct, "expected 'construct'", "construct declarations start with 'construct'");
        const name_token = try self.expect(.identifier, "expected construct name", "name the construct here");
        _ = try self.expect(.l_brace, "expected '{' to start construct body", "open the construct body here");
        var sections = std.array_list.Managed(syntax.ast.ConstructSection).init(self.allocator);

        while (!self.at(.r_brace) and !self.at(.eof)) {
            try sections.append(try self.parseConstructSection());
        }

        const close = try self.expect(.r_brace, "expected '}' to close construct body", "construct body should end here");
        const start = if (annotations.len > 0) annotations[0].span.start else construct_token.span.start;
        return .{
            .annotations = annotations,
            .name = name_token.lexeme,
            .sections = try sections.toOwnedSlice(),
            .span = source_pkg.Span.init(start, close.span.end),
        };
    }

    fn parseConstructSection(self: *Parser) !syntax.ast.ConstructSection {
        const name_token = try self.expect(.identifier, "expected construct section name", "name the section here");
        _ = try self.expect(.l_brace, "expected '{' after construct section name", "open the construct section here");
        var entries = std.array_list.Managed(syntax.ast.ConstructSectionEntry).init(self.allocator);

        while (!self.at(.r_brace) and !self.at(.eof)) {
            if (self.at(.at_sign) and sectionKind(name_token.lexeme) == .annotations) {
                try entries.append(.{ .annotation_spec = try self.parseAnnotationSpec() });
                continue;
            }
            if (self.at(.kw_let)) {
                try entries.append(.{ .field_decl = try self.parseFieldDecl(&.{}) });
                continue;
            }
            if (self.at(.kw_function)) {
                const signature = try self.parseFunctionSignature();
                _ = try self.expect(.semicolon, "expected ';' after construct function signature", "terminate the construct function signature with ';'");
                try entries.append(.{ .function_signature = signature });
                continue;
            }
            if (self.isLifecycleHookStart()) {
                try entries.append(.{ .lifecycle_hook = try self.parseLifecycleHook() });
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

    fn parseAnnotationSpec(self: *Parser) !syntax.ast.AnnotationSpec {
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

    fn parseConstructFormDeclWithAnnotations(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ConstructFormDecl {
        const construct_name = try self.parseQualifiedName("expected construct name");
        const name_token = try self.expect(.identifier, "expected declaration name after construct name", "name the construct-defined declaration here");
        const params = try self.parseParamList();
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

    fn parseConstructBody(self: *Parser) !syntax.ast.ConstructBody {
        const open = try self.expect(.l_brace, "expected '{' to start declaration body", "open the declaration body here");
        var members = std.array_list.Managed(syntax.ast.BodyMember).init(self.allocator);
        while (!self.at(.r_brace) and !self.at(.eof)) {
            const annotations = try self.parseAnnotations();
            try members.append(try self.parseBodyMember(annotations));
        }
        const close = try self.expect(.r_brace, "expected '}' to close declaration body", "declaration body should end here");
        return .{
            .members = try members.toOwnedSlice(),
            .span = source_pkg.Span.init(open.span.start, close.span.end),
        };
    }

    fn parseBodyMember(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.BodyMember {
        if (self.at(.kw_let) or self.at(.kw_var) or self.at(.kw_static)) return .{ .field_decl = try self.parseFieldDecl(annotations) };
        if (self.at(.kw_function)) return .{ .function_decl = try self.parseFunctionDeclWithAnnotations(annotations) };
        if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "content") and self.peekNext().kind == .l_brace) {
            return .{ .content_section = try self.parseContentSection(annotations) };
        }
        if (self.isLifecycleHookStart()) return .{ .lifecycle_hook = try self.parseLifecycleHook() };
        return .{ .named_rule = try self.parseNamedRule() };
    }

    fn parseFieldDecl(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.FieldDecl {
        const static_token = if (self.match(.kw_static)) self.previous() else null;
        const is_static = static_token != null;
        const storage_token = if (self.at(.kw_let) or self.at(.kw_var))
            self.advance()
        else
            try self.expect(.kw_let, "expected field declaration", "field declarations use 'let' or 'var'");
        const name_token = try self.expect(.identifier, "expected field name", "name the field here");
        var type_expr: ?*syntax.ast.TypeExpr = null;
        var value: ?*syntax.ast.Expr = null;
        var end = name_token.span.end;
        if (self.match(.colon)) {
            type_expr = try self.parseTypeExpr();
            end = typeSpan(type_expr.?.*).end;
        }
        if (self.match(.equal)) {
            value = try self.parseExpression();
            end = exprSpan(value.?.*).end;
        }
        end = try self.consumeFieldTerminator(end);
        return .{
            .annotations = annotations,
            .is_static = is_static,
            .storage = switch (storage_token.kind) {
                .kw_let => .immutable,
                .kw_var => .mutable,
                else => unreachable,
            },
            .name = name_token.lexeme,
            .type_expr = type_expr,
            .value = value,
            .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else if (static_token) |token| token.span.start else storage_token.span.start, end),
        };
    }

    fn parseContentSection(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.ContentSection {
        const content_token = try self.expect(.identifier, "expected 'content'", "content sections start with 'content'");
        const builder = try self.parseBuilderBlock();
        return .{
            .annotations = annotations,
            .builder = builder,
            .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else content_token.span.start, builder.span.end),
        };
    }

    fn parseLifecycleHook(self: *Parser) !syntax.ast.LifecycleHook {
        const name_token = try self.expect(.identifier, "expected lifecycle hook name", "write the lifecycle hook name here");
        _ = try self.expect(.l_paren, "expected '(' after lifecycle hook name", "open the lifecycle hook arguments here");
        var args = std.array_list.Managed(syntax.ast.RuleArg).init(self.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            const start_token = self.peek();
            var label: ?[]const u8 = null;
            var value: ?*syntax.ast.Expr = null;
            if (self.at(.identifier) and self.peekNext().kind == .colon) {
                label = self.advance().lexeme;
                _ = self.advance();
                value = try self.parseExpression();
            } else if (!self.at(.r_paren)) {
                value = try self.parseExpression();
            }
            try args.append(.{
                .label = label,
                .value = value,
                .span = source_pkg.Span.init(start_token.span.start, if (value) |expr| exprSpan(expr.*).end else start_token.span.end),
            });
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.r_paren, "expected ')' after lifecycle hook arguments", "close the lifecycle hook arguments here");
        const body = try self.parseBlock();
        return .{
            .name = name_token.lexeme,
            .args = try args.toOwnedSlice(),
            .body = body,
            .span = source_pkg.Span.init(name_token.span.start, body.span.end),
        };
    }

    fn parseNamedRule(self: *Parser) !syntax.ast.NamedRule {
        const name = try self.parseQualifiedName("expected rule name");
        var args = std.array_list.Managed(syntax.ast.RuleArg).init(self.allocator);
        var type_expr: ?*syntax.ast.TypeExpr = null;
        var value: ?*syntax.ast.Expr = null;
        var block: ?syntax.ast.Block = null;
        var end = name.span.end;

        if (self.match(.l_paren)) {
            while (!self.at(.r_paren) and !self.at(.eof)) {
                const start_token = self.peek();
                var label: ?[]const u8 = null;
                var arg_value: ?*syntax.ast.Expr = null;
                if (self.at(.identifier) and self.peekNext().kind == .colon) {
                    label = self.advance().lexeme;
                    _ = self.advance();
                    arg_value = try self.parseExpression();
                } else if (!self.at(.r_paren)) {
                    arg_value = try self.parseExpression();
                }
                try args.append(.{
                    .label = label,
                    .value = arg_value,
                    .span = source_pkg.Span.init(start_token.span.start, if (arg_value) |expr| exprSpan(expr.*).end else start_token.span.end),
                });
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_paren, "expected ')' after rule arguments", "close the rule arguments here");
            end = close.span.end;
        }

        if (self.match(.colon)) {
            type_expr = try self.parseTypeExpr();
            end = typeSpan(type_expr.?.*).end;
        }

        if (self.match(.equal)) {
            value = try self.parseExpression();
            end = exprSpan(value.?.*).end;
        }

        if (self.at(.l_brace)) {
            block = try self.parseBlock();
            end = block.?.span.end;
        } else {
            _ = try self.expect(.semicolon, "expected ';' after rule", "terminate the rule with ';'");
        }

        return .{
            .name = name,
            .args = try args.toOwnedSlice(),
            .type_expr = type_expr,
            .value = value,
            .block = block,
            .span = source_pkg.Span.init(name.span.start, end),
        };
    }

    fn parseBlock(self: *Parser) anyerror!syntax.ast.Block {
        const open = try self.expect(.l_brace, "expected '{' to start block", "open the block here");
        var statements = std.array_list.Managed(syntax.ast.Statement).init(self.allocator);
        var had_errors = false;

        while (!self.at(.r_brace) and !self.at(.eof)) {
            const statement = self.parseStatement() catch |err| switch (err) {
                error.DiagnosticsEmitted => blk: {
                    had_errors = true;
                    self.recoverToStatementBoundary();
                    break :blk null;
                },
                else => return err,
            };
            if (statement) |value| try statements.append(value);
        }

        const close = try self.expect(.r_brace, "expected '}' to close block", "block should end here");
        if (had_errors) return error.DiagnosticsEmitted;
        return .{
            .statements = try statements.toOwnedSlice(),
            .span = source_pkg.Span.init(open.span.start, close.span.end),
        };
    }

    fn parseStatement(self: *Parser) anyerror!?syntax.ast.Statement {
        const annotations = try self.parseAnnotations();
        if (self.at(.kw_let)) {
            const let_token = self.advance();
            const name_token = try self.expect(.identifier, "expected identifier after 'let'", "write the binding name here");
            var type_expr: ?*syntax.ast.TypeExpr = null;
            var value: ?*syntax.ast.Expr = null;
            var end = name_token.span.end;
            if (self.match(.colon)) type_expr = try self.parseTypeExpr();
            if (type_expr) |ty| end = typeSpan(ty.*).end;
            if (self.match(.equal)) {
                value = try self.parseExpression();
                end = exprSpan(value.?.*).end;
            }
            end = try self.consumeStatementTerminator(end, "expected ';' after let binding", "terminate the binding with ';'");
            return .{ .let_stmt = .{
                .annotations = annotations,
                .name = name_token.lexeme,
                .type_expr = type_expr,
                .value = value,
                .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else let_token.span.start, end),
            } };
        }
        if (self.match(.kw_return)) {
            const return_token = self.previous();
            var value: ?*syntax.ast.Expr = null;
            var end = return_token.span.end;
            if (!self.at(.semicolon) and !self.at(.r_brace) and !self.at(.eof)) {
                value = try self.parseExpression();
                end = exprSpan(value.?.*).end;
            }
            end = try self.consumeStatementTerminator(end, "expected ';' after return", "terminate the return statement with ';'");
            return .{ .return_stmt = .{
                .value = value,
                .span = source_pkg.Span.init(return_token.span.start, end),
            } };
        }
        if (self.match(.kw_if)) {
            return .{ .if_stmt = try self.finishIfStatement(self.previous().span.start) };
        }
        if (self.match(.kw_for)) {
            return .{ .for_stmt = try self.finishForStatement(self.previous().span.start) };
        }
        if (self.match(.kw_switch)) {
            return .{ .switch_stmt = try self.finishSwitchStatement(self.previous().span.start) };
        }

        const expr = try self.parseExpression();
        if (self.match(.equal)) {
            const value = try self.parseExpression();
            const end = try self.consumeStatementTerminator(exprSpan(value.*).end, "expected ';' after assignment", "terminate the assignment with ';'");
            return .{ .assign_stmt = .{
                .target = expr,
                .value = value,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, end),
            } };
        }
        const end = try self.consumeStatementTerminator(exprSpan(expr.*).end, "expected ';' after expression", "terminate the expression with ';'");
        return .{ .expr_stmt = .{
            .expr = expr,
            .span = source_pkg.Span.init(exprSpan(expr.*).start, end),
        } };
    }

    fn finishIfStatement(self: *Parser, start: usize) anyerror!syntax.ast.IfStatement {
        const condition = try self.parseExpression();
        const then_block = try self.parseBlock();
        var else_block: ?syntax.ast.Block = null;
        var end = then_block.span.end;
        if (self.match(.kw_else)) {
            else_block = try self.parseBlock();
            end = else_block.?.span.end;
        }
        return .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
            .span = source_pkg.Span.init(start, end),
        };
    }

    fn finishForStatement(self: *Parser, start: usize) anyerror!syntax.ast.ForStatement {
        const name_token = try self.expect(.identifier, "expected loop binding name", "write the loop variable name here");
        _ = try self.expect(.kw_in, "expected 'in' after loop binding", "use 'in' to introduce the iterable");
        const iterator = try self.parseExpression();
        const body = try self.parseBlock();
        return .{
            .binding_name = name_token.lexeme,
            .iterator = iterator,
            .body = body,
            .span = source_pkg.Span.init(start, body.span.end),
        };
    }

    fn finishSwitchStatement(self: *Parser, start: usize) anyerror!syntax.ast.SwitchStatement {
        const subject = try self.parseExpression();
        _ = try self.expect(.l_brace, "expected '{' to start switch body", "open the switch body here");
        var cases = std.array_list.Managed(syntax.ast.SwitchCase).init(self.allocator);
        var default_block: ?syntax.ast.Block = null;
        var end = start;

        while (!self.at(.r_brace) and !self.at(.eof)) {
            if (self.match(.kw_case)) {
                const pattern = try self.parseExpression();
                _ = self.match(.colon);
                const body = try self.parseBlock();
                end = body.span.end;
                try cases.append(.{
                    .pattern = pattern,
                    .body = body,
                    .span = source_pkg.Span.init(exprSpan(pattern.*).start, body.span.end),
                });
                continue;
            }
            if (self.match(.kw_default)) {
                _ = self.match(.colon);
                default_block = try self.parseBlock();
                end = default_block.?.span.end;
                continue;
            }
            try self.emitUnexpectedToken(
                "expected switch case",
                self.peek(),
                "expected 'case' or 'default' here",
                "Each switch body must contain `case` arms and optionally one `default` arm.",
            );
            return error.DiagnosticsEmitted;
        }

        const close = try self.expect(.r_brace, "expected '}' to close switch body", "switch body should end here");
        end = close.span.end;
        return .{
            .subject = subject,
            .cases = try cases.toOwnedSlice(),
            .default_block = default_block,
            .span = source_pkg.Span.init(start, end),
        };
    }

    fn parseBuilderBlock(self: *Parser) anyerror!syntax.ast.BuilderBlock {
        const open = try self.expect(.l_brace, "expected '{' to start builder block", "open the builder block here");
        var items = std.array_list.Managed(syntax.ast.BuilderItem).init(self.allocator);
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try items.append(try self.parseBuilderItem());
            _ = self.match(.semicolon);
        }
        const close = try self.expect(.r_brace, "expected '}' to close builder block", "builder block should end here");
        return .{
            .items = try items.toOwnedSlice(),
            .span = source_pkg.Span.init(open.span.start, close.span.end),
        };
    }

    fn parseBuilderItem(self: *Parser) anyerror!syntax.ast.BuilderItem {
        if (self.match(.kw_if)) {
            const start = self.previous().span.start;
            const condition = try self.parseExpression();
            const then_block = try self.parseBuilderBlock();
            var else_block: ?syntax.ast.BuilderBlock = null;
            var end = then_block.span.end;
            if (self.match(.kw_else)) {
                else_block = try self.parseBuilderBlock();
                end = else_block.?.span.end;
            }
            return .{ .if_item = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
                .span = source_pkg.Span.init(start, end),
            } };
        }
        if (self.match(.kw_for)) {
            const start = self.previous().span.start;
            const name_token = try self.expect(.identifier, "expected loop binding name", "write the loop variable name here");
            _ = try self.expect(.kw_in, "expected 'in' after loop binding", "use 'in' to introduce the iterable");
            const iterator = try self.parseExpression();
            const body = try self.parseBuilderBlock();
            return .{ .for_item = .{
                .binding_name = name_token.lexeme,
                .iterator = iterator,
                .body = body,
                .span = source_pkg.Span.init(start, body.span.end),
            } };
        }
        if (self.match(.kw_switch)) {
            const start = self.previous().span.start;
            const subject = try self.parseExpression();
            _ = try self.expect(.l_brace, "expected '{' to start switch builder", "open the switch builder here");
            var cases = std.array_list.Managed(syntax.ast.BuilderSwitchCase).init(self.allocator);
            var default_block: ?syntax.ast.BuilderBlock = null;
            var end = start;
            while (!self.at(.r_brace) and !self.at(.eof)) {
                if (self.match(.kw_case)) {
                    const pattern = try self.parseExpression();
                    _ = self.match(.colon);
                    const body = try self.parseBuilderBlock();
                    end = body.span.end;
                    try cases.append(.{
                        .pattern = pattern,
                        .body = body,
                        .span = source_pkg.Span.init(exprSpan(pattern.*).start, body.span.end),
                    });
                    continue;
                }
                if (self.match(.kw_default)) {
                    _ = self.match(.colon);
                    default_block = try self.parseBuilderBlock();
                    end = default_block.?.span.end;
                    continue;
                }
                try self.emitUnexpectedToken(
                    "expected switch builder case",
                    self.peek(),
                    "expected 'case' or 'default' here",
                    "Each switch builder must contain `case` arms and optionally one `default` arm.",
                );
                return error.DiagnosticsEmitted;
            }
            const close = try self.expect(.r_brace, "expected '}' to close switch builder", "switch builder should end here");
            end = close.span.end;
            return .{ .switch_item = .{
                .subject = subject,
                .cases = try cases.toOwnedSlice(),
                .default_block = default_block,
                .span = source_pkg.Span.init(start, end),
            } };
        }

        const expr = try self.parseExpression();
        return .{ .expr = .{
            .expr = expr,
            .span = exprSpan(expr.*),
        } };
    }

    fn parseTypeExpr(self: *Parser) anyerror!*syntax.ast.TypeExpr {
        if (self.match(.l_bracket)) {
            const start = self.previous().span.start;
            const element_type = try self.parseTypeExpr();
            const close = try self.expect(.r_bracket, "expected ']' after array type", "close the array type here");
            const node = try self.allocator.create(syntax.ast.TypeExpr);
            node.* = .{ .array = .{
                .element_type = element_type,
                .span = source_pkg.Span.init(start, close.span.end),
            } };
            return node;
        }

        const name = try self.parseQualifiedName("expected type name");
        const node = try self.allocator.create(syntax.ast.TypeExpr);
        node.* = .{ .named = name };
        return node;
    }

    fn parseExpression(self: *Parser) anyerror!*syntax.ast.Expr {
        return self.parseConditional();
    }

    fn parseConditional(self: *Parser) anyerror!*syntax.ast.Expr {
        const condition = try self.parseLogicalOr();
        if (!self.match(.question)) return condition;

        const then_expr = try self.parseExpression();
        _ = try self.expect(.colon, "expected ':' in conditional expression", "separate the true and false branches with ':'");
        const else_expr = try self.parseExpression();
        const node = try self.allocator.create(syntax.ast.Expr);
        node.* = .{ .conditional = .{
            .condition = condition,
            .then_expr = then_expr,
            .else_expr = else_expr,
            .span = source_pkg.Span.init(exprSpan(condition.*).start, exprSpan(else_expr.*).end),
        } };
        return node;
    }

    fn parseLogicalOr(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseLogicalAnd();
        while (self.match(.pipe_pipe)) {
            const operator = self.previous();
            const rhs = try self.parseLogicalAnd();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseLogicalAnd(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseEquality();
        while (self.match(.amp_amp)) {
            const operator = self.previous();
            const rhs = try self.parseEquality();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseEquality(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseComparison();
        while (self.match(.equal_equal) or self.match(.bang_equal)) {
            const operator = self.previous();
            const rhs = try self.parseComparison();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseComparison(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseTerm();
        while (self.match(.less) or self.match(.less_equal) or self.match(.greater) or self.match(.greater_equal)) {
            const operator = self.previous();
            const rhs = try self.parseTerm();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseTerm(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseFactor();
        while (self.match(.plus) or self.match(.minus)) {
            const operator = self.previous();
            const rhs = try self.parseFactor();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseFactor(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseUnary();
        while (self.match(.star) or self.match(.slash) or self.match(.percent)) {
            const operator = self.previous();
            const rhs = try self.parseUnary();
            expr = try self.makeBinaryExpr(operator, expr, rhs);
        }
        return expr;
    }

    fn parseUnary(self: *Parser) anyerror!*syntax.ast.Expr {
        if (self.match(.minus) or self.match(.bang)) {
            const operator = self.previous();
            const operand = try self.parseUnary();
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .unary = .{
                .op = switch (operator.kind) {
                    .minus => .negate,
                    .bang => .not,
                    else => unreachable,
                },
                .operand = operand,
                .span = source_pkg.Span.init(operator.span.start, exprSpan(operand.*).end),
            } };
            return node;
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.match(.dot)) {
                const member_token = try self.expect(.identifier, "expected member name after '.'", "write the member name here");
                const node = try self.allocator.create(syntax.ast.Expr);
                node.* = .{ .member = .{
                    .object = expr,
                    .member = member_token.lexeme,
                    .span = source_pkg.Span.init(exprSpan(expr.*).start, member_token.span.end),
                } };
                expr = node;
                continue;
            }
            if (self.match(.l_paren)) {
                var args = std.array_list.Managed(syntax.ast.CallArg).init(self.allocator);
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
                const close = try self.expect(.r_paren, "expected ')' after call arguments", "close the argument list here");
                var trailing_builder: ?syntax.ast.BuilderBlock = null;
                var end = close.span.end;
                if (self.at(.l_brace)) {
                    trailing_builder = try self.parseBuilderBlock();
                    end = trailing_builder.?.span.end;
                }
                const node = try self.allocator.create(syntax.ast.Expr);
                node.* = .{ .call = .{
                    .callee = expr,
                    .args = try args.toOwnedSlice(),
                    .trailing_builder = trailing_builder,
                    .span = source_pkg.Span.init(exprSpan(expr.*).start, end),
                } };
                expr = node;
                continue;
            }
            break;
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) anyerror!*syntax.ast.Expr {
        if (self.match(.integer)) {
            const token = self.previous();
            const value = std.fmt.parseInt(i64, token.lexeme, 10) catch {
                try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
                    .severity = .@"error",
                    .code = "KPAR003",
                    .title = "integer literal is out of range",
                    .message = "This integer literal does not fit in Kira's current 64-bit integer range.",
                    .labels = &.{
                        diagnostics.primaryLabel(token.span, "integer literal is too large"),
                    },
                    .help = "Use a smaller integer literal.",
                });
                return error.DiagnosticsEmitted;
            };
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .integer = .{ .value = value, .span = token.span } };
            return expr;
        }
        if (self.match(.float)) {
            const token = self.previous();
            const value = std.fmt.parseFloat(f64, token.lexeme) catch {
                try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
                    .severity = .@"error",
                    .code = "KPAR004",
                    .title = "invalid float literal",
                    .message = "This floating-point literal could not be parsed.",
                    .labels = &.{
                        diagnostics.primaryLabel(token.span, "invalid float literal"),
                    },
                    .help = "Use a literal such as `12.0`.",
                });
                return error.DiagnosticsEmitted;
            };
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .float = .{ .value = value, .span = token.span } };
            return expr;
        }
        if (self.match(.string)) {
            const token = self.previous();
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .string = .{ .value = token.lexeme, .span = token.span } };
            return expr;
        }
        if (self.match(.kw_true) or self.match(.kw_false)) {
            const token = self.previous();
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .bool = .{ .value = token.kind == .kw_true, .span = token.span } };
            return expr;
        }
        if (self.match(.identifier)) {
            const token = self.previous();
            const name = try self.makeSingleSegmentName(token);
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .identifier = .{
                .name = name,
                .span = token.span,
            } };
            return expr;
        }
        if (self.match(.l_paren)) {
            const expr = try self.parseExpression();
            _ = try self.expect(.r_paren, "expected ')' after grouped expression", "close the grouped expression here");
            return expr;
        }
        if (self.match(.l_bracket)) {
            const start = self.previous().span.start;
            var elements = std.array_list.Managed(*syntax.ast.Expr).init(self.allocator);
            while (!self.at(.r_bracket) and !self.at(.eof)) {
                try elements.append(try self.parseExpression());
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_bracket, "expected ']' after array literal", "close the array literal here");
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .array = .{
                .elements = try elements.toOwnedSlice(),
                .span = source_pkg.Span.init(start, close.span.end),
            } };
            return expr;
        }

        const token = self.peek();
        const detail = try std.fmt.allocPrint(
            self.allocator,
            "Kira expected an expression here, but found {s}.",
            .{tokenDescription(token.kind)},
        );
        try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = "KPAR002",
            .title = "expected expression",
            .message = detail,
            .labels = &.{
                diagnostics.primaryLabel(token.span, unexpectedTokenLabel(token.kind)),
            },
            .help = "Insert a literal, name, call, collection literal, or parenthesized expression.",
        });
        return error.DiagnosticsEmitted;
    }

    fn parseQualifiedName(self: *Parser, title: []const u8) !syntax.ast.QualifiedName {
        const first = try self.expect(.identifier, title, "write an identifier here");
        var segments = std.array_list.Managed(syntax.ast.NameSegment).init(self.allocator);
        try segments.append(.{ .text = first.lexeme, .span = first.span });
        var end = first.span.end;
        while (self.match(.dot)) {
            const next = try self.expect(.identifier, "expected identifier after '.'", "write an identifier here");
            try segments.append(.{ .text = next.lexeme, .span = next.span });
            end = next.span.end;
        }
        return .{
            .segments = try segments.toOwnedSlice(),
            .span = source_pkg.Span.init(first.span.start, end),
        };
    }

    fn makeSingleSegmentName(self: *Parser, token: syntax.Token) !syntax.ast.QualifiedName {
        const segments = try self.allocator.alloc(syntax.ast.NameSegment, 1);
        segments[0] = .{ .text = token.lexeme, .span = token.span };
        return .{
            .segments = segments,
            .span = token.span,
        };
    }

    fn makeBinaryExpr(self: *Parser, operator: syntax.Token, lhs: *syntax.ast.Expr, rhs: *syntax.ast.Expr) !*syntax.ast.Expr {
        const node = try self.allocator.create(syntax.ast.Expr);
        node.* = .{ .binary = .{
            .op = switch (operator.kind) {
                .plus => .add,
                .minus => .subtract,
                .star => .multiply,
                .slash => .divide,
                .percent => .modulo,
                .equal_equal => .equal,
                .bang_equal => .not_equal,
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
                .amp_amp => .logical_and,
                .pipe_pipe => .logical_or,
                else => unreachable,
            },
            .lhs = lhs,
            .rhs = rhs,
            .span = source_pkg.Span.init(exprSpan(lhs.*).start, exprSpan(rhs.*).end),
        } };
        return node;
    }

    fn consumeFieldTerminator(self: *Parser, fallback_end: usize) !usize {
        if (self.match(.semicolon)) return self.previous().span.end;
        if (self.at(.r_brace) or self.at(.eof) or self.at(.at_sign) or self.at(.kw_function) or self.at(.kw_let) or self.at(.kw_var) or self.at(.kw_static) or self.isLifecycleHookStart()) {
            return fallback_end;
        }
        if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "content") and self.peekNext().kind == .l_brace) return fallback_end;
        return (try self.expect(.semicolon, "expected ';' after field declaration", "terminate the field declaration with ';'")).span.end;
    }

    fn consumeStatementTerminator(self: *Parser, fallback_end: usize, title: []const u8, label_message: []const u8) !usize {
        if (self.match(.semicolon)) return self.previous().span.end;
        if (self.isStatementBoundary()) return fallback_end;
        return (try self.expect(.semicolon, title, label_message)).span.end;
    }

    fn isStatementBoundary(self: *Parser) bool {
        return self.at(.r_brace) or self.at(.eof) or self.at(.at_sign) or self.at(.kw_let) or self.at(.kw_return) or self.at(.kw_if) or self.at(.kw_for) or self.at(.kw_switch) or
            self.at(.identifier) or self.at(.integer) or self.at(.float) or self.at(.string) or self.at(.kw_true) or self.at(.kw_false) or self.at(.l_paren) or self.at(.l_bracket) or self.at(.bang) or self.at(.minus);
    }

    fn looksLikeConstructFormDecl(self: *Parser) bool {
        if (!self.at(.identifier)) return false;
        var cursor = self.index;
        cursor += 1;
        while (cursor + 1 < self.tokens.len and self.tokens[cursor].kind == .dot and self.tokens[cursor + 1].kind == .identifier) {
            cursor += 2;
        }
        return cursor + 1 < self.tokens.len and self.tokens[cursor].kind == .identifier and self.tokens[cursor + 1].kind == .l_paren;
    }

    fn isLifecycleHookStart(self: *Parser) bool {
        return self.at(.identifier) and self.peekNext().kind == .l_paren and
            (std.mem.eql(u8, self.peek().lexeme, "onAppear") or
                std.mem.eql(u8, self.peek().lexeme, "onDisappear") or
                std.mem.eql(u8, self.peek().lexeme, "onChange"));
    }

    fn expect(self: *Parser, kind: syntax.TokenKind, title: []const u8, label_message: []const u8) !syntax.Token {
        if (self.at(kind)) return self.advance();
        const actual = self.peek();
        const detail = try std.fmt.allocPrint(
            self.allocator,
            "Kira expected {s}, but found {s}.",
            .{ tokenDescription(kind), tokenDescription(actual.kind) },
        );
        try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = "KPAR001",
            .title = title,
            .message = detail,
            .labels = &.{
                diagnostics.primaryLabel(actual.span, label_message),
            },
            .help = expectedTokenHelp(kind),
        });
        return error.DiagnosticsEmitted;
    }

    fn emitUnexpectedToken(self: *Parser, title: []const u8, token: syntax.Token, label_message: []const u8, help: ?[]const u8) !void {
        const detail = try std.fmt.allocPrint(
            self.allocator,
            "Kira expected different syntax here, but found {s}.",
            .{tokenDescription(token.kind)},
        );
        try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = "KPAR005",
            .title = title,
            .message = detail,
            .labels = &.{
                diagnostics.primaryLabel(token.span, label_message),
            },
            .help = help,
        });
    }

    fn recoverToStatementBoundary(self: *Parser) void {
        if (self.at(.semicolon)) {
            _ = self.advance();
            return;
        }
        while (!self.at(.semicolon) and !self.at(.r_brace) and !self.at(.eof)) _ = self.advance();
        if (self.at(.semicolon)) _ = self.advance();
    }

    fn recoverToTopLevel(self: *Parser) void {
        if (!self.at(.eof)) _ = self.advance();
        while (!self.at(.eof) and !self.at(.kw_import) and !self.at(.kw_function) and !self.at(.kw_type) and !self.at(.kw_construct) and !self.at(.at_sign) and !self.looksLikeConstructFormDecl()) {
            _ = self.advance();
        }
    }

    fn match(self: *Parser, kind: syntax.TokenKind) bool {
        if (!self.at(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn at(self: *Parser, kind: syntax.TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn peek(self: *Parser) syntax.Token {
        return self.tokens[self.index];
    }

    fn peekNext(self: *Parser) syntax.Token {
        if (self.index + 1 >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.index + 1];
    }

    fn previous(self: *Parser) syntax.Token {
        return self.tokens[self.index - 1];
    }

    fn advance(self: *Parser) syntax.Token {
        const token = self.tokens[self.index];
        if (self.index < self.tokens.len - 1) self.index += 1;
        return token;
    }
};

fn exprSpan(expr: syntax.ast.Expr) source_pkg.Span {
    return switch (expr) {
        .integer => |node| node.span,
        .float => |node| node.span,
        .string => |node| node.span,
        .bool => |node| node.span,
        .identifier => |node| node.span,
        .array => |node| node.span,
        .unary => |node| node.span,
        .binary => |node| node.span,
        .conditional => |node| node.span,
        .member => |node| node.span,
        .call => |node| node.span,
    };
}

fn typeSpan(ty: syntax.ast.TypeExpr) source_pkg.Span {
    return switch (ty) {
        .named => |node| node.span,
        .array => |node| node.span,
    };
}

fn paramsEnd(params: []const syntax.ast.ParamDecl, fallback: usize) usize {
    if (params.len == 0) return fallback + 2;
    return params[params.len - 1].span.end + 1;
}

fn sectionKind(name: []const u8) syntax.ast.ConstructSectionKind {
    if (std.mem.eql(u8, name, "annotations")) return .annotations;
    if (std.mem.eql(u8, name, "modifiers")) return .modifiers;
    if (std.mem.eql(u8, name, "requires")) return .requires;
    if (std.mem.eql(u8, name, "lifecycle")) return .lifecycle;
    if (std.mem.eql(u8, name, "builder")) return .builder;
    if (std.mem.eql(u8, name, "representation")) return .representation;
    return .custom;
}

fn tokenDescription(kind: syntax.TokenKind) []const u8 {
    return switch (kind) {
        .eof => "the end of the file",
        .identifier => "an identifier",
        .integer => "an integer literal",
        .float => "a float literal",
        .string => "a string literal",
        .kw_construct => "'construct'",
        .kw_type => "'type'",
        .kw_function => "'function'",
        .kw_let => "'let'",
        .kw_var => "'var'",
        .kw_static => "'static'",
        .kw_return => "'return'",
        .kw_import => "'import'",
        .kw_as => "'as'",
        .kw_if => "'if'",
        .kw_else => "'else'",
        .kw_for => "'for'",
        .kw_in => "'in'",
        .kw_switch => "'switch'",
        .kw_case => "'case'",
        .kw_default => "'default'",
        .kw_true => "'true'",
        .kw_false => "'false'",
        .at_sign => "'@'",
        .l_paren => "'('",
        .r_paren => "')'",
        .l_brace => "'{'",
        .r_brace => "'}'",
        .l_bracket => "'['",
        .r_bracket => "']'",
        .semicolon => "';'",
        .comma => "','",
        .colon => "':'",
        .question => "'?'",
        .equal => "'='",
        .equal_equal => "'=='",
        .bang => "'!'",
        .bang_equal => "'!='",
        .amp_amp => "'&&'",
        .pipe_pipe => "'||'",
        .plus => "'+'",
        .minus => "'-'",
        .arrow => "'->'",
        .star => "'*'",
        .slash => "'/'",
        .percent => "'%'",
        .dot => "'.'",
        .less => "'<'",
        .less_equal => "'<='",
        .greater => "'>'",
        .greater_equal => "'>='",
    };
}

fn unexpectedTokenLabel(kind: syntax.TokenKind) []const u8 {
    return switch (kind) {
        .eof => "the file ends here",
        else => "unexpected token here",
    };
}

fn expectedTokenHelp(kind: syntax.TokenKind) ?[]const u8 {
    return switch (kind) {
        .semicolon => "Add ';' to end the current construct.",
        .r_brace => "Close the current block with '}'.",
        .r_paren => "Close the current list with ')'.",
        .r_bracket => "Close the array or array type with ']'.",
        .l_brace => "Start the block or body with '{'.",
        .l_paren => "Open the parameter or argument list with '('.",
        .identifier => "Insert a valid Kira identifier here.",
        else => null,
    };
}

fn parseSource(
    allocator: std.mem.Allocator,
    text: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const lexer = @import("kira_lexer");
    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    return parse(allocator, tokens, diags);
}

fn readRepoFileForTest(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

test "parses imports functions and construct declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parseSource(
        allocator,
        "import UI as Kit\n" ++
            "@Doc(\"demo\")\n" ++
            "construct Widget { annotations { @State; } requires { content; } lifecycle { onAppear() {} } }\n" ++
            "Widget Button(title: String) { @State let count: Int = 0; content { Text(title) } }\n" ++
            "@Main function entry(): Int { let x: Float = 12; print(x); return 0; }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.imports.len);
    try std.testing.expectEqual(@as(usize, 3), program.decls.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
}

test "parses builder control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const program = try parseSource(
        allocator,
        "Widget Screen() { content { if ready { Button() { Text(\"ok\") } } else { Text(\"wait\") } for item in items { Row(item) } switch mode { case current { Text(\"a\") } default { Text(\"b\") } } } }",
        &diags,
    );

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.decls.len);
}

test "parses the hybrid example corpus shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const source_text = try readRepoFileForTest(allocator, "examples/hybrid_roundtrip/main.kira");
    const program = try parseSource(allocator, source_text, &diags);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), program.functions.len);
    try std.testing.expectEqual(@as(usize, 3), program.decls.len);
}

test "parses the restored hello example with modern type syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const source_text = try readRepoFileForTest(allocator, "examples/hello/main.kira");
    const program = try parseSource(allocator, source_text, &diags);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 4), program.decls.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
}

test "reports malformed annotations as diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = parseSource(allocator, "@\nfunction main() { return; }", &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expect(diags.items.len >= 1);
    try std.testing.expectEqualStrings("expected annotation name after '@'", diags.items[0].title);
}

test "reports malformed function headers as diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = parseSource(allocator, "@Main\nfunction () { return; }", &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("expected function name", diags.items[0].title);
}

test "reports missing block delimiters as diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const result = parseSource(allocator, "@Main\nfunction main() { return;", &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("expected '}' to close block", diags.items[0].title);
}
