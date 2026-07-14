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

fn isOwnershipUnaryOperandStart(kind: syntax.TokenKind) bool {
    return switch (kind) {
        .identifier,
        .integer,
        .float,
        .string,
        .kw_true,
        .kw_false,
        .minus,
        .bang,
        => true,
        else => false,
    };
}

fn looksLikeOwnershipUnary(self: *Parser) bool {
    if (!self.at(.identifier)) return false;
    const keyword = self.peek().lexeme;
    if (!(std.mem.eql(u8, keyword, "move") or std.mem.eql(u8, keyword, "copy"))) return false;
    return isOwnershipUnaryOperandStart(self.peekNext().kind);
}

pub fn parseTypeExpr(self: *Parser) anyerror!*syntax.ast.TypeExpr {
    if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "borrow")) {
        const start = self.advance().span.start;
        const mode: syntax.ast.OwnershipMode = if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "mut")) blk: {
            _ = self.advance();
            break :blk .borrow_mut;
        } else .borrow_read;
        const target = try self.parseTypeExpr();
        const node = try self.allocator.create(syntax.ast.TypeExpr);
        node.* = .{ .ownership = .{
            .mode = mode,
            .target = target,
            .span = source_pkg.Span.init(start, typeSpan(target.*).end),
        } };
        return node;
    }

    if (self.at(.identifier) and (std.mem.eql(u8, self.peek().lexeme, "move") or std.mem.eql(u8, self.peek().lexeme, "copy"))) {
        const token = self.advance();
        const target = try self.parseTypeExpr();
        const node = try self.allocator.create(syntax.ast.TypeExpr);
        node.* = .{ .ownership = .{
            .mode = if (std.mem.eql(u8, token.lexeme, "move")) .move else .copy,
            .target = target,
            .span = source_pkg.Span.init(token.span.start, typeSpan(target.*).end),
        } };
        return node;
    }

    if (self.at(.identifier) and (std.mem.eql(u8, self.peek().lexeme, "any") or std.mem.eql(u8, self.peek().lexeme, "some"))) {
        const existential = std.mem.eql(u8, self.peek().lexeme, "some");
        const start = self.advance().span.start;
        const target = try self.parseTypeExpr();
        const node = try self.allocator.create(syntax.ast.TypeExpr);
        node.* = .{ .any = .{
            .target = target,
            .span = source_pkg.Span.init(start, typeSpan(target.*).end),
            .existential = existential,
        } };
        return node;
    }

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

    if (self.match(.l_paren)) {
        const start = self.previous().span.start;
        var params = std.array_list.Managed(*syntax.ast.TypeExpr).init(self.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try params.append(try self.parseTypeExpr());
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.r_paren, "expected ')' after function type parameters", "close the function parameter type list here");
        _ = try self.expect(.arrow, "expected '->' in function type", "write `->` before the function result type");
        const result = try self.parseTypeExpr();
        const node = try self.allocator.create(syntax.ast.TypeExpr);
        node.* = .{ .function = .{
            .params = try params.toOwnedSlice(),
            .result = result,
            .span = source_pkg.Span.init(start, typeSpan(result.*).end),
        } };
        return node;
    }

    const name = try self.parseQualifiedName("expected type name");
    const node = try self.allocator.create(syntax.ast.TypeExpr);
    if (self.match(.less)) {
        var args = std.array_list.Managed(*syntax.ast.TypeExpr).init(self.allocator);
        while (!self.at(.greater) and !self.at(.eof)) {
            try args.append(try self.parseTypeExpr());
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.greater, "expected '>' after generic type arguments", "close the generic type argument list here");
        node.* = .{ .generic = .{
            .base = name,
            .args = try args.toOwnedSlice(),
            .span = source_pkg.Span.init(name.span.start, close.span.end),
        } };
    } else {
        node.* = .{ .named = name };
    }
    return node;
}

pub fn parseExpression(self: *Parser) anyerror!*syntax.ast.Expr {
    // Depth guard: every level of expression nesting (parens, call args, array /
    // struct literals, closures, match scrutinees) recurses through here, so one
    // bound here prevents the recursive-descent parser from overflowing the native
    // stack on pathologically deep input.
    self.expr_depth += 1;
    defer self.expr_depth -= 1;
    if (self.expr_depth > Parser.max_expr_depth) {
        const token = self.peek();
        const detail = try std.fmt.allocPrint(
            self.allocator,
            "Kira stopped parsing after {d} levels of nested expression to avoid a stack overflow.",
            .{Parser.max_expr_depth},
        );
        try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
            .severity = .@"error",
            .code = "KPAR014",
            .title = "expression nesting too deep",
            .message = detail,
            .labels = &.{
                diagnostics.primaryLabel(token.span, "expression nested too deeply here"),
            },
            .help = "Split this into smaller subexpressions or named `let` bindings.",
        });
        return error.DiagnosticsEmitted;
    }
    return self.parseConditional();
}

pub fn parseExpressionWithoutTrailingBlockCall(self: *Parser) anyerror!*syntax.ast.Expr {
    const previous_setting = self.allow_trailing_block_call;
    self.allow_trailing_block_call = false;
    defer self.allow_trailing_block_call = previous_setting;
    return self.parseExpression();
}

pub fn makeIdentifierExpr(self: *Parser, token: syntax.Token) !*syntax.ast.Expr {
    const name = try self.makeSingleSegmentName(token);
    const expr = try self.allocator.create(syntax.ast.Expr);
    expr.* = .{ .identifier = .{
        .name = name,
        .span = token.span,
    } };
    return expr;
}

pub fn parseNativeStateBuiltin(self: *Parser, token: syntax.Token) anyerror!*syntax.ast.Expr {
    _ = try self.expect(.l_paren, "expected '(' after nativeState", "open the native state expression here");
    const value = try self.parseExpression();
    const close = try self.expect(.r_paren, "expected ')' after nativeState value", "close the native state expression here");
    const expr = try self.allocator.create(syntax.ast.Expr);
    expr.* = .{ .native_state = .{
        .value = value,
        .span = source_pkg.Span.init(token.span.start, close.span.end),
    } };
    return expr;
}

pub fn parseNativeUserDataBuiltin(self: *Parser, token: syntax.Token) anyerror!*syntax.ast.Expr {
    _ = try self.expect(.l_paren, "expected '(' after nativeUserData", "open the native userdata expression here");
    const state = try self.parseExpression();
    const close = try self.expect(.r_paren, "expected ')' after nativeUserData value", "close the native userdata expression here");
    const expr = try self.allocator.create(syntax.ast.Expr);
    expr.* = .{ .native_user_data = .{
        .state = state,
        .span = source_pkg.Span.init(token.span.start, close.span.end),
    } };
    return expr;
}

pub fn parseNativeStateFreeBuiltin(self: *Parser, token: syntax.Token) anyerror!*syntax.ast.Expr {
    _ = try self.expect(.l_paren, "expected '(' after nativeStateFree", "open the native state free expression here");
    const state = try self.parseExpression();
    const close = try self.expect(.r_paren, "expected ')' after nativeStateFree value", "close the native state free expression here");
    const expr = try self.allocator.create(syntax.ast.Expr);
    expr.* = .{ .native_state_free = .{
        .state = state,
        .span = source_pkg.Span.init(token.span.start, close.span.end),
    } };
    return expr;
}

pub fn parseNativeRecoverBuiltin(self: *Parser, token: syntax.Token) anyerror!*syntax.ast.Expr {
    _ = try self.expect(.less, "expected '<' after nativeRecover", "write the recovered type here");
    const state_type = try self.parseTypeExpr();
    _ = try self.expect(.greater, "expected '>' after nativeRecover type", "close the recovered type here");
    _ = try self.expect(.l_paren, "expected '(' after nativeRecover type", "open the native recover expression here");
    const value = try self.parseExpression();
    const close = try self.expect(.r_paren, "expected ')' after nativeRecover value", "close the native recover expression here");
    const expr = try self.allocator.create(syntax.ast.Expr);
    expr.* = .{ .native_recover = .{
        .state_type = state_type,
        .value = value,
        .span = source_pkg.Span.init(token.span.start, close.span.end),
    } };
    return expr;
}

pub fn looksLikeStructLiteral(self: *Parser) bool {
    if (!self.at(.l_brace)) return false;
    const next = self.peekNext().kind;
    if (next == .r_brace) return true;
    if (next != .identifier) return false;
    // `Point { x: 1 }` (type-annotation colon) and `Point { x = 1 }` (the
    // Construct 2.0 canonical binder) both open a struct literal.
    const binder = self.peekAhead(2).kind;
    return binder == .colon or binder == .equal;
}

pub fn parseStructLiteral(self: *Parser, type_expr: *syntax.ast.Expr) anyerror!*syntax.ast.Expr {
    const type_name = try self.qualifiedNameFromExpr(type_expr);
    _ = try self.expect(.l_brace, "expected '{' to start struct literal", "open the struct literal here");
    var fields = std.array_list.Managed(syntax.ast.StructLiteralField).init(self.allocator);
    while (!self.at(.r_brace) and !self.at(.eof)) {
        const field_name = try self.expect(.identifier, "expected struct field name", "write the field name here");
        // Construct 2.0 `=` unification: `=` is the canonical binder for struct
        // fields (`Point { x = 1 }`); `:` stays accepted during the transition
        // window. Both normalize to the same StructLiteralField below.
        if (!(self.match(.equal) or self.match(.colon))) {
            _ = try self.expect(.equal, "expected '=' after field name", "use '=' between the field name and value");
        }
        const value = try self.parseExpression();
        try fields.append(.{
            .name = field_name.lexeme,
            .value = value,
            .span = source_pkg.Span.init(field_name.span.start, exprSpan(value.*).end),
        });
        _ = self.match(.comma);
        _ = self.match(.semicolon);
    }
    const close = try self.expect(.r_brace, "expected '}' after struct literal", "close the struct literal here");
    const node = try self.allocator.create(syntax.ast.Expr);
    node.* = .{ .struct_literal = .{
        .type_name = type_name,
        .fields = try fields.toOwnedSlice(),
        .span = source_pkg.Span.init(exprSpan(type_expr.*).start, close.span.end),
    } };
    return node;
}

pub fn qualifiedNameFromExpr(self: *Parser, expr: *syntax.ast.Expr) anyerror!syntax.ast.QualifiedName {
    return switch (expr.*) {
        .identifier => |node| cloneQualifiedName(self.allocator, node.name),
        .member => |node| blk: {
            const object_name = try self.qualifiedNameFromExpr(node.object);
            const segments = try self.allocator.alloc(syntax.ast.NameSegment, object_name.segments.len + 1);
            @memcpy(segments[0..object_name.segments.len], object_name.segments);
            segments[object_name.segments.len] = .{
                .text = node.member,
                .span = .{ .start = node.span.end - node.member.len, .end = node.span.end },
            };
            break :blk .{
                .segments = segments,
                .span = source_pkg.Span.init(object_name.span.start, node.span.end),
            };
        },
        else => {
            try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
                .severity = .@"error",
                .code = "KPAR013",
                .title = "struct literal requires a type name",
                .message = "Kira expected a named type before this struct literal.",
                .labels = &.{
                    diagnostics.primaryLabel(exprSpan(expr.*), "this expression is not a type name"),
                },
                .help = "Write a type name such as `Rect { width: 10.0 }`.",
            });
            return error.DiagnosticsEmitted;
        },
    };
}

pub fn parseConditional(self: *Parser) anyerror!*syntax.ast.Expr {
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

pub fn parseLogicalOr(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseLogicalAnd();
    while (self.match(.pipe_pipe)) {
        const operator = self.previous();
        const rhs = try self.parseLogicalAnd();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseLogicalAnd(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseBitOr();
    while (self.match(.amp_amp)) {
        const operator = self.previous();
        const rhs = try self.parseBitOr();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

// Bitwise precedence (C-style): `|` binds looser than `^`, which binds looser
// than `&`, all looser than equality. `move a & b` still parses as `(move a) & b`
// since bitwise sits above the unary/ownership level.
pub fn parseBitOr(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseBitXor();
    while (self.match(.pipe)) {
        const operator = self.previous();
        const rhs = try self.parseBitXor();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseBitXor(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseBitAnd();
    while (self.match(.caret)) {
        const operator = self.previous();
        const rhs = try self.parseBitAnd();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseBitAnd(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseEquality();
    while (self.match(.amp)) {
        const operator = self.previous();
        const rhs = try self.parseEquality();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseEquality(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseComparison();
    while (self.match(.equal_equal) or self.match(.bang_equal)) {
        const operator = self.previous();
        const rhs = try self.parseComparison();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseComparison(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseShift();
    while (self.match(.less) or self.match(.less_equal) or self.match(.greater) or self.match(.greater_equal)) {
        const operator = self.previous();
        const rhs = try self.parseShift();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

// Shifts bind tighter than comparison, looser than additive (`a + b << c` is
// `a + (b << c)`? No — additive is tighter, so `(a + b) << c`). Matches C.
pub fn parseShift(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseTerm();
    while (self.match(.less_less) or self.match(.greater_greater)) {
        const operator = self.previous();
        const rhs = try self.parseTerm();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseTerm(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseFactor();
    while (self.match(.plus) or self.match(.minus)) {
        const operator = self.previous();
        const rhs = try self.parseFactor();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseFactor(self: *Parser) anyerror!*syntax.ast.Expr {
    var expr = try self.parseUnary();
    while (self.match(.star) or self.match(.slash) or self.match(.percent)) {
        const operator = self.previous();
        const rhs = try self.parseUnary();
        expr = try self.makeBinaryExpr(operator, expr, rhs);
    }
    return expr;
}

pub fn parseUnary(self: *Parser) anyerror!*syntax.ast.Expr {
    if (self.match(.kw_try)) {
        const try_token = self.previous();
        const operand = try self.parseUnary();
        const node = try self.allocator.create(syntax.ast.Expr);
        node.* = .{ .try_expr = .{
            .operand = operand,
            .span = source_pkg.Span.init(try_token.span.start, exprSpan(operand.*).end),
        } };
        return node;
    }

    if (looksLikeOwnershipUnary(self)) {
        const token = self.advance();
        const operand = try self.parseUnary();
        const node = try self.allocator.create(syntax.ast.Expr);
        node.* = .{ .ownership = .{
            .op = if (std.mem.eql(u8, token.lexeme, "move")) .move else .copy,
            .operand = operand,
            .span = source_pkg.Span.init(token.span.start, exprSpan(operand.*).end),
        } };
        return node;
    }

    if (self.match(.minus) or self.match(.bang) or self.match(.tilde)) {
        const operator = self.previous();
        const operand = try self.parseUnary();
        const node = try self.allocator.create(syntax.ast.Expr);
        node.* = .{ .unary = .{
            .op = switch (operator.kind) {
                .minus => .negate,
                .bang => .not,
                .tilde => .bit_not,
                else => unreachable,
            },
            .operand = operand,
            .span = source_pkg.Span.init(operator.span.start, exprSpan(operand.*).end),
        } };
        return node;
    }
    return self.parsePostfix();
}
