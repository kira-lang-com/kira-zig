const std = @import("std");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;

pub fn parseLifecycleHook(self: *Parser) !syntax.ast.LifecycleHook {
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

pub fn parseNamedRule(self: *Parser) !syntax.ast.NamedRule {
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
