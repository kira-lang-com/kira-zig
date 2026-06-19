const std = @import("std");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;

pub fn parseParamList(self: *Parser) ![]syntax.ast.ParamDecl {
    _ = try self.expect(.l_paren, "expected '(' after name", "open the parameter list here");
    var params = std.array_list.Managed(syntax.ast.ParamDecl).init(self.allocator);

    while (!self.at(.r_paren) and !self.at(.eof)) {
        const annotations = try self.parseAnnotations();
        const name_token = try self.expect(.identifier, "expected parameter name", "write the parameter name here");
        var type_expr: ?*syntax.ast.TypeExpr = null;
        var default_value: ?*syntax.ast.Expr = null;
        var end = name_token.span.end;
        if (std.mem.eql(u8, name_token.lexeme, "_")) {
            const unlabeled_name = try self.expect(.identifier, "expected parameter name after '_'", "write the internal parameter name here");
            end = unlabeled_name.span.end;
            if (self.match(.colon)) {
                type_expr = try self.parseTypeExpr();
                end = typeSpan(type_expr.?.*).end;
            }
            if (self.match(.equal)) {
                default_value = try self.parseExpression();
                end = exprSpan(default_value.?.*).end;
            }
            try params.append(.{
                .annotations = annotations,
                .name = unlabeled_name.lexeme,
                .type_expr = type_expr,
                .default_value = default_value,
                .span = source_pkg.Span.init(name_token.span.start, end),
            });
            if (!self.match(.comma)) break;
            continue;
        }
        if (self.match(.colon)) {
            type_expr = try self.parseTypeExpr();
            end = typeSpan(type_expr.?.*).end;
        }
        if (self.match(.equal)) {
            default_value = try self.parseExpression();
            end = exprSpan(default_value.?.*).end;
        }
        try params.append(.{
            .annotations = annotations,
            .name = name_token.lexeme,
            .type_expr = type_expr,
            .default_value = default_value,
            .span = source_pkg.Span.init(name_token.span.start, end),
        });
        if (!self.match(.comma)) break;
    }

    _ = try self.expect(.r_paren, "expected ')' after parameters", "close the parameter list here");
    return params.toOwnedSlice();
}
