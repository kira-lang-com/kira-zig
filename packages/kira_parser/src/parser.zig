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

    fn parseProgram(self: *Parser) anyerror!syntax.ast.Program {
        var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(self.allocator);
        var had_errors = false;

        while (!self.at(.eof)) {
            const function_decl = self.parseFunctionDecl() catch |err| switch (err) {
                error.DiagnosticsEmitted => blk: {
                    had_errors = true;
                    self.recoverToTopLevel();
                    break :blk null;
                },
                else => return err,
            };
            if (function_decl) |value| {
                try functions.append(value);
            }
        }

        if (had_errors) return error.DiagnosticsEmitted;
        return .{ .functions = try functions.toOwnedSlice() };
    }

    fn parseFunctionDecl(self: *Parser) anyerror!?syntax.ast.FunctionDecl {
        const annotations = try self.parseAnnotations();
        const function_token = try self.expect(.kw_function, "expected 'function' to start a function", "function declarations start with 'function'");
        const name_token = try self.expect(.identifier, "expected function name", "name the function here");
        _ = try self.expect(.l_paren, "expected '(' after function name", "open the parameter list here");
        _ = try self.expect(.r_paren, "expected ')' after function name", "close the parameter list here");
        const body = try self.parseBlock();
        const start = if (annotations.len > 0) annotations[0].span.start else function_token.span.start;
        return .{
            .annotations = annotations,
            .name = name_token.lexeme,
            .body = body,
            .span = source_pkg.Span.init(start, body.span.end),
        };
    }

    fn parseAnnotations(self: *Parser) anyerror![]syntax.ast.Annotation {
        var annotations = std.array_list.Managed(syntax.ast.Annotation).init(self.allocator);
        while (self.match(.at_sign)) {
            const at_token = self.previous();
            const name_token = try self.expect(.identifier, "expected annotation name after '@'", "annotation name expected here");
            try annotations.append(.{
                .name = name_token.lexeme,
                .span = source_pkg.Span.init(at_token.span.start, name_token.span.end),
            });
        }
        return annotations.toOwnedSlice();
    }

    fn parseBlock(self: *Parser) anyerror!syntax.ast.Block {
        const open = try self.expect(.l_brace, "expected '{' to start a block", "open the block here");
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
            if (statement) |value| {
                try statements.append(value);
            }
        }

        const close = try self.expect(.r_brace, "expected '}' to close block", "block should end here");
        if (had_errors) return error.DiagnosticsEmitted;

        return .{
            .statements = try statements.toOwnedSlice(),
            .span = source_pkg.Span.init(open.span.start, close.span.end),
        };
    }

    fn parseStatement(self: *Parser) anyerror!?syntax.ast.Statement {
        if (self.match(.kw_let)) {
            const let_token = self.previous();
            const name = try self.expect(.identifier, "expected identifier after 'let'", "binding name expected here");
            _ = try self.expect(.equal, "expected '=' in let binding", "assignment should use '='");
            const expr = try self.parseExpression();
            const semicolon = try self.expect(.semicolon, "expected ';' after let binding", "terminate the binding with ';'");
            return .{ .let_stmt = .{
                .name = name.lexeme,
                .value = expr,
                .span = source_pkg.Span.init(let_token.span.start, semicolon.span.end),
            } };
        }
        if (self.match(.kw_return)) {
            const token = self.previous();
            const semicolon = try self.expect(.semicolon, "expected ';' after return", "terminate the return statement with ';'");
            return .{ .return_stmt = .{
                .span = source_pkg.Span.init(token.span.start, semicolon.span.end),
            } };
        }

        const expr = try self.parseExpression();
        const semicolon = try self.expect(.semicolon, "expected ';' after expression", "terminate the expression with ';'");
        return .{ .expr_stmt = .{
            .expr = expr,
            .span = source_pkg.Span.init(exprSpan(expr.*).start, semicolon.span.end),
        } };
    }

    fn parseExpression(self: *Parser) anyerror!*syntax.ast.Expr {
        return self.parseAddition();
    }

    fn parseAddition(self: *Parser) anyerror!*syntax.ast.Expr {
        var expr = try self.parsePrimary();
        while (self.match(.plus)) {
            const operator = self.previous();
            const rhs = try self.parsePrimary();
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .binary = .{
                .op = .add,
                .lhs = expr,
                .rhs = rhs,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, exprSpan(rhs.*).end),
            } };
            expr = node;
            _ = operator;
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
        if (self.match(.string)) {
            const token = self.previous();
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .string = .{ .value = token.lexeme, .span = token.span } };
            return expr;
        }
        if (self.match(.identifier)) {
            const token = self.previous();
            if (self.match(.l_paren)) {
                var args = std.array_list.Managed(*syntax.ast.Expr).init(self.allocator);
                if (!self.at(.r_paren)) {
                    while (true) {
                        try args.append(try self.parseExpression());
                        if (!self.match(.comma)) break;
                    }
                }
                const close = try self.expect(.r_paren, "expected ')' after call arguments", "close the argument list here");
                const expr = try self.allocator.create(syntax.ast.Expr);
                expr.* = .{ .call = .{
                    .callee = token.lexeme,
                    .args = try args.toOwnedSlice(),
                    .span = source_pkg.Span.init(token.span.start, close.span.end),
                } };
                return expr;
            }
            const expr = try self.allocator.create(syntax.ast.Expr);
            expr.* = .{ .identifier = .{ .name = token.lexeme, .span = token.span } };
            return expr;
        }
        if (self.match(.l_paren)) {
            const expr = try self.parseExpression();
            _ = try self.expect(.r_paren, "expected ')' after grouped expression", "close the grouped expression here");
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
            .help = "Insert a literal, name, or parenthesized expression.",
        });
        return error.DiagnosticsEmitted;
    }

    fn expect(self: *Parser, kind: syntax.TokenKind, title: []const u8, label_message: []const u8) anyerror!syntax.Token {
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

    fn recoverToStatementBoundary(self: *Parser) void {
        if (self.at(.semicolon)) {
            _ = self.advance();
            return;
        }
        while (!self.at(.semicolon) and !self.at(.r_brace) and !self.at(.eof)) {
            _ = self.advance();
        }
        if (self.at(.semicolon)) {
            _ = self.advance();
        }
    }

    fn recoverToTopLevel(self: *Parser) void {
        if (!self.at(.eof)) {
            _ = self.advance();
        }
        while (!self.at(.eof) and !self.at(.kw_function) and !self.at(.at_sign)) {
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
        .string => |node| node.span,
        .identifier => |node| node.span,
        .binary => |node| node.span,
        .call => |node| node.span,
    };
}

fn tokenDescription(kind: syntax.TokenKind) []const u8 {
    return switch (kind) {
        .eof => "the end of the file",
        .identifier => "an identifier",
        .integer => "an integer literal",
        .string => "a string literal",
        .kw_function => "'function'",
        .kw_let => "'let'",
        .kw_return => "'return'",
        .at_sign => "'@'",
        .l_paren => "'('",
        .r_paren => "')'",
        .l_brace => "'{'",
        .r_brace => "'}'",
        .semicolon => "';'",
        .comma => "','",
        .equal => "'='",
        .plus => "'+'",
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
        .semicolon => "Add ';' to end the statement.",
        .r_brace => "Close the block with '}'.",
        .r_paren => "Close the expression or argument list with ')'.",
        .l_brace => "Start the block with '{'.",
        .l_paren => "Open the parameter or argument list with '('.",
        .identifier => "Insert a valid Kira identifier here.",
        else => null,
    };
}

test "parses annotated main function and let statement" {
    const lexer = @import("kira_lexer");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", "@Main\nfunction main() { let x = 1 + 2; print(x); return; }");
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    const program = try parse(allocator, tokens, &diags);

    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions[0].annotations.len);
    try std.testing.expectEqualStrings("Main", program.functions[0].annotations[0].name);
    try std.testing.expectEqualStrings("main", program.functions[0].name);
    try std.testing.expectEqual(@as(usize, 3), program.functions[0].body.statements.len);
}

test "reports malformed expressions as diagnostics instead of crashing" {
    const lexer = @import("kira_lexer");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", "@Main\nfunction main() { let x = 1 + ; return; }");
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    const result = parse(allocator, tokens, &diags);

    try std.testing.expectError(error.DiagnosticsEmitted, result);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("expected expression", diags.items[0].title);
}
