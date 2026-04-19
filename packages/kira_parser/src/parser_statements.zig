const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;
const tokenDescription = parent.tokenDescription;
const unexpectedTokenLabel = parent.unexpectedTokenLabel;
const expectedTokenHelp = parent.expectedTokenHelp;
pub fn parseBlock(self: *Parser) anyerror!syntax.ast.Block {
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

pub fn parseStatement(self: *Parser) anyerror!?syntax.ast.Statement {
    const annotations = try self.parseAnnotations();
    if (self.at(.kw_let) or self.at(.kw_var)) {
        const storage_token = self.advance();
        const storage: syntax.ast.FieldStorage = if (storage_token.kind == .kw_var) .mutable else .immutable;
        const name_token = try self.expect(.identifier, "expected identifier after binding keyword", "write the binding name here");
        var type_expr: ?*syntax.ast.TypeExpr = null;
        var value: ?*syntax.ast.Expr = null;
        var end = name_token.span.end;
        if (self.match(.colon)) type_expr = try self.parseTypeExpr();
        if (type_expr) |ty| end = typeSpan(ty.*).end;
        if (self.match(.equal)) {
            value = try self.parseExpression();
            end = exprSpan(value.?.*).end;
        }
        end = try self.consumeStatementTerminator(end, "expected ';' after binding", "terminate the binding with ';'");
        return .{ .let_stmt = .{
            .annotations = annotations,
            .storage = storage,
            .name = name_token.lexeme,
            .type_expr = type_expr,
            .value = value,
            .span = source_pkg.Span.init(if (annotations.len > 0) annotations[0].span.start else storage_token.span.start, end),
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
    if (self.match(.kw_while)) {
        return .{ .while_stmt = try self.finishWhileStatement(self.previous().span.start) };
    }
    if (self.match(.kw_break)) {
        const token = self.previous();
        const end = try self.consumeStatementTerminator(token.span.end, "expected ';' after break", "terminate the break statement with ';'");
        return .{ .break_stmt = .{ .span = source_pkg.Span.init(token.span.start, end) } };
    }
    if (self.match(.kw_continue)) {
        const token = self.previous();
        const end = try self.consumeStatementTerminator(token.span.end, "expected ';' after continue", "terminate the continue statement with ';'");
        return .{ .continue_stmt = .{ .span = source_pkg.Span.init(token.span.start, end) } };
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

pub fn finishIfStatement(self: *Parser, start: usize) anyerror!syntax.ast.IfStatement {
    const condition = try self.parseExpressionWithoutTrailingBlockCall();
    const then_block = try self.parseBlock();
    var else_block: ?syntax.ast.Block = null;
    var end = then_block.span.end;
    if (self.match(.kw_else)) {
        if (self.match(.kw_if)) {
            const nested_if = try self.finishIfStatement(self.previous().span.start);
            const nested_statements = try self.allocator.alloc(syntax.ast.Statement, 1);
            nested_statements[0] = .{ .if_stmt = nested_if };
            else_block = .{
                .statements = nested_statements,
                .span = nested_if.span,
            };
        } else {
            else_block = try self.parseBlock();
        }
        end = else_block.?.span.end;
    }
    return .{
        .condition = condition,
        .then_block = then_block,
        .else_block = else_block,
        .span = source_pkg.Span.init(start, end),
    };
}

pub fn finishForStatement(self: *Parser, start: usize) anyerror!syntax.ast.ForStatement {
    const name_token = try self.expect(.identifier, "expected loop binding name", "write the loop variable name here");
    _ = try self.expect(.kw_in, "expected 'in' after loop binding", "use 'in' to introduce the iterable");
    const iterator = try self.parseExpressionWithoutTrailingBlockCall();
    const body = try self.parseBlock();
    return .{
        .binding_name = name_token.lexeme,
        .iterator = iterator,
        .body = body,
        .span = source_pkg.Span.init(start, body.span.end),
    };
}

pub fn finishWhileStatement(self: *Parser, start: usize) anyerror!syntax.ast.WhileStatement {
    const condition = try self.parseExpressionWithoutTrailingBlockCall();
    const body = try self.parseBlock();
    return .{
        .condition = condition,
        .body = body,
        .span = source_pkg.Span.init(start, body.span.end),
    };
}

pub fn finishSwitchStatement(self: *Parser, start: usize) anyerror!syntax.ast.SwitchStatement {
    const subject = try self.parseExpressionWithoutTrailingBlockCall();
    _ = try self.expect(.l_brace, "expected '{' to start switch body", "open the switch body here");
    var cases = std.array_list.Managed(syntax.ast.SwitchCase).init(self.allocator);
    var default_block: ?syntax.ast.Block = null;
    var end = start;

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (self.match(.kw_case)) {
            const pattern = try self.parseExpressionWithoutTrailingBlockCall();
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
