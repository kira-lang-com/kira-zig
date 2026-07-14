const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;
const exprSpan = parent.exprSpan;
const typeSpan = parent.typeSpan;
const cloneQualifiedName = Parser.cloneQualifiedName;
const tokenDescription = parent.tokenDescription;
const unexpectedTokenLabel = parent.unexpectedTokenLabel;
const expectedTokenHelp = parent.expectedTokenHelp;
const expr_core = @import("parser_types_exprs.zig");
const parseNativeStateBuiltin = expr_core.parseNativeStateBuiltin;
const parseNativeUserDataBuiltin = expr_core.parseNativeUserDataBuiltin;
const parseNativeStateFreeBuiltin = expr_core.parseNativeStateFreeBuiltin;
const parseNativeRecoverBuiltin = expr_core.parseNativeRecoverBuiltin;

pub fn parsePostfix(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parsePrimary();

    while (true) {
        // `name!(args)` — a macro call. The trailing `!` immediately before `(` distinguishes it
        // from an ordinary call; `callee` (an identifier) names the macro. The macro-expansion
        // pass replaces this node before semantics.
        if (self.at(.bang) and self.peekNext().kind == .l_paren) {
            _ = self.advance(); // '!'
            _ = self.advance(); // '('
            const outer_block_call = self.allow_trailing_block_call;
            self.allow_trailing_block_call = true;
            var macro_args = std.array_list.Managed(syntax.ast.CallArg).init(self.allocator);
            while (!self.at(.r_paren) and !self.at(.eof)) {
                const start_token = self.peek();
                const value = try self.parseExpression();
                try macro_args.append(.{
                    .label = null,
                    .value = value,
                    .span = source_pkg.Span.init(start_token.span.start, exprSpan(value.*).end),
                });
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_paren, "expected ')' after macro arguments", "close the macro argument list here");
            self.allow_trailing_block_call = outer_block_call;
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .call = .{
                .callee = expr,
                .args = try macro_args.toOwnedSlice(),
                .trailing_builder = null,
                .trailing_callback = null,
                .is_macro = true,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, close.span.end),
            } };
            expr = node;
            continue;
        }
        if (self.match(.dot)) {
            // `type` is a removed declaration keyword but stays legal as a MEMBER name so the
            // macro reflection API's `field.type` (docs/macros.md) parses.
            const member_token = if (self.at(.kw_type))
                self.advance()
            else
                try self.expect(.identifier, "expected member name after '.'", "write the member name here");
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .member = .{
                .object = expr,
                .member = member_token.lexeme,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, member_token.span.end),
            } };
            expr = node;
            continue;
        }
        if (self.match(.l_bracket)) {
            // `[ ... ]` is self-delimited; re-enable trailing-block parsing inside
            // it so a struct-literal index works even in a control-flow header.
            const outer_block_call = self.allow_trailing_block_call;
            self.allow_trailing_block_call = true;
            const index = try self.parseExpression();
            self.allow_trailing_block_call = outer_block_call;
            const close = try self.expect(.r_bracket, "expected ']' after index expression", "close the index expression here");
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .index = .{
                .object = expr,
                .index = index,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, close.span.end),
            } };
            expr = node;
            continue;
        }
        if (self.match(.l_paren)) {
            // Argument lists are delimited by parens, so the trailing-block
            // ambiguity that `allow_trailing_block_call` guards against cannot
            // arise here. Re-enable it while parsing arguments so nested
            // builder/callback calls still work even inside a control-flow
            // condition, then restore the outer setting to decide whether *this*
            // call may take a trailing block.
            const outer_block_call = self.allow_trailing_block_call;
            self.allow_trailing_block_call = true;
            var args = std.array_list.Managed(syntax.ast.CallArg).init(self.allocator);
            while (!self.at(.r_paren) and !self.at(.eof)) {
                const start_token = self.peek();
                var label: ?[]const u8 = null;
                if (self.at(.identifier) and (self.peekNext().kind == .colon or self.peekNext().kind == .equal)) {
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
            self.allow_trailing_block_call = outer_block_call;
            var trailing_builder: ?syntax.ast.BuilderBlock = null;
            var trailing_callback: ?syntax.ast.CallbackBlock = null;
            var end = close.span.end;
            // Only attach a trailing block when the current context permits it.
            // In a control-flow header (`if f(x) { ... }`) the `{` belongs to the
            // block, not to the call.
            if (self.allow_trailing_block_call and self.at(.l_brace)) {
                if (self.looksLikeCallbackBlock()) {
                    trailing_callback = try self.parseCallbackBlock();
                    end = trailing_callback.?.span.end;
                } else if (self.looksLikeCallbackBlockMissingIn()) {
                    trailing_callback = try self.parseCallbackBlock();
                    end = trailing_callback.?.span.end;
                } else {
                    trailing_builder = try self.parseBuilderBlock();
                    end = trailing_builder.?.span.end;
                }
            }
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .call = .{
                .callee = expr,
                .args = try args.toOwnedSlice(),
                .trailing_builder = trailing_builder,
                .trailing_callback = trailing_callback,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, end),
            } };
            expr = node;
            continue;
        }
        if (self.allow_trailing_block_call and self.at(.l_brace) and !self.looksLikeStructLiteral()) {
            var trailing_builder: ?syntax.ast.BuilderBlock = null;
            var trailing_callback: ?syntax.ast.CallbackBlock = null;
            var end: usize = exprSpan(expr.*).end;
            if (self.looksLikeCallbackBlock()) {
                trailing_callback = try self.parseCallbackBlock();
                end = trailing_callback.?.span.end;
            } else if (self.looksLikeCallbackBlockMissingIn()) {
                trailing_callback = try self.parseCallbackBlock();
                end = trailing_callback.?.span.end;
            } else {
                trailing_builder = try self.parseBuilderBlock();
                end = trailing_builder.?.span.end;
            }
            const node = try self.allocator.create(syntax.ast.Expr);
            node.* = .{ .call = .{
                .callee = expr,
                .args = &.{},
                .trailing_builder = trailing_builder,
                .trailing_callback = trailing_callback,
                .span = source_pkg.Span.init(exprSpan(expr.*).start, end),
            } };
            expr = node;
            continue;
        }
        // A trailing `{ ... }` is only a struct literal when the context permits
        // a trailing block. In a control-flow header (`if cond {}`, `while c {}`,
        // `for x in xs {}`, `match s {}`, `switch s {}`) the `{` opens the body,
        // not a struct literal — otherwise an empty body `{}` is misparsed as an
        // empty struct literal (KPAR013 / a misleading downstream error). A
        // struct literal that genuinely belongs in a condition must be
        // parenthesized (`if (Foo { x: 1 }).ok {}`); parens re-enable the flag.
        if (self.allow_trailing_block_call and self.at(.l_brace) and self.looksLikeStructLiteral()) {
            expr = try self.parseStructLiteral(expr);
            continue;
        }
        break;
    }

    return expr;
}

pub fn parsePrimary(self: *Parser) anyerror!*syntax.ast.Expr {
    if (self.at(.kw_quote)) {
        return self.parseQuoteExpr();
    }
    if (self.at(.l_brace) and self.looksLikeCallbackBlock()) {
        const expr = try self.allocator.create(syntax.ast.Expr);
        expr.* = .{ .callback = try self.parseCallbackBlock() };
        return expr;
    }
    // Content-block expression (`let header = { Text(...); child; For(...) { ... } }`).
    // A leading `{` in expression position that is NOT a closure (matched above:
    // `{ ident, ... in ... }` or the bare `{ in ... }`) is a content block whose
    // body is the exact trailing-builder-block grammar. It reuses the BuilderBlock
    // AST as a `builder_array` expression; downstream lowering infers the element
    // type from the annotation/receiving field. An empty `{}` is an empty content
    // block (the empty closure spells `{ in }`).
    if (self.at(.l_brace)) {
        const builder = try self.parseBuilderBlock();
        const expr = try self.allocator.create(syntax.ast.Expr);
        expr.* = .{ .builder_array = .{
            .builder = builder,
            .span = builder.span,
        } };
        return expr;
    }
    if (self.match(.dot)) {
        const start = self.previous().span.start;
        const member = try self.expect(.identifier, "expected implicit member name after '.'", "write the member name here");
        const expr = try self.allocator.create(syntax.ast.Expr);
        expr.* = .{ .implicit_member = .{
            .name = member.lexeme,
            .span = source_pkg.Span.init(start, member.span.end),
        } };
        return expr;
    }
    if (self.match(.integer)) {
        const token = self.previous();
        const value = parseIntegerLiteral(token.lexeme) catch {
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
        if (std.mem.eql(u8, token.lexeme, "nativeState") and self.at(.l_paren)) {
            return parseNativeStateBuiltin(self, token);
        }
        if (std.mem.eql(u8, token.lexeme, "nativeUserData") and self.at(.l_paren)) {
            return parseNativeUserDataBuiltin(self, token);
        }
        if (std.mem.eql(u8, token.lexeme, "nativeRecover") and self.at(.less)) {
            return parseNativeRecoverBuiltin(self, token);
        }
        if (std.mem.eql(u8, token.lexeme, "nativeStateFree") and self.at(.l_paren)) {
            return parseNativeStateFreeBuiltin(self, token);
        }
        return try self.makeIdentifierExpr(token);
    }
    if (self.match(.dollar)) {
        const start = self.previous().span.start;
        const token = try self.expect(.identifier, "expected binding name after '$'", "write the state or binding name to project here");
        const name = try self.makeSingleSegmentName(token);
        const expr = try self.allocator.create(syntax.ast.Expr);
        expr.* = .{ .identifier = .{
            .name = name,
            .span = source_pkg.Span.init(start, token.span.end),
        } };
        return expr;
    }
    if (self.match(.l_paren)) {
        // A parenthesized group is explicitly delimited, so trailing blocks are
        // unambiguous inside it even within a control-flow condition.
        const outer_block_call = self.allow_trailing_block_call;
        self.allow_trailing_block_call = true;
        const expr = try self.parseExpression();
        self.allow_trailing_block_call = outer_block_call;
        _ = try self.expect(.r_paren, "expected ')' after grouped expression", "close the grouped expression here");
        return expr;
    }
    if (self.match(.l_bracket)) {
        const start = self.previous().span.start;
        // `[ ... ]` is self-delimited, so the trailing-block ambiguity that
        // `allow_trailing_block_call` guards against in a control-flow header
        // cannot arise inside it. Re-enable it while parsing elements so a struct
        // literal element (`for p in [Foo { x: 1 }] {}`) still parses, then
        // restore the outer setting (same pattern as the `(` argument list).
        const outer_block_call = self.allow_trailing_block_call;
        self.allow_trailing_block_call = true;
        defer self.allow_trailing_block_call = outer_block_call;
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

fn parseIntegerLiteral(lexeme: []const u8) !i64 {
    if (lexeme.len > 2 and lexeme[0] == '0' and (lexeme[1] == 'x' or lexeme[1] == 'X')) {
        return std.fmt.parseInt(i64, lexeme[2..], 16);
    }
    return std.fmt.parseInt(i64, lexeme, 10);
}
