const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source = @import("kira_source");
const syntax = @import("kira_ksl_syntax_model");

pub fn parse(
    allocator: std.mem.Allocator,
    tokens: []const syntax.Token,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Module {
    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .diagnostics = out_diagnostics,
    };
    return parser.parseModule();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const syntax.Token,
    index: usize = 0,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),

    fn parseModule(self: *Parser) !syntax.ast.Module {
        var imports = std.array_list.Managed(syntax.ast.ImportDecl).init(self.allocator);
        var types = std.array_list.Managed(syntax.ast.TypeDecl).init(self.allocator);
        var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(self.allocator);
        var shaders = std.array_list.Managed(syntax.ast.ShaderDecl).init(self.allocator);

        while (!self.at(.eof)) {
            if (self.at(.kw_import)) {
                try imports.append(try self.parseImportDecl());
                continue;
            }
            if (self.at(.kw_type)) {
                try types.append(try self.parseTypeDecl());
                continue;
            }
            if (self.at(.kw_function)) {
                try functions.append(try self.parseFunctionDecl());
                continue;
            }
            if (self.at(.kw_shader)) {
                try shaders.append(try self.parseShaderDecl());
                continue;
            }
            return self.unexpected("expected a top-level KSL declaration", self.peek().span, "Use `import`, `type`, `function`, or `shader`.");
        }

        return .{
            .imports = try imports.toOwnedSlice(),
            .types = try types.toOwnedSlice(),
            .functions = try functions.toOwnedSlice(),
            .shaders = try shaders.toOwnedSlice(),
        };
    }

    fn parseImportDecl(self: *Parser) !syntax.ast.ImportDecl {
        const start = (try self.expect(.kw_import, "expected `import`")).span.start;
        const module_name = try self.parseQualifiedName();
        var alias: ?[]const u8 = null;
        var end = module_name.span.end;
        if (self.match(.kw_as)) {
            const alias_token = try self.expectNameToken("expected an import alias after `as`");
            alias = alias_token.lexeme;
            end = alias_token.span.end;
        }
        _ = self.match(.semicolon);
        return .{
            .module_name = module_name,
            .alias = alias,
            .span = source.Span.init(start, end),
        };
    }

    fn parseTypeDecl(self: *Parser) !syntax.ast.TypeDecl {
        const start = (try self.expect(.kw_type, "expected `type`")).span.start;
        const name_token = try self.expectNameToken("expected a type name");
        _ = try self.expect(.l_brace, "expected `{` after the type name");
        var fields = std.array_list.Managed(syntax.ast.TypeField).init(self.allocator);
        while (!self.at(.r_brace)) {
            const annotations = try self.parseAnnotations();
            const field_start = self.peek().span.start;
            _ = try self.expect(.kw_let, "type fields start with `let`");
            const field_name = try self.expectNameToken("expected a field name");
            _ = try self.expect(.colon, "expected `:` after the field name");
            const field_ty = try self.parseTypeRef();
            _ = self.match(.semicolon);
            try fields.append(.{
                .annotations = annotations,
                .name = field_name.lexeme,
                .ty = field_ty,
                .span = source.Span.init(field_start, syntax.ast.typeSpan(field_ty.*).end),
            });
        }
        const end = (try self.expect(.r_brace, "expected `}` after the type body")).span.end;
        return .{
            .name = name_token.lexeme,
            .fields = try fields.toOwnedSlice(),
            .span = source.Span.init(start, end),
        };
    }

    fn parseFunctionDecl(self: *Parser) !syntax.ast.FunctionDecl {
        const start = (try self.expect(.kw_function, "expected `function`")).span.start;
        const name_token = try self.expectNameToken("expected a function name");
        const params = try self.parseParamList();
        var return_type: ?*syntax.ast.TypeRef = null;
        if (self.match(.arrow)) return_type = try self.parseTypeRef();
        const body = try self.parseBlock();
        return .{
            .name = name_token.lexeme,
            .params = params,
            .return_type = return_type,
            .body = body,
            .span = source.Span.init(start, body.span.end),
        };
    }

    fn parseShaderDecl(self: *Parser) !syntax.ast.ShaderDecl {
        const start = (try self.expect(.kw_shader, "expected `shader`")).span.start;
        const name_token = try self.expectNameToken("expected a shader name");
        _ = try self.expect(.l_brace, "expected `{` after the shader name");

        var options = std.array_list.Managed(syntax.ast.OptionDecl).init(self.allocator);
        var groups = std.array_list.Managed(syntax.ast.GroupDecl).init(self.allocator);
        var stages = std.array_list.Managed(syntax.ast.StageDecl).init(self.allocator);

        while (!self.at(.r_brace)) {
            if (self.at(.kw_option)) {
                try options.append(try self.parseOptionDecl());
                continue;
            }
            if (self.at(.kw_group)) {
                try groups.append(try self.parseGroupDecl());
                continue;
            }
            if (self.at(.kw_vertex) or self.at(.kw_fragment) or self.at(.kw_compute)) {
                try stages.append(try self.parseStageDecl());
                continue;
            }
            return self.unexpected("expected a shader member", self.peek().span, "Use `option`, `group`, `vertex`, `fragment`, or `compute` inside a shader.");
        }

        const end = (try self.expect(.r_brace, "expected `}` after the shader body")).span.end;
        return .{
            .name = name_token.lexeme,
            .options = try options.toOwnedSlice(),
            .groups = try groups.toOwnedSlice(),
            .stages = try stages.toOwnedSlice(),
            .span = source.Span.init(start, end),
        };
    }

    fn parseOptionDecl(self: *Parser) !syntax.ast.OptionDecl {
        const start = (try self.expect(.kw_option, "expected `option`")).span.start;
        const name_token = try self.expectNameToken("expected an option name");
        _ = try self.expect(.colon, "expected `:` after the option name");
        const option_ty = try self.parseTypeRef();
        _ = try self.expect(.equal, "expected `=` after the option type");
        const default_value = try self.parseExpression();
        _ = self.match(.semicolon);
        return .{
            .name = name_token.lexeme,
            .ty = option_ty,
            .default_value = default_value,
            .span = source.Span.init(start, syntax.ast.exprSpan(default_value.*).end),
        };
    }

    fn parseGroupDecl(self: *Parser) !syntax.ast.GroupDecl {
        const start = (try self.expect(.kw_group, "expected `group`")).span.start;
        const name_token = try self.expectNameToken("expected a group name");
        _ = try self.expect(.l_brace, "expected `{` after the group name");

        var resources = std.array_list.Managed(syntax.ast.ResourceDecl).init(self.allocator);
        while (!self.at(.r_brace)) {
            try resources.append(try self.parseResourceDecl());
        }

        const end = (try self.expect(.r_brace, "expected `}` after the group body")).span.end;
        return .{
            .name = name_token.lexeme,
            .resources = try resources.toOwnedSlice(),
            .span = source.Span.init(start, end),
        };
    }

    fn parseResourceDecl(self: *Parser) !syntax.ast.ResourceDecl {
        const start = self.peek().span.start;
        var kind: syntax.ast.ResourceKind = undefined;
        var access: ?syntax.ast.AccessMode = null;
        if (self.match(.kw_uniform)) {
            kind = .uniform;
        } else if (self.match(.kw_storage)) {
            kind = .storage;
            if (self.match(.kw_read)) {
                access = .read;
            } else if (self.match(.kw_read_write)) {
                access = .read_write;
            } else {
                return self.unexpected("expected a storage access mode", self.peek().span, "Write `storage read` or `storage read_write`.");
            }
        } else if (self.match(.kw_texture)) {
            kind = .texture;
        } else if (self.match(.kw_sampler)) {
            kind = .sampler;
        } else {
            return self.unexpected("expected a resource declaration", self.peek().span, "Resources start with `uniform`, `storage`, `texture`, or `sampler`.");
        }

        const name_token = try self.expectNameToken("expected a resource name");
        _ = try self.expect(.colon, "expected `:` after the resource name");
        const resource_ty = try self.parseTypeRef();
        _ = self.match(.semicolon);
        return .{
            .kind = kind,
            .access = access,
            .name = name_token.lexeme,
            .ty = resource_ty,
            .span = source.Span.init(start, syntax.ast.typeSpan(resource_ty.*).end),
        };
    }

    fn parseStageDecl(self: *Parser) !syntax.ast.StageDecl {
        const stage_token = self.advance();
        const kind: syntax.ast.StageKind = switch (stage_token.kind) {
            .kw_vertex => .vertex,
            .kw_fragment => .fragment,
            .kw_compute => .compute,
            else => unreachable,
        };
        _ = try self.expect(.l_brace, "expected `{` after the stage keyword");

        var input_type: ?syntax.ast.QualifiedName = null;
        var output_type: ?syntax.ast.QualifiedName = null;
        var threads: ?syntax.ast.ThreadsDecl = null;
        var entry: ?syntax.ast.FunctionDecl = null;

        while (!self.at(.r_brace)) {
            if (self.match(.kw_input)) {
                input_type = try self.parseQualifiedName();
                _ = self.match(.semicolon);
                continue;
            }
            if (self.match(.kw_output)) {
                output_type = try self.parseQualifiedName();
                _ = self.match(.semicolon);
                continue;
            }
            if (self.match(.kw_threads)) {
                _ = try self.expect(.l_paren, "expected `(` after `threads`");
                const x = try self.parseExpression();
                _ = try self.expect(.comma, "expected `,` between thread counts");
                const y = try self.parseExpression();
                _ = try self.expect(.comma, "expected `,` between thread counts");
                const z = try self.parseExpression();
                const end_threads = (try self.expect(.r_paren, "expected `)` after the thread counts")).span.end;
                _ = self.match(.semicolon);
                threads = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .span = source.Span.init(stage_token.span.start, end_threads),
                };
                continue;
            }
            if (self.at(.kw_function)) {
                entry = try self.parseFunctionDecl();
                continue;
            }
            return self.unexpected("expected a stage member", self.peek().span, "Use `input`, `output`, `threads`, or the stage `function entry(...)`.");
        }

        const end = (try self.expect(.r_brace, "expected `}` after the stage body")).span.end;
        return .{
            .kind = kind,
            .input_type = input_type,
            .output_type = output_type,
            .threads = threads,
            .entry = entry orelse return self.unexpected("expected a stage entry function", source.Span.init(stage_token.span.start, end), "Add `function entry(...)` inside the stage."),
            .span = source.Span.init(stage_token.span.start, end),
        };
    }

    fn parseAnnotations(self: *Parser) ![]const syntax.ast.Annotation {
        var annotations = std.array_list.Managed(syntax.ast.Annotation).init(self.allocator);
        while (self.match(.at_sign)) {
            const start = self.previous().span.start;
            const name = try self.parseQualifiedName();
            var args = std.array_list.Managed(*syntax.ast.Expr).init(self.allocator);
            var end = name.span.end;
            if (self.match(.l_paren)) {
                if (!self.at(.r_paren)) {
                    while (true) {
                        try args.append(try self.parseExpression());
                        if (!self.match(.comma)) break;
                    }
                }
                end = (try self.expect(.r_paren, "expected `)` after annotation arguments")).span.end;
            }
            try annotations.append(.{
                .name = name,
                .args = try args.toOwnedSlice(),
                .span = source.Span.init(start, end),
            });
        }
        return annotations.toOwnedSlice();
    }

    fn parseParamList(self: *Parser) ![]const syntax.ast.ParamDecl {
        _ = try self.expect(.l_paren, "expected `(` after the function name");
        var params = std.array_list.Managed(syntax.ast.ParamDecl).init(self.allocator);
        if (!self.at(.r_paren)) {
            while (true) {
                const name_token = try self.expectNameToken("expected a parameter name");
                _ = try self.expect(.colon, "expected `:` after the parameter name");
                const param_ty = try self.parseTypeRef();
                try params.append(.{
                    .name = name_token.lexeme,
                    .ty = param_ty,
                    .span = source.Span.init(name_token.span.start, syntax.ast.typeSpan(param_ty.*).end),
                });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.r_paren, "expected `)` after the parameter list");
        return params.toOwnedSlice();
    }

    fn parseTypeRef(self: *Parser) !*syntax.ast.TypeRef {
        if (self.match(.l_bracket)) {
            const start = self.previous().span.start;
            const element = try self.parseTypeRef();
            const end = (try self.expect(.r_bracket, "expected `]` after the runtime array element type")).span.end;
            return self.allocType(.{
                .runtime_array = .{
                    .element = element,
                    .span = source.Span.init(start, end),
                },
            });
        }
        return self.allocType(.{ .named = try self.parseQualifiedName() });
    }

    fn parseBlock(self: *Parser) anyerror!syntax.ast.Block {
        const start = (try self.expect(.l_brace, "expected `{` to start a block")).span.start;
        var statements = std.array_list.Managed(syntax.ast.Statement).init(self.allocator);
        while (!self.at(.r_brace)) {
            try statements.append(try self.parseStatement());
        }
        const end = (try self.expect(.r_brace, "expected `}` after the block")).span.end;
        return .{
            .statements = try statements.toOwnedSlice(),
            .span = source.Span.init(start, end),
        };
    }

    fn parseStatement(self: *Parser) anyerror!syntax.ast.Statement {
        if (self.at(.kw_let)) return .{ .let_stmt = try self.parseLetStatement() };
        if (self.at(.kw_return)) return .{ .return_stmt = try self.parseReturnStatement() };
        if (self.at(.kw_if)) return .{ .if_stmt = try self.parseIfStatement() };

        const expr = try self.parseExpression();
        if (self.match(.equal)) {
            const value = try self.parseExpression();
            _ = self.match(.semicolon);
            return .{ .assign_stmt = .{
                .target = expr,
                .value = value,
                .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, syntax.ast.exprSpan(value.*).end),
            } };
        }
        _ = self.match(.semicolon);
        return .{ .expr_stmt = .{
            .expr = expr,
            .span = syntax.ast.exprSpan(expr.*),
        } };
    }

    fn parseLetStatement(self: *Parser) anyerror!syntax.ast.LetStatement {
        const start = (try self.expect(.kw_let, "expected `let`")).span.start;
        const name_token = try self.expect(.identifier, "expected a local name");
        var explicit_ty: ?*syntax.ast.TypeRef = null;
        if (self.match(.colon)) explicit_ty = try self.parseTypeRef();
        var value: ?*syntax.ast.Expr = null;
        var end = if (explicit_ty) |ty| syntax.ast.typeSpan(ty.*).end else name_token.span.end;
        if (self.match(.equal)) {
            value = try self.parseExpression();
            end = syntax.ast.exprSpan(value.?.*).end;
        }
        _ = self.match(.semicolon);
        return .{
            .name = name_token.lexeme,
            .ty = explicit_ty,
            .value = value,
            .span = source.Span.init(start, end),
        };
    }

    fn parseReturnStatement(self: *Parser) anyerror!syntax.ast.ReturnStatement {
        const start = (try self.expect(.kw_return, "expected `return`")).span.start;
        var value: ?*syntax.ast.Expr = null;
        var end = self.previous().span.end;
        if (!self.at(.r_brace) and !self.at(.semicolon)) {
            value = try self.parseExpression();
            end = syntax.ast.exprSpan(value.?.*).end;
        }
        _ = self.match(.semicolon);
        return .{
            .value = value,
            .span = source.Span.init(start, end),
        };
    }

    fn parseIfStatement(self: *Parser) anyerror!syntax.ast.IfStatement {
        const start = (try self.expect(.kw_if, "expected `if`")).span.start;
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
            .span = source.Span.init(start, end),
        };
    }

    fn parseExpression(self: *Parser) anyerror!*syntax.ast.Expr {
        return self.parseEquality();
    }

    fn parseEquality(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseComparison();
        while (self.match(.equal_equal) or self.match(.bang_equal)) {
            const op_token = self.previous();
            const right = try self.parseComparison();
            expr = try self.allocExpr(.{
                .binary = .{
                    .op = if (op_token.kind == .equal_equal) .equal else .not_equal,
                    .left = expr,
                    .right = right,
                    .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, syntax.ast.exprSpan(right.*).end),
                },
            });
        }
        return expr;
    }

    fn parseComparison(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseTerm();
        while (self.match(.less) or self.match(.less_equal) or self.match(.greater) or self.match(.greater_equal)) {
            const op_token = self.previous();
            const right = try self.parseTerm();
            const op: syntax.ast.BinaryOp = switch (op_token.kind) {
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
                else => unreachable,
            };
            expr = try self.allocExpr(.{
                .binary = .{
                    .op = op,
                    .left = expr,
                    .right = right,
                    .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, syntax.ast.exprSpan(right.*).end),
                },
            });
        }
        return expr;
    }

    fn parseTerm(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseFactor();
        while (self.match(.plus) or self.match(.minus)) {
            const op_token = self.previous();
            const right = try self.parseFactor();
            expr = try self.allocExpr(.{
                .binary = .{
                    .op = if (op_token.kind == .plus) .add else .sub,
                    .left = expr,
                    .right = right,
                    .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, syntax.ast.exprSpan(right.*).end),
                },
            });
        }
        return expr;
    }

    fn parseFactor(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parseUnary();
        while (self.match(.star) or self.match(.slash)) {
            const op_token = self.previous();
            const right = try self.parseUnary();
            expr = try self.allocExpr(.{
                .binary = .{
                    .op = if (op_token.kind == .star) .mul else .div,
                    .left = expr,
                    .right = right,
                    .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, syntax.ast.exprSpan(right.*).end),
                },
            });
        }
        return expr;
    }

    fn parseUnary(self: *Parser) anyerror!*syntax.ast.Expr {
        if (self.match(.minus) or self.match(.bang)) {
            const op_token = self.previous();
            const operand = try self.parseUnary();
            return self.allocExpr(.{
                .unary = .{
                    .op = if (op_token.kind == .minus) .neg else .not,
                    .operand = operand,
                    .span = source.Span.init(op_token.span.start, syntax.ast.exprSpan(operand.*).end),
                },
            });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parsePrimary();
        while (true) {
            if (self.match(.dot)) {
                const name_token = try self.expectNameToken("expected a field name after `.`");
                expr = try self.allocExpr(.{
                    .member = .{
                        .object = expr,
                        .name = name_token.lexeme,
                        .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, name_token.span.end),
                    },
                });
                continue;
            }
            if (self.match(.l_bracket)) {
                const index = try self.parseExpression();
                const end = (try self.expect(.r_bracket, "expected `]` after the index")).span.end;
                expr = try self.allocExpr(.{
                    .index = .{
                        .object = expr,
                        .index = index,
                        .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, end),
                    },
                });
                continue;
            }
            if (self.match(.l_paren)) {
                var args = std.array_list.Managed(*syntax.ast.Expr).init(self.allocator);
                if (!self.at(.r_paren)) {
                    while (true) {
                        try args.append(try self.parseExpression());
                        if (!self.match(.comma)) break;
                    }
                }
                const end = (try self.expect(.r_paren, "expected `)` after the argument list")).span.end;
                expr = try self.allocExpr(.{
                    .call = .{
                        .callee = expr,
                        .args = try args.toOwnedSlice(),
                        .span = source.Span.init(syntax.ast.exprSpan(expr.*).start, end),
                    },
                });
                continue;
            }
            break;
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) anyerror!*syntax.ast.Expr {
        if (self.match(.integer_literal)) {
            const token = self.previous();
            return self.allocExpr(.{ .integer = .{ .text = token.lexeme, .span = token.span } });
        }
        if (self.match(.float_literal)) {
            const token = self.previous();
            return self.allocExpr(.{ .float = .{ .text = token.lexeme, .span = token.span } });
        }
        if (self.match(.string_literal)) {
            const token = self.previous();
            return self.allocExpr(.{ .string = .{ .text = token.lexeme[1 .. token.lexeme.len - 1], .span = token.span } });
        }
        if (self.match(.kw_true) or self.match(.kw_false)) {
            const token = self.previous();
            return self.allocExpr(.{ .bool = .{ .value = token.kind == .kw_true, .span = token.span } });
        }
        if (isNameToken(self.peek().kind)) {
            const token = try self.expectNameToken("expected an identifier");
            const segments = try self.allocator.dupe(syntax.ast.NameSegment, &.{.{
                .text = token.lexeme,
                .span = token.span,
            }});
            const name: syntax.ast.QualifiedName = .{
                .segments = segments,
                .span = token.span,
            };
            return self.allocExpr(.{
                .identifier = .{
                    .name = name,
                    .span = name.span,
                },
            });
        }
        if (self.match(.l_paren)) {
            const expr = try self.parseExpression();
            _ = try self.expect(.r_paren, "expected `)` after the expression");
            return expr;
        }
        return self.unexpected("expected an expression", self.peek().span, "Write a value, identifier, or function call here.");
    }

    fn parseQualifiedName(self: *Parser) !syntax.ast.QualifiedName {
        var segments = std.array_list.Managed(syntax.ast.NameSegment).init(self.allocator);
        const first = try self.expectNameToken("expected an identifier");
        try segments.append(.{
            .text = first.lexeme,
            .span = first.span,
        });
        var end = first.span.end;
        while (self.match(.dot)) {
            const token = try self.expectNameToken("expected an identifier after `.`");
            try segments.append(.{
                .text = token.lexeme,
                .span = token.span,
            });
            end = token.span.end;
        }
        return .{
            .segments = try segments.toOwnedSlice(),
            .span = source.Span.init(first.span.start, end),
        };
    }

    fn allocExpr(self: *Parser, expr: syntax.ast.Expr) !*syntax.ast.Expr {
        const value = try self.allocator.create(syntax.ast.Expr);
        value.* = expr;
        return value;
    }

    fn allocType(self: *Parser, ty: syntax.ast.TypeRef) !*syntax.ast.TypeRef {
        const value = try self.allocator.create(syntax.ast.TypeRef);
        value.* = ty;
        return value;
    }

    fn expect(self: *Parser, kind: syntax.TokenKind, title: []const u8) !syntax.Token {
        if (!self.at(kind)) return self.unexpected(title, self.peek().span, "Adjust the syntax here.");
        return self.advance();
    }

    fn expectNameToken(self: *Parser, title: []const u8) !syntax.Token {
        if (!isNameToken(self.peek().kind)) return self.unexpected(title, self.peek().span, "Adjust the syntax here.");
        return self.advance();
    }

    fn unexpected(self: *Parser, title: []const u8, span: source.Span, help: []const u8) error{DiagnosticsEmitted} {
        diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = "KSLP010",
            .title = title,
            .message = title,
            .labels = &.{diagnostics.primaryLabel(span, "unexpected syntax here")},
            .help = help,
        }) catch {};
        return error.DiagnosticsEmitted;
    }

    fn at(self: *Parser, kind: syntax.TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn match(self: *Parser, kind: syntax.TokenKind) bool {
        if (!self.at(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn advance(self: *Parser) syntax.Token {
        const token = self.tokens[self.index];
        self.index += 1;
        return token;
    }

    fn previous(self: *Parser) syntax.Token {
        return self.tokens[self.index - 1];
    }

    fn peek(self: *Parser) syntax.Token {
        return self.tokens[self.index];
    }
};

fn isNameToken(kind: syntax.TokenKind) bool {
    return switch (kind) {
        .identifier,
        .kw_import,
        .kw_as,
        .kw_type,
        .kw_function,
        .kw_shader,
        .kw_option,
        .kw_group,
        .kw_uniform,
        .kw_storage,
        .kw_read,
        .kw_read_write,
        .kw_texture,
        .kw_sampler,
        .kw_vertex,
        .kw_fragment,
        .kw_compute,
        .kw_input,
        .kw_output,
        .kw_threads,
        .kw_let,
        .kw_if,
        .kw_else,
        .kw_return,
        => true,
        else => false,
    };
}

test "parser reads a minimal shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const source_file = try source.SourceFile.initOwned(allocator, "test.ksl",
        \\type VertexIn { let position: Float3 }
        \\type VertexOut { @builtin(position) let clip_position: Float4 }
        \\shader Demo {
        \\    vertex {
        \\        input VertexIn
        \\        output VertexOut
        \\        function entry(input: VertexIn) -> VertexOut {
        \\            let out: VertexOut
        \\            return out
        \\        }
        \\    }
        \\}
    );
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try @import("lexer.zig").tokenize(allocator, &source_file, &diags);
    const module = try parse(allocator, tokens, &diags);
    try std.testing.expectEqual(@as(usize, 2), module.types.len);
    try std.testing.expectEqual(@as(usize, 1), module.shaders.len);
}
