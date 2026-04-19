const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const tokenDescription = parent.tokenDescription;
const unexpectedTokenLabel = parent.unexpectedTokenLabel;
const expectedTokenHelp = parent.expectedTokenHelp;
pub fn parseBuilderBlock(self: *Parser) anyerror!syntax.ast.BuilderBlock {
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

pub fn looksLikeCallbackBlock(self: *Parser) bool {
    if (!self.at(.l_brace)) return false;
    var lookahead = self.index + 1;
    if (lookahead >= self.tokens.len) return false;
    if (self.tokens[lookahead].kind == .kw_in) return true;
    if (self.tokens[lookahead].kind != .identifier) return false;
    while (lookahead < self.tokens.len and self.tokens[lookahead].kind == .identifier) {
        lookahead += 1;
        if (lookahead < self.tokens.len and self.tokens[lookahead].kind == .comma) {
            lookahead += 1;
            continue;
        }
        break;
    }
    return lookahead < self.tokens.len and self.tokens[lookahead].kind == .kw_in;
}

pub fn parseCallbackBlock(self: *Parser) anyerror!syntax.ast.CallbackBlock {
    const open = try self.expect(.l_brace, "expected '{' to start callback block", "open the callback block here");
    var params = std.array_list.Managed(syntax.ast.CallbackParam).init(self.allocator);

    if (!self.at(.kw_in)) {
        while (true) {
            const param = try self.expect(.identifier, "expected callback parameter name", "write the callback parameter name here");
            try params.append(.{
                .name = param.lexeme,
                .span = param.span,
            });
            if (!self.match(.comma)) break;
        }
    }

    _ = try self.expect(.kw_in, "expected 'in' after callback parameters", "separate the callback parameter list from the body with `in`");
    var statements = std.array_list.Managed(syntax.ast.Statement).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (try self.parseStatement()) |statement| try statements.append(statement);
    }
    const close = try self.expect(.r_brace, "expected '}' to close callback block", "callback block should end here");
    return .{
        .params = try params.toOwnedSlice(),
        .body = .{
            .statements = try statements.toOwnedSlice(),
            .span = source_pkg.Span.init(open.span.start, close.span.end),
        },
        .span = source_pkg.Span.init(open.span.start, close.span.end),
    };
}

pub fn parseBuilderItem(self: *Parser) anyerror!syntax.ast.BuilderItem {
    if (self.match(.kw_if)) {
        const start = self.previous().span.start;
        const condition = try self.parseExpressionWithoutTrailingBlockCall();
        const then_block = try self.parseBuilderBlock();
        var else_block: ?syntax.ast.BuilderBlock = null;
        var end = then_block.span.end;
        if (self.match(.kw_else)) {
            if (self.match(.kw_if)) {
                const nested_if = try self.parseBuilderIfItem(self.previous().span.start);
                const nested_items = try self.allocator.alloc(syntax.ast.BuilderItem, 1);
                nested_items[0] = .{ .if_item = nested_if };
                else_block = .{
                    .items = nested_items,
                    .span = nested_if.span,
                };
            } else {
                else_block = try self.parseBuilderBlock();
            }
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
        const iterator = try self.parseExpressionWithoutTrailingBlockCall();
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
        const subject = try self.parseExpressionWithoutTrailingBlockCall();
        _ = try self.expect(.l_brace, "expected '{' to start switch builder", "open the switch builder here");
        var cases = std.array_list.Managed(syntax.ast.BuilderSwitchCase).init(self.allocator);
        var default_block: ?syntax.ast.BuilderBlock = null;
        var end = start;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            if (self.match(.kw_case)) {
                const pattern = try self.parseExpressionWithoutTrailingBlockCall();
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

pub fn parseBuilderIfItem(self: *Parser, start: usize) anyerror!syntax.ast.BuilderIfItem {
    const condition = try self.parseExpressionWithoutTrailingBlockCall();
    const then_block = try self.parseBuilderBlock();
    var else_block: ?syntax.ast.BuilderBlock = null;
    var end = then_block.span.end;
    if (self.match(.kw_else)) {
        if (self.match(.kw_if)) {
            const nested_if = try self.parseBuilderIfItem(self.previous().span.start);
            const nested_items = try self.allocator.alloc(syntax.ast.BuilderItem, 1);
            nested_items[0] = .{ .if_item = nested_if };
            else_block = .{
                .items = nested_items,
                .span = nested_if.span,
            };
        } else {
            else_block = try self.parseBuilderBlock();
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
